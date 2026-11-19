#!/bin/bash
# Funciones y variables comunes de los scripts de operación.
set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$RAIZ"
# shellcheck disable=SC1091
source "$RAIZ/.env"

PRIMARIO=${PRIMARIO:-hotel-primario}
REPLICA=${REPLICA:-hotel-replica}
DB=hotel
DIR_BACKUPS="$RAIZ/backups"
DIR_LOGS="$RAIZ/logs"
mkdir -p "$DIR_BACKUPS" "$DIR_LOGS"

log() { echo "[$(date '+%F %T')] $*"; }

# psql como superusuario dentro del contenedor (autenticación peer por socket)
psql_su() { docker exec -i -u postgres "$PRIMARIO" psql -X -q -v ON_ERROR_STOP=1 -d "${PSQL_DB:-$DB}" "$@"; }

# registrar_backup tipo inicio archivo tamaño estado detalle
registrar_backup() {
  psql_su -c "INSERT INTO monitoreo.registro_backup (tipo, inicio, fin, archivo, tamano, estado, detalle)
              VALUES ('$1', '$2', now(), NULLIF('$3',''), NULLIF('$4','')::bigint, '$5', NULLIF(\$\$$6\$\$,''))" \
    || log "ADVERTENCIA: no se pudo registrar el respaldo en monitoreo.registro_backup"
}

contenedor_activo() { [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]]; }
