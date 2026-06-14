-- mysql/data-management/init/01_tables.sql
-- Tablas de lecturas de sensores (Bai et al. 2020, Tabla 1).
-- Sub-tablas verticales por tipo de sensor.
-- gnss_readings y deep_displacement_readings tienen particionamiento
-- anual por volumen (>10M registros según el paper).

USE data_management;

-- ─────────────────────────────────────────────────────────────────
-- Tablas de baja frecuencia (sin particionamiento)
-- ─────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS rainfall_readings (
  message_id              VARCHAR(36)   NOT NULL,
  project_id              VARCHAR(64)   NOT NULL,
  sensor_id               VARCHAR(64)   NOT NULL,
  schema_version          VARCHAR(10)   NOT NULL,
  sensor_timestamp        DATETIME(3)   NOT NULL,
  received_at             DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  sampling_interval_s     INT UNSIGNED,
  rainfall_mm             DECIMAL(8,2)  NOT NULL,
  cumulative_mm           DECIMAL(10,2),
  PRIMARY KEY (message_id),
  INDEX idx_rainfall_sensor_time  (sensor_id, sensor_timestamp),
  INDEX idx_rainfall_project_time (project_id, sensor_timestamp)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS strain_readings (
  message_id              VARCHAR(36)   NOT NULL,
  project_id              VARCHAR(64)   NOT NULL,
  sensor_id               VARCHAR(64)   NOT NULL,
  schema_version          VARCHAR(10)   NOT NULL,
  sensor_timestamp        DATETIME(3)   NOT NULL,
  received_at             DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  sampling_interval_s     INT UNSIGNED,
  strain_microstrain      DECIMAL(10,3) NOT NULL,
  temperature_c           DECIMAL(6,2),
  PRIMARY KEY (message_id),
  INDEX idx_strain_sensor_time  (sensor_id, sensor_timestamp),
  INDEX idx_strain_project_time (project_id, sensor_timestamp)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS soil_pressure_readings (
  message_id              VARCHAR(36)   NOT NULL,
  project_id              VARCHAR(64)   NOT NULL,
  sensor_id               VARCHAR(64)   NOT NULL,
  schema_version          VARCHAR(10)   NOT NULL,
  sensor_timestamp        DATETIME(3)   NOT NULL,
  received_at             DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  sampling_interval_s     INT UNSIGNED,
  pressure_kpa            DECIMAL(10,3) NOT NULL,
  temperature_c           DECIMAL(6,2),
  PRIMARY KEY (message_id),
  INDEX idx_soil_sensor_time  (sensor_id, sensor_timestamp),
  INDEX idx_soil_project_time (project_id, sensor_timestamp)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ─────────────────────────────────────────────────────────────────
-- Tablas de alto volumen CON PARTICIONAMIENTO ANUAL
-- ─────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS gnss_readings (
  message_id                 VARCHAR(36)   NOT NULL,
  project_id                 VARCHAR(64)   NOT NULL,
  sensor_id                  VARCHAR(64)   NOT NULL,
  schema_version             VARCHAR(10)   NOT NULL,
  sensor_timestamp           DATETIME(3)   NOT NULL,
  received_at                DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  sampling_interval_s        INT UNSIGNED,
  latitude_deg               DECIMAL(12,8) NOT NULL,
  longitude_deg              DECIMAL(12,8) NOT NULL,
  elevation_m                DECIMAL(10,3),
  displacement_n_mm          DECIMAL(10,3),
  displacement_e_mm          DECIMAL(10,3),
  displacement_u_mm          DECIMAL(10,3),
  cumulative_displacement_mm DECIMAL(10,3),
  PRIMARY KEY (message_id, sensor_timestamp),
  INDEX idx_gnss_sensor_time  (sensor_id, sensor_timestamp),
  INDEX idx_gnss_project_time (project_id, sensor_timestamp)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
PARTITION BY RANGE (YEAR(sensor_timestamp)) (
  PARTITION p2019 VALUES LESS THAN (2020),
  PARTITION p2020 VALUES LESS THAN (2021),
  PARTITION p2021 VALUES LESS THAN (2022),
  PARTITION p2022 VALUES LESS THAN (2023),
  PARTITION p2023 VALUES LESS THAN (2024),
  PARTITION p2024 VALUES LESS THAN (2025),
  PARTITION p2025 VALUES LESS THAN (2026),
  PARTITION p2026 VALUES LESS THAN (2027),
  PARTITION p_future VALUES LESS THAN MAXVALUE
);

CREATE TABLE IF NOT EXISTS deep_displacement_readings (
  message_id              VARCHAR(36)   NOT NULL,
  project_id              VARCHAR(64)   NOT NULL,
  sensor_id               VARCHAR(64)   NOT NULL,
  schema_version          VARCHAR(10)   NOT NULL,
  sensor_timestamp        DATETIME(3)   NOT NULL,
  received_at             DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  sampling_interval_s     INT UNSIGNED,
  depth_m                 DECIMAL(8,3)  NOT NULL,
  tilt_x_mm               DECIMAL(10,3) NOT NULL,
  tilt_y_mm               DECIMAL(10,3) NOT NULL,
  cumulative_tilt_mm      DECIMAL(10,3),
  PRIMARY KEY (message_id, sensor_timestamp),
  INDEX idx_deep_sensor_time  (sensor_id, sensor_timestamp),
  INDEX idx_deep_project_time (project_id, sensor_timestamp)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
PARTITION BY RANGE (YEAR(sensor_timestamp)) (
  PARTITION p2019 VALUES LESS THAN (2020),
  PARTITION p2020 VALUES LESS THAN (2021),
  PARTITION p2021 VALUES LESS THAN (2022),
  PARTITION p2022 VALUES LESS THAN (2023),
  PARTITION p2023 VALUES LESS THAN (2024),
  PARTITION p2024 VALUES LESS THAN (2025),
  PARTITION p2025 VALUES LESS THAN (2026),
  PARTITION p2026 VALUES LESS THAN (2027),
  PARTITION p_future VALUES LESS THAN MAXVALUE
);