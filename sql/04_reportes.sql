-- =====================================================================
--  04_reportes.sql — Vistas y funciones de consulta (requerimiento 6)
--  Ocupación, ingresos, servicios más utilizados e historial de huéspedes.
-- =====================================================================
SET ROLE hotel_owner;
SET search_path = hotel, public;

-- Estado actual de cada habitación y quién la ocupa
CREATE OR REPLACE VIEW vw_ocupacion_actual AS
SELECT h.numero, h.piso, t.nombre AS tipo, h.estado,
       hu.nombres || ' ' || hu.apellidos AS huesped_actual,
       r.id_reservacion, r.fecha_entrada, r.fecha_salida
  FROM habitacion h
  JOIN tipo_habitacion t USING (id_tipo)
  LEFT JOIN reservacion_habitacion rh ON rh.id_habitacion = h.id_habitacion AND rh.activa
       AND EXISTS (SELECT 1 FROM reservacion x WHERE x.id_reservacion = rh.id_reservacion AND x.estado = 'en_curso')
  LEFT JOIN reservacion r  ON r.id_reservacion = rh.id_reservacion
  LEFT JOIN huesped hu     ON hu.id_huesped = r.id_huesped
 ORDER BY h.numero;

-- Ocupación por día en un rango: habitaciones-noche vendidas / disponibles
CREATE OR REPLACE FUNCTION fn_reporte_ocupacion(p_desde date, p_hasta date)
RETURNS TABLE (fecha date, habitaciones_ocupadas bigint, total_habitaciones bigint, porcentaje numeric)
LANGUAGE sql STABLE SET search_path = hotel, public AS $$
    SELECT d::date,
           count(rh.id_res_hab),
           (SELECT count(*) FROM habitacion WHERE estado <> 'fuera_servicio'),
           round(100.0 * count(rh.id_res_hab) /
                 NULLIF((SELECT count(*) FROM habitacion WHERE estado <> 'fuera_servicio'), 0), 1)
      FROM generate_series(p_desde, p_hasta, interval '1 day') d
      LEFT JOIN reservacion_habitacion rh ON rh.activa AND rh.periodo @> d::date  -- canceladas/no_show quedan inactivas
     GROUP BY d ORDER BY d
$$;

-- Ingresos por mes (facturado vs cobrado)
CREATE OR REPLACE VIEW vw_ingresos_mensuales AS
WITH fact AS (
    SELECT date_trunc('month', f.fecha_emision)::date AS mes,
           sum(d.subtotal) FILTER (WHERE d.tipo = 'habitacion') AS alojamiento,
           sum(d.subtotal) FILTER (WHERE d.tipo = 'servicio')   AS servicios
      FROM factura f JOIN detalle_factura d USING (id_factura)
     WHERE f.estado <> 'anulada'
     GROUP BY 1),
tot AS (
    SELECT date_trunc('month', fecha_emision)::date AS mes, count(*) AS facturas,
           sum(subtotal) AS subtotal, sum(iva) AS iva, sum(total) AS total
      FROM factura WHERE estado <> 'anulada' GROUP BY 1),
cob AS (
    SELECT date_trunc('month', fecha)::date AS mes, sum(monto) AS cobrado
      FROM pago GROUP BY 1)
SELECT tot.mes, tot.facturas, COALESCE(fact.alojamiento, 0) AS alojamiento,
       COALESCE(fact.servicios, 0) AS servicios, tot.subtotal, tot.iva, tot.total,
       COALESCE(cob.cobrado, 0) AS cobrado
  FROM tot LEFT JOIN fact USING (mes) LEFT JOIN cob USING (mes)
 ORDER BY tot.mes;

-- Servicios más utilizados
CREATE OR REPLACE VIEW vw_servicios_mas_utilizados AS
SELECT s.nombre AS servicio, s.categoria,
       count(c.id_consumo)                         AS veces_solicitado,
       COALESCE(sum(c.cantidad), 0)                AS unidades,
       COALESCE(sum(c.cantidad * c.precio_unitario), 0) AS ingresos,
       rank() OVER (ORDER BY count(c.id_consumo) DESC) AS ranking
  FROM servicio s LEFT JOIN consumo_servicio c USING (id_servicio)
 GROUP BY s.id_servicio, s.nombre, s.categoria
 ORDER BY ranking, ingresos DESC;

-- Historial de estadías por huésped (requerimiento 2)
CREATE OR REPLACE VIEW vw_historial_huesped AS
SELECT hu.id_huesped, hu.nombres || ' ' || hu.apellidos AS huesped, hu.nacionalidad,
       count(r.id_reservacion) FILTER (WHERE r.estado = 'finalizada')                    AS estadias,
       COALESCE(sum(r.fecha_salida - r.fecha_entrada) FILTER (WHERE r.estado = 'finalizada'), 0) AS noches,
       COALESCE(sum(f.total) FILTER (WHERE f.estado <> 'anulada'), 0)                    AS total_facturado,
       max(r.fecha_salida) FILTER (WHERE r.estado = 'finalizada')                        AS ultima_estadia,
       count(r.id_reservacion) FILTER (WHERE r.estado IN ('confirmada','pendiente'))     AS reservas_futuras
  FROM huesped hu
  LEFT JOIN reservacion r USING (id_huesped)
  LEFT JOIN factura f     USING (id_reservacion)
 GROUP BY hu.id_huesped;

-- Facturas con saldo pendiente
CREATE OR REPLACE VIEW vw_facturas_pendientes AS
SELECT f.numero, f.fecha_emision, hu.nombres || ' ' || hu.apellidos AS huesped,
       f.total, COALESCE(sum(p.monto), 0) AS pagado, f.total - COALESCE(sum(p.monto), 0) AS saldo
  FROM factura f
  JOIN reservacion r USING (id_reservacion)
  JOIN huesped hu    USING (id_huesped)
  LEFT JOIN pago p   USING (id_factura)
 WHERE f.estado = 'emitida'
 GROUP BY f.id_factura, hu.id_huesped;

-- Resumen mensual materializado para gerencia (se refresca cada noche en
-- scripts/mantenimiento.sh): consultas pesadas sin cargar las tablas transaccionales
CREATE MATERIALIZED VIEW mv_resumen_mensual AS
SELECT date_trunc('month', r.fecha_entrada)::date AS mes,
       count(*)                                         AS reservaciones,
       count(*) FILTER (WHERE r.estado = 'cancelada')   AS canceladas,
       count(*) FILTER (WHERE r.estado = 'no_show')     AS no_show,
       sum(r.fecha_salida - r.fecha_entrada) FILTER (WHERE r.estado = 'finalizada') AS noches_vendidas,
       round(avg(r.fecha_salida - r.fecha_entrada), 2)  AS estancia_promedio,
       COALESCE(sum(f.total), 0)                        AS ingresos
  FROM reservacion r LEFT JOIN factura f USING (id_reservacion)
 GROUP BY 1
WITH DATA;
CREATE UNIQUE INDEX ux_mv_resumen_mensual ON mv_resumen_mensual (mes);   -- permite REFRESH CONCURRENTLY

RESET ROLE;
