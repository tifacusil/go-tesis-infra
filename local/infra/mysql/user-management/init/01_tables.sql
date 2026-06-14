-- mysql/user-management/init/01_tables.sql

USE user_management;

CREATE TABLE IF NOT EXISTS users (
  id            BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
  username      VARCHAR(64)      NOT NULL,
  password_hash VARCHAR(255)     NOT NULL,
  email         VARCHAR(255),
  is_active     TINYINT(1)       NOT NULL DEFAULT 1,
  created_at    DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at    DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_username (username),
  UNIQUE KEY uq_email (email)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS roles (
  id          INT UNSIGNED  NOT NULL AUTO_INCREMENT,
  name        VARCHAR(64)   NOT NULL,
  description VARCHAR(255),
  PRIMARY KEY (id),
  UNIQUE KEY uq_role_name (name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS user_roles (
  user_id   BIGINT UNSIGNED NOT NULL,
  role_id   INT UNSIGNED    NOT NULL,
  assigned_at DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (user_id, role_id),
  CONSTRAINT fk_ur_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
  CONSTRAINT fk_ur_role FOREIGN KEY (role_id) REFERENCES roles(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS refresh_tokens (
  id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id     BIGINT UNSIGNED NOT NULL,
  token_hash  VARCHAR(255)    NOT NULL,
  expires_at  DATETIME        NOT NULL,
  created_at  DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  INDEX idx_token_hash (token_hash),
  INDEX idx_user_tokens (user_id, expires_at),
  CONSTRAINT fk_rt_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ─────────────────────────────────────────────────────────────────
-- Datos de prueba: roles base y usuario admin
-- ─────────────────────────────────────────────────────────────────

INSERT IGNORE INTO roles (name, description) VALUES
  ('admin',    'Administrador del sistema'),
  ('operator', 'Operador de monitoreo'),
  ('viewer',   'Solo lectura de datos y alertas');