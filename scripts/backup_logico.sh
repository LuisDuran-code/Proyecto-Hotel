#!/bin/bash
# =====================================================================
#  backup_logico.sh — Respaldo lógico diario (pg_dump, formato custom)
#   * Usuario de mínimo privilegio: backup_operador
#   * Excluye los datos de la clave de cifrado (se custodia en .env)
#   * Verifica el archivo, calcula SHA-256 y aplica retención:
#       diarios 7 días  |  el del día 1 de cada mes se conserva 6 meses
#  Programado: todos los días 02:00 (scripts/systemd o crontab.ejemplo)
# =====================================================================
source "$(dirname "$0")/lib.sh"

DESTINO="$DIR_BACKUPS/logico"; mkdir -p "$DESTINO/mensual"
FECHA=$(date +%Y%m%d_%H%M%S)
ARCHIVO="$DESTINO/hotel_$FECHA.dump"
INICIO=$(date '+%F %T%z')

log "Inicio de respaldo lógico -> $ARCHIVO"
if ! docker exec -e PGPASSWORD="$PASS_BACKUP" "$PRIMARIO" \
      pg_dump -U backup_operador -d "$DB" -Fc -Z 6 \
              --exclude-table-data=seguridad.clave_cifrado > "$ARCHIVO.tmp"; then
  rm -f "$ARCHIVO.tmp"
  registrar_backup logico "$INICIO" "$ARCHIVO" "" error "pg_dump falló"
  log "ERROR: pg_dump falló"; exit 1
fi
mv "$ARCHIVO.tmp" "$ARCHIVO"

# Objetos globales (roles y tablespaces, sin contraseñas)
docker exec -u postgres "$PRIMARIO" pg_dumpall --globals-only --no-role-passwords > "$DESTINO/globales_$FECHA.sql"

# Verificación: el catálogo del archivo debe poder leerse completo
if ! docker exec -i "$PRIMARIO" pg_restore --list < "$ARCHIVO" > /dev/null; then
  registrar_backup logico "$INICIO" "$ARCHIVO" "" error "Archivo corrupto (pg_restore --list)"
  log "ERROR: el archivo no es legible"; exit 1
fi
sha256sum "$ARCHIVO" > "$ARCHIVO.sha256"
TAM=$(stat -c %s "$ARCHIVO")

# Copia mensual
[[ "$(date +%d)" == "01" ]] && cp "$ARCHIVO" "$ARCHIVO.sha256" "$DESTINO/mensual/"

# Retención
find "$DESTINO" -maxdepth 1 -name 'hotel_*.dump*'   -mtime +7   -delete
find "$DESTINO" -maxdepth 1 -name 'globales_*.sql'  -mtime +7   -delete
find "$DESTINO/mensual"     -name 'hotel_*.dump*'   -mtime +183 -delete

registrar_backup logico "$INICIO" "$ARCHIVO" "$TAM" ok "sha256 $(cut -c1-16 "$ARCHIVO.sha256")"
log "Respaldo lógico OK ($(numfmt --to=iec "$TAM"))"
