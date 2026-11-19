#!/bin/bash
# Instala la base de datos "hotel" ejecutando, en orden, los scripts de /sql.
set -euo pipefail

psql_hotel() {
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "${POSTGRES_DB:-hotel}" \
       -v clave_cifrado="$HOTEL_CLAVE_CIFRADO" \
       -v pass_replicador="$PASS_REPLICADOR" \
       -v pass_backup="$PASS_BACKUP" \
       -v pass_monitor="$PASS_MONITOR" \
       -v pass_empleados="$PASS_EMPLEADOS" \
       "$@"
}

for f in /sql/0*.sql; do
  echo ">> Ejecutando $(basename "$f")"
  psql_hotel -f "$f"
done
