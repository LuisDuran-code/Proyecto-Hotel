-- =====================================================================
--  00_base.sql — Tablespaces, extensiones, esquemas y rol propietario
--  Ejecutar como superusuario (postgres) conectado a la base "hotel":
--     psql -d hotel -f sql/00_base.sql
-- =====================================================================

-- ---------------------------------------------------------------------
-- Tablespaces: separan índices y datos históricos en otros volúmenes
-- (en Docker cada ruta es un volumen independiente => otro "disco").
-- ---------------------------------------------------------------------
SELECT 'CREATE TABLESPACE ts_indices LOCATION ''/ts/indices'''
WHERE NOT EXISTS (SELECT 1 FROM pg_tablespace WHERE spcname = 'ts_indices') \gexec
SELECT 'CREATE TABLESPACE ts_historico LOCATION ''/ts/historico'''
WHERE NOT EXISTS (SELECT 1 FROM pg_tablespace WHERE spcname = 'ts_historico') \gexec

-- ---------------------------------------------------------------------
-- Extensiones
-- ---------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pgcrypto;            -- cifrado de documentos (pgp_sym_encrypt, hmac)
CREATE EXTENSION IF NOT EXISTS btree_gist;          -- restricción EXCLUDE (habitación + rango de fechas)
CREATE EXTENSION IF NOT EXISTS pg_trgm;             -- búsqueda de huéspedes por nombre aproximado
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;  -- monitoreo de consultas

-- ---------------------------------------------------------------------
-- Rol propietario de todos los objetos (no puede iniciar sesión).
-- Ningún usuario de aplicación es dueño de tablas => no puede alterarlas.
-- ---------------------------------------------------------------------
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'hotel_owner') THEN
    CREATE ROLE hotel_owner NOLOGIN;
  END IF;
END $$;

GRANT CREATE ON TABLESPACE ts_indices, ts_historico TO hotel_owner;

-- Endurecimiento del esquema public y de la base
REVOKE ALL    ON SCHEMA public FROM PUBLIC;
GRANT  USAGE  ON SCHEMA public TO PUBLIC;           -- solo para usar funciones de extensiones
REVOKE ALL    ON DATABASE hotel FROM PUBLIC;
GRANT  CONNECT, TEMPORARY ON DATABASE hotel TO hotel_owner;

-- ---------------------------------------------------------------------
-- Esquemas
--   hotel      : modelo de negocio
--   seguridad  : clave de cifrado (solo el propietario)
--   historico  : particiones archivadas de la bitácora
--   monitoreo  : vistas de salud, alertas y registro de respaldos
-- ---------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS hotel     AUTHORIZATION hotel_owner;
CREATE SCHEMA IF NOT EXISTS seguridad AUTHORIZATION hotel_owner;
CREATE SCHEMA IF NOT EXISTS historico AUTHORIZATION hotel_owner;
CREATE SCHEMA IF NOT EXISTS monitoreo AUTHORIZATION hotel_owner;

ALTER DATABASE hotel SET search_path = hotel, public;
ALTER ROLE hotel_owner SET search_path = hotel, public;
