-- mysql/project-management/init/00_schema.sql
-- Base de datos exclusiva del microservicio project-management.

CREATE DATABASE IF NOT EXISTS project_management
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS 'svc_project_mgmt'@'%'
  IDENTIFIED BY 'changeme_project_mgmt';

GRANT SELECT, INSERT, UPDATE, DELETE
  ON project_management.*
  TO 'svc_project_mgmt'@'%';

-- early-warning necesita leer proyectos y sensores para validar
-- umbrales. Acceso de solo lectura desde su propio contenedor MySQL
-- no aplica aquí (son BDs distintas); early-warning consultará
-- project-management vía HTTP API, no directamente a esta BD.
-- Este usuario queda como referencia si se decide exponer réplica.
-- CREATE USER IF NOT EXISTS 'svc_early_warning_ro'@'%' ...

FLUSH PRIVILEGES;