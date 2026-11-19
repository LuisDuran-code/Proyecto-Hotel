# Imagen única para primario y réplica del Sistema de Administración Hotelera.
FROM postgres:18

# Directorios para tablespaces, respaldos físicos y archivado de WAL.
# Se crean con dueño postgres para que los volúmenes nombrados hereden los permisos.
RUN mkdir -p /ts/indices /ts/historico /backups /wal_archive \
 && chown -R postgres:postgres /ts /backups /wal_archive \
 && chmod 700 /ts/indices /ts/historico /backups /wal_archive

COPY postgresql.conf /etc/postgresql/postgresql.conf
COPY pg_hba.conf     /etc/postgresql/pg_hba.conf
COPY initdb/         /docker-entrypoint-initdb.d/
COPY replica-entrypoint.sh /usr/local/bin/replica-entrypoint.sh
RUN chmod 755 /usr/local/bin/replica-entrypoint.sh

CMD ["postgres", "-c", "config_file=/etc/postgresql/postgresql.conf"]
