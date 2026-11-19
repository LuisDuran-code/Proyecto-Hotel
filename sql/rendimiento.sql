-- =====================================================================
--  rendimiento.sql — Demostración de optimización (índices y particiones)
--  Genera ~300.000 consumos y 20.000 huéspedes DENTRO de una transacción,
--  muestra los planes de ejecución y al final hace ROLLBACK (no deja datos).
--     docker exec -i -u postgres hotel-primario psql -d hotel < sql/rendimiento.sql
-- =====================================================================
\timing on
SET search_path = hotel, public;
BEGIN;

-- Generación de volumen (se desactivan triggers de validación/auditoría solo aquí)
ALTER TABLE consumo_servicio DISABLE TRIGGER USER;
ALTER TABLE huesped          DISABLE TRIGGER USER;

INSERT INTO consumo_servicio (fecha, id_reservacion, id_servicio, id_empleado, cantidad, precio_unitario)
SELECT TIMESTAMPTZ '2026-01-01' + random() * interval '320 days',
       1 + (random() * 17)::int, 1 + (random() * 11)::int, 3 + (random() * 3)::int,
       1 + (random() * 3)::int, 10
  FROM generate_series(1, 300000);

INSERT INTO huesped (nombres, apellidos, tipo_documento, documento_cifrado, documento_hash, email)
SELECT 'Nombre' || g, (ARRAY['García','López','Martínez','Hernández','Pérez','Romero','Flores'])[1 + g % 7] || ' ' || g,
       'pasaporte', '\x00', md5(g::text) || md5(g::text), 'h' || g || '@demo.com'
  FROM generate_series(1, 20000) g;
ANALYZE consumo_servicio; ANALYZE huesped;

\echo '\n=== 1. Poda de particiones: consumos de un mes (solo se lee la partición de marzo) ==='
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY ON)
SELECT id_servicio, sum(cantidad * precio_unitario)
  FROM consumo_servicio
 WHERE fecha >= '2026-03-01' AND fecha < '2026-04-01'
 GROUP BY id_servicio;

\echo '\n=== 2. Consumos de una reservación: índice particionado ix_consumo_reservacion ==='
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY ON)
SELECT * FROM consumo_servicio WHERE id_reservacion = 7 AND fecha >= '2026-10-01';

\echo '\n=== 3. Búsqueda aproximada de huésped por nombre: índice GIN trigramas ==='
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY ON)
SELECT id_huesped, nombres, apellidos FROM huesped
 WHERE (apellidos::text || ' ' || nombres::text) ILIKE '%romero 1234%';

\echo '\n=== 3b. La misma búsqueda SIN el índice (para comparar tiempos) ==='
DROP INDEX ix_huesped_nombre_trgm;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY ON)
SELECT id_huesped, nombres, apellidos FROM huesped
 WHERE (apellidos::text || ' ' || nombres::text) ILIKE '%romero 1234%';

\echo '\n=== 4. Disponibilidad: índice GiST de la restricción EXCLUDE ==='
SET enable_seqscan = off;   -- con 19 filas el planificador preferiría un seq scan; se fuerza para mostrar el índice
EXPLAIN (COSTS OFF)
SELECT 1 FROM reservacion_habitacion WHERE id_habitacion = 3 AND activa AND periodo && daterange('2026-12-01','2026-12-05');
RESET enable_seqscan;

\echo '\n=== 5. Tamaño: índice BRIN vs B-tree sobre la fecha de consumo ==='
CREATE INDEX tmp_btree_fecha ON consumo_servicio_202603 (fecha);
CREATE INDEX tmp_brin_fecha  ON consumo_servicio_202603 USING brin (fecha);
SELECT 'btree' AS tipo, pg_size_pretty(pg_relation_size('tmp_btree_fecha')) AS tamano
UNION ALL SELECT 'brin', pg_size_pretty(pg_relation_size('tmp_brin_fecha'));

ROLLBACK;
\echo '\nROLLBACK: no quedaron datos de prueba.'
