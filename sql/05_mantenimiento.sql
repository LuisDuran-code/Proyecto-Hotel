-- =====================================================================
--  05_mantenimiento.sql — Gestión del crecimiento y del espacio en disco
--   * Creación anticipada de particiones mensuales
--   * Traslado de particiones antiguas al tablespace ts_historico
--   * Archivado (DETACH) de la bitácora vencida al esquema historico
--   * Rutina de mantenimiento integral (llamada por scripts/mantenimiento.sh)
-- =====================================================================
SET ROLE hotel_owner;
SET search_path = hotel, public;

-- Mueve al tablespace histórico (disco más barato/lento) las particiones
-- con más de p_meses de antigüedad: rara vez se consultan.
CREATE OR REPLACE FUNCTION fn_mover_particiones_historico(p_tabla text, p_meses int DEFAULT 6)
RETURNS SETOF text LANGUAGE plpgsql SET search_path = hotel, public AS $$
DECLARE p record; v_limite date := (date_trunc('month', current_date) - make_interval(months => p_meses))::date;
BEGIN
    FOR p IN
        SELECT c.relname, c.oid
          FROM pg_inherits i
          JOIN pg_class c ON c.oid = i.inhrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'hotel'
         WHERE i.inhparent = ('hotel.' || p_tabla)::regclass
           AND c.relname ~ '_[0-9]{6}$'
           AND to_date(right(c.relname, 6), 'YYYYMM') < v_limite
           AND c.reltablespace <> (SELECT oid FROM pg_tablespace WHERE spcname = 'ts_historico')
    LOOP
        EXECUTE format('ALTER TABLE hotel.%I SET TABLESPACE ts_historico', p.relname);
        RETURN NEXT p.relname;
    END LOOP;
END $$;

-- Retención de la bitácora: las particiones con más de p_meses se
-- desvinculan (DETACH) y pasan al esquema "historico". Ya no ocupan el
-- índice ni el plan de la tabla viva; pueden exportarse y eliminarse.
CREATE OR REPLACE FUNCTION fn_archivar_bitacora(p_meses int DEFAULT 12)
RETURNS SETOF text LANGUAGE plpgsql SET search_path = hotel, public AS $$
DECLARE p record; v_limite date := (date_trunc('month', current_date) - make_interval(months => p_meses))::date;
BEGIN
    FOR p IN
        SELECT c.relname
          FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
         WHERE i.inhparent = 'hotel.bitacora'::regclass
           AND c.relname ~ '^bitacora_[0-9]{6}$'
           AND to_date(right(c.relname, 6), 'YYYYMM') < v_limite
    LOOP
        EXECUTE format('ALTER TABLE hotel.bitacora DETACH PARTITION hotel.%I', p.relname);
        EXECUTE format('ALTER TABLE hotel.%I SET SCHEMA historico', p.relname);
        EXECUTE format('ALTER TABLE historico.%I SET TABLESPACE ts_historico', p.relname);
        RETURN NEXT p.relname;
    END LOOP;
END $$;

-- Rutina mensual/diaria de mantenimiento lógico
CREATE OR REPLACE FUNCTION fn_mantenimiento_diario()
RETURNS TABLE (tarea text, resultado text) LANGUAGE plpgsql SET search_path = hotel, public AS $$
BEGIN
    -- 1) particiones de los próximos 3 meses
    tarea := 'particiones consumo_servicio'; resultado := fn_crear_particiones('consumo_servicio', current_date, 3) || ' creadas'; RETURN NEXT;
    tarea := 'particiones bitacora';         resultado := fn_crear_particiones('bitacora', current_date, 3) || ' creadas';         RETURN NEXT;
    -- 2) consumos con más de 12 meses al tablespace histórico
    tarea := 'consumo -> ts_historico';      resultado := COALESCE((SELECT string_agg(x, ', ') FROM fn_mover_particiones_historico('consumo_servicio', 12) x), 'nada que mover'); RETURN NEXT;
    -- 3) retención de bitácora: 24 meses en línea
    tarea := 'archivar bitacora';            resultado := COALESCE((SELECT string_agg(x, ', ') FROM fn_archivar_bitacora(24) x), 'nada que archivar'); RETURN NEXT;
    -- 4) reservaciones confirmadas cuya fecha de entrada pasó hace más de 1 día => no_show
    UPDATE reservacion SET estado = 'no_show'
     WHERE estado IN ('pendiente','confirmada') AND fecha_entrada < current_date - 1;
    tarea := 'marcar no_show'; resultado := (SELECT count(*) FROM reservacion WHERE estado = 'no_show') || ' en total'; RETURN NEXT;
    -- 5) refrescar resumen de gerencia sin bloquear lecturas
    REFRESH MATERIALIZED VIEW CONCURRENTLY mv_resumen_mensual;
    tarea := 'refrescar mv_resumen_mensual'; resultado := 'ok'; RETURN NEXT;
END $$;

REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA hotel FROM PUBLIC;
RESET ROLE;
