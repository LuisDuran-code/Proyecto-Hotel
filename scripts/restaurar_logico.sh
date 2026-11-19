#!/bin/bash
# =====================================================================
#  restaurar_logico.sh — Restaura un respaldo lógico en una base nueva
#     ./scripts/restaurar_logico.sh [archivo.dump] [base_destino]
#  Por defecto usa el respaldo más reciente y crea "hotel_restaurada".
#  Nunca sobrescribe la base "hotel": para reemplazarla, verificar la
#  restaurada y luego renombrar (ALTER DATABASE ... RENAME TO ...).
# =====================================================================
source "$(dirname "$0")/lib.sh"

ARCHIVO="${1:-$(ls -1t "$DIR_BACKUPS"/logico/hotel_*.dump | head -1)}"
DESTINO="${2:-hotel_restaurada}"
[[ "$DESTINO" == "hotel" ]] && { echo "Por seguridad no se restaura sobre 'hotel'"; exit 1; }
[[ -f "$ARCHIVO" ]] || { echo "No existe $ARCHIVO"; exit 1; }
INICIO=$(date '+%F %T%z')

if [[ -f "$ARCHIVO.sha256" ]] && ! sha256sum -c --quiet "$ARCHIVO.sha256"; then
  echo "ERROR: el SHA-256 no coincide, el respaldo está alterado o dañado"; exit 1
fi

log "Restaurando $(basename "$ARCHIVO") en la base '$DESTINO'"
PSQL_DB=postgres psql_su -c "DROP DATABASE IF EXISTS $DESTINO WITH (FORCE)" -c "CREATE DATABASE $DESTINO"
docker exec -i -u postgres "$PRIMARIO" pg_restore -d "$DESTINO" --exit-on-error -j 1 < "$ARCHIVO"

# La clave de cifrado no viaja en el respaldo: se repone desde .env
PSQL_DB=$DESTINO psql_su -v clave="$HOTEL_CLAVE_CIFRADO" <<SQL
ALTER DATABASE $DESTINO SET search_path = hotel, public;
INSERT INTO seguridad.clave_cifrado (clave) VALUES (:'clave')
    ON CONFLICT (id) DO UPDATE SET clave = EXCLUDED.clave;
SQL

registrar_backup restauracion "$INICIO" "$ARCHIVO" "" ok "restaurado en $DESTINO"
log "Restauración completada en '$DESTINO'"
