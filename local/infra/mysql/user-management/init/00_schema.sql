-- mysql/user-management/init/00_schema.sql
-- Base de datos exclusiva del microservicio user-management.

CREATE DATABASE IF NOT EXISTS user_management
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS 'svc_user_mgmt'@'%'
  IDENTIFIED BY 'changeme_user_mgmt';

GRANT SELECT, INSERT, UPDATE, DELETE
  ON user_management.*
  TO 'svc_user_mgmt'@'%';

FLUSH PRIVILEGES;