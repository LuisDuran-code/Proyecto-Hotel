-- =====================================================================
--  08_seguridad.sql — Roles, permisos (mínimo privilegio), seguridad a
--  nivel de fila (RLS) y usuarios de los empleados
--
--  Modelo:   usuario (LOGIN)  --miembro de-->  rol de grupo (NOLOGIN)  --permisos--> objetos
--  Rol de grupo        Quién                      Puede
--  rol_administrador   administración del hotel   todo el negocio, bitácora (solo lectura), monitoreo
--  rol_recepcionista   recepción                  huéspedes, reservaciones, check-in/out, consumos, pagos
--  rol_mantenimiento   técnicos                   ver habitaciones, gestionar SUS órdenes de mantenimiento
--  rol_gerente         gerencia                   solo lectura y reportes
--  Técnicos: replicador (replicación), backup_operador (pg_dump), monitor (alertas)
-- =====================================================================
SET search_path = hotel, public;

-- ---------------------------------------------------------------------
-- 1. Roles de grupo
-- ---------------------------------------------------------------------
SELECT format('CREATE ROLE %I NOLOGIN', r)
  FROM unnest(ARRAY['rol_administrador','rol_recepcionista','rol_mantenimiento','rol_gerente']) r
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) \gexec

GRANT CONNECT ON DATABASE hotel TO rol_administrador, rol_recepcionista, rol_mantenimiento, rol_gerente;
GRANT USAGE   ON SCHEMA hotel   TO rol_administrador, rol_recepcionista, rol_mantenimiento, rol_gerente;
-- Ningún rol de aplicación recibe acceso al esquema "seguridad" (clave de cifrado)

-- Límites de sesión para usuarios de aplicación
ALTER ROLE rol_recepcionista SET statement_timeout = '30s';
ALTER ROLE rol_mantenimiento SET statement_timeout = '30s';
ALTER ROLE rol_gerente       SET statement_timeout = '120s';

-- ---------------------------------------------------------------------
-- 2. Administrador
-- ---------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA hotel TO rol_administrador;
REVOKE INSERT, UPDATE, DELETE ON hotel.bitacora FROM rol_administrador;   -- bitácora inmutable
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA hotel TO rol_administrador;
GRANT EXECUTE ON ALL ROUTINES IN SCHEMA hotel TO rol_administrador;
GRANT USAGE ON SCHEMA monitoreo, historico TO rol_administrador;
GRANT SELECT ON ALL TABLES IN SCHEMA monitoreo, historico TO rol_administrador;
GRANT EXECUTE ON FUNCTION monitoreo.fn_verificar_alertas(boolean) TO rol_administrador;
ALTER DEFAULT PRIVILEGES FOR ROLE hotel_owner IN SCHEMA hotel
      GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO rol_administrador;

-- ---------------------------------------------------------------------
-- 3. Recepcionista
-- ---------------------------------------------------------------------
GRANT SELECT ON tipo_habitacion, habitacion, servicio TO rol_recepcionista;
GRANT SELECT (id_empleado, nombres, apellidos, cargo) ON empleado TO rol_recepcionista;
-- Huésped: todo menos el documento cifrado; el alta se hace con fn_registrar_huesped()
GRANT SELECT (id_huesped, nombres, apellidos, tipo_documento, email, telefono, nacionalidad, fecha_registro)
      ON huesped TO rol_recepcionista;
GRANT UPDATE (nombres, apellidos, email, telefono, nacionalidad) ON huesped TO rol_recepcionista;
-- Reservaciones: se crean/cambian de estado solo con funciones (garantiza las reglas)
GRANT SELECT ON reservacion, reservacion_habitacion TO rol_recepcionista;
GRANT UPDATE (fecha_entrada, fecha_salida, cantidad_personas) ON reservacion TO rol_recepcionista;
GRANT INSERT ON reservacion_habitacion TO rol_recepcionista;
GRANT SELECT, INSERT ON consumo_servicio, pago, mantenimiento TO rol_recepcionista;
GRANT SELECT ON factura, detalle_factura TO rol_recepcionista;
GRANT USAGE ON SEQUENCE reservacion_habitacion_id_res_hab_seq, consumo_servicio_id_consumo_seq,
                        pago_id_pago_seq, mantenimiento_id_mantenimiento_seq TO rol_recepcionista;
GRANT SELECT ON vw_ocupacion_actual, vw_facturas_pendientes, vw_historial_huesped TO rol_recepcionista;
GRANT EXECUTE ON FUNCTION
      fn_registrar_huesped(text,text,text,text,text,text,text), fn_documento_huesped(int),
      fn_buscar_huesped_por_documento(text), fn_empleado_actual(),
      fn_habitaciones_disponibles(date,date,int), fn_crear_reservacion(int,date,date,int,int[],int),
      fn_reporte_ocupacion(date,date)
   TO rol_recepcionista;
GRANT EXECUTE ON PROCEDURE sp_check_in(int,timestamptz), sp_check_out(int,timestamptz),
      sp_cancelar_reservacion(int) TO rol_recepcionista;

-- ---------------------------------------------------------------------
-- 4. Mantenimiento: sin acceso a huéspedes, reservaciones ni dinero
-- ---------------------------------------------------------------------
GRANT SELECT ON habitacion, tipo_habitacion TO rol_mantenimiento;
GRANT SELECT (id_empleado, nombres, apellidos, cargo) ON empleado TO rol_mantenimiento;
GRANT SELECT, INSERT ON mantenimiento TO rol_mantenimiento;
GRANT UPDATE (estado, fecha_fin, descripcion) ON mantenimiento TO rol_mantenimiento;
GRANT USAGE ON SEQUENCE mantenimiento_id_mantenimiento_seq TO rol_mantenimiento;
GRANT EXECUTE ON FUNCTION fn_empleado_actual() TO rol_mantenimiento;

-- ---------------------------------------------------------------------
-- 5. Gerente: solo lectura (sin documentos ni bitácora)
-- ---------------------------------------------------------------------
GRANT SELECT ON tipo_habitacion, habitacion, servicio, empleado, reservacion, reservacion_habitacion,
                consumo_servicio, mantenimiento, factura, detalle_factura, pago TO rol_gerente;
GRANT SELECT (id_huesped, nombres, apellidos, nacionalidad, fecha_registro) ON huesped TO rol_gerente;
GRANT SELECT ON vw_ocupacion_actual, vw_ingresos_mensuales, vw_servicios_mas_utilizados,
                vw_historial_huesped, vw_facturas_pendientes, mv_resumen_mensual TO rol_gerente;
GRANT EXECUTE ON FUNCTION fn_reporte_ocupacion(date,date), fn_habitaciones_disponibles(date,date,int)
   TO rol_gerente;

-- ---------------------------------------------------------------------
-- 6. Seguridad a nivel de fila (RLS) en mantenimiento:
--    todos ven las órdenes, pero un técnico solo modifica las suyas.
-- ---------------------------------------------------------------------
ALTER TABLE mantenimiento ENABLE ROW LEVEL SECURITY;
CREATE POLICY p_mant_lectura   ON mantenimiento FOR SELECT USING (true);
CREATE POLICY p_mant_alta      ON mantenimiento FOR INSERT
       TO rol_administrador, rol_recepcionista, rol_mantenimiento WITH CHECK (true);
CREATE POLICY p_mant_admin_upd ON mantenimiento FOR UPDATE TO rol_administrador USING (true);
CREATE POLICY p_mant_admin_del ON mantenimiento FOR DELETE TO rol_administrador USING (true);
CREATE POLICY p_mant_tecnico   ON mantenimiento FOR UPDATE TO rol_mantenimiento
       USING      (id_empleado = hotel.fn_empleado_actual())
       WITH CHECK (id_empleado = hotel.fn_empleado_actual());

-- ---------------------------------------------------------------------
-- 7. Usuarios de los empleados (uno por empleado activo con usuario_db).
--    Contraseña inicial con vencimiento a 90 días.
-- ---------------------------------------------------------------------
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L CONNECTION LIMIT 3 VALID UNTIL %L IN ROLE %I',
              e.usuario_db, :'pass_empleados', (current_date + 90)::text,
              CASE e.cargo WHEN 'administrador' THEN 'rol_administrador'
                           WHEN 'recepcionista' THEN 'rol_recepcionista'
                           WHEN 'mantenimiento' THEN 'rol_mantenimiento'
                           ELSE 'rol_gerente' END)
  FROM empleado e
 WHERE e.activo AND e.usuario_db IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = e.usuario_db) \gexec

-- ---------------------------------------------------------------------
-- 8. Roles técnicos
-- ---------------------------------------------------------------------
-- Replicación (réplica en streaming y pg_basebackup)
SELECT format('CREATE ROLE replicador WITH LOGIN REPLICATION PASSWORD %L', :'pass_replicador')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'replicador') \gexec

-- Respaldos lógicos: lectura de todo (BYPASSRLS para que pg_dump vea todas las filas)
SELECT format('CREATE ROLE backup_operador WITH LOGIN BYPASSRLS PASSWORD %L IN ROLE pg_read_all_data', :'pass_backup')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'backup_operador') \gexec
GRANT CONNECT ON DATABASE hotel TO backup_operador;
GRANT USAGE ON SCHEMA monitoreo TO backup_operador;
GRANT INSERT ON monitoreo.registro_backup TO backup_operador;
GRANT USAGE ON SEQUENCE monitoreo.registro_backup_id_seq TO backup_operador;

-- Monitoreo
SELECT format('CREATE ROLE monitor WITH LOGIN PASSWORD %L IN ROLE pg_monitor', :'pass_monitor')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'monitor') \gexec
GRANT CONNECT ON DATABASE hotel TO monitor;
GRANT USAGE ON SCHEMA monitoreo TO monitor;
GRANT SELECT ON ALL TABLES IN SCHEMA monitoreo TO monitor;
GRANT EXECUTE ON FUNCTION monitoreo.fn_verificar_alertas(boolean) TO monitor;
GRANT INSERT ON monitoreo.registro_backup TO monitor;
GRANT USAGE ON SEQUENCE monitoreo.registro_backup_id_seq TO monitor;
