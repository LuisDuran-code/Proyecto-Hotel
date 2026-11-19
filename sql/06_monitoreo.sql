-- =====================================================================
--  06_monitoreo.sql — Vistas de salud del servidor, registro de
--  respaldos y motor de alertas (scripts/monitoreo.sh lo ejecuta cada 5 min)
-- =====================================================================
GRANT pg_monitor TO hotel_owner;   -- las vistas leen estadísticas de todas las sesiones
SET ROLE hotel_owner;
SET search_path = monitoreo, hotel, public;

-- ---------------------------------------------------------------------
-- Registro de respaldos (lo alimentan scripts/backup_*.sh)
-- ---------------------------------------------------------------------
CREATE TABLE monitoreo.registro_backup (
    id          serial PRIMARY KEY,
    tipo        varchar(15) NOT NULL CHECK (tipo IN ('logico','fisico','verificacion','restauracion')),
    inicio      timestamptz NOT NULL,
    fin         timestamptz,
    archivo     text,
    tamano      bigint,
    estado      varchar(10) NOT NULL CHECK (estado IN ('ok','error')),
    detalle     text
);

CREATE TABLE monitoreo.alerta (
    id         bigserial PRIMARY KEY,
    fecha      timestamptz NOT NULL DEFAULT now(),
    nivel      varchar(12) NOT NULL CHECK (nivel IN ('INFO','ADVERTENCIA','CRITICO')),
    categoria  varchar(30) NOT NULL,
    mensaje    text NOT NULL
);
CREATE INDEX ix_alerta_fecha ON monitoreo.alerta USING brin (fecha);

-- ---------------------------------------------------------------------
-- Vistas de monitoreo
-- ---------------------------------------------------------------------
CREATE VIEW vw_espacio_bd AS
SELECT d.datname AS base, pg_size_pretty(pg_database_size(d.datname)) AS tamano,
       pg_database_size(d.datname) AS bytes
  FROM pg_database d WHERE d.datname = current_database();

CREATE VIEW vw_espacio_tablespaces AS
SELECT spcname AS tablespace, pg_size_pretty(pg_tablespace_size(oid)) AS tamano,
       COALESCE(pg_tablespace_location(oid), '(PGDATA)') AS ubicacion
  FROM pg_tablespace;

CREATE VIEW vw_espacio_tablas AS
SELECT n.nspname AS esquema, c.relname AS tabla,
       COALESCE(t.spcname, 'pg_default') AS tablespace,
       pg_size_pretty(pg_table_size(c.oid))   AS datos,
       pg_size_pretty(pg_indexes_size(c.oid)) AS indices,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS total,
       pg_total_relation_size(c.oid) AS bytes_total,
       c.reltuples::bigint AS filas_estimadas
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  LEFT JOIN pg_tablespace t ON t.oid = c.reltablespace
 WHERE c.relkind IN ('r','m') AND n.nspname IN ('hotel','historico','monitoreo')
 ORDER BY pg_total_relation_size(c.oid) DESC;

CREATE VIEW vw_conexiones AS
SELECT usename AS usuario, application_name, client_addr, state, count(*) AS sesiones,
       max(now() - state_change) AS mayor_tiempo_en_estado
  FROM pg_stat_activity WHERE backend_type = 'client backend'
 GROUP BY 1, 2, 3, 4 ORDER BY sesiones DESC;

CREATE VIEW vw_actividad_larga AS
SELECT pid, usename, state, now() - xact_start AS duracion_transaccion,
       now() - query_start AS duracion_consulta, wait_event_type, left(query, 120) AS consulta
  FROM pg_stat_activity
 WHERE backend_type = 'client backend' AND state <> 'idle'
   AND (now() - xact_start) > interval '1 minute'
 ORDER BY xact_start;

CREATE VIEW vw_bloqueos AS
SELECT bloqueado.pid AS pid_bloqueado, bloqueado.usename AS usuario_bloqueado,
       left(bloqueado.query, 80) AS consulta_bloqueada,
       bloqueador.pid AS pid_bloqueador, bloqueador.usename AS usuario_bloqueador,
       left(bloqueador.query, 80) AS consulta_bloqueadora,
       now() - bloqueado.query_start AS esperando
  FROM pg_stat_activity bloqueado
  JOIN LATERAL unnest(pg_blocking_pids(bloqueado.pid)) b(pid) ON true
  JOIN pg_stat_activity bloqueador ON bloqueador.pid = b.pid;

CREATE VIEW vw_consultas_costosas AS
SELECT round(total_exec_time::numeric, 1) AS ms_total, calls AS llamadas,
       round(mean_exec_time::numeric, 2)  AS ms_promedio, rows AS filas,
       round(100.0 * shared_blks_hit / NULLIF(shared_blks_hit + shared_blks_read, 0), 1) AS pct_cache,
       left(regexp_replace(query, '\s+', ' ', 'g'), 150) AS consulta
  FROM pg_stat_statements
 WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
 ORDER BY total_exec_time DESC LIMIT 20;

CREATE VIEW vw_salud_tablas AS
SELECT schemaname AS esquema, relname AS tabla, n_live_tup AS filas_vivas, n_dead_tup AS filas_muertas,
       round(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 1) AS pct_muertas,
       seq_scan, idx_scan, last_autovacuum, last_autoanalyze
  FROM pg_stat_user_tables
 WHERE schemaname IN ('hotel','monitoreo')
 ORDER BY n_dead_tup DESC;

CREATE VIEW vw_indices_sin_uso AS
SELECT s.schemaname AS esquema, s.relname AS tabla, s.indexrelname AS indice,
       pg_size_pretty(pg_relation_size(s.indexrelid)) AS tamano, s.idx_scan
  FROM pg_stat_user_indexes s JOIN pg_index i ON i.indexrelid = s.indexrelid
 WHERE s.idx_scan = 0 AND NOT i.indisunique AND NOT i.indisprimary
   AND s.schemaname = 'hotel' AND NOT EXISTS (SELECT 1 FROM pg_inherits WHERE inhrelid = s.relid)
 ORDER BY pg_relation_size(s.indexrelid) DESC;

CREATE VIEW vw_cache_hit AS
SELECT round(100.0 * blks_hit / NULLIF(blks_hit + blks_read, 0), 2) AS pct_cache_hit,
       xact_commit, xact_rollback, deadlocks, temp_files, pg_size_pretty(temp_bytes) AS temp_bytes
  FROM pg_stat_database WHERE datname = current_database();

CREATE VIEW vw_replicacion AS
SELECT r.application_name, r.client_addr, r.state, r.sync_state,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), r.replay_lsn)) AS retraso_bytes,
       r.write_lag, r.flush_lag, r.replay_lag
  FROM pg_stat_replication r;

CREATE VIEW vw_slots_replicacion AS
SELECT slot_name, active, wal_status,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_retenido
  FROM pg_replication_slots;

CREATE VIEW vw_archivado_wal AS
SELECT archived_count, last_archived_wal, last_archived_time,
       failed_count, last_failed_wal, last_failed_time,
       (last_failed_time IS NOT NULL AND (last_archived_time IS NULL OR last_failed_time > last_archived_time)) AS fallando
  FROM pg_stat_archiver;

CREATE VIEW vw_ultimos_backups AS
SELECT DISTINCT ON (tipo) tipo, inicio, fin, fin - inicio AS duracion, pg_size_pretty(tamano) AS tamano,
       estado, archivo, now() - fin AS antiguedad
  FROM registro_backup ORDER BY tipo, inicio DESC;

-- ---------------------------------------------------------------------
-- Motor de alertas: evalúa reglas técnicas y de negocio
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION monitoreo.fn_verificar_alertas(p_registrar boolean DEFAULT true)
RETURNS TABLE (nivel text, categoria text, mensaje text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = monitoreo, hotel, public AS $$
DECLARE v_max int := current_setting('max_connections')::int; v record;
BEGIN
    CREATE TEMP TABLE IF NOT EXISTS _alertas (nivel text, categoria text, mensaje text) ON COMMIT DROP;
    TRUNCATE _alertas;

    -- Conexiones
    INSERT INTO _alertas
    SELECT CASE WHEN c >= v_max * 0.9 THEN 'CRITICO' ELSE 'ADVERTENCIA' END, 'conexiones',
           format('%s de %s conexiones en uso (%s%%)', c, v_max, round(100.0 * c / v_max))
      FROM (SELECT count(*) c FROM pg_stat_activity) x WHERE c >= v_max * 0.8;

    -- Consultas largas y transacciones abiertas sin actividad
    INSERT INTO _alertas
    SELECT 'ADVERTENCIA', 'consulta_larga', format('PID %s (%s) lleva %s: %s', pid, usename,
           date_trunc('second', now() - query_start), left(query, 60))
      FROM pg_stat_activity
     WHERE state = 'active' AND backend_type = 'client backend' AND now() - query_start > interval '5 minutes';
    INSERT INTO _alertas
    SELECT 'ADVERTENCIA', 'idle_in_transaction', format('PID %s (%s) con transacción abierta sin actividad hace %s',
           pid, usename, date_trunc('second', now() - state_change))
      FROM pg_stat_activity WHERE state = 'idle in transaction' AND now() - state_change > interval '10 minutes';

    -- Bloqueos
    INSERT INTO _alertas
    SELECT 'ADVERTENCIA', 'bloqueo', format('PID %s bloqueado por %s desde hace %s', pid_bloqueado, pid_bloqueador,
           date_trunc('second', esperando))
      FROM vw_bloqueos WHERE esperando > interval '30 seconds';

    -- Tablas con muchas filas muertas (vacuum atrasado)
    INSERT INTO _alertas
    SELECT 'ADVERTENCIA', 'bloat', format('%s.%s tiene %s%% de filas muertas (%s)', esquema, tabla, pct_muertas, filas_muertas)
      FROM vw_salud_tablas WHERE filas_muertas > 1000 AND pct_muertas > 20;

    -- Cache hit ratio
    INSERT INTO _alertas
    SELECT 'ADVERTENCIA', 'memoria', format('Cache hit ratio bajo: %s%% (aumentar shared_buffers)', pct_cache_hit)
      FROM vw_cache_hit WHERE pct_cache_hit < 95
       AND (SELECT blks_hit + blks_read FROM pg_stat_database WHERE datname = current_database()) > 100000;

    -- Espacio en disco
    INSERT INTO _alertas
    SELECT 'ADVERTENCIA', 'espacio', format('La base de datos ocupa %s (umbral 5 GB)', tamano)
      FROM vw_espacio_bd WHERE bytes > 5 * 1024^3;

    -- Alta disponibilidad: réplica conectada y al día
    IF NOT pg_is_in_recovery() THEN
        IF NOT EXISTS (SELECT 1 FROM pg_stat_replication WHERE state = 'streaming') THEN
            INSERT INTO _alertas VALUES ('CRITICO', 'replicacion', 'No hay ninguna réplica conectada en streaming');
        END IF;
        INSERT INTO _alertas
        SELECT 'ADVERTENCIA', 'replicacion', format('Réplica %s con retraso de %s', application_name, replay_lag)
          FROM pg_stat_replication WHERE replay_lag > interval '60 seconds';
        INSERT INTO _alertas
        SELECT 'CRITICO', 'replicacion', format('Slot %s inactivo reteniendo %s de WAL', slot_name, wal_retenido)
          FROM vw_slots_replicacion
         WHERE NOT active AND pg_wal_lsn_diff(pg_current_wal_lsn(),
               (SELECT restart_lsn FROM pg_replication_slots s WHERE s.slot_name = vw_slots_replicacion.slot_name)) > 1024^3;
    END IF;

    -- Archivado de WAL (base del PITR)
    INSERT INTO _alertas
    SELECT 'CRITICO', 'archivado_wal', format('Falla el archivado de WAL desde %s (segmento %s)', last_failed_time, last_failed_wal)
      FROM vw_archivado_wal WHERE fallando;

    -- Respaldos
    IF NOT EXISTS (SELECT 1 FROM registro_backup WHERE tipo = 'logico' AND estado = 'ok' AND fin > now() - interval '26 hours') THEN
        INSERT INTO _alertas VALUES ('CRITICO', 'backup', 'No hay respaldo lógico exitoso en las últimas 26 horas');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM registro_backup WHERE tipo = 'fisico' AND estado = 'ok' AND fin > now() - interval '8 days') THEN
        INSERT INTO _alertas VALUES ('ADVERTENCIA', 'backup', 'No hay respaldo físico (base backup) en los últimos 8 días');
    END IF;
    INSERT INTO _alertas
    SELECT 'CRITICO', 'backup', format('Respaldo %s falló el %s: %s', tipo, inicio, detalle)
      FROM registro_backup WHERE estado = 'error' AND inicio > now() - interval '1 day';

    -- Particiones: la del próximo mes debe existir; las DEFAULT deben estar vacías
    IF to_regclass('hotel.consumo_servicio_' || to_char(current_date + interval '1 month', 'YYYYMM')) IS NULL THEN
        INSERT INTO _alertas VALUES ('CRITICO', 'particiones', 'Falta la partición de consumo_servicio del próximo mes');
    END IF;
    IF EXISTS (SELECT 1 FROM hotel.consumo_servicio_default) OR EXISTS (SELECT 1 FROM hotel.bitacora_default) THEN
        INSERT INTO _alertas VALUES ('ADVERTENCIA', 'particiones', 'Hay filas en una partición DEFAULT: crear la partición faltante');
    END IF;

    -- Reglas de negocio
    INSERT INTO _alertas
    SELECT 'ADVERTENCIA', 'operacion', format('Habitación %s lleva %s días en mantenimiento', h.numero, current_date - m.fecha_inicio)
      FROM hotel.mantenimiento m JOIN hotel.habitacion h USING (id_habitacion)
     WHERE m.estado = 'en_proceso' AND current_date - m.fecha_inicio > 7;
    INSERT INTO _alertas
    SELECT 'INFO', 'operacion', format('Reservación %s: entrada el %s y aún sin check-in', id_reservacion, fecha_entrada)
      FROM hotel.reservacion WHERE estado IN ('pendiente','confirmada') AND fecha_entrada < current_date;
    INSERT INTO _alertas
    SELECT 'ADVERTENCIA', 'cobros', format('Factura %s con saldo %s desde hace más de 30 días', numero, saldo)
      FROM hotel.vw_facturas_pendientes WHERE fecha_emision < now() - interval '30 days';

    IF p_registrar THEN
        INSERT INTO alerta (nivel, categoria, mensaje) SELECT * FROM _alertas WHERE _alertas.nivel <> 'INFO';
    END IF;
    RETURN QUERY SELECT * FROM _alertas
                 ORDER BY CASE _alertas.nivel WHEN 'CRITICO' THEN 1 WHEN 'ADVERTENCIA' THEN 2 ELSE 3 END;
END $$;
REVOKE EXECUTE ON FUNCTION monitoreo.fn_verificar_alertas(boolean) FROM PUBLIC;

RESET ROLE;
