#!/bin/bash
# Arranque del servidor réplica (hot standby).
# Si el directorio de datos está vacío, clona el primario con pg_basebackup
# y queda en modo standby con replicación en streaming.
set -euo pipefail

PGDATA="${PGDATA:-/var/lib/postgresql/18/docker}"

if [[ "$(id -u)" == "0" ]]; then
  mkdir -p "$PGDATA" && chown -R postgres:postgres "$(dirname "$PGDATA")" /ts
  chmod 700 "$PGDATA"
  exec gosu postgres "$0" "$@"
fi

if [[ ! -s "$PGDATA/PG_VERSION" ]]; then
  echo ">> Esperando al primario ${PRIMARY_HOST}..."
  until pg_isready -h "$PRIMARY_HOST" -p 5432 -q; do sleep 2; done
  sleep 3

  echo ">> Clonando el primario con pg_basebackup"
  export PGPASSWORD="$PASS_REPLICADOR"
  # -R escribe standby.signal y primary_conninfo; -C/-S crea un slot de replicación
  pg_basebackup -h "$PRIMARY_HOST" -U replicador -D "$PGDATA" \
      -X stream -R -C -S slot_replica --checkpoint=fast --progress \
      -d "sslmode=require" \
    || pg_basebackup -h "$PRIMARY_HOST" -U replicador -D "$PGDATA" \
      -X stream -R -S slot_replica --checkpoint=fast -d "sslmode=require"
  chmod 700 "$PGDATA"

  # Respaldo: si el streaming se corta, la réplica recupera WAL del archivo compartido
  echo "restore_command = 'gunzip -c /wal_archive/%f.gz > %p'" >> "$PGDATA/postgresql.auto.conf"
  echo ">> Réplica inicializada"
fi

exec postgres -c config_file=/etc/postgresql/postgresql.conf \
              -c archive_mode=off "$@"
