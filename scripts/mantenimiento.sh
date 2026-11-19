#!/bin/bash
# =====================================================================
#  mantenimiento.sh — Tareas periódicas de mantenimiento
#   ./scripts/mantenimiento.sh diario   (03:30) particiones, retención,
#                                        no-shows, vista materializada, VACUUM ANALYZE
#   ./scripts/mantenimiento.sh semanal  (domingo 04:30) REINDEX CONCURRENTLY,
#                                        limpieza de alertas y logs, informe de espacio
# =====================================================================
source "$(dirname "$0")/lib.sh"
MODO="${1:-diario}"

case "$MODO" in
  diario)
    log "Mantenimiento diario"
    psql_su -c "SELECT * FROM hotel.fn_mantenimiento_diario()"
    # Autovacuum hace el trabajo continuo; esta pasada nocturna actualiza
    # estadísticas del planificador y el mapa de visibilidad en horario de baja carga.
    docker exec -u postgres "$PRIMARIO" vacuumdb -d "$DB" --analyze --jobs 2 --schema hotel --quiet
    log "VACUUM ANALYZE completado"
    ;;
  semanal)
    log "Mantenimiento semanal"
    # Reconstruye índices sin bloquear escrituras (elimina hinchazón de índices)
    docker exec -u postgres "$PRIMARIO" reindexdb -d "$DB" --schema hotel --concurrently --quiet
    psql_su -c "DELETE FROM monitoreo.alerta WHERE fecha < now() - interval '90 days'" \
            -c "DELETE FROM monitoreo.registro_backup WHERE inicio < now() - interval '1 year'"
    find "$DIR_LOGS" -name '*.log' -mtime +30 -delete
    psql_su -c "SELECT * FROM monitoreo.vw_espacio_tablespaces" \
            -c "SELECT esquema, tabla, tablespace, total FROM monitoreo.vw_espacio_tablas LIMIT 10" \
            -c "SELECT * FROM monitoreo.vw_indices_sin_uso"
    log "Mantenimiento semanal completado"
    ;;
  *) echo "Uso: $0 diario|semanal"; exit 1 ;;
esac
