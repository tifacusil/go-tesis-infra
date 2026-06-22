-- mysql/early-warning/init/00_schema.sql
-- Base de datos exclusiva del microservicio early-warning.
-- Solo crea la BD y el usuario; las TABLAS las aplica el propio servicio al
-- arrancar via golang-migrate (migraciones embebidas, idempotentes). Por eso
-- el usuario necesita DDL (CREATE/ALTER/...) acotado a SU PROPIO esquema.

CREATE DATABASE IF NOT EXISTS early_warning
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS 'svc_early_warning'@'%'
  IDENTIFIED BY 'changeme_early_warning';

-- DML (runtime) + DDL acotado a early_warning.* (migraciones del servicio).
-- Database-per-service: el privilegio NO se extiende a otros esquemas.
GRANT SELECT, INSERT, UPDATE, DELETE,
      CREATE, ALTER, DROP, INDEX, REFERENCES
  ON early_warning.*
  TO 'svc_early_warning'@'%';

FLUSH PRIVILEGES;