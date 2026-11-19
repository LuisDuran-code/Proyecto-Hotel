#!/bin/bash
# =====================================================================
#  backup_fisico.sh — Respaldo físico semanal (pg_basebackup)
#   * Copia binaria completa del clúster + tablespaces, comprimida
#   * Junto con el archivado continuo de WAL permite PITR
#     (recuperar a cualquier instante, ver restaurar_pitr.sh)
#   * Retención: 2 respaldos; borra el WAL archivado anterior al más
#     antiguo conservado (pg_archivecleanup)
#  Programado: domingos 03:00
# =====================================================================
source "$(dirname "$0")/lib.sh"

NOMBRE="base_$(date +%Y%m%d_%H%M%S)"
INICIO=$(date '+%F %T%z')
log "Inicio de respaldo físico $NOMBRE"

if ! docker exec -u postgres -e PGPASSWORD="$PASS_REPLICADOR" "$PRIMARIO" \
     pg_basebackup -h localhost -U replicador -D "/backups/$NOMBRE" \
                   -Ft -z -X stream --checkpoint=fast -l "$NOMBRE" -c fast; then
  registrar_backup fisico "$INICIO" "$NOMBRE" "" error "pg_basebackup falló"
  log "ERROR: pg_basebackup falló"; exit 1
fi
docker exec -u postgres "$PRIMARIO" pg_verifybackup -n "/backups/$NOMBRE" >/dev/null 2>&1 \
  || docker exec -u postgres "$PRIMARIO" test -f "/backups/$NOMBRE/backup_manifest"

# Copia al host (fuera del servidor de base de datos)
mkdir -p "$DIR_BACKUPS/fisico"
docker cp -q "$PRIMARIO:/backups/$NOMBRE" "$DIR_BACKUPS/fisico/$NOMBRE"
TAM=$(du -sb "$DIR_BACKUPS/fisico/$NOMBRE" | cut -f1)

# Retención: conservar los 2 más recientes (en el contenedor y en el host)
for dir in $(docker exec "$PRIMARIO" sh -c 'ls -1d /backups/base_* 2>/dev/null' | sort -r | tail -n +3); do
  docker exec -u postgres "$PRIMARIO" rm -rf "$dir"
done
ls -1d "$DIR_BACKUPS"/fisico/base_* 2>/dev/null | sort -r | tail -n +3 | xargs -r rm -rf

# Limpieza de WAL: lo anterior al inicio del respaldo más antiguo conservado ya no sirve
MAS_ANTIGUO=$(docker exec "$PRIMARIO" sh -c 'ls -1d /backups/base_* | sort | head -1')
LSN=$(docker exec "$PRIMARIO" sh -c "grep -o '\"Start-LSN\": \"[^\"]*\"' $MAS_ANTIGUO/backup_manifest | head -1 | cut -d'\"' -f4")
SEGMENTO=$(psql_su -At -c "SELECT pg_walfile_name('$LSN')")
docker exec -u postgres "$PRIMARIO" pg_archivecleanup -x .gz /wal_archive "$SEGMENTO"

registrar_backup fisico "$INICIO" "$NOMBRE" "$TAM" ok "WAL conservado desde $SEGMENTO"
log "Respaldo físico OK ($(numfmt --to=iec "$TAM")); WAL limpiado hasta $SEGMENTO"
