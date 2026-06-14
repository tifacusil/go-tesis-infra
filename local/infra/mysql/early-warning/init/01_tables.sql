-- mysql/early-warning/init/01_tables.sql

USE early_warning;

-- ─────────────────────────────────────────────────────────────────
-- Umbrales de alerta por proyecto y tipo de sensor
-- Basado en Tabla 4 (Shangtan) y Tabla 5 del paper (Bai et al. 2020)
-- ─────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS thresholds (
  id              BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  project_id      VARCHAR(64)     NOT NULL,
  sensor_type     ENUM(
    'gnss',
    'rainfall',
    'strain',
    'soil_pressure',
    'deep_displacement'
  )                               NOT NULL,
  alarm_level     ENUM('blue', 'orange', 'red') NOT NULL,
  metric          VARCHAR(64)     NOT NULL COMMENT 'Campo del payload a evaluar, ej: cumulative_displacement_mm',
  operator        ENUM('gte', 'gt', 'lte', 'lt') NOT NULL,
  value           DECIMAL(12,4)   NOT NULL,
  unit            VARCHAR(32),
  is_active       TINYINT(1)      NOT NULL DEFAULT 1,
  created_at      DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at      DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  INDEX idx_threshold_project_type (project_id, sensor_type),
  INDEX idx_threshold_active       (is_active)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ─────────────────────────────────────────────────────────────────
-- Historial de alertas emitidas
-- ─────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS alerts (
  id              BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  message_id      VARCHAR(36)     NOT NULL COMMENT 'message_id del envelope que disparó la alerta',
  project_id      VARCHAR(64)     NOT NULL,
  sensor_id       VARCHAR(64)     NOT NULL,
  sensor_type     VARCHAR(32)     NOT NULL,
  alarm_level     ENUM('blue', 'orange', 'red') NOT NULL,
  threshold_id    BIGINT UNSIGNED,
  metric          VARCHAR(64)     NOT NULL,
  measured_value  DECIMAL(12,4)   NOT NULL,
  threshold_value DECIMAL(12,4)   NOT NULL,
  sensor_timestamp DATETIME(3)    NOT NULL,
  emitted_at      DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  notified        TINYINT(1)      NOT NULL DEFAULT 0,
  notified_at     DATETIME(3),
  PRIMARY KEY (id),
  UNIQUE KEY uq_alert_message (message_id, metric),
  INDEX idx_alert_project_time  (project_id, emitted_at),
  INDEX idx_alert_level         (alarm_level),
  INDEX idx_alert_notified      (notified),
  CONSTRAINT fk_alert_threshold FOREIGN KEY (threshold_id)
    REFERENCES thresholds(id) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ─────────────────────────────────────────────────────────────────
-- Datos de prueba: umbrales del paper
-- Tabla 4 Shangtan — deformación superficial (GNSS)
-- "deformation speed" se aproxima como velocidad acumulada
-- ─────────────────────────────────────────────────────────────────

INSERT IGNORE INTO thresholds
  (project_id, sensor_type, alarm_level, metric, operator, value, unit)
VALUES
  -- Shangtan GNSS (Tabla 4 del paper: velocidad de deformación en mm/día)
  ('shangtan', 'gnss', 'blue',   'cumulative_displacement_mm', 'gte', 10.0, 'mm/day'),
  ('shangtan', 'gnss', 'orange', 'cumulative_displacement_mm', 'gte', 15.0, 'mm/day'),
  ('shangtan', 'gnss', 'red',    'cumulative_displacement_mm', 'gte', 20.0, 'mm/day'),

  -- Lingzhan deep displacement (Figura 11 del paper — referencia)
  ('lingzhan', 'deep_displacement', 'blue',   'cumulative_tilt_mm', 'gte', 50.0,  'mm'),
  ('lingzhan', 'deep_displacement', 'orange', 'cumulative_tilt_mm', 'gte', 100.0, 'mm'),
  ('lingzhan', 'deep_displacement', 'red',    'cumulative_tilt_mm', 'gte', 130.0, 'mm');