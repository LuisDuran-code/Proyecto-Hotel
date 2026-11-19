-- =====================================================================
--  01_esquema.sql — Tablas, restricciones de integridad y particiones
--  Implementa el diagrama ER (13 tablas). Todos los objetos pertenecen
--  al rol hotel_owner.
-- =====================================================================
SET ROLE hotel_owner;
SET search_path = hotel, public;

-- ---------------------------------------------------------------------
-- Catálogos
-- ---------------------------------------------------------------------
CREATE TABLE tipo_habitacion (
    id_tipo       serial        PRIMARY KEY,
    nombre        varchar(30)   NOT NULL UNIQUE,
    capacidad     smallint      NOT NULL CHECK (capacidad BETWEEN 1 AND 10),
    tarifa_base   numeric(10,2) NOT NULL CHECK (tarifa_base > 0),
    descripcion   text
);
COMMENT ON TABLE tipo_habitacion IS 'Catálogo de tipos de habitación (individual, doble, suite...) con capacidad y tarifa base por noche';

CREATE TABLE habitacion (
    id_habitacion serial        PRIMARY KEY,
    numero        varchar(10)   NOT NULL UNIQUE,
    piso          smallint      NOT NULL CHECK (piso BETWEEN 0 AND 50),
    id_tipo       int           NOT NULL REFERENCES tipo_habitacion(id_tipo) ON UPDATE CASCADE ON DELETE RESTRICT,
    estado        varchar(20)   NOT NULL DEFAULT 'disponible'
                  CHECK (estado IN ('disponible','ocupada','mantenimiento','fuera_servicio'))
) WITH (fillfactor = 85);   -- espacio libre para actualizaciones HOT del estado
COMMENT ON COLUMN habitacion.estado IS 'Estado operativo actual; se actualiza automáticamente en check-in/check-out y mantenimiento';

CREATE TABLE servicio (
    id_servicio   serial        PRIMARY KEY,
    nombre        varchar(60)   NOT NULL UNIQUE,
    categoria     varchar(20)   NOT NULL
                  CHECK (categoria IN ('restaurante','lavanderia','transporte','spa','minibar','otros')),
    precio        numeric(10,2) NOT NULL CHECK (precio >= 0),
    activo        boolean       NOT NULL DEFAULT true
);
COMMENT ON TABLE servicio IS 'Servicios adicionales que pueden consumir los huéspedes';

-- ---------------------------------------------------------------------
-- Personas
-- ---------------------------------------------------------------------
CREATE TABLE huesped (
    id_huesped        serial        PRIMARY KEY,
    nombres           varchar(60)   NOT NULL,
    apellidos         varchar(60)   NOT NULL,
    tipo_documento    varchar(20)   NOT NULL CHECK (tipo_documento IN ('DUI','pasaporte','carnet_residente','otro')),
    documento_cifrado bytea         NOT NULL,
    documento_hash    varchar(64)   NOT NULL UNIQUE,
    email             varchar(100)  CHECK (email ~* '^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$'),
    telefono          varchar(20),
    nacionalidad      varchar(40),
    fecha_registro    timestamptz   NOT NULL DEFAULT now()
);
COMMENT ON COLUMN huesped.documento_cifrado IS 'Número de documento cifrado con pgp_sym_encrypt (AES-256). Se descifra solo con hotel.fn_documento_huesped()';
COMMENT ON COLUMN huesped.documento_hash    IS 'HMAC-SHA256 del documento: permite buscar y evitar duplicados sin descifrar';

CREATE TABLE empleado (
    id_empleado   serial        PRIMARY KEY,
    nombres       varchar(60)   NOT NULL,
    apellidos     varchar(60)   NOT NULL,
    cargo         varchar(20)   NOT NULL CHECK (cargo IN ('administrador','recepcionista','mantenimiento','gerente')),
    usuario_db    varchar(63)   UNIQUE,
    activo        boolean       NOT NULL DEFAULT true
);
COMMENT ON COLUMN empleado.usuario_db IS 'Rol de PostgreSQL con el que el empleado inicia sesión (vincula seguridad y negocio)';

-- ---------------------------------------------------------------------
-- Reservaciones
-- ---------------------------------------------------------------------
CREATE TABLE reservacion (
    id_reservacion    serial        PRIMARY KEY,
    id_huesped        int           NOT NULL REFERENCES huesped(id_huesped)   ON DELETE RESTRICT,
    id_empleado       int           NOT NULL REFERENCES empleado(id_empleado) ON DELETE RESTRICT,
    fecha_entrada     date          NOT NULL,
    fecha_salida      date          NOT NULL,
    cantidad_personas smallint      NOT NULL CHECK (cantidad_personas BETWEEN 1 AND 20),
    estado            varchar(20)   NOT NULL DEFAULT 'confirmada'
                      CHECK (estado IN ('pendiente','confirmada','en_curso','finalizada','cancelada','no_show')),
    checkin_real      timestamptz,
    checkout_real     timestamptz,
    fecha_creacion    timestamptz   NOT NULL DEFAULT now(),
    CONSTRAINT ck_reservacion_fechas   CHECK (fecha_salida > fecha_entrada),
    CONSTRAINT ck_reservacion_checkout CHECK (checkout_real IS NULL OR (checkin_real IS NOT NULL AND checkout_real >= checkin_real)),
    CONSTRAINT ck_reservacion_estado_checkin CHECK (estado NOT IN ('en_curso','finalizada') OR checkin_real IS NOT NULL)
) WITH (fillfactor = 90);

-- Tabla puente: una reservación puede incluir varias habitaciones.
-- "periodo" es [entrada, salida) y la restricción EXCLUDE hace IMPOSIBLE
-- que una misma habitación quede reservada dos veces en fechas que se traslapan.
CREATE TABLE reservacion_habitacion (
    id_res_hab     serial        PRIMARY KEY,
    id_reservacion int           NOT NULL REFERENCES reservacion(id_reservacion) ON DELETE CASCADE,
    id_habitacion  int           NOT NULL REFERENCES habitacion(id_habitacion)   ON DELETE RESTRICT,
    periodo        daterange     NOT NULL CHECK (NOT isempty(periodo) AND lower_inc(periodo) AND NOT upper_inc(periodo)),
    tarifa_noche   numeric(10,2) NOT NULL CHECK (tarifa_noche > 0),
    activa         boolean       NOT NULL DEFAULT true,
    CONSTRAINT uq_res_hab UNIQUE (id_reservacion, id_habitacion),
    CONSTRAINT ex_habitacion_sin_traslape
        EXCLUDE USING gist (id_habitacion WITH =, periodo WITH &&) WHERE (activa)
);
COMMENT ON CONSTRAINT ex_habitacion_sin_traslape ON reservacion_habitacion IS
    'Evita sobre-reservaciones: no pueden existir dos asignaciones activas de la misma habitación con fechas traslapadas';

-- ---------------------------------------------------------------------
-- Consumo de servicios — PARTICIONADA por mes (tabla de mayor crecimiento)
-- ---------------------------------------------------------------------
CREATE TABLE consumo_servicio (
    id_consumo      bigserial,
    fecha           timestamptz   NOT NULL DEFAULT now(),
    id_reservacion  int           NOT NULL REFERENCES reservacion(id_reservacion) ON DELETE RESTRICT,
    id_servicio     int           NOT NULL REFERENCES servicio(id_servicio)       ON DELETE RESTRICT,
    id_empleado     int           NOT NULL REFERENCES empleado(id_empleado)       ON DELETE RESTRICT,
    cantidad        smallint      NOT NULL DEFAULT 1 CHECK (cantidad > 0),
    precio_unitario numeric(10,2) NOT NULL CHECK (precio_unitario >= 0),
    PRIMARY KEY (id_consumo, fecha)       -- la clave de partición debe formar parte de la PK
) PARTITION BY RANGE (fecha);

-- ---------------------------------------------------------------------
-- Mantenimiento de habitaciones
-- ---------------------------------------------------------------------
CREATE TABLE mantenimiento (
    id_mantenimiento serial      PRIMARY KEY,
    id_habitacion    int         NOT NULL REFERENCES habitacion(id_habitacion) ON DELETE RESTRICT,
    id_empleado      int         NOT NULL REFERENCES empleado(id_empleado)     ON DELETE RESTRICT,
    tipo             varchar(15) NOT NULL CHECK (tipo IN ('preventivo','correctivo','limpieza')),
    descripcion      text        NOT NULL,
    fecha_inicio     date        NOT NULL DEFAULT current_date,
    fecha_fin        date,
    estado           varchar(15) NOT NULL DEFAULT 'programado'
                     CHECK (estado IN ('programado','en_proceso','finalizado','cancelado')),
    CONSTRAINT ck_mant_fechas CHECK (fecha_fin IS NULL OR fecha_fin >= fecha_inicio),
    CONSTRAINT ck_mant_finalizado CHECK (estado <> 'finalizado' OR fecha_fin IS NOT NULL)
);

-- ---------------------------------------------------------------------
-- Facturación
-- ---------------------------------------------------------------------
CREATE TABLE factura (
    id_factura     serial        PRIMARY KEY,
    id_reservacion int           NOT NULL UNIQUE REFERENCES reservacion(id_reservacion) ON DELETE RESTRICT,
    numero         varchar(20)   NOT NULL UNIQUE,
    fecha_emision  timestamptz   NOT NULL DEFAULT now(),
    subtotal       numeric(12,2) NOT NULL CHECK (subtotal >= 0),
    iva            numeric(12,2) NOT NULL CHECK (iva >= 0),
    total          numeric(12,2) NOT NULL,
    estado         varchar(15)   NOT NULL DEFAULT 'emitida' CHECK (estado IN ('emitida','pagada','anulada')),
    CONSTRAINT ck_factura_total CHECK (total = subtotal + iva)
);
COMMENT ON TABLE factura IS 'Una factura por estadía (1:1 con reservación). IVA 13% (El Salvador)';

CREATE TABLE detalle_factura (
    id_detalle      serial        PRIMARY KEY,
    id_factura      int           NOT NULL REFERENCES factura(id_factura) ON DELETE CASCADE,
    tipo            varchar(15)   NOT NULL CHECK (tipo IN ('habitacion','servicio','descuento','otro')),
    concepto        varchar(120)  NOT NULL,
    cantidad        numeric(10,2) NOT NULL CHECK (cantidad > 0),
    precio_unitario numeric(10,2) NOT NULL,
    subtotal        numeric(12,2) NOT NULL,
    CONSTRAINT ck_detalle_subtotal CHECK (subtotal = round(cantidad * precio_unitario, 2)),
    CONSTRAINT ck_detalle_signo    CHECK ((tipo = 'descuento') = (precio_unitario < 0))
);

CREATE TABLE pago (
    id_pago     serial        PRIMARY KEY,
    id_factura  int           NOT NULL REFERENCES factura(id_factura) ON DELETE RESTRICT,
    fecha       timestamptz   NOT NULL DEFAULT now(),
    monto       numeric(12,2) NOT NULL CHECK (monto > 0),
    metodo      varchar(15)   NOT NULL CHECK (metodo IN ('efectivo','tarjeta','transferencia')),
    ultimos_4   char(4),
    -- Nunca se guarda el número completo de tarjeta (PCI-DSS): solo los últimos 4 dígitos
    CONSTRAINT ck_pago_tarjeta CHECK (
        (metodo = 'tarjeta' AND ultimos_4 IS NOT NULL AND ultimos_4 ~ '^[0-9]{4}$') OR (metodo <> 'tarjeta' AND ultimos_4 IS NULL))
);

-- ---------------------------------------------------------------------
-- Bitácora de auditoría — PARTICIONADA por mes, con retención
-- ---------------------------------------------------------------------
CREATE TABLE bitacora (
    id_bitacora      bigserial,
    fecha            timestamptz  NOT NULL DEFAULT now(),
    tabla            varchar(63)  NOT NULL,
    operacion        varchar(10)  NOT NULL CHECK (operacion IN ('INSERT','UPDATE','DELETE','CONSULTA')),
    usuario          varchar(63)  NOT NULL DEFAULT session_user,
    datos_anteriores jsonb,
    datos_nuevos     jsonb,
    PRIMARY KEY (id_bitacora, fecha)
) PARTITION BY RANGE (fecha);
COMMENT ON TABLE bitacora IS 'Auditoría automática (triggers) de INSERT/UPDATE/DELETE sobre tablas críticas';

-- ---------------------------------------------------------------------
-- Clave de cifrado (esquema "seguridad": ningún rol de aplicación tiene acceso)
-- ---------------------------------------------------------------------
CREATE TABLE seguridad.clave_cifrado (
    id      smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    clave   text     NOT NULL CHECK (length(clave) >= 16),
    creada  timestamptz NOT NULL DEFAULT now()
);
INSERT INTO seguridad.clave_cifrado (clave) VALUES (:'clave_cifrado');

-- ---------------------------------------------------------------------
-- Gestión de particiones mensuales
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION hotel.fn_crear_particiones(p_tabla text, p_desde date, p_meses int)
RETURNS int LANGUAGE plpgsql SET search_path = hotel, public AS $$
DECLARE
    v_ini date; v_fin date; v_nombre text; v_creadas int := 0;
BEGIN
    FOR i IN 0 .. p_meses - 1 LOOP
        v_ini    := (date_trunc('month', p_desde) + make_interval(months => i))::date;
        v_fin    := (v_ini + interval '1 month')::date;
        v_nombre := p_tabla || '_' || to_char(v_ini, 'YYYYMM');
        IF to_regclass('hotel.' || v_nombre) IS NULL
           AND to_regclass('historico.' || v_nombre) IS NULL THEN
            EXECUTE format('CREATE TABLE hotel.%I PARTITION OF hotel.%I FOR VALUES FROM (%L) TO (%L)',
                           v_nombre, p_tabla, v_ini, v_fin);
            v_creadas := v_creadas + 1;
        END IF;
    END LOOP;
    RETURN v_creadas;
END $$;
COMMENT ON FUNCTION hotel.fn_crear_particiones IS 'Crea particiones mensuales (tabla_AAAAMM) si no existen. Se ejecuta mensualmente desde scripts/mantenimiento.sh';

-- Particiones iniciales: enero 2026 a junio 2027 + partición DEFAULT de seguridad
SELECT fn_crear_particiones('consumo_servicio', DATE '2026-01-01', 18);
SELECT fn_crear_particiones('bitacora',         DATE '2026-01-01', 18);
CREATE TABLE consumo_servicio_default PARTITION OF consumo_servicio DEFAULT;
CREATE TABLE bitacora_default         PARTITION OF bitacora DEFAULT;

-- Ajustes de autovacuum para tablas de solo inserción y alto volumen
ALTER TABLE consumo_servicio_default SET (autovacuum_vacuum_insert_scale_factor = 0.05);
ALTER TABLE bitacora_default         SET (autovacuum_vacuum_insert_scale_factor = 0.05);

RESET ROLE;
