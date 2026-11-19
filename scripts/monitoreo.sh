#!/bin/bash
# =====================================================================
#  monitoreo.sh — Verificación de salud y alertas (cada 5 minutos)
#   * Contenedores activos (primario y réplica)
#   * Reglas de monitoreo.fn_verificar_alertas() (conexiones, bloqueos,
#     replicación, archivado WAL, respaldos, particiones, negocio)
#   * Uso de disco de cada volumen
#   * Intentos de inicio de sesión fallidos (posible ataque de fuerza bruta)
#  Código de salida: 0 = OK, 1 = advertencias, 2 = críticas.
#  Las alertas CRÍTICAS se notifican al escritorio (notify-send) y quedan
#  en logs/monitoreo.log y en la tabla monitoreo.alerta.
# =====================================================================
source "$(dirname "$0")/lib.sh"

ALERTAS=()
agregar() { ALERTAS+=("$1|$2|$3"); }

for c in "$PRIMARIO" "$REPLICA"; do
  contenedor_activo "$c" || agregar CRITICO servidor "El contenedor $c está detenido"
done

if contenedor_activo "$PRIMARIO"; then
  # Reglas en la base de datos (usuario monitor, mínimo privilegio)
  while IFS='|' read -r nivel cat msg; do
    [[ -n "$nivel" ]] && agregar "$nivel" "$cat" "$msg"
  done < <(docker exec -e PGPASSWORD="$PASS_MONITOR" "$PRIMARIO" \
             psql -X -At -U monitor -d "$DB" -c "SELECT * FROM monitoreo.fn_verificar_alertas()" 2>&1 \
           || echo "CRITICO|servidor|No se pudo consultar la base de datos")

  # Disco
  while read -r uso punto; do
    uso=${uso%\%}
    (( uso >= 90 )) && agregar CRITICO espacio "Volumen $punto al ${uso}%"
    (( uso >= 80 && uso < 90 )) && agregar ADVERTENCIA espacio "Volumen $punto al ${uso}%"
  done < <(docker exec "$PRIMARIO" df -P /var/lib/postgresql /wal_archive /backups /ts/indices /ts/historico \
           | awk 'NR>1 {print $5, $6}')

  # Intentos fallidos de autenticación en el log del día
  LOGF=$(docker exec "$PRIMARIO" sh -c 'ls -1t $PGDATA/log/*.log 2>/dev/null | head -1')
  if [[ -n "$LOGF" ]]; then
    HOY=$(date +%F)
    FALLOS=$(docker exec "$PRIMARIO" sh -c "grep '^$HOY' '$LOGF' | grep -c 'password authentication failed'" || true)
    (( FALLOS > 5 )) && agregar ADVERTENCIA seguridad "$FALLOS intentos de autenticación fallidos hoy"
  fi
fi

MAX=0
{
  echo "[$(date '+%F %T')] Verificación de salud: ${#ALERTAS[@]} alerta(s)"
  for a in "${ALERTAS[@]}"; do
    IFS='|' read -r nivel cat msg <<<"$a"
    printf "  %-12s %-20s %s\n" "$nivel" "$cat" "$msg"
    [[ "$nivel" == "ADVERTENCIA" && $MAX -lt 1 ]] && MAX=1
    [[ "$nivel" == "CRITICO" ]] && MAX=2
  done
} | tee -a "$DIR_LOGS/monitoreo.log"
for a in "${ALERTAS[@]}"; do [[ "$a" == CRITICO* ]] && MAX=2; [[ "$a" == ADVERTENCIA* && $MAX -lt 1 ]] && MAX=1; done

if (( MAX == 2 )) && command -v notify-send >/dev/null; then
  notify-send -u critical "Hotel DB: alerta crítica" "$(printf '%s\n' "${ALERTAS[@]}" | grep '^CRITICO' | cut -d'|' -f3 | head -5)" || true
fi
exit $MAX
