-- mysql/data-management/init/00_schema.sql
-- Base de datos exclusiva del microservicio data-management.
-- Solo este servicio tiene acceso a esta BD.

CREATE DATABASE IF NOT EXISTS data_management
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

-- Usuario con permisos mínimos (least-privilege)
-- El root solo se usa en init; el microservicio usa svc_data_mgmt.
CREATE USER IF NOT EXISTS 'svc_data_mgmt'@'%'
  IDENTIFIED BY 'changeme_data_mgmt';

GRANT SELECT, INSERT, UPDATE
  ON data_management.*
  TO 'svc_data_mgmt'@'%';

-- Réplica de lectura para data-analysis (acceso solo lectura)
-- data-analysis no tiene BD propia; lee de aquí vía usuario restringido.
CREATE USER IF NOT EXISTS 'svc_data_analysis_ro'@'%'
  IDENTIFIED BY 'changeme_data_analysis_ro';

GRANT SELECT
  ON data_management.*
  TO 'svc_data_analysis_ro'@'%';

FLUSH PRIVILEGES;