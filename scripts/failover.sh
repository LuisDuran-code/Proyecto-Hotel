#!/bin/bash
# =====================================================================
#  failover.sh — Alta disponibilidad: conmutación por falla
#
#   ./scripts/failover.sh estado                 Muestra el rol de cada servidor
#   ./scripts/failover.sh promover [--forzar]    Promueve la réplica a primario
#   ./scripts/failover.sh reconstruir-replica    Re-clona la réplica desde el primario
#
#  Promover con el primario vivo provoca "cerebro dividido" (dos servidores
#  aceptando escrituras): solo se permite con --forzar (simulacros).
# =====================================================================
source "$(dirname "$0")/lib.sh"

rol() {
  contenedor_activo "$1" || { echo "DETENIDO"; return; }
  docker exec -u postgres "$1" psql -X -At -d hotel -c \
    "SELECT CASE WHEN pg_is_in_recovery() THEN 'RÉPLICA (solo lectura)' ELSE 'PRIMARIO (lectura/escritura)' END" 2>/dev/null \
    || echo "NO RESPONDE"
}

estado() {
  echo "  $PRIMARIO (puerto 5433): $(rol "$PRIMARIO")"
  echo "  $REPLICA  (puerto 5434): $(rol "$REPLICA")"
  contenedor_activo "$PRIMARIO" && psql_su -c "SELECT * FROM monitoreo.vw_replicacion" 2>/dev/null || true
}

case "${1:-estado}" in
  estado) estado ;;
  promover)
    if contenedor_activo "$PRIMARIO" && [[ "${2:-}" != "--forzar" ]]; then
      echo "El primario sigue activo. Deténgalo primero (docker stop $PRIMARIO) o use --forzar en un simulacro."; exit 1
    fi
    log "Promoviendo $REPLICA a primario..."
    docker exec -u postgres "$REPLICA" psql -X -At -c "SELECT pg_promote(wait => true)"
    estado
    echo
    echo "Siguiente paso: apuntar la aplicación al puerto 5434 (host hotel-replica)."
    echo "Cuando el servidor original se repare, ver docs/plan-mantenimiento.md §6 (failback con pg_rewind)."
    ;;
  reconstruir-replica)
    log "Reconstruyendo la réplica desde $PRIMARIO"
    docker compose rm -sf replica
    docker volume rm -f hotel_pgdata_replica hotel_ts_indices_replica hotel_ts_historico_replica >/dev/null
    docker compose up -d replica
    for _ in $(seq 1 45); do
      [[ "$(rol "$REPLICA")" == RÉPLICA* ]] && break; sleep 2
    done
    estado ;;
  *) echo "Uso: $0 estado | promover [--forzar] | reconstruir-replica"; exit 1 ;;
esac
