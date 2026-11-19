-- =====================================================================
--  07_datos_prueba.sql — Datos de prueba (>= 10 registros por tabla)
--  Se cargan usando las funciones y procedimientos de negocio para que
--  los datos respeten todas las reglas (fechas de referencia: nov-2026).
-- =====================================================================
SET search_path = hotel, public;

-- ---------------------------------------------------------------------
-- Catálogos
-- ---------------------------------------------------------------------
INSERT INTO tipo_habitacion (nombre, capacidad, tarifa_base, descripcion) VALUES
 ('Individual',          1,  45.00, 'Cama individual, escritorio, baño privado'),
 ('Doble',               2,  65.00, 'Dos camas individuales o una matrimonial'),
 ('Doble Superior',      2,  85.00, 'Cama queen, vista al jardín, minibar'),
 ('Triple',              3,  95.00, 'Tres camas individuales'),
 ('Familiar',            4, 120.00, 'Dos camas matrimoniales y sofá cama'),
 ('Suite Junior',        2, 140.00, 'Cama king y sala de estar'),
 ('Suite Ejecutiva',     3, 190.00, 'Cama king, sala, área de trabajo y sofá cama'),
 ('Suite Presidencial',  4, 350.00, 'Dos habitaciones, sala, comedor y jacuzzi'),
 ('Accesible',           2,  70.00, 'Adaptada para personas con movilidad reducida'),
 ('Cuádruple',           4, 110.00, 'Cuatro camas individuales');

INSERT INTO habitacion (numero, piso, id_tipo) VALUES
 ('101',1,1), ('102',1,1), ('103',1,2), ('104',1,2), ('105',1,9),
 ('201',2,2), ('202',2,3), ('203',2,4), ('204',2,5), ('205',2,2),
 ('301',3,6), ('302',3,6), ('303',3,3), ('304',3,10),('305',3,4),
 ('401',4,7), ('402',4,7), ('403',4,8), ('404',4,5), ('405',4,1);

INSERT INTO servicio (nombre, categoria, precio, activo) VALUES
 ('Desayuno buffet',            'restaurante', 12.00, true),
 ('Cena a la carta',            'restaurante', 25.00, true),
 ('Servicio a la habitación',   'restaurante', 18.00, true),
 ('Lavado y planchado (pieza)', 'lavanderia',   3.50, true),
 ('Lavado express',             'lavanderia',  15.00, true),
 ('Traslado aeropuerto',        'transporte',  35.00, true),
 ('Tour Ruta de las Flores',    'transporte',  60.00, true),
 ('Masaje relajante 60 min',    'spa',         50.00, true),
 ('Facial hidratante',          'spa',         40.00, true),
 ('Minibar - bebida',           'minibar',      3.00, true),
 ('Minibar - snack',            'minibar',      2.50, true),
 ('Estacionamiento por noche',  'otros',        5.00, true),
 ('Alquiler de bicicleta',      'otros',        8.00, false);

INSERT INTO empleado (nombres, apellidos, cargo, usuario_db, activo) VALUES
 ('Carlos',   'Morales',   'administrador', 'admin_cmorales',  true),   -- 1
 ('Ana',      'Rivas',     'administrador', 'admin_arivas',    true),   -- 2
 ('Laura',    'Hernández', 'recepcionista', 'rec_lhernandez',  true),   -- 3
 ('José',     'Martínez',  'recepcionista', 'rec_jmartinez',   true),   -- 4
 ('Sofía',    'Castillo',  'recepcionista', 'rec_scastillo',   true),   -- 5
 ('Diego',    'Flores',    'recepcionista', 'rec_dflores',     true),   -- 6
 ('Mario',    'López',     'mantenimiento', 'mant_mlopez',     true),   -- 7
 ('Pedro',    'Ramírez',   'mantenimiento', 'mant_pramirez',   true),   -- 8
 ('Rosa',     'Guzmán',    'mantenimiento', 'mant_rguzman',    true),   -- 9
 ('Luis',     'Portillo',  'mantenimiento', 'mant_lportillo',  true),   -- 10
 ('Gabriela', 'Mejía',     'gerente',       'ger_gmejia',      true),   -- 11
 ('Ernesto',  'Aguilar',   'recepcionista', NULL,              false);  -- 12 (ex-empleado, sin acceso)

-- ---------------------------------------------------------------------
-- Huéspedes (el documento se cifra dentro de la función)
-- ---------------------------------------------------------------------
SELECT fn_registrar_huesped('María José', 'Pérez Alvarado', 'DUI',       '04567812-3', 'mjperez@correo.com',     '7012-3344', 'Salvadoreña');
SELECT fn_registrar_huesped('Roberto',    'Campos Díaz',    'DUI',       '03322114-5', 'rcampos@correo.com',     '7788-1020', 'Salvadoreña');
SELECT fn_registrar_huesped('Andrea',     'Velásquez',      'DUI',       '05893321-0', 'avelasquez@correo.com',  '7555-6677', 'Salvadoreña');
SELECT fn_registrar_huesped('John',       'Miller',         'pasaporte', 'X12345678',  'jmiller@mail.com',       '+1 305 555 0101', 'Estadounidense');
SELECT fn_registrar_huesped('Lucía',      'Fernández',      'pasaporte', 'PAB998877',  'lfernandez@mail.es',     '+34 600 112 233', 'Española');
SELECT fn_registrar_huesped('Héctor',     'Mendoza Ruiz',   'pasaporte', 'G44556677',  'hmendoza@correo.gt',     '+502 5544 3322',  'Guatemalteca');
SELECT fn_registrar_huesped('Karla',      'Orellana',       'DUI',       '06112233-4', 'korellana@correo.com',   '7111-2233', 'Salvadoreña');
SELECT fn_registrar_huesped('Thomas',     'Becker',         'pasaporte', 'C7Y8Z9K1L',  'tbecker@mail.de',        '+49 151 2345678', 'Alemana');
SELECT fn_registrar_huesped('Daniela',    'Rodríguez',      'carnet_residente', 'CR-2024-0815', 'drodriguez@correo.com', '7999-0001', 'Hondureña');
SELECT fn_registrar_huesped('Fernando',   'Quintanilla',    'DUI',       '02233445-6', 'fquintanilla@correo.com','7234-5678', 'Salvadoreña');
SELECT fn_registrar_huesped('Valeria',    'Navarro',        'pasaporte', 'N33221100',  'vnavarro@mail.mx',       '+52 55 1234 5678', 'Mexicana');
SELECT fn_registrar_huesped('Samuel',     'Chávez Torres',  'DUI',       '01987654-3', NULL,                     '7654-3210', 'Salvadoreña');

-- ---------------------------------------------------------------------
-- Reservaciones: fn_crear_reservacion(huésped, entrada, salida, personas, habitaciones[], empleado)
-- ---------------------------------------------------------------------
SELECT fn_crear_reservacion( 1, '2026-09-03', '2026-09-06', 2, ARRAY[3],      3);  -- 1
SELECT fn_crear_reservacion( 2, '2026-09-10', '2026-09-14', 4, ARRAY[9],      4);  -- 2
SELECT fn_crear_reservacion( 3, '2026-09-18', '2026-09-20', 1, ARRAY[1],      5);  -- 3
SELECT fn_crear_reservacion( 4, '2026-09-25', '2026-09-28', 2, ARRAY[11],     6);  -- 4
SELECT fn_crear_reservacion( 5, '2026-10-02', '2026-10-05', 3, ARRAY[8],      3);  -- 5
SELECT fn_crear_reservacion( 6, '2026-10-09', '2026-10-12', 6, ARRAY[16, 9],  4);  -- 6 (dos habitaciones)
SELECT fn_crear_reservacion( 7, '2026-10-20', '2026-10-24', 2, ARRAY[18],     5);  -- 7
SELECT fn_crear_reservacion( 1, '2026-10-30', '2026-11-02', 2, ARRAY[6],      6);  -- 8 (huésped recurrente)
SELECT fn_crear_reservacion( 8, '2026-11-05', '2026-11-08', 2, ARRAY[12],     3);  -- 9
SELECT fn_crear_reservacion( 9, '2026-11-10', '2026-11-13', 1, ARRAY[2],      4);  -- 10
SELECT fn_crear_reservacion(10, '2026-11-16', '2026-11-20', 2, ARRAY[4],      5);  -- 11 en curso
SELECT fn_crear_reservacion(11, '2026-11-17', '2026-11-21', 4, ARRAY[14],     6);  -- 12 en curso
SELECT fn_crear_reservacion(12, '2026-11-15', '2026-11-19', 2, ARRAY[17],     3);  -- 13 en curso
SELECT fn_crear_reservacion( 2, '2026-11-27', '2026-11-30', 3, ARRAY[15],     4);  -- 14 futura
SELECT fn_crear_reservacion( 3, '2026-12-20', '2026-12-27', 4, ARRAY[19],     5);  -- 15 futura
SELECT fn_crear_reservacion( 5, '2026-12-30', '2027-01-02', 2, ARRAY[18],     6);  -- 16 futura (cruza de año)
SELECT fn_crear_reservacion( 6, '2026-12-05', '2026-12-08', 2, ARRAY[3],      3);  -- 17 se cancela
SELECT fn_crear_reservacion( 7, '2026-11-12', '2026-11-14', 1, ARRAY[20],     4);  -- 18 no se presentó

CALL sp_cancelar_reservacion(17);
UPDATE reservacion SET estado = 'no_show' WHERE id_reservacion = 18;

-- ---------------------------------------------------------------------
-- Estadías: check-in -> consumos -> check-out (genera factura) -> pagos
-- ---------------------------------------------------------------------
-- 1
CALL sp_check_in(1, '2026-09-03 14:20');
INSERT INTO consumo_servicio (fecha, id_reservacion, id_servicio, id_empleado, cantidad) VALUES
 ('2026-09-04 07:30', 1, 1, 3, 2), ('2026-09-04 20:10', 1, 2, 3, 2), ('2026-09-05 07:45', 1, 1, 3, 2);
CALL sp_check_out(1, '2026-09-06 11:05');
-- 2
CALL sp_check_in(2, '2026-09-10 15:00');
INSERT INTO consumo_servicio (fecha, id_reservacion, id_servicio, id_empleado, cantidad) VALUES
 ('2026-09-11 08:00', 2, 1, 4, 4), ('2026-09-11 10:00', 2, 7, 4, 4), ('2026-09-12 16:00', 2, 4, 4, 8),
 ('2026-09-13 21:00', 2, 10, 4, 6);
CALL sp_check_out(2, '2026-09-14 10:40');
-- 3
CALL sp_check_in(3, '2026-09-18 16:30');
INSERT INTO consumo_servicio (fecha, id_reservacion, id_servicio, id_empleado, cantidad) VALUES
 ('2026-09-19 07:00', 3, 1, 5, 1), ('2026-09-19 19:00', 3, 12, 5, 2);
CALL sp_check_out(3, '2026-09-20 09:15');
-- 4
CALL sp_check_in(4, '2026-09-25 13:00');
INSERT INTO consumo_servicio (fecha, id_reservacion, id_servicio, id_empleado, cantidad) VALUES
 ('2026-09-25 13:30', 4, 6, 6, 1), ('2026-09-26 17:00', 4, 8, 6, 2), ('2026-09-27 20:00', 4, 3, 6, 2),
 ('2026-09-28 06:00', 4, 6, 6, 1);
CALL sp_check_out(4, '2026-09-28 06:30');
-- 5
CALL sp_check_in(5, '2026-10-02 15:10');
INSERT INTO consumo_servicio (fecha, id_reservacion, id_servicio, id_empleado, cantidad) VALUES
 ('2026-10-03 08:00', 5, 1, 3, 3), ('2026-10-04 08:00', 5, 1, 3, 3), ('2026-10-04 15:00', 5, 5, 3, 1);
CALL sp_check_out(5, '2026-10-05 11:00');
-- 6
CALL sp_check_in(6, '2026-10-09 14:00');
INSERT INTO consumo_servicio (fecha, id_reservacion, id_servicio, id_empleado, cantidad) VALUES
 ('2026-10-10 08:00', 6, 1, 4, 6), ('2026-10-10 09:00', 6, 7, 4, 6), ('2026-10-11 19:30', 6, 2, 4, 6),
 ('2026-10-11 22:00', 6, 11, 4, 5);
CALL sp_check_out(6, '2026-10-12 10:30');
-- 7
CALL sp_check_in(7, '2026-10-20 12:00');
INSERT INTO consumo_servicio (fecha, id_reservacion, id_servicio, id_empleado, cantidad) VALUES
 ('2026-10-20 12:30', 7, 6, 5, 1), ('2026-10-21 10:00', 7, 8, 5, 2), ('2026-10-22 10:00', 7, 9, 5, 2),
 ('2026-10-23 20:00', 7, 3, 5, 2), ('2026-10-24 05:00', 7, 6, 5, 1);
CALL sp_check_out(7, '2026-10-24 05:30');
-- 8
CALL sp_check_in(8, '2026-10-30 15:45');
INSERT INTO consumo_servicio (fecha, id_reservacion, id_servicio, id_empleado, cantidad) VALUES
 ('2026-10-31 08:00', 8, 1, 6, 2), ('2026-11-01 08:10', 8, 1, 6, 2), ('2026-11-01 21:00', 8, 10, 6, 3);
CALL sp_check_out(8, '2026-11-02 11:20');
-- 9
CALL sp_check_in(9, '2026-11-05 14:00');
INSERT INTO consumo_servicio (fecha, id_reservacion, id_servicio, id_empleado, cantidad) VALUES
 ('2026-11-06 09:00', 9, 7, 3, 2), ('2026-11-07 18:00', 9, 8, 3, 1), ('2026-11-07 20:30', 9, 2, 3, 2);
CALL sp_check_out(9, '2026-11-08 10:00');
-- 10
CALL sp_check_in(10, '2026-11-10 17:00');
INSERT INTO consumo_servicio (fecha, id_reservacion, id_servicio, id_empleado, cantidad) VALUES
 ('2026-11-11 07:30', 10, 1, 4, 1), ('2026-11-12 18:00', 10, 4, 4, 5);
CALL sp_check_out(10, '2026-11-13 09:00');
-- 11, 12, 13: estadías en curso (sin check-out)
CALL sp_check_in(11, '2026-11-16 15:00');
CALL sp_check_in(12, '2026-11-17 13:30');
CALL sp_check_in(13, '2026-11-15 14:10');
INSERT INTO consumo_servicio (fecha, id_reservacion, id_servicio, id_empleado, cantidad) VALUES
 ('2026-11-17 08:00', 11, 1, 5, 2), ('2026-11-17 19:00', 11, 2, 5, 2),
 ('2026-11-18 08:00', 12, 1, 6, 4), ('2026-11-16 10:00', 13, 8, 3, 1), ('2026-11-17 22:00', 13, 10, 3, 4);

-- Pagos (tarjeta: solo últimos 4 dígitos)
INSERT INTO pago (id_factura, fecha, monto, metodo, ultimos_4)
SELECT f.id_factura, f.fecha_emision + interval '5 minutes', f.total, x.metodo, x.ult4
  FROM factura f
  JOIN (VALUES (1,'tarjeta','4242'), (2,'efectivo',NULL), (3,'transferencia',NULL), (4,'tarjeta','1881'),
               (5,'tarjeta','0005'), (6,'transferencia',NULL), (7,'tarjeta','7777'), (8,'efectivo',NULL))
       AS x(id_res, metodo, ult4) ON x.id_res = f.id_reservacion;
-- Reservación 9: pago dividido (tarjeta + efectivo)
INSERT INTO pago (id_factura, fecha, monto, metodo, ultimos_4)
SELECT id_factura, fecha_emision + interval '3 minutes', 200.00, 'tarjeta', '3141' FROM factura WHERE id_reservacion = 9;
INSERT INTO pago (id_factura, fecha, monto, metodo)
SELECT id_factura, fecha_emision + interval '4 minutes', total - 200.00, 'efectivo' FROM factura WHERE id_reservacion = 9;
-- Reservación 10: abono parcial (queda saldo pendiente)
INSERT INTO pago (id_factura, fecha, monto, metodo)
SELECT id_factura, fecha_emision + interval '2 minutes', 100.00, 'efectivo' FROM factura WHERE id_reservacion = 10;

-- ---------------------------------------------------------------------
-- Mantenimiento (el trigger sincroniza el estado de la habitación)
-- ---------------------------------------------------------------------
INSERT INTO mantenimiento (id_habitacion, id_empleado, tipo, descripcion, fecha_inicio, fecha_fin, estado) VALUES
 ( 3, 7, 'limpieza',   'Limpieza profunda de alfombra',               '2026-09-06', '2026-09-06', 'finalizado'),
 ( 9, 8, 'correctivo', 'Fuga en lavamanos',                           '2026-09-15', '2026-09-16', 'finalizado'),
 (11, 9, 'preventivo', 'Mantenimiento de aire acondicionado',         '2026-09-29', '2026-09-30', 'finalizado'),
 (16, 10,'preventivo', 'Revisión de instalación eléctrica',           '2026-10-13', '2026-10-13', 'finalizado'),
 (18, 7, 'correctivo', 'Reparación de bomba del jacuzzi',             '2026-10-25', '2026-10-27', 'finalizado'),
 ( 6, 8, 'preventivo', 'Fumigación preventiva',                       '2026-11-03', '2026-11-03', 'finalizado'),
 (10, 9, 'correctivo', 'Cambio de cerradura electrónica',             '2026-11-09', '2026-11-10', 'finalizado'),
 ( 7, 10,'preventivo', 'Pintura de paredes',                          '2026-11-20', NULL,         'programado'),
 (20, 7, 'preventivo', 'Revisión de calentador de agua',              '2026-11-25', NULL,         'programado'),
 ( 1, 8, 'correctivo', 'Cortina dañada (se repondrá con otra)',       '2026-11-01', '2026-11-01', 'cancelado');
-- Trabajos en proceso: la habitación pasa a "mantenimiento"
INSERT INTO mantenimiento (id_habitacion, id_empleado, tipo, descripcion, fecha_inicio, estado) VALUES
 ( 5, 9, 'correctivo', 'Reemplazo de barras de apoyo del baño',       '2026-11-17', 'en_proceso'),
 (13, 10,'correctivo', 'Filtración de agua en techo (espera repuesto)','2026-11-08', 'en_proceso');

-- La vista materializada se creó vacía en 04_reportes.sql (antes de estos datos)
REFRESH MATERIALIZED VIEW mv_resumen_mensual;
ANALYZE;
