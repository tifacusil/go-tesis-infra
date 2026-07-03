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

-- data-analysis ya NO accede a esta BD: lee las series vía gRPC
-- (data-management.ReadingService), respetando database-per-service. El usuario
-- svc_data_analysis_ro fue eliminado. En un cluster ya inicializado, dropearlo
-- a mano: DROP USER IF EXISTS 'svc_data_analysis_ro'@'%';

FLUSH PRIVILEGES;