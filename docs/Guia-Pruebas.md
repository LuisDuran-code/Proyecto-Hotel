<div class="portada" markdown="1">

# Guía de pruebas
## Sistema de Administración Hotelera — PostgreSQL 18

Cómo conectarse a la base de datos, qué comprueba cada una de las 30 pruebas automáticas y qué consultas ejecutar para verificar el sistema a mano.

</div>

## 1. Antes de empezar

Los dos servidores deben estar corriendo. Desde la carpeta del proyecto:

```bash
docker compose up -d          # levanta el primario y la réplica
./scripts/failover.sh estado  # debe mostrar PRIMARIO y RÉPLICA
```

| Servidor | Puerto | Uso |
|----------|-------:|-----|
| `hotel-primario` | **5433** | Lectura y escritura |
| `hotel-replica` | **5434** | Solo lectura (copia en tiempo real del primario) |

Las contraseñas están en el archivo `.env` del proyecto, que no se sube a GitHub:

| Variable de `.env` | Para qué usuario |
|--------------------|------------------|
| `POSTGRES_PASSWORD` | `postgres` (superusuario) |
| `PASS_EMPLEADOS` | Todos los usuarios de empleados |

## 2. Cómo conectarse

**Regla importante:** el servidor **solo acepta conexiones cifradas con SSL**. Una conexión sin SSL se rechaza con el mensaje `pg_hba.conf rejects connection … no encryption`. Esto es intencional (ver la prueba 1).

### 2.1 Beekeeper Studio

Nueva conexión → tipo **PostgreSQL**:

| Campo | Valor |
|-------|-------|
| Host | `localhost` |
| Port | `5433` (o `5434` para la réplica) |
| User | `postgres` o un usuario de empleado (sección 2.4) |
| Password | La que corresponda de `.env` |
| Default Database | `hotel` |
| Enable SSL | **Activado** |
| Reject Unauthorized | **Desactivado** (el certificado es autofirmado) |

Pulsar **Test** y luego **Connect**. Las tablas están en el esquema **`hotel`**, y las vistas de salud del servidor en el esquema **`monitoreo`**.

> Beekeeper confirma cada sentencia automáticamente (*autocommit*). Para probar algo que modifica datos sin dejarlo guardado, escribir `BEGIN;` antes y `ROLLBACK;` después.

### 2.2 pgAdmin 4

```bash
docker compose --profile tools up -d
```

Abrir <http://localhost:8080>. El usuario y la contraseña de pgAdmin son `PGADMIN_EMAIL` y `PGADMIN_PASSWORD` de `.env`. Registrar un servidor con:

- **Host:** `hotel-primario`. pgAdmin corre dentro de Docker, así que se usa el nombre del contenedor, no `localhost`.
- **Port:** `5432`.
- **Database:** `hotel`.
- **Pestaña Parameters:** SSL mode = `require`.

### 2.3 psql (terminal)

```bash
psql "host=localhost port=5433 dbname=hotel user=rec_lhernandez sslmode=require"
```

### 2.4 Usuarios disponibles

Cada empleado inicia sesión con su propio usuario, que hereda los permisos de su rol:

| Usuario | Rol | Puede |
|---------|-----|-------|
| `admin_cmorales`, `admin_arivas` | Administrador | Todo el negocio; leer (no borrar) la bitácora; monitoreo |
| `rec_lhernandez`, `rec_jmartinez`, `rec_scastillo`, `rec_dflores` | Recepcionista | Huéspedes (sin el documento cifrado), reservas, check-in/out, consumos, pagos |
| `mant_mlopez`, `mant_pramirez`, `mant_rguzman`, `mant_lportillo` | Mantenimiento | Ver habitaciones; gestionar **sus propias** órdenes de mantenimiento |
| `ger_gmejia` | Gerente | Solo lectura y reportes |
| `postgres` | Superusuario | Todo (administración técnica) |

Al conectarse como empleado, Beekeeper puede mostrar la lista de tablas vacía o incompleta: solo aparecen las que ese rol tiene permiso de ver. Las consultas funcionan igual si se escriben en el editor.

## 3. Ejecutar las pruebas automáticas

```bash
./scripts/pruebas.sh
```

El script se conecta **como cada usuario real**, por red y con SSL, igual que lo haría una aplicación. Cada prueba indica si se espera que la operación funcione (**OK**) o que la base la rechace (**ERROR**), y verifica además el mensaje obtenido. Las pruebas que modifican datos terminan en `ROLLBACK`, así que el script se puede repetir cuantas veces se quiera. El resultado esperado es:

```
Resultado: 30 correctas, 0 fallidas
```

## 4. Qué comprueba cada prueba

### 4.1 Conexión y cifrado en tránsito

| # | Prueba | Usuario | Esperado | Qué demuestra |
|--:|--------|---------|----------|---------------|
| 1 | Conexión sin SSL es rechazada | `rec_lhernandez` | ERROR | `pg_hba.conf` solo admite conexiones `hostssl`; nadie puede leer el tráfico en la red |
| 2 | Conexión con SSL usa TLS | `rec_lhernandez` | OK | `pg_stat_ssl` confirma que la sesión va cifrada |
| 3 | Contraseña incorrecta es rechazada | `rec_lhernandez` | ERROR | Autenticación SCRAM-SHA-256; el intento fallido queda en el log y el monitoreo lo cuenta |

### 4.2 Integridad y reglas de negocio

| # | Prueba | Esperado | Qué demuestra |
|--:|--------|----------|---------------|
| 4 | Sobre-reservación bloqueada | ERROR | Se intenta reservar la habitación 104, que está ocupada hoy. La restricción `EXCLUDE` impide que una habitación tenga dos reservas activas con fechas que se cruzan, **aunque dos recepcionistas lo intenten al mismo tiempo** |
| 5 | Capacidad insuficiente bloqueada | ERROR | 5 personas en una habitación individual: `fn_crear_reservacion` compara contra la capacidad del tipo de habitación |
| 6 | Fechas invertidas bloqueadas | ERROR | La restricción `CHECK (fecha_salida > fecha_entrada)` |
| 7 | Consumo en estadía finalizada bloqueado | ERROR | Un trigger solo admite consumos en reservas `en_curso`; nada se agrega a una cuenta ya cerrada |
| 8 | Pago mayor al saldo bloqueado | ERROR | Un trigger compara el pago contra el saldo pendiente de la factura |
| 9 | Tarjeta sin últimos 4 dígitos bloqueada | ERROR | Un pago con tarjeta exige exactamente 4 dígitos, y nunca se guarda el número completo. Esta prueba **encontró un error real** (el `CHECK` aceptaba NULL), que ya está corregido |
| 10 | Huésped con documento duplicado bloqueado | ERROR | El HMAC del documento es `UNIQUE`: se detectan duplicados sin descifrar nada |
| 11 | Flujo completo | OK | Registrar huésped → buscar disponibilidad → reservar → check-in → consumo → check-out (genera la factura con IVA) → pagar. Al final la factura debe quedar en estado **pagada** |

Todas estas pruebas se ejecutan como `rec_lhernandez`.

### 4.3 Permisos por rol

| # | Prueba | Usuario | Esperado | Qué demuestra |
|--:|--------|---------|----------|---------------|
| 12 | Recepción NO lee el documento cifrado | `rec_lhernandez` | ERROR | Permiso por columna: la recepción ve al huésped, pero no la columna `documento_cifrado` |
| 13 | Recepción SÍ lee datos de contacto | `rec_lhernandez` | OK | Las demás columnas (email, teléfono) sí son visibles |
| 14 | Recepción descifra con función auditada | `rec_lhernandez` | OK | `fn_documento_huesped()` devuelve el documento en claro **y deja registro en la bitácora** de quién lo consultó |
| 15 | Recepción NO accede a la clave | `rec_lhernandez` | ERROR | El esquema `seguridad` no es accesible para ningún rol de aplicación |
| 16 | Recepción NO cambia estado directamente | `rec_lhernandez` | ERROR | El estado de una reserva solo cambia con `sp_check_in`, `sp_check_out` o `sp_cancelar_reservacion`, que validan las reglas |
| 17 | Recepción NO borra reservaciones | `rec_lhernandez` | ERROR | No se borra historia; las reservas se cancelan |
| 18 | Mantenimiento NO ve huéspedes | `mant_mlopez` | ERROR | Mínimo privilegio: el técnico no necesita datos personales |
| 19 | Mantenimiento NO ve facturas | `mant_mlopez` | ERROR | Ni información financiera |
| 20 | Mantenimiento ve todas las órdenes | `mant_mlopez` | OK | Puede consultar las 12 órdenes para coordinarse con el equipo |
| 21 | RLS: técnico NO modifica orden ajena | `mant_mlopez` | OK (0 filas) | **Seguridad a nivel de fila.** Intenta modificar la orden 12, que no es suya: no da error, pero modifica **0 filas** porque la política la oculta para escritura |
| 22 | RLS: técnico SÍ cierra su propia orden | `mant_rguzman` | OK | Cierra su orden 11, y un trigger devuelve la habitación 105 a **disponible** |
| 23 | Gerente consulta reportes | `ger_gmejia` | OK | Acceso a las vistas de reportes |
| 24 | Gerente NO modifica datos | `ger_gmejia` | ERROR | Rol de solo lectura |
| 25 | Gerente NO lee la bitácora | `ger_gmejia` | ERROR | La auditoría es solo para administración |
| 26 | Administrador lee la bitácora | `admin_cmorales` | OK | Encuentra el registro `CONSULTA` que generó la prueba 14 |
| 27 | Bitácora inmutable incluso para admin | `admin_cmorales` | ERROR | Nadie puede borrar ni alterar la auditoría |
| 28 | Bitácora registra usuario real | `admin_cmorales` | OK | La bitácora guarda `rec_lhernandez` (quién lo hizo), no el dueño de las funciones |

### 4.4 Alta disponibilidad

| # | Prueba | Usuario | Esperado | Qué demuestra |
|--:|--------|---------|----------|---------------|
| 29 | Réplica responde consultas de lectura | `ger_gmejia` | OK | La réplica (puerto 5434) tiene los mismos datos y usuarios, y puede atender los reportes |
| 30 | Réplica rechaza escrituras | `admin_cmorales` | ERROR | Es una copia de solo lectura (*hot standby*); solo el primario acepta cambios |

## 5. Consultas para probar a mano

Las consultas de cada sección se ejecutan **conectado con el usuario indicado**. Las marcadas con ❌ deben dar error: ese error es el resultado correcto.

### 5.1 Como recepcionista (`rec_lhernandez`)

```sql
-- Estado de todas las habitaciones y quién las ocupa
SELECT * FROM vw_ocupacion_actual;

-- Habitaciones libres para los próximos 3 días
SELECT * FROM fn_habitaciones_disponibles(current_date, current_date + 3);

-- ❌ Reservar una habitación ocupada: "Alguna habitación ya está reservada"
SELECT fn_crear_reservacion(4, current_date, current_date + 1, 1, ARRAY[4]);

-- Historial de estadías por huésped
SELECT * FROM vw_historial_huesped ORDER BY estadias DESC;

-- Facturas con saldo pendiente
SELECT * FROM vw_facturas_pendientes;

-- ❌ La columna cifrada no es visible: "permission denied"
SELECT documento_cifrado FROM huesped;

-- Descifrar con la función autorizada (queda registrado en la bitácora)
SELECT fn_documento_huesped(1);
```

**Flujo completo sin guardar cambios** (ejecutar todo el bloque junto):

```sql
BEGIN;
DO $$
DECLARE r int;
BEGIN
  r := fn_crear_reservacion(4, current_date, current_date + 2, 2,
       ARRAY[(SELECT id_habitacion FROM fn_habitaciones_disponibles(current_date, current_date + 2, 2) LIMIT 1)]);
  CALL sp_check_in(r);                                       -- habitación pasa a "ocupada"
  INSERT INTO consumo_servicio (id_reservacion, id_servicio, cantidad) VALUES (r, 1, 2);  -- 2 desayunos
  CALL sp_check_out(r, now() + interval '2 days');           -- genera la factura
END $$;
-- La factura generada y su detalle
SELECT numero, subtotal, iva, total, estado FROM factura ORDER BY id_factura DESC LIMIT 1;
SELECT tipo, concepto, cantidad, precio_unitario, subtotal FROM detalle_factura
 WHERE id_factura = (SELECT max(id_factura) FROM factura);
ROLLBACK;
```

### 5.2 Como técnico de mantenimiento (`mant_mlopez`)

```sql
SELECT * FROM mantenimiento ORDER BY fecha_inicio DESC;   -- ve todas las órdenes
SELECT numero, estado FROM habitacion;                    -- ve las habitaciones

-- ❌ Datos personales y financieros: "permission denied"
SELECT * FROM huesped;
SELECT * FROM factura;

-- RLS: la orden 12 es de otro técnico -> modifica 0 filas
BEGIN;
UPDATE mantenimiento SET descripcion = 'prueba' WHERE id_mantenimiento = 12;
ROLLBACK;
```

### 5.3 Como gerente (`ger_gmejia`)

```sql
SELECT * FROM vw_ingresos_mensuales;          -- facturado vs. cobrado por mes
SELECT * FROM vw_servicios_mas_utilizados;    -- ranking de servicios
SELECT * FROM fn_reporte_ocupacion(current_date - 14, current_date);  -- % de ocupación diaria
SELECT * FROM mv_resumen_mensual;             -- resumen materializado

-- ❌ Solo lectura: "permission denied"
UPDATE servicio SET precio = 0;
```

### 5.4 Como administrador (`admin_cmorales`)

```sql
-- Auditoría: qué se hizo, quién y cuándo
SELECT fecha, tabla, operacion, usuario FROM bitacora ORDER BY fecha DESC LIMIT 20;

-- Antes y después de un cambio concreto
SELECT datos_anteriores, datos_nuevos FROM bitacora
 WHERE tabla = 'reservacion' AND operacion = 'UPDATE' LIMIT 3;

-- ❌ La bitácora no se puede alterar: "permission denied"
DELETE FROM bitacora;

-- Monitoreo del servidor
SELECT * FROM monitoreo.fn_verificar_alertas(false);  -- alertas activas
SELECT * FROM monitoreo.vw_replicacion;               -- estado de la réplica
SELECT * FROM monitoreo.vw_espacio_tablas;            -- tamaño por tabla y tablespace
SELECT * FROM monitoreo.vw_ultimos_backups;           -- últimos respaldos
SELECT * FROM monitoreo.vw_consultas_costosas;        -- consultas más pesadas
```

### 5.5 Como `postgres`: ver el cifrado

```sql
-- El documento guardado es ilegible...
SELECT nombres, encode(documento_cifrado, 'hex') AS guardado, documento_hash FROM huesped LIMIT 3;
-- ...y solo la función con la clave lo recupera
SELECT nombres, fn_documento_huesped(id_huesped) AS documento FROM huesped LIMIT 3;
```

### 5.6 En la réplica (puerto 5434)

```sql
SELECT pg_is_in_recovery();          -- true: es una réplica
SELECT count(*) FROM reservacion;    -- mismos datos que el primario
-- ❌ "cannot execute UPDATE in a read-only transaction"
UPDATE servicio SET precio = precio;
```

Para ver la replicación en tiempo real: insertar algo en el primario (5433) y consultarlo de inmediato en la réplica (5434).

## 6. Pruebas desde la terminal

Estas pruebas no se hacen desde Beekeeper, sino con los scripts del proyecto:

| Qué probar | Comando | Resultado esperado |
|------------|---------|--------------------|
| Respaldo lógico | `./scripts/backup_logico.sh` | `Respaldo lógico OK`; archivo en `backups/logico/` |
| Respaldo físico | `./scripts/backup_fisico.sh` | `Respaldo físico OK`; archivo en `backups/fisico/` |
| Que el respaldo se puede restaurar | `./scripts/verificar_backup.sh` | `VERIFICACIÓN OK`, con conteos iguales en producción y en la copia restaurada |
| Rendimiento | `docker exec -i -u postgres hotel-primario psql -d hotel < sql/rendimiento.sql` | Planes de ejecución que muestran la poda de particiones y el uso de índices; termina en `ROLLBACK` |
| Monitoreo | `./scripts/monitoreo.sh` | Lista de alertas. Con los datos de prueba aparece una advertencia esperada: la habitación 303 lleva más de 7 días en mantenimiento |

### 6.1 Recuperación a un punto en el tiempo (PITR)

Simula un borrado accidental y lo recupera sin detener producción. Requiere haber hecho antes un respaldo físico.

```bash
X="docker exec -u postgres hotel-primario psql -d hotel -At -c"
$X "SELECT to_char(now(),'YYYY-MM-DD HH24:MI:SS')"      # 1. anotar la hora
$X "DELETE FROM pago WHERE id_pago = 11"                # 2. el "accidente"
./scripts/restaurar_pitr.sh "<hora anotada>"            # 3. servidor temporal en el puerto 5435
docker exec -u postgres hotel-pitr psql -d hotel -c "SELECT * FROM hotel.pago WHERE id_pago = 11"
```

El registro borrado aparece en el servidor temporal. Para devolverlo a producción y limpiar:

```bash
docker exec -u postgres hotel-pitr psql -d hotel -c "COPY (SELECT * FROM hotel.pago WHERE id_pago = 11) TO STDOUT" \
  | docker exec -i -u postgres hotel-primario psql -d hotel -c "COPY hotel.pago FROM STDIN"
docker rm -f hotel-pitr
```

### 6.2 Failover (caída del servidor principal)

```bash
docker stop hotel-primario             # simular la caída
./scripts/failover.sh promover         # la réplica pasa a ser primario (puerto 5434)
```

Desde ese momento la conexión de Beekeeper al puerto 5434 **acepta escrituras**. Para volver al estado normal:

```bash
docker start hotel-primario
./scripts/failover.sh reconstruir-replica
```

## 7. Problemas frecuentes

| Síntoma | Causa y solución |
|---------|------------------|
| `pg_hba.conf rejects connection … no encryption` | Falta activar SSL en la conexión |
| `self signed certificate` o error de certificado | Desactivar **Reject Unauthorized** en Beekeeper, o usar `sslmode=require` en psql |
| `Connection refused` | Los contenedores no están corriendo: `docker compose up -d`. Revisar también el puerto (5433, no 5432) |
| `password authentication failed` | Revisar la contraseña en `.env`; los empleados usan `PASS_EMPLEADOS` |
| `relation "huesped" does not exist` | Falta el esquema: escribir `hotel.huesped`, o ejecutar `SET search_path = hotel, public;` |
| `permission denied` | Si la consulta está marcada con ❌, ese es el resultado correcto. Si no, revisar el usuario conectado con `SELECT current_user;` |
| Los datos cambiaron después de probar | Beekeeper hace *autocommit*: usar `BEGIN; … ROLLBACK;`. Para volver a los datos originales: `./scripts/reset_entorno.sh` (**borra todo** y reinstala) |
