-- mysql/data-management/init/01_tables.sql
-- Tablas de lecturas del microservicio data-management.
-- DEBE coincidir con go-data-management/migrations/*.up.sql (fuente de verdad).
-- Corre como root en init del contenedor; el usuario runtime (svc_data_mgmt)
-- no tiene DDL, por eso el esquema se crea aqui y no via migrate al boot.
--
-- gnss_readings y deep_displacement_readings particionadas RANGE(YEAR(timestamp))
-- (alto volumen). Restriccion MySQL: PK/UNIQUE de tabla particionada debe
-- incluir la columna de particion -> PK (id, timestamp), UNIQUE (message_id, timestamp).

USE data_management;

-- ── no particionadas ────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS rainfall_readings (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    message_id VARCHAR(64),
    project_id VARCHAR(64) NOT NULL,
    sensor_id VARCHAR(64) NOT NULL,
    timestamp DATETIME NOT NULL,
    received_at DATETIME NOT NULL,
    rainfall_mm DOUBLE,
    cumulative_rainfall_mm DOUBLE,
    interval_minutes INT,
    UNIQUE KEY uk_rainfall_message (message_id),
    INDEX idx_rainfall_sensor_ts (sensor_id, timestamp),
    INDEX idx_rainfall_project_ts (project_id, timestamp)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS strain_readings (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    message_id VARCHAR(64),
    project_id VARCHAR(64) NOT NULL,
    sensor_id VARCHAR(64) NOT NULL,
    timestamp DATETIME NOT NULL,
    received_at DATETIME NOT NULL,
    strain_microstrain DOUBLE,
    temperature_celsius DOUBLE,
    UNIQUE KEY uk_strain_message (message_id),
    INDEX idx_strain_sensor_ts (sensor_id, timestamp),
    INDEX idx_strain_project_ts (project_id, timestamp)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS soil_pressure_readings (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    message_id VARCHAR(64),
    project_id VARCHAR(64) NOT NULL,
    sensor_id VARCHAR(64) NOT NULL,
    timestamp DATETIME NOT NULL,
    received_at DATETIME NOT NULL,
    pressure_kpa DOUBLE,
    temperature_celsius DOUBLE,
    UNIQUE KEY uk_soil_pressure_message (message_id),
    INDEX idx_soil_pressure_sensor_ts (sensor_id, timestamp),
    INDEX idx_soil_pressure_project_ts (project_id, timestamp)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ── particionadas por anio ──────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS gnss_readings (
    id BIGINT AUTO_INCREMENT,
    message_id VARCHAR(64),
    project_id VARCHAR(64) NOT NULL,
    sensor_id VARCHAR(64) NOT NULL,
    timestamp DATETIME NOT NULL,
    received_at DATETIME NOT NULL,
    displacement_x_mm DOUBLE,
    displacement_y_mm DOUBLE,
    displacement_z_mm DOUBLE,
    displacement_horizontal_mm DOUBLE,
    cumulative_displacement_mm DOUBLE,
    fix_quality VARCHAR(16),
    PRIMARY KEY (id, timestamp),
    UNIQUE KEY uk_gnss_message (message_id, timestamp),
    INDEX idx_gnss_sensor_ts (sensor_id, timestamp),
    INDEX idx_gnss_project_ts (project_id, timestamp)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
PARTITION BY RANGE (YEAR(timestamp)) (
    PARTITION p2024 VALUES LESS THAN (2025),
    PARTITION p2025 VALUES LESS THAN (2026),
    PARTITION p2026 VALUES LESS THAN (2027),
    PARTITION p2027 VALUES LESS THAN (2028),
    PARTITION pmax  VALUES LESS THAN MAXVALUE
);

CREATE TABLE IF NOT EXISTS deep_displacement_readings (
    id BIGINT AUTO_INCREMENT,
    message_id VARCHAR(64),
    project_id VARCHAR(64) NOT NULL,
    sensor_id VARCHAR(64) NOT NULL,
    timestamp DATETIME NOT NULL,
    received_at DATETIME NOT NULL,
    depth_m DOUBLE,
    tilt_x_mm DOUBLE,
    tilt_y_mm DOUBLE,
    cumulative_tilt_mm DOUBLE,
    PRIMARY KEY (id, timestamp),
    UNIQUE KEY uk_deep_displacement_message (message_id, timestamp),
    INDEX idx_deep_displacement_sensor_ts (sensor_id, timestamp),
    INDEX idx_deep_displacement_project_ts (project_id, timestamp)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
PARTITION BY RANGE (YEAR(timestamp)) (
    PARTITION p2024 VALUES LESS THAN (2025),
    PARTITION p2025 VALUES LESS THAN (2026),
    PARTITION p2026 VALUES LESS THAN (2027),
    PARTITION p2027 VALUES LESS THAN (2028),
    PARTITION pmax  VALUES LESS THAN MAXVALUE
);
