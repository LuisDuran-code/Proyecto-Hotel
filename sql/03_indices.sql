-- =====================================================================
--  03_indices.sql — Índices para rendimiento
--  Criterios:
--   * Toda clave foránea tiene índice (evita escaneos al hacer JOIN y
--     bloqueos amplios al borrar/actualizar en la tabla padre).
--   * Índices parciales para los estados "vivos" (las consultas de
--     recepción casi nunca buscan reservaciones finalizadas).
--   * BRIN en la bitácora: datos insertados en orden cronológico; ocupa
--     cientos de veces menos que un B-tree.
--   * Los índices de tablas normales se ubican en el tablespace ts_indices
--     (otro volumen), separando E/S de datos e índices.
-- =====================================================================
SET ROLE hotel_owner;
SET search_path = hotel, public;

-- Habitaciones
CREATE INDEX ix_habitacion_tipo        ON habitacion (id_tipo)                         TABLESPACE ts_indices;
CREATE INDEX ix_habitacion_estado      ON habitacion (estado)                          TABLESPACE ts_indices;

-- Huéspedes: búsqueda aproximada por nombre (recepción) y por correo
CREATE INDEX ix_huesped_nombre_trgm    ON huesped USING gin ((apellidos::text || ' ' || nombres::text) gin_trgm_ops)
                                                                                       TABLESPACE ts_indices;
CREATE INDEX ix_huesped_email          ON huesped (lower(email))                       TABLESPACE ts_indices;

-- Reservaciones
CREATE INDEX ix_reservacion_huesped    ON reservacion (id_huesped)                     TABLESPACE ts_indices;
CREATE INDEX ix_reservacion_empleado   ON reservacion (id_empleado)                    TABLESPACE ts_indices;
CREATE INDEX ix_reservacion_fechas     ON reservacion (fecha_entrada, fecha_salida)    TABLESPACE ts_indices;
CREATE INDEX ix_reservacion_activas    ON reservacion (fecha_entrada)                  TABLESPACE ts_indices
       WHERE estado IN ('pendiente','confirmada','en_curso');
-- reservacion_habitacion: (id_reservacion) cubierto por uq_res_hab;
-- (id_habitacion, periodo) cubierto por el índice GiST de la restricción EXCLUDE.

-- Consumo de servicios (índices particionados: se crean en cada partición)
CREATE INDEX ix_consumo_reservacion    ON consumo_servicio (id_reservacion);
CREATE INDEX ix_consumo_servicio_fecha ON consumo_servicio (id_servicio, fecha);
CREATE INDEX ix_consumo_empleado       ON consumo_servicio (id_empleado);

-- Mantenimiento
CREATE INDEX ix_mant_habitacion        ON mantenimiento (id_habitacion, estado)        TABLESPACE ts_indices;
CREATE INDEX ix_mant_empleado          ON mantenimiento (id_empleado)                  TABLESPACE ts_indices;
CREATE INDEX ix_mant_abiertos          ON mantenimiento (fecha_inicio)                 TABLESPACE ts_indices
       WHERE estado IN ('programado','en_proceso');

-- Facturación
CREATE INDEX ix_factura_fecha          ON factura (fecha_emision)                      TABLESPACE ts_indices;
CREATE INDEX ix_factura_pendientes     ON factura (fecha_emision) TABLESPACE ts_indices WHERE estado = 'emitida';
CREATE INDEX ix_detalle_factura        ON detalle_factura (id_factura)                 TABLESPACE ts_indices;
CREATE INDEX ix_pago_factura           ON pago (id_factura)                            TABLESPACE ts_indices;
CREATE INDEX ix_pago_fecha             ON pago (fecha)                                 TABLESPACE ts_indices;

-- Bitácora
CREATE INDEX ix_bitacora_fecha_brin    ON bitacora USING brin (fecha);
CREATE INDEX ix_bitacora_tabla         ON bitacora (tabla, fecha);

RESET ROLE;
