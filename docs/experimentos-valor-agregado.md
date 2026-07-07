# Cómo ejecutar los 4 experimentos de valor agregado

Guía de ejecución para las 4 métricas de valor agregado de la investigación
(no reportadas ni por Bai et al. 2020 ni por El Fellah et al. 2026):

1. Latencia sensor→alerta (umbral cruzado → FCM ack)
2. Tolerancia a fallos cuantificada (chaos/fault-injection)
3. Burst vs. steady-state
4. Backpressure en la ingesta

Cada sección lista: **qué prueba existe**, **en qué repo/archivo vive**, y **el
comando exacto** para correrla. Los tests unitarios verifican que la
instrumentación es correcta (no rompe nada); los escenarios de infra/carga son
los que producen los números para el paper.

---

## 1. Latencia sensor→alerta

Instrumentado en [go-early-warning](../../go/go-early-warning). Mide el tramo
controlable: `threshold.Alert.EvaluatedAt` (umbral cruzado) → FCM acepta el
multicast (`SuccessCount > 0`, message ID asignado).

### Tests unitarios (verifican la instrumentación, no producen el número final)

| Test | Archivo | Qué verifica |
|---|---|---|
| `TestAlertEvaluatedAtUsesInjectedClock` | `internal/earlywarning/threshold/threshold_test.go` | `EvaluatedAt` se setea con el reloj inyectado (`Config.Now`) al momento de construir el `Alert` |
| `TestSpeedAndLevels` | `internal/earlywarning/threshold/threshold_test.go` | Cada alerta generada (blue/orange/red) tiene `EvaluatedAt` no-cero |
| `TestHandlerExposesCustomAndProcessMetrics` | `pkg/metrics/metrics_test.go` | El histograma `ew_alert_delivery_latency_seconds` está registrado y expuesto en `/metrics` |

```bash
cd go-early-warning
go test ./internal/earlywarning/threshold/... ./pkg/metrics/... -run 'EvaluatedAt|SpeedAndLevels|ExposesCustom' -v
```

### Cómo obtener el número real (no es un test, es una métrica en producción/staging)

1. Levantar el stack completo (`local/infra` + `local/services/early-warning`)
   con Firebase configurado (`FirebaseConfig.CredentialsPath`/`CredentialsJSON`
   reales — con no-op pusher la métrica nunca se observa, ver
   `internal/earlywarning/publisher/firebase.go:39-55`).
2. Generar una lectura GNSS que cruce umbral (real o vía `sensor_reading`
   publicado directo a RabbitMQ, ver `contracts/examples/`).
3. Query Prometheus:
   ```promql
   histogram_quantile(0.50, sum(rate(ew_alert_delivery_latency_seconds_bucket[5m])) by (le))
   histogram_quantile(0.95, sum(rate(ew_alert_delivery_latency_seconds_bucket[5m])) by (le))
   histogram_quantile(0.99, sum(rate(ew_alert_delivery_latency_seconds_bucket[5m])) by (le))
   ```
4. Dashboard: agregar panel a `tesis-infra/local/infra/grafana/provisioning/dashboards/dashboard.json`
   (aún no incluido — pendiente de primera corrida real para fijar buckets/escala).

---

## 2. Backpressure en la ingesta

Instrumentado en [go-data-receiving](../../go/go-data-receiving). Gauge
`data_receiving_redis_buffer_pending` reporta el backlog de `sensor_buffer:*`
en cada pasada del `RetryWorker` (sin costo extra de `SCAN`).

### Tests unitarios

| Test | Archivo | Qué verifica |
|---|---|---|
| `TestRetryWorker_Pass_ReportsBacklogGauge` | `internal/buffer/retry_worker_test.go` | El gauge recibe el conteo correcto tras una pasada (`Count()` del buffer) |
| `TestRetryWorker_Pass_RepublishesAndDeletes` | `internal/buffer/retry_worker_test.go` | El drenado del buffer sigue funcionando igual (no regresión) |
| `TestMetrics_*` | `internal/observability/metrics_test.go` | Colectores base siguen registrados |

```bash
cd go-data-receiving
go test ./internal/buffer/... ./internal/observability/... -v
```

### Integration test (RabbitMQ + Redis reales, Testcontainers/docker-compose)

```bash
cd go-data-receiving
go test ./test/integration/... -run 'TestPublish_DeliversAndClearsBuffer|TestBrokerDown_PersistsThenRetryRecovers' -v
# Requiere RabbitMQ + Redis accesibles — ver test/integration/rabbitmq_buffer_test.go
# para las env vars esperadas (o levantar local/infra primero).
# TestBrokerDown_PersistsThenRetryRecovers es el que ejercita el RetryWorker
# (y por tanto el gauge de backlog) con un broker real caído/recuperado.
```

### Cómo encontrar el punto de saturación (el experimento real)

1. Levantar `local/infra` (RabbitMQ + Redis + exporters) + `local/services/data-receiving`.
2. Correr Artillery a tasas crecientes — usa los escenarios steady-state
   existentes en orden creciente, o el escenario burst (sección 3) para saltar
   directo a una tasa alta:
   ```bash
   cd tesis-infra/load-tests
   TARGET_HOST=http://<host> SYSTEM=B ./run-all.sh   # 001, 010, 050, 100, 400 vu
   ```
3. Mientras corre, observar en Grafana (paneles nuevos "Sist B - data-receiving:
   backlog Redis" y "Sist B - RabbitMQ: profundidad de cola / mensajes sin ack")
   o directo en Prometheus:
   ```promql
   sum(data_receiving_redis_buffer_pending)
   sum(rabbitmq_queue_messages_ready{queue="sensors.raw"})
   sum(rabbitmq_channel_messages_unacked)
   ```
4. El throughput límite real es la tasa de VU en la que estas curvas dejan de
   drenar entre pasadas del `RetryWorker` (crecimiento sostenido, no serrucho).

---

## 3. Burst vs. steady-state

Escenarios Artillery nuevos en `tesis-infra/load-tests/scenarios/`, paralelos
a los steady-state existentes (`vu-001/010/050/100/400.yml`).

| Escenario | Archivo | Fases |
|---|---|---|
| Burst suave | `scenarios/vu-burst-10to100.yml` | steady 10/s (120s) → ramp a 100/s (15s) → hold 100/s (30s) → ramp a 10/s (15s) → steady 10/s (120s) |
| Burst agresivo | `scenarios/vu-burst-50to400.yml` | steady 50/s (120s) → ramp a 400/s (30s) → hold 400/s (30s) → ramp a 50/s (30s) → steady 50/s (120s) |

```bash
cd tesis-infra/load-tests
TARGET_HOST=http://<host> SYSTEM=B ./run-all-burst.sh
# Resultados: load-tests/results/B/burst-10to100.json y burst-50to400.json
```

Comparar contra el baseline steady-state ya corrido (`run-all.sh`) al mismo
nivel de VU pico (100 y 400) — mismas métricas (throughput/latencia/CPU/mem),
mismo dashboard Grafana, ventana de tiempo distinta (la del spike vs. la
sostenida).

```bash
artillery report load-tests/results/B/burst-50to400.json   # reporte HTML local
```

No hay test unitario para esto — es configuración de carga, no código; la
validación es que el YAML parsea (`artillery run --dry-run`, si la versión de
Artillery lo soporta) o simplemente la primera corrida real.

---

## 4. Tolerancia a fallos cuantificada (chaos)

Scripts en `tesis-infra/chaos/`. Requieren la infra Docker Compose levantada
(`local/infra` + `local/services/*`) y Docker corriendo (montan
`/var/run/docker.sock` para invocar Pumba).

| Script | Escenario | Qué mide |
|---|---|---|
| `chaos/kill-rabbitmq.sh` | `pumba kill` sobre `rabbitmq-1` | MTTR de reconexión, mensajes perdidos (published vs. consumed) |
| `chaos/pause-data-management.sh [duration] [gateway_url]` | `pumba pause` sobre `data-management-1` | Blast radius: ¿el balanceador desvía tráfico a `data-management-2` sin errores? |
| `chaos/netem-delay-ew-da.sh [delay_ms] [duration]` | `pumba netem delay` sobre `data-analysis-1` | Circuit breaker bajo latencia alta (no solo caída total); continuidad operativa por umbral simple (CLAUDE.md §2.3) |

```bash
cd tesis-infra
docker compose -f local/infra/docker-compose.yml up -d
docker compose -f local/infra/docker-compose.observability.yml --env-file local/infra/envs/observability.env up -d
# + levantar local/services/* necesarios

./chaos/kill-rabbitmq.sh
./chaos/pause-data-management.sh 30 http://localhost/api/v1/data/health
./chaos/netem-delay-ew-da.sh 2000 60
```

No son tests unitarios — son runbooks de infra. Cada uno guarda snapshots
crudos en `chaos/results/<escenario>-<epoch>.snapshot` (contadores
Prometheus antes/después) para el análisis posterior. `chaos/README.md` tiene
el detalle de qué representa cada métrica capturada.

---

## Resumen: comando único por experimento

```bash
# 1. Latencia sensor->alerta (unit tests que validan la instrumentación)
(cd go-early-warning && go test ./internal/earlywarning/threshold/... ./pkg/metrics/... -v)

# 2. Backpressure (unit + integration)
(cd go-data-receiving && go test ./internal/buffer/... ./internal/observability/... -v)
(cd go-data-receiving && go test ./test/integration/... -run 'TestPublish_DeliversAndClearsBuffer|TestBrokerDown_PersistsThenRetryRecovers' -v)

# 3. Burst vs steady-state (carga real, requiere TARGET_HOST)
(cd tesis-infra/load-tests && TARGET_HOST=http://<host> SYSTEM=B ./run-all-burst.sh)

# 4. Chaos (requiere infra Docker Compose levantada)
(cd tesis-infra/chaos && ./kill-rabbitmq.sh && ./pause-data-management.sh && ./netem-delay-ew-da.sh)
```
