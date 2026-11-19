-- =====================================================================
--  02_funciones.sql — Cifrado, auditoría, reglas de negocio,
--                     procedimientos de check-in/check-out y facturación
-- =====================================================================
SET ROLE hotel_owner;
SET search_path = hotel, public;

-- =====================================================================
-- 1. CIFRADO DE DATOS SENSIBLES (documento de identidad del huésped)
-- =====================================================================
CREATE OR REPLACE FUNCTION seguridad.fn_clave()
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = seguridad AS
$$ SELECT clave FROM seguridad.clave_cifrado WHERE id = 1 $$;
REVOKE ALL ON FUNCTION seguridad.fn_clave() FROM PUBLIC;

-- HMAC del documento normalizado: búsqueda exacta sin descifrar y sin
-- posibilidad de ataque por diccionario (requiere la clave).
CREATE OR REPLACE FUNCTION hotel.fn_hash_documento(p_documento text)
RETURNS varchar(64) LANGUAGE sql STABLE SECURITY DEFINER SET search_path = hotel, public AS $$
    SELECT encode(hmac(upper(regexp_replace(p_documento, '[^0-9A-Za-z]', '', 'g')),
                       seguridad.fn_clave(), 'sha256'), 'hex')
$$;

CREATE OR REPLACE FUNCTION hotel.fn_registrar_huesped(
    p_nombres text, p_apellidos text, p_tipo_documento text, p_documento text,
    p_email text DEFAULT NULL, p_telefono text DEFAULT NULL, p_nacionalidad text DEFAULT NULL)
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = hotel, public AS $$
DECLARE v_id int;
BEGIN
    INSERT INTO huesped (nombres, apellidos, tipo_documento, documento_cifrado, documento_hash,
                         email, telefono, nacionalidad)
    VALUES (p_nombres, p_apellidos, p_tipo_documento,
            pgp_sym_encrypt(p_documento, seguridad.fn_clave(), 'cipher-algo=aes256'),
            fn_hash_documento(p_documento),
            p_email, p_telefono, p_nacionalidad)
    RETURNING id_huesped INTO v_id;
    RETURN v_id;
EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'Ya existe un huésped registrado con ese documento' USING ERRCODE = 'unique_violation';
END $$;

-- Descifra el documento y deja constancia del acceso en la bitácora
CREATE OR REPLACE FUNCTION hotel.fn_documento_huesped(p_id_huesped int)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = hotel, public AS $$
DECLARE v_doc text;
BEGIN
    SELECT pgp_sym_decrypt(documento_cifrado, seguridad.fn_clave())
      INTO v_doc FROM huesped WHERE id_huesped = p_id_huesped;
    INSERT INTO bitacora (tabla, operacion, datos_nuevos)
    VALUES ('huesped', 'CONSULTA', jsonb_build_object('id_huesped', p_id_huesped, 'campo', 'documento'));
    RETURN v_doc;
END $$;

CREATE OR REPLACE FUNCTION hotel.fn_buscar_huesped_por_documento(p_documento text)
RETURNS int LANGUAGE sql STABLE SECURITY DEFINER SET search_path = hotel, public AS $$
    SELECT id_huesped FROM huesped WHERE documento_hash = fn_hash_documento(p_documento)
$$;

-- Empleado asociado al usuario de base de datos que inició la sesión
CREATE OR REPLACE FUNCTION hotel.fn_empleado_actual()
RETURNS int LANGUAGE sql STABLE SECURITY DEFINER SET search_path = hotel, public AS $$
    SELECT id_empleado FROM empleado WHERE usuario_db = session_user AND activo
$$;

-- =====================================================================
-- 2. AUDITORÍA AUTOMÁTICA
-- =====================================================================
CREATE OR REPLACE FUNCTION hotel.fn_auditoria()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = hotel, public AS $$
DECLARE v_old jsonb; v_new jsonb;
BEGIN
    IF TG_OP <> 'INSERT' THEN v_old := to_jsonb(OLD) - 'documento_cifrado'; END IF;
    IF TG_OP <> 'DELETE' THEN v_new := to_jsonb(NEW) - 'documento_cifrado'; END IF;
    IF TG_OP = 'UPDATE' AND v_old = v_new THEN RETURN NULL; END IF;   -- sin cambios reales
    INSERT INTO bitacora (tabla, operacion, usuario, datos_anteriores, datos_nuevos)
    -- TG_ARGV[0] = nombre lógico (en tablas particionadas TG_TABLE_NAME sería la partición)
    VALUES (COALESCE(TG_ARGV[0], TG_TABLE_NAME), TG_OP, session_user, v_old, v_new);
    RETURN NULL;
END $$;

DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['tipo_habitacion','habitacion','servicio','huesped','empleado',
                             'reservacion','reservacion_habitacion','mantenimiento',
                             'factura','detalle_factura','pago','consumo_servicio']
    LOOP
        EXECUTE format('CREATE TRIGGER trg_auditoria AFTER INSERT OR UPDATE OR DELETE ON hotel.%I
                        FOR EACH ROW EXECUTE FUNCTION hotel.fn_auditoria(%L)', t, t);
    END LOOP;
END $$;

-- =====================================================================
-- 3. REGLAS DE NEGOCIO (triggers)
-- =====================================================================

-- 3.1 Asignación de habitación: completa periodo y tarifa, valida estado
CREATE OR REPLACE FUNCTION hotel.fn_tg_res_hab_antes()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = hotel, public AS $$
DECLARE r reservacion; v_estado text;
BEGIN
    SELECT * INTO r FROM reservacion WHERE id_reservacion = NEW.id_reservacion;
    NEW.periodo := daterange(r.fecha_entrada, r.fecha_salida, '[)');
    IF NEW.tarifa_noche IS NULL THEN
        SELECT t.tarifa_base INTO NEW.tarifa_noche
          FROM habitacion h JOIN tipo_habitacion t USING (id_tipo)
         WHERE h.id_habitacion = NEW.id_habitacion;
    END IF;
    SELECT estado INTO v_estado FROM habitacion WHERE id_habitacion = NEW.id_habitacion;
    IF TG_OP = 'INSERT' AND v_estado = 'fuera_servicio' THEN
        RAISE EXCEPTION 'La habitación % está fuera de servicio', NEW.id_habitacion;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_res_hab_antes BEFORE INSERT OR UPDATE OF id_habitacion, periodo
    ON reservacion_habitacion FOR EACH ROW EXECUTE FUNCTION fn_tg_res_hab_antes();

-- 3.2 Cambios en la reservación se propagan a sus habitaciones
CREATE OR REPLACE FUNCTION hotel.fn_tg_reservacion_despues()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = hotel, public AS $$
BEGIN
    IF NEW.fecha_entrada <> OLD.fecha_entrada OR NEW.fecha_salida <> OLD.fecha_salida THEN
        UPDATE reservacion_habitacion
           SET periodo = daterange(NEW.fecha_entrada, NEW.fecha_salida, '[)')
         WHERE id_reservacion = NEW.id_reservacion;
    END IF;
    IF NEW.estado IN ('cancelada','no_show') AND OLD.estado NOT IN ('cancelada','no_show') THEN
        -- libera las habitaciones para otras reservaciones
        UPDATE reservacion_habitacion SET activa = false WHERE id_reservacion = NEW.id_reservacion;
    END IF;
    RETURN NULL;
END $$;
CREATE TRIGGER trg_reservacion_despues AFTER UPDATE OF fecha_entrada, fecha_salida, estado
    ON reservacion FOR EACH ROW EXECUTE FUNCTION fn_tg_reservacion_despues();

-- 3.3 Consumo de servicios: solo en estadías en curso; precio del catálogo
CREATE OR REPLACE FUNCTION hotel.fn_tg_consumo_antes()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = hotel, public AS $$
DECLARE v_estado text; v_precio numeric; v_activo boolean;
BEGIN
    SELECT estado INTO v_estado FROM reservacion WHERE id_reservacion = NEW.id_reservacion;
    IF v_estado IS DISTINCT FROM 'en_curso' THEN
        RAISE EXCEPTION 'Solo se registran consumos de reservaciones en curso (estado actual: %)', v_estado;
    END IF;
    SELECT precio, activo INTO v_precio, v_activo FROM servicio WHERE id_servicio = NEW.id_servicio;
    IF NOT v_activo THEN RAISE EXCEPTION 'El servicio % no está activo', NEW.id_servicio; END IF;
    NEW.precio_unitario := COALESCE(NEW.precio_unitario, v_precio);
    NEW.id_empleado     := COALESCE(NEW.id_empleado, fn_empleado_actual());
    RETURN NEW;
END $$;
CREATE TRIGGER trg_consumo_antes BEFORE INSERT ON consumo_servicio
    FOR EACH ROW EXECUTE FUNCTION fn_tg_consumo_antes();

-- 3.4 Pagos: no se permite pagar de más ni pagar facturas anuladas;
--     la factura pasa a "pagada" al completar el total
CREATE OR REPLACE FUNCTION hotel.fn_tg_pago_antes()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = hotel, public AS $$
DECLARE f factura; v_pagado numeric;
BEGIN
    SELECT * INTO f FROM factura WHERE id_factura = NEW.id_factura FOR UPDATE;
    IF f.estado <> 'emitida' THEN
        RAISE EXCEPTION 'La factura % está %; no admite pagos', f.numero, f.estado;
    END IF;
    SELECT COALESCE(sum(monto), 0) INTO v_pagado FROM pago WHERE id_factura = NEW.id_factura;
    IF v_pagado + NEW.monto > f.total THEN
        RAISE EXCEPTION 'El pago excede el saldo pendiente (saldo: %)', f.total - v_pagado;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_pago_antes BEFORE INSERT ON pago FOR EACH ROW EXECUTE FUNCTION fn_tg_pago_antes();

CREATE OR REPLACE FUNCTION hotel.fn_tg_pago_despues()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = hotel, public AS $$
BEGIN
    UPDATE factura f SET estado = 'pagada'
     WHERE f.id_factura = NEW.id_factura
       AND (SELECT sum(monto) FROM pago WHERE id_factura = f.id_factura) >= f.total;
    RETURN NULL;
END $$;
CREATE TRIGGER trg_pago_despues AFTER INSERT ON pago FOR EACH ROW EXECUTE FUNCTION fn_tg_pago_despues();

-- 3.5 Mantenimiento: sincroniza el estado de la habitación
CREATE OR REPLACE FUNCTION hotel.fn_tg_mantenimiento_despues()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = hotel, public AS $$
BEGIN
    IF NEW.estado = 'en_proceso' THEN
        IF (SELECT estado FROM habitacion WHERE id_habitacion = NEW.id_habitacion) = 'ocupada' THEN
            RAISE EXCEPTION 'La habitación está ocupada; programe el mantenimiento para después del check-out';
        END IF;
        UPDATE habitacion SET estado = 'mantenimiento' WHERE id_habitacion = NEW.id_habitacion;
    ELSIF NEW.estado IN ('finalizado','cancelado') THEN
        UPDATE habitacion SET estado = 'disponible'
         WHERE id_habitacion = NEW.id_habitacion AND estado = 'mantenimiento'
           AND NOT EXISTS (SELECT 1 FROM mantenimiento m
                            WHERE m.id_habitacion = NEW.id_habitacion
                              AND m.estado = 'en_proceso' AND m.id_mantenimiento <> NEW.id_mantenimiento);
    END IF;
    RETURN NULL;
END $$;
CREATE TRIGGER trg_mantenimiento_despues AFTER INSERT OR UPDATE OF estado ON mantenimiento
    FOR EACH ROW EXECUTE FUNCTION fn_tg_mantenimiento_despues();

-- =====================================================================
-- 4. DISPONIBILIDAD Y RESERVACIONES
-- =====================================================================
CREATE OR REPLACE FUNCTION hotel.fn_habitaciones_disponibles(
    p_entrada date, p_salida date, p_id_tipo int DEFAULT NULL)
RETURNS TABLE (id_habitacion int, numero varchar, piso smallint, tipo varchar,
               capacidad smallint, tarifa numeric)
LANGUAGE sql STABLE SET search_path = hotel, public AS $$
    SELECT h.id_habitacion, h.numero, h.piso, t.nombre, t.capacidad, t.tarifa_base
      FROM habitacion h JOIN tipo_habitacion t USING (id_tipo)
     WHERE h.estado <> 'fuera_servicio'
       AND (p_id_tipo IS NULL OR h.id_tipo = p_id_tipo)
       AND NOT EXISTS (SELECT 1 FROM reservacion_habitacion rh
                        WHERE rh.id_habitacion = h.id_habitacion AND rh.activa
                          AND rh.periodo && daterange(p_entrada, p_salida, '[)'))
     ORDER BY t.tarifa_base, h.numero
$$;

CREATE OR REPLACE FUNCTION hotel.fn_crear_reservacion(
    p_id_huesped int, p_entrada date, p_salida date, p_personas int,
    p_habitaciones int[], p_id_empleado int DEFAULT NULL)
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = hotel, public AS $$
DECLARE v_id int; v_capacidad int; v_emp int;
BEGIN
    v_emp := COALESCE(p_id_empleado, fn_empleado_actual());
    IF v_emp IS NULL THEN
        RAISE EXCEPTION 'El usuario % no está asociado a un empleado activo', session_user;
    END IF;
    SELECT sum(t.capacidad) INTO v_capacidad
      FROM habitacion h JOIN tipo_habitacion t USING (id_tipo)
     WHERE h.id_habitacion = ANY (p_habitaciones);
    IF COALESCE(v_capacidad, 0) < p_personas THEN
        RAISE EXCEPTION 'Capacidad insuficiente: % personas para % plazas', p_personas, COALESCE(v_capacidad, 0);
    END IF;

    INSERT INTO reservacion (id_huesped, id_empleado, fecha_entrada, fecha_salida, cantidad_personas, estado)
    VALUES (p_id_huesped, v_emp, p_entrada, p_salida, p_personas, 'confirmada')
    RETURNING id_reservacion INTO v_id;

    INSERT INTO reservacion_habitacion (id_reservacion, id_habitacion)
    SELECT v_id, unnest(p_habitaciones);
    RETURN v_id;
EXCEPTION WHEN exclusion_violation THEN
    RAISE EXCEPTION 'Alguna habitación ya está reservada entre % y %', p_entrada, p_salida
          USING ERRCODE = 'exclusion_violation';
END $$;

CREATE OR REPLACE PROCEDURE hotel.sp_cancelar_reservacion(p_id_reservacion int)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = hotel, public AS $$
BEGIN
    UPDATE reservacion SET estado = 'cancelada'
     WHERE id_reservacion = p_id_reservacion AND estado IN ('pendiente','confirmada');
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La reservación % no existe o ya no se puede cancelar', p_id_reservacion;
    END IF;
END $$;

-- =====================================================================
-- 5. CHECK-IN, CHECK-OUT Y FACTURACIÓN
-- =====================================================================
CREATE OR REPLACE PROCEDURE hotel.sp_check_in(p_id_reservacion int, p_momento timestamptz DEFAULT now())
LANGUAGE plpgsql SECURITY DEFINER SET search_path = hotel, public AS $$
DECLARE r reservacion;
BEGIN
    SELECT * INTO r FROM reservacion WHERE id_reservacion = p_id_reservacion FOR UPDATE;
    IF r.estado NOT IN ('pendiente','confirmada') THEN
        RAISE EXCEPTION 'No se puede hacer check-in: la reservación está %', r.estado;
    END IF;
    IF p_momento::date NOT BETWEEN r.fecha_entrada AND r.fecha_salida - 1 THEN
        RAISE EXCEPTION 'Check-in fuera de las fechas reservadas (% a %)', r.fecha_entrada, r.fecha_salida;
    END IF;
    IF EXISTS (SELECT 1 FROM reservacion_habitacion rh JOIN habitacion h USING (id_habitacion)
                WHERE rh.id_reservacion = p_id_reservacion AND h.estado <> 'disponible') THEN
        RAISE EXCEPTION 'Alguna habitación asignada no está disponible (ocupada o en mantenimiento)';
    END IF;
    UPDATE reservacion SET estado = 'en_curso', checkin_real = p_momento
     WHERE id_reservacion = p_id_reservacion;
    UPDATE habitacion SET estado = 'ocupada'
     WHERE id_habitacion IN (SELECT id_habitacion FROM reservacion_habitacion
                              WHERE id_reservacion = p_id_reservacion AND activa);
END $$;

CREATE SEQUENCE IF NOT EXISTS hotel.seq_numero_factura;

CREATE OR REPLACE FUNCTION hotel.fn_generar_factura(p_id_reservacion int, p_fecha timestamptz DEFAULT now())
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = hotel, public AS $$
DECLARE
    r reservacion; v_id int; v_subtotal numeric(12,2); v_iva numeric(12,2);
BEGIN
    SELECT * INTO r FROM reservacion WHERE id_reservacion = p_id_reservacion;
    IF EXISTS (SELECT 1 FROM factura WHERE id_reservacion = p_id_reservacion) THEN
        RAISE EXCEPTION 'La reservación % ya tiene factura', p_id_reservacion;
    END IF;

    INSERT INTO factura (id_reservacion, numero, fecha_emision, subtotal, iva, total)
    VALUES (p_id_reservacion,
            'F-' || to_char(p_fecha, 'YYYY') || '-' || lpad(nextval('seq_numero_factura')::text, 6, '0'),
            p_fecha, 0, 0, 0)
    RETURNING id_factura INTO v_id;

    -- Alojamiento: una línea por habitación
    INSERT INTO detalle_factura (id_factura, tipo, concepto, cantidad, precio_unitario, subtotal)
    SELECT v_id, 'habitacion',
           format('Habitación %s (%s) - %s noche(s)', h.numero, t.nombre, upper(rh.periodo) - lower(rh.periodo)),
           upper(rh.periodo) - lower(rh.periodo), rh.tarifa_noche,
           round((upper(rh.periodo) - lower(rh.periodo)) * rh.tarifa_noche, 2)
      FROM reservacion_habitacion rh
      JOIN habitacion h USING (id_habitacion) JOIN tipo_habitacion t USING (id_tipo)
     WHERE rh.id_reservacion = p_id_reservacion AND rh.activa;

    -- Servicios consumidos, agrupados (el filtro por fecha permite poda de particiones)
    INSERT INTO detalle_factura (id_factura, tipo, concepto, cantidad, precio_unitario, subtotal)
    SELECT v_id, 'servicio', s.nombre, sum(c.cantidad), c.precio_unitario,
           round(sum(c.cantidad) * c.precio_unitario, 2)
      FROM consumo_servicio c JOIN servicio s USING (id_servicio)
     WHERE c.id_reservacion = p_id_reservacion
       AND c.fecha >= r.fecha_entrada - 1
     GROUP BY s.nombre, c.precio_unitario;

    SELECT COALESCE(sum(subtotal), 0) INTO v_subtotal FROM detalle_factura WHERE id_factura = v_id;
    v_iva := round(v_subtotal * 0.13, 2);
    UPDATE factura SET subtotal = v_subtotal, iva = v_iva, total = v_subtotal + v_iva
     WHERE id_factura = v_id;
    RETURN v_id;
END $$;

CREATE OR REPLACE PROCEDURE hotel.sp_check_out(p_id_reservacion int, p_momento timestamptz DEFAULT now())
LANGUAGE plpgsql SECURITY DEFINER SET search_path = hotel, public AS $$
DECLARE r reservacion;
BEGIN
    SELECT * INTO r FROM reservacion WHERE id_reservacion = p_id_reservacion FOR UPDATE;
    IF r.estado <> 'en_curso' THEN
        RAISE EXCEPTION 'No se puede hacer check-out: la reservación está %', r.estado;
    END IF;
    UPDATE reservacion SET estado = 'finalizada', checkout_real = p_momento
     WHERE id_reservacion = p_id_reservacion;
    UPDATE habitacion SET estado = 'disponible'
     WHERE estado = 'ocupada'
       AND id_habitacion IN (SELECT id_habitacion FROM reservacion_habitacion
                              WHERE id_reservacion = p_id_reservacion AND activa);
    PERFORM fn_generar_factura(p_id_reservacion, p_momento);
END $$;

-- Ninguna función se ejecuta por defecto: los permisos se otorgan por rol en 05_seguridad.sql
REVOKE EXECUTE ON ALL FUNCTIONS  IN SCHEMA hotel, seguridad FROM PUBLIC;
REVOKE EXECUTE ON ALL PROCEDURES IN SCHEMA hotel FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA hotel REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

RESET ROLE;
