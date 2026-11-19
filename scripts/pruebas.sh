#!/bin/bash
# =====================================================================
#  pruebas.sh — Validación automática de integridad, reglas de negocio
#  y seguridad. Se conecta como cada usuario real, por TCP + SSL.
#  Las pruebas que modifican datos terminan en ROLLBACK (repetibles).
#     ./scripts/pruebas.sh
# =====================================================================
set -uo pipefail
cd "$(dirname "$0")/.."
source .env

HOST=${PGHOST_HOTEL:-localhost}; PORT=${PGPORT_HOTEL:-5433}; PORT_REPLICA=${PGPORT_REPLICA:-5434}
ok=0; fallas=0

# probar "descripción" usuario OK|ERROR "patrón esperado en la salida" "sql" [puerto] [sslmode]
probar() {
  local desc="$1" usuario="$2" esperado="$3" patron="$4" sql="$5" puerto="${6:-$PORT}" ssl="${7:-require}"
  local pass="$PASS_EMPLEADOS"
  [[ "$usuario" == "postgres" ]] && pass="$POSTGRES_PASSWORD"
  local salida
  salida=$(PGPASSWORD="$pass" psql "host=$HOST port=$puerto dbname=hotel user=$usuario sslmode=$ssl" \
           -X -q -v ON_ERROR_STOP=1 -At -f - <<<"$sql" 2>&1)
  local rc=$?
  local res="OK"; [[ $rc -ne 0 ]] && res="ERROR"
  if [[ "$res" == "$esperado" ]] && grep -qiE -- "$patron" <<<"$salida"; then
    printf "  \e[32m✔\e[0m %s\n" "$desc"; ((ok++))
  else
    printf "  \e[31m✘\e[0m %s\n     esperado=%s obtenido=%s\n     %s\n" "$desc" "$esperado" "$res" "$(head -3 <<<"$salida")"
    ((fallas++))
  fi
}

echo "== Conexión y cifrado en tránsito =="
probar "Conexión sin SSL es rechazada"            rec_lhernandez ERROR "no encryption|reject" "SELECT 1" "$PORT" disable
probar "Conexión con SSL usa TLS"                 rec_lhernandez OK    "^t$" "SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()"
probar "Contraseña incorrecta es rechazada"       rec_lhernandez ERROR "password authentication failed" \
       "SELECT 1" "$PORT" "require password=incorrecta"

echo "== Integridad y reglas de negocio =="
probar "Sobre-reservación bloqueada (EXCLUDE)"    rec_lhernandez ERROR "ya está reservada" \
       "SELECT fn_crear_reservacion(4, current_date, current_date + 1, 1, ARRAY[4])"
probar "Capacidad insuficiente bloqueada"         rec_lhernandez ERROR "Capacidad insuficiente" \
       "SELECT fn_crear_reservacion(4, '2027-03-01', '2027-03-03', 5, ARRAY[1])"
probar "Fechas invertidas bloqueadas (CHECK)"     rec_lhernandez ERROR "ck_reservacion_fechas" \
       "SELECT fn_crear_reservacion(4, '2027-03-05', '2027-03-01', 1, ARRAY[1])"
probar "Consumo en estadía finalizada bloqueado"  rec_lhernandez ERROR "reservaciones en curso" \
       "INSERT INTO consumo_servicio (id_reservacion, id_servicio) VALUES (1, 1)"
probar "Pago mayor al saldo bloqueado"            rec_lhernandez ERROR "excede el saldo" \
       "INSERT INTO pago (id_factura, monto, metodo) VALUES (10, 999, 'efectivo')"
probar "Tarjeta sin últimos 4 dígitos bloqueada"  rec_lhernandez ERROR "ck_pago_tarjeta" \
       "INSERT INTO pago (id_factura, monto, metodo) VALUES (10, 1, 'tarjeta')"
probar "Huésped con documento duplicado bloqueado" rec_lhernandez ERROR "Ya existe" \
       "SELECT fn_registrar_huesped('X','Y','DUI','04567812-3')"
probar "Flujo completo: reservar → check-in → consumo → check-out → pago" rec_lhernandez OK "pagada" "
  BEGIN;
  SELECT fn_registrar_huesped('Prueba','Automática','pasaporte','TEST0001') \gset
  SELECT fn_crear_reservacion(:fn_registrar_huesped, current_date, current_date + 2, 2,
         ARRAY[(SELECT id_habitacion FROM fn_habitaciones_disponibles(current_date, current_date + 2, 2) LIMIT 1)]) AS r \gset
  CALL sp_check_in(:r);
  INSERT INTO consumo_servicio (id_reservacion, id_servicio, cantidad) VALUES (:r, 1, 2);
  CALL sp_check_out(:r, now() + interval '2 days');
  INSERT INTO pago (id_factura, monto, metodo, ultimos_4)
       SELECT id_factura, total, 'tarjeta', '1234' FROM factura WHERE id_reservacion = :r;
  SELECT estado FROM factura WHERE id_reservacion = :r;
  ROLLBACK;"

echo "== Permisos por rol =="
probar "Recepción NO lee el documento cifrado"    rec_lhernandez ERROR "permission denied" "SELECT documento_cifrado FROM huesped"
probar "Recepción SÍ lee datos de contacto"       rec_lhernandez OK    "@" "SELECT email FROM huesped WHERE email IS NOT NULL LIMIT 1"
probar "Recepción descifra con función auditada"  rec_lhernandez OK    "04567812-3" "SELECT fn_documento_huesped(1)"
probar "Recepción NO accede a la clave"           rec_lhernandez ERROR "permission denied" "SELECT * FROM seguridad.clave_cifrado"
probar "Recepción NO cambia estado directamente"  rec_lhernandez ERROR "permission denied" "UPDATE reservacion SET estado='finalizada' WHERE id_reservacion=14"
probar "Recepción NO borra reservaciones"         rec_lhernandez ERROR "permission denied" "DELETE FROM reservacion WHERE id_reservacion=17"
probar "Mantenimiento NO ve huéspedes"            mant_mlopez    ERROR "permission denied" "SELECT * FROM huesped"
probar "Mantenimiento NO ve facturas"             mant_mlopez    ERROR "permission denied" "SELECT * FROM factura"
probar "Mantenimiento ve todas las órdenes"       mant_mlopez    OK    "^12$" "SELECT count(*) FROM mantenimiento"
probar "RLS: técnico NO modifica orden ajena"     mant_mlopez    OK    "UPDATE 0|^$" \
       "BEGIN; UPDATE mantenimiento SET descripcion = 'x' WHERE id_mantenimiento = 12; ROLLBACK;"
probar "RLS: técnico SÍ cierra su propia orden"   mant_rguzman   OK    "disponible" \
       "BEGIN; UPDATE mantenimiento SET estado='finalizado', fecha_fin=current_date WHERE id_mantenimiento = 11;
        SELECT estado FROM habitacion WHERE id_habitacion = 5; ROLLBACK;"
probar "Gerente consulta reportes"                ger_gmejia     OK    "2026" "SELECT mes FROM vw_ingresos_mensuales LIMIT 1"
probar "Gerente NO modifica datos"                ger_gmejia     ERROR "permission denied" "UPDATE servicio SET precio = 0"
probar "Gerente NO lee la bitácora"               ger_gmejia     ERROR "permission denied" "SELECT * FROM bitacora"
probar "Administrador lee la bitácora"            admin_cmorales OK    "CONSULTA" "SELECT operacion FROM bitacora WHERE operacion='CONSULTA' LIMIT 1"
probar "Bitácora inmutable incluso para admin"    admin_cmorales ERROR "permission denied" "DELETE FROM bitacora"
probar "Bitácora registra usuario real"           admin_cmorales OK    "rec_lhernandez" "SELECT DISTINCT usuario FROM bitacora WHERE usuario='rec_lhernandez'"

echo "== Alta disponibilidad =="
probar "Réplica responde consultas de lectura"    ger_gmejia     OK    "^[0-9]+$" "SELECT count(*) FROM reservacion" "$PORT_REPLICA"
probar "Réplica rechaza escrituras"               admin_cmorales ERROR "read-only" "UPDATE servicio SET precio = precio" "$PORT_REPLICA"

echo
echo "Resultado: $ok correctas, $fallas fallidas"
[[ $fallas -eq 0 ]]
