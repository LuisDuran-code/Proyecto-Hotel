# Plan de crecimiento, mantenimiento y continuidad

**Sistema de Administración Hotelera — Base de datos `hotel` (PostgreSQL 18)**

Este documento describe cómo se gestionará el crecimiento de la base de datos, cómo se usa el espacio en disco y qué procesos de mantenimiento, respaldo y recuperación se ejecutan, con qué frecuencia y con qué herramienta.

---

## 1. Arquitectura de almacenamiento

| Volumen (Docker)         | Ruta en el contenedor     | Contenido                                        |
|--------------------------|---------------------------|--------------------------------------------------|
| `pgdata_primario`        | `/var/lib/postgresql`     | Catálogo, tablas activas y WAL en curso (`pg_default`) |
| `ts_indices_primario`    | `/ts/indices`             | Tablespace `ts_indices`: índices B-tree/GIN de tablas no particionadas |
| `ts_historico_primario`  | `/ts/historico`           | Tablespace `ts_historico`: particiones antiguas y bitácora archivada |
| `wal_archive`            | `/wal_archive`            | WAL archivado y comprimido (base de la recuperación PITR) |
| `backups`                | `/backups`                | Respaldos físicos (`pg_basebackup`)              |
| `./backups` (host)       | —                         | Copia externa de los respaldos lógicos y físicos |

En un servidor real cada volumen sería un disco o una partición distinta: los índices pueden ir en almacenamiento rápido, el histórico en uno más barato, y el WAL archivado junto con los respaldos en un disco distinto del de los datos, para no perderlos si ese disco falla.

## 2. Estimación de crecimiento

**Supuestos:** 20 habitaciones, 70 % de ocupación, estancia promedio de 2,5 noches, 3 consumos por noche ocupada y 10 % de cancelaciones. Los tamaños por fila se midieron sobre los datos de prueba con `pg_column_size`, más 28 bytes de cabecera por tupla.

| Tabla                    | Filas/año | Bytes/fila | Datos/año | Con índices |
|--------------------------|----------:|-----------:|----------:|------------:|
| reservacion              |   ~2 300  |   83 + 28  |  0,25 MB  |   0,6 MB    |
| reservacion_habitacion   |   ~2 500  |   56 + 28  |  0,21 MB  |   0,5 MB    |
| consumo_servicio *(part.)* | ~15 300 |  59 + 28  |  1,3 MB   |   2,5 MB    |
| factura + detalle + pago |  ~12 700  |   ~75 + 28 |  1,3 MB   |   2,2 MB    |
| huesped                  |   ~1 300  |  251 + 28  |  0,36 MB  |   0,7 MB    |
| **bitacora** *(part.)*   |  ~50 000  |  334 + 28  |  **18 MB**|  **20 MB**  |
| **Total aproximado**     |           |            |           | **≈ 27 MB/año** |

Proyección: unos 135 MB en 5 años con 20 habitaciones, o unos 700 MB si el hotel crece a 100 habitaciones. **La bitácora es el 75 % del crecimiento**, así que es la tabla con política de retención. En volumen, los datos del negocio son pequeños; el espacio que realmente hay que planificar es el del **WAL archivado y los respaldos** (sección 4).

## 3. Técnicas de uso eficiente del espacio

1. **Particionamiento por rango mensual** de `consumo_servicio` y `bitacora`, que son las dos tablas que más crecen.
   - Las consultas por fecha solo leen la partición necesaria (*partition pruning*, comprobado con `sql/rendimiento.sql`).
   - Borrar o archivar un mes completo es una operación de metadatos (`DETACH`/`DROP`), sin `DELETE` masivo y sin dejar espacio muerto que luego tenga que limpiar `VACUUM`.
   - La partición `DEFAULT` recoge filas fuera de rango. El monitoreo avisa si contiene datos.
2. **Ciclo de vida de las particiones** (`hotel.fn_mantenimiento_diario()`):
   - Crea con anticipación las particiones de los próximos 3 meses.
   - Mueve al tablespace `ts_historico` los consumos con más de 12 meses de antigüedad.
   - Deja 24 meses de bitácora en línea. Las particiones más antiguas se desvinculan (`DETACH`), pasan al esquema `historico` y se mueven a `ts_historico`; desde allí se pueden exportar y eliminar.
3. **Índices adecuados al patrón de acceso:**
   - BRIN sobre `bitacora.fecha`: ocupa unas 27 veces menos que un B-tree (24 kB frente a 656 kB con 30 000 filas).
   - Índices parciales sobre los estados "vivos" (reservaciones activas, facturas pendientes y órdenes abiertas), que solo indexan la fracción útil de la tabla.
   - Sin índices duplicados: el índice GiST de la restricción `EXCLUDE` también sirve para buscar disponibilidad.
4. **`fillfactor`** de 85 en `habitacion` y de 90 en `reservacion`: deja espacio libre en cada página para que los cambios de estado sean *HOT updates*, que no generan entradas nuevas en los índices.
5. **Compresión:**
   - `wal_compression = lz4` comprime las imágenes de página completa dentro del WAL.
   - El WAL archivado se guarda con gzip: un segmento de 16 MB casi vacío queda en unos 16 KB.
   - `pg_dump -Fc -Z 6` comprime los respaldos lógicos.
6. **Autovacuum ajustado:**
   - `scale_factor` de 0,1 y de 0,05 para análisis.
   - `autovacuum_vacuum_insert_scale_factor = 0,05` en las tablas de solo inserción.
   - Registro de cada ejecución de autovacuum que dure más de 1 s.
7. **Bitácora del servidor (logs):** rotación diaria con nombre por día de la semana y truncado, de modo que nunca hay más de 7 archivos.

## 4. Respaldos y recuperación

| Tipo | Herramienta | Frecuencia | Retención | Script |
|------|-------------|-----------|-----------|--------|
| Lógico (completo) | `pg_dump -Fc` como `backup_operador` | Diario 02:00 | 7 diarios + 1 mensual × 6 meses | `backup_logico.sh` |
| Objetos globales  | `pg_dumpall --globals-only` | Diario 02:00 | 7 días | `backup_logico.sh` |
| Físico (base)     | `pg_basebackup -Ft -z` | Domingo 03:00 | 2 semanas | `backup_fisico.sh` |
| WAL continuo      | `archive_command` + gzip | Cada segmento o cada 5 min | Desde el respaldo físico más antiguo | automático |
| Prueba de restauración | `pg_restore` en una base temporal | Lunes 04:00 | — | `verificar_backup.sh` |

**Objetivos:**

- **RPO** (pérdida máxima de datos): ≤ 5 minutos por `archive_timeout`, y prácticamente 0 con la réplica en streaming.
- **RTO** (tiempo de recuperación): < 1 minuto promoviendo la réplica, y unos minutos con PITR o con una restauración lógica.

**Controles de integridad:**

- Cada dump se valida con `pg_restore --list` y se guarda junto a su SHA-256, que se comprueba antes de restaurar.
- El respaldo físico incluye un `backup_manifest`.
- Cada ejecución, correcta o fallida, queda en `monitoreo.registro_backup`.

**La clave de cifrado nunca viaja en el respaldo** (`--exclude-table-data=seguridad.clave_cifrado`). Se custodia aparte, en `.env` o en un gestor de secretos, y `restaurar_logico.sh` la repone al restaurar. Así, un respaldo robado no permite descifrar los documentos de los huéspedes.

### Procedimientos de restauración

| Escenario | Procedimiento |
|-----------|---------------|
| Se dañó el servidor primario | `./scripts/failover.sh promover`: la réplica pasa a primario (RTO < 1 min) |
| Borrado o actualización accidental a una hora conocida | `./scripts/restaurar_pitr.sh "AAAA-MM-DD HH:MM:SS"`: se levanta un servidor temporal en el puerto 5435, recuperado justo antes del error; los datos se copian a producción con `COPY` o `pg_dump -t` |
| Se perdió todo el clúster | Restaurar el último respaldo físico + WAL (mismo procedimiento que PITR, sin `recovery_target_time`), o `restaurar_logico.sh` en un servidor nuevo después de cargar `globales_*.sql` |
| Recuperar una tabla o base en paralelo | `./scripts/restaurar_logico.sh [archivo] [base_destino]` (nunca sobrescribe `hotel`) |

## 5. Calendario de mantenimiento

| Frecuencia | Tarea | Script |
|------------|-------|--------|
| Cada 5 min | Salud, alertas, disco, accesos fallidos | `monitoreo.sh` |
| Diario 02:00 | Respaldo lógico | `backup_logico.sh` |
| Diario 03:30 | Particiones futuras, traslado a histórico, retención de bitácora, marcado de *no-show*, `REFRESH MATERIALIZED VIEW CONCURRENTLY`, `VACUUM ANALYZE` | `mantenimiento.sh diario` |
| Domingo 03:00 | Respaldo físico y limpieza de WAL (`pg_archivecleanup`) | `backup_fisico.sh` |
| Domingo 04:30 | `REINDEX CONCURRENTLY`, purga de alertas (90 días) y logs (30 días), informe de espacio e índices sin uso | `mantenimiento.sh semanal` |
| Lunes 04:00 | Prueba de restauración del último respaldo | `verificar_backup.sh` |
| Trimestral (manual) | Simulacro de failover y de PITR; revisión de `vw_consultas_costosas` e `vw_indices_sin_uso`; rotación de contraseñas (vencen a los 90 días) | `failover.sh`, `restaurar_pitr.sh` |

La programación se instala con `./scripts/instalar_tareas.sh` (temporizadores de systemd). La alternativa con cron está en `scripts/crontab.ejemplo`.

> Nota: `REINDEX CONCURRENTLY` omite el índice de la restricción `EXCLUDE`, porque PostgreSQL no lo permite. Ese índice se puede reconstruir en una ventana de mantenimiento con `REINDEX INDEX` normal.

## 6. Alta disponibilidad y vuelta a la normalidad (*failback*)

- La **réplica** (`hotel-replica`, puerto 5434) recibe el WAL por streaming y usa un *replication slot* (`slot_replica`), así que el primario no borra WAL que la réplica aún no recibió.
- Si el streaming se corta, la réplica toma el WAL del archivo compartido (`restore_command`).
- Mientras tanto atiende consultas de solo lectura (reportes de gerencia), lo que quita carga al primario.

**Failover:** detener el primario dañado y ejecutar `./scripts/failover.sh promover`. Después hay que apuntar la aplicación al nuevo primario.

**Failback** (cuando el servidor original se repara):

1. Reincorporar el servidor original como réplica del nuevo primario con `pg_rewind --target-pgdata=$PGDATA --source-server="host=hotel-replica user=postgres"`, o volver a clonarlo con `pg_basebackup`.
2. En una ventana de mantenimiento, detener el primario temporal y promover el original (`pg_promote()`).
3. Reconstruir la réplica: `./scripts/failover.sh reconstruir-replica`.

## 7. Monitoreo y umbrales de alerta

`monitoreo.fn_verificar_alertas()` evalúa estas reglas y guarda las alertas en `monitoreo.alerta`:

| Regla | Advertencia | Crítico |
|-------|-------------|---------|
| Conexiones en uso | ≥ 80 % de `max_connections` | ≥ 90 % |
| Consulta activa | > 5 min | — |
| Transacción abierta sin actividad | > 10 min | — |
| Sesión bloqueada | > 30 s | — |
| Filas muertas en una tabla | > 20 % (y > 1 000) | — |
| *Cache hit ratio* | < 95 % | — |
| Tamaño de la base | > 5 GB | — |
| Disco de cualquier volumen | ≥ 80 % | ≥ 90 % |
| Réplica | retraso > 60 s | desconectada, o slot inactivo con > 1 GB retenido |
| Archivado de WAL | — | falla |
| Respaldo lógico | — | ninguno exitoso en 26 h, o falla en el último día |
| Respaldo físico | ninguno en 8 días | — |
| Particiones | filas en `DEFAULT` | falta la del próximo mes |
| Accesos fallidos | > 5 en el día (posible fuerza bruta) | — |
| Negocio | habitación > 7 días en mantenimiento; factura con saldo > 30 días | — |

Vistas de apoyo en el esquema `monitoreo`:

- **Espacio:** `vw_espacio_bd`, `vw_espacio_tablespaces`, `vw_espacio_tablas`.
- **Actividad y bloqueos:** `vw_conexiones`, `vw_actividad_larga`, `vw_bloqueos`.
- **Rendimiento:** `vw_consultas_costosas` (`pg_stat_statements`), `vw_salud_tablas`, `vw_indices_sin_uso`, `vw_cache_hit`.
- **Replicación y archivado:** `vw_replicacion`, `vw_slots_replicacion`, `vw_archivado_wal`.
- **Respaldos:** `vw_ultimos_backups`.
