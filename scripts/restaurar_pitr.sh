#!/bin/bash
# =====================================================================
#  restaurar_pitr.sh — Recuperación a un punto en el tiempo (PITR)
#     ./scripts/restaurar_pitr.sh "2026-11-18 17:50:00" [base_xxx]
#
#  Levanta un servidor TEMPORAL (contenedor hotel-pitr, puerto 5435) a
#  partir del último respaldo físico y reaplica el WAL archivado hasta el
#  instante indicado. Producción no se toca: desde el servidor temporal
#  se extraen los datos perdidos (pg_dump -t / COPY) y se reinsertan.
#  Caso de uso: borrado o actualización accidental a una hora conocida.
#  Detener al terminar:  docker rm -f hotel-pitr
# =====================================================================
source "$(dirname "$0")/lib.sh"

OBJETIVO="${1:?Uso: restaurar_pitr.sh 'AAAA-MM-DD HH:MM:SS' [base_xxx]}"
BASE="${2:-$(docker exec "$PRIMARIO" sh -c 'ls -1d /backups/base_* | sort | tail -1 | xargs basename')}"
PROYECTO=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$PRIMARIO")

# Forzar el archivado del segmento WAL actual para incluir los últimos cambios
psql_su -At -c "SELECT pg_switch_wal()" >/dev/null && sleep 2

log "PITR: respaldo $BASE  ->  objetivo '$OBJETIVO'"
docker rm -f hotel-pitr >/dev/null 2>&1 || true
docker run -d --name hotel-pitr -p 5435:5432 -e TZ=America/El_Salvador \
  -v "${PROYECTO}_backups:/backups:ro" -v "${PROYECTO}_wal_archive:/wal_archive:ro" \
  --entrypoint bash hotel-postgres:18 -c "
set -e
B=/backups/$BASE; PGDATA=/var/lib/postgresql/18/docker
mkdir -p \$PGDATA/pg_wal
tar xzf \$B/base.tar.gz   -C \$PGDATA
tar xzf \$B/pg_wal.tar.gz -C \$PGDATA/pg_wal
while read -r oid ruta; do mkdir -p \$ruta; tar xzf \$B/\$oid.tar.gz -C \$ruta; done < \$PGDATA/tablespace_map
cat >> \$PGDATA/postgresql.auto.conf <<CONF
restore_command = 'gunzip -c /wal_archive/%f.gz > %p'
recovery_target_time = '$OBJETIVO'
recovery_target_action = 'promote'
CONF
touch \$PGDATA/recovery.signal
chown -R postgres:postgres /var/lib/postgresql /ts && chmod 700 \$PGDATA
exec gosu postgres postgres -c config_file=/etc/postgresql/postgresql.conf -c archive_mode=off \
     -c logging_collector=off
" >/dev/null

for _ in $(seq 1 60); do
  if docker exec -u postgres hotel-pitr psql -X -At -d hotel -c "SELECT NOT pg_is_in_recovery()" 2>/dev/null | grep -q t; then
    log "Servidor PITR listo en el puerto 5435 (estado al $OBJETIVO)"
    docker logs hotel-pitr 2>&1 | grep -E "recovery stopping|archive recovery complete|selected new timeline" | sed 's/^/    /'
    echo "  Consultar:  docker exec -it -u postgres hotel-pitr psql -d hotel"
    echo "  Eliminar :  docker rm -f hotel-pitr"
    exit 0
  fi
  sleep 2
done
log "ERROR: la recuperación no terminó; revisar 'docker logs hotel-pitr'"; docker logs hotel-pitr 2>&1 | tail -15; exit 1
