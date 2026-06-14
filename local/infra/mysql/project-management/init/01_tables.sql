-- mysql/project-management/init/01_tables.sql

USE project_management;

CREATE TABLE IF NOT EXISTS projects (
  id          VARCHAR(64)  NOT NULL,
  name        VARCHAR(255) NOT NULL,
  location    VARCHAR(255),
  description TEXT,
  is_active   TINYINT(1)   NOT NULL DEFAULT 1,
  created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS sensors (
  id           VARCHAR(64)  NOT NULL,
  project_id   VARCHAR(64)  NOT NULL,
  sensor_type  ENUM(
    'gnss',
    'rainfall',
    'strain',
    'soil_pressure',
    'deep_displacement'
  )                         NOT NULL,
  description  VARCHAR(255),
  latitude_deg  DECIMAL(12,8),
  longitude_deg DECIMAL(12,8),
  elevation_m   DECIMAL(10,3),
  is_active     TINYINT(1)  NOT NULL DEFAULT 1,
  installed_at  DATETIME,
  created_at    DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at    DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  INDEX idx_sensor_project (project_id),
  INDEX idx_sensor_type    (sensor_type),
  CONSTRAINT fk_sensor_project FOREIGN KEY (project_id)
    REFERENCES projects(id) ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ─────────────────────────────────────────────────────────────────
-- Datos de prueba: proyectos y sensores del paper (Bai et al. 2020)
-- ─────────────────────────────────────────────────────────────────

INSERT IGNORE INTO projects (id, name, location, description) VALUES
  ('shangtan', 'Shangtan Landslide', 'Hezhou, Guangxi, China',
   'Deslizamiento con 8 sensores GNSS (GXZM-DB01 a DB08) y pluviómetro'),
  ('lingzhan', 'Lingzhan Landslide', 'Lingyun, Guangxi, China',
   'Deslizamiento con 3 sensores de desplazamiento profundo (LZ-DB01 a DB03)');

-- Sensores Shangtan (Figura 8 y Tabla 4 del paper)
INSERT IGNORE INTO sensors (id, project_id, sensor_type, description) VALUES
  ('GXZM-DB01', 'shangtan', 'gnss',     'GNSS superficie — punto de observación 01'),
  ('GXZM-DB02', 'shangtan', 'gnss',     'GNSS superficie — punto de observación 02'),
  ('GXZM-DB03', 'shangtan', 'gnss',     'GNSS superficie — punto de observación 03'),
  ('GXZM-DB04', 'shangtan', 'gnss',     'GNSS superficie — punto de observación 04'),
  ('GXZM-DB05', 'shangtan', 'gnss',     'GNSS superficie — punto de observación 05'),
  ('GXZM-DB06', 'shangtan', 'gnss',     'GNSS superficie — punto de observación 06'),
  ('GXZM-DB07', 'shangtan', 'gnss',     'GNSS superficie — punto de observación 07'),
  ('GXZM-DB08', 'shangtan', 'gnss',     'GNSS superficie — punto de observación 08'),
  ('ST-RAIN-01', 'shangtan', 'rainfall', 'Pluviómetro Shangtan');

-- Sensores Lingzhan (Figura 11 del paper)
INSERT IGNORE INTO sensors (id, project_id, sensor_type, description) VALUES
  ('LZ-DB01', 'lingzhan', 'deep_displacement', 'Inclinómetro profundo — pozo 01'),
  ('LZ-DB02', 'lingzhan', 'deep_displacement', 'Inclinómetro profundo — pozo 02'),
  ('LZ-DB03', 'lingzhan', 'deep_displacement', 'Inclinómetro profundo — pozo 03');