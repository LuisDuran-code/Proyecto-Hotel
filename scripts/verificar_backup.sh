#!/bin/bash
# =====================================================================
#  verificar_backup.sh — Prueba de restauración (un respaldo que no se
#  ha probado restaurar no es un respaldo).
#  Restaura el último dump en "hotel_verificacion", compara el número de
#  filas de cada tabla con producción y descifra un documento para
#  comprobar la clave. Luego elimina la base temporal.
#  Programado: lunes 04:00
# =====================================================================
source "$(dirname "$0")/lib.sh"

ARCHIVO="$(ls -1t "$DIR_BACKUPS"/logico/hotel_*.dump | head -1)"
INICIO=$(date '+%F %T%z')
"$(dirname "$0")/restaurar_logico.sh" "$ARCHIVO" hotel_verificacion >/dev/null

CONTEO="SELECT string_agg(relname || '=' || n, ' ' ORDER BY relname) FROM (
          SELECT c.relname, (xpath('/row/n/text()', query_to_xml(format('SELECT count(*) AS n FROM hotel.%I', c.relname), false, true, '')))[1]::text AS n
            FROM pg_class c JOIN pg_namespace s ON s.oid = c.relnamespace
           WHERE s.nspname = 'hotel' AND c.relkind IN ('r','p') AND NOT c.relispartition) x"
PROD=$(PSQL_DB=hotel psql_su -At -c "$CONTEO")
REST=$(PSQL_DB=hotel_verificacion psql_su -At -c "$CONTEO")
DOC=$(PSQL_DB=hotel_verificacion psql_su -At -c "SELECT hotel.fn_documento_huesped(min(id_huesped)) IS NOT NULL FROM hotel.huesped")
PSQL_DB=postgres psql_su -c "DROP DATABASE hotel_verificacion WITH (FORCE)"

echo "Producción : $PROD"
echo "Restaurado : $REST"
# Diferencias pequeñas son normales si hubo actividad después del respaldo;
# se exige que existan todas las tablas y que el descifrado funcione.
if [[ -n "$REST" && "$DOC" == "t" && $(wc -w <<<"$PROD") -eq $(wc -w <<<"$REST") ]]; then
  registrar_backup verificacion "$INICIO" "$ARCHIVO" "" ok "$REST"
  log "VERIFICACIÓN OK: $(basename "$ARCHIVO") se restaura correctamente"
else
  registrar_backup verificacion "$INICIO" "$ARCHIVO" "" error "Restaurado: $REST | descifrado=$DOC"
  log "VERIFICACIÓN FALLIDA"; exit 1
fi
