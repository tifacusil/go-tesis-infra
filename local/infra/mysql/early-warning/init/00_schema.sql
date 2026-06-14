-- mysql/early-warning/init/00_schema.sql
-- Base de datos exclusiva del microservicio early-warning.
-- Persiste historial de alertas emitidas y umbrales por proyecto/sensor.

CREATE DATABASE IF NOT EXISTS early_warning
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS 'svc_early_warning'@'%'
  IDENTIFIED BY 'changeme_early_warning';

GRANT SELECT, INSERT, UPDATE, DELETE
  ON early_warning.*
  TO 'svc_early_warning'@'%';

FLUSH PRIVILEGES;