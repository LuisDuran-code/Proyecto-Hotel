# Sistema de Administración Hotelera: PostgreSQL 18

Proyecto final de **Administración de Bases de Datos** (UES-FMOcc, Ciclo II 2026), **Escenario 7: Hotel (reservaciones y servicios)**.

Incluye un modelo ER de 13 tablas, la lógica de negocio en la base de datos, particionamiento, tablespaces, respaldos lógicos y físicos con PITR, una réplica en streaming para alta disponibilidad, seguridad (TLS, roles, RLS, cifrado y auditoría) y monitoreo con alertas.

| Documento | Contenido |
|-----------|-----------|
| [docs/Informe-Tecnico.md](docs/Informe-Tecnico.md) | Informe final: decisiones, seguridad, retos y soluciones |
| [docs/plan-mantenimiento.md](docs/plan-mantenimiento.md) | Plan de crecimiento, espacio en disco, mantenimiento y continuidad |
| [Diagrama-Proyecto.pdf](Diagrama-Proyecto.pdf) | Diagrama ER (dbdiagram.io) |

## Requisitos

- Docker y Docker Compose.
- `psql` en el equipo, solo para `scripts/pruebas.sh`. Los demás scripts usan las herramientas que trae el contenedor.

## Puesta en marcha

```bash
cp .env.example .env              # cambiar contraseñas y la clave de cifrado
docker compose up -d --build      # primario (5433) + réplica (5434)
docker logs -f hotel-primario     # ver la ejecución de sql/00 … sql/08
./scripts/pruebas.sh              # 30 pruebas de integridad y seguridad
```

Para usar pgAdmin, ejecutar `docker compose --profile tools up -d` y abrir <http://localhost:8080>. Registrar el servidor con host `hotel-primario`, puerto `5432`, base `hotel` y **SSL mode = require**.

Usuarios de prueba (contraseña `PASS_EMPLEADOS` de `.env`):

| Usuario | Rol |
|---------|-----|
| `admin_cmorales`, `admin_arivas` | administrador |
| `rec_lhernandez`, `rec_jmartinez`, `rec_scastillo`, `rec_dflores` | recepcionista |
| `mant_mlopez`, `mant_pramirez`, `mant_rguzman`, `mant_lportillo` | mantenimiento |
| `ger_gmejia` | gerente |

```bash
psql "host=localhost port=5433 dbname=hotel user=rec_lhernandez sslmode=require"
```

## Operación

| Script | Uso |
|--------|-----|
| `backup_logico.sh` | `pg_dump` diario, SHA-256 y retención de 7 días + mensuales |
| `backup_fisico.sh` | `pg_basebackup` semanal y limpieza del WAL archivado |
| `verificar_backup.sh` | Restaura el último respaldo en una base temporal y compara los datos |
| `restaurar_logico.sh [dump] [base]` | Restauración lógica (nunca sobrescribe `hotel`) |
| `restaurar_pitr.sh "AAAA-MM-DD HH:MM:SS"` | Recuperación a un punto en el tiempo, en un servidor temporal (puerto 5435) |
| `failover.sh estado\|promover\|reconstruir-replica` | Alta disponibilidad |
| `mantenimiento.sh diario\|semanal` | Particiones, retención, VACUUM, REINDEX |
| `monitoreo.sh` | Salud y alertas (código de salida 0/1/2) |
| `pruebas.sh` | Validación automática |
| `instalar_tareas.sh [--quitar]` | Programa todo con temporizadores systemd (alternativa: `crontab.ejemplo`) |
| `reset_entorno.sh` | Borra todo y reinstala desde cero |

## Guion sugerido para la demostración

```sql
-- Como rec_lhernandez: disponibilidad, reservar y sobre-reservación bloqueada
SELECT * FROM fn_habitaciones_disponibles(current_date, current_date + 3);
SELECT fn_crear_reservacion(4, current_date, current_date + 1, 1, ARRAY[4]);  -- error: ya está reservada
SELECT * FROM vw_ocupacion_actual;
SELECT documento_cifrado FROM huesped;                                    -- permission denied
SELECT fn_documento_huesped(1);                                           -- descifra y queda en la bitácora

-- Como ger_gmejia: reportes
SELECT * FROM vw_ingresos_mensuales;
SELECT * FROM vw_servicios_mas_utilizados;
SELECT * FROM fn_reporte_ocupacion(current_date - 7, current_date);

-- Como admin_cmorales: auditoría y monitoreo
SELECT fecha, tabla, operacion, usuario FROM bitacora ORDER BY fecha DESC LIMIT 10;
SELECT * FROM monitoreo.fn_verificar_alertas(false);
SELECT * FROM monitoreo.vw_replicacion;
```

```bash
# PITR: borrado accidental y recuperación
docker exec -u postgres hotel-primario psql -d hotel -c "SELECT now()"        # anotar la hora
docker exec -u postgres hotel-primario psql -d hotel -c "DELETE FROM pago WHERE id_pago = 11"
./scripts/restaurar_pitr.sh "<hora anotada>"
docker exec -u postgres hotel-pitr psql -d hotel -c "SELECT * FROM hotel.pago WHERE id_pago = 11"

# Failover
docker stop hotel-primario && ./scripts/failover.sh promover

# Rendimiento (EXPLAIN de particiones e índices, termina en ROLLBACK)
docker exec -i -u postgres hotel-primario psql -d hotel < sql/rendimiento.sql
```

## Distribución sugerida del trabajo (4 integrantes)

| Integrante | Área | Archivos |
|------------|------|----------|
| 1 | Modelo ER, implementación e integridad | `sql/01`, `02`, `04`, `07` |
| 2 | Almacenamiento, rendimiento y mantenimiento | `sql/00`, `03`, `05`, `rendimiento.sql`, `mantenimiento.sh`, `plan-mantenimiento.md` |
| 3 | Respaldos, recuperación y alta disponibilidad | `docker/`, `backup_*.sh`, `restaurar_*.sh`, `failover.sh` |
| 4 | Seguridad, monitoreo y alertas | `sql/06`, `08`, `pg_hba.conf`, `monitoreo.sh`, `pruebas.sh` |
