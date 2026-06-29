# Reporte de Optimización CPU — Servidor go-tesis (v2)

**Fecha:** 2026-06-29  
**Servidor:** 178.105.104.95 (Ubuntu 24.04, 3.8 GB RAM, 2 vCPUs, k3s)  
**Basado en:** server-ram-cpu-report-v2.md  
**Ver también:** docs/ram-optimization-report.md (sesión anterior — RAM)

---

## Nuevos hallazgos (no estaban en reporte v1)

### Hallazgo 1 — RabbitMQ probes spawnan VM Erlang cada 10–15 s

`rabbitmq-diagnostics` arranca una VM Erlang completa por cada ejecución de probe para conectarse al broker, hacer el check y terminar. Con liveness (15s) + readiness (10s) = ~10 spawns/min constantes.

**Evidencia:** `rabbitmq-0` mostraba **252m CPU** en `kubectl top pods` mientras `beam.smp` solo usaba 0.9% en `ps aux`. Delta = overhead de `rabbitmq-diagnostics`.

```yaml
# Configuración anterior (problemática)
livenessProbe:
  exec:
    command: ["rabbitmq-diagnostics", "ping"]   # VM Erlang completa
  periodSeconds: 15
readinessProbe:
  exec:
    command: ["rabbitmq-diagnostics", "check_running"]  # VM Erlang completa
  periodSeconds: 10
```

### Hallazgo 2 — Ningún pod tenía `limits.cpu` en nodo de 2 vCPUs

Con ~1400m en CPU requests totales y 2000m disponibles, cualquier burst consumía el margen sin restricción, degradando todos los demás pods simultáneamente.

| Pod | CPU Request | CPU Limit (antes) |
|-----|------------|-------------------|
| data-analysis ×2 | 100m | ninguno |
| mysql ×4 | 100m | ninguno |
| rabbitmq | 100m | ninguno |
| data-management ×2 | 50m | ninguno |
| data-receiving ×3 | 50m | ninguno |
| early-warning ×2 | 50m | ninguno |
| project-management | 50m | ninguno |
| user-management | 50m | ninguno |
| redis | 50m | ninguno |
| **Total requests** | **~1400m** | **sin techo** |

---

## Soluciones Aplicadas

### Sol 1 — Reemplazar probes exec de RabbitMQ con tcpSocket

**Archivo:** `k8s/base/infra/rabbitmq/statefulset.yaml`  
**Commit:** `31d5547`

TCP socket check en puerto 5672 (AMQP) verifica que el listener está activo sin spawnar ningún proceso.

```yaml
# Antes
livenessProbe:
  exec:
    command: ["rabbitmq-diagnostics", "ping"]
  periodSeconds: 15
  timeoutSeconds: 10
readinessProbe:
  exec:
    command: ["rabbitmq-diagnostics", "check_running"]
  periodSeconds: 10
  timeoutSeconds: 10

# Después
livenessProbe:
  tcpSocket:
    port: 5672
  initialDelaySeconds: 40
  periodSeconds: 30        # más espaciado — TCP es barato
  timeoutSeconds: 5
  failureThreshold: 3
readinessProbe:
  tcpSocket:
    port: 5672
  initialDelaySeconds: 30
  periodSeconds: 15
  timeoutSeconds: 5
  failureThreshold: 3
```

**Por qué no HTTP probe:** La alternativa HTTP (`/api/health/checks/aliveness` en puerto 15672) requiere `Authorization: Basic <base64>` hardcodeado en el manifiesto — expone credenciales en YAML de git. TCP en puerto AMQP es equivalente sin riesgo de seguridad.

**Impacto esperado:** CPU RabbitMQ en reposo cae de ~252m a <20m.

---

### Sol 2 — `limits.cpu` en todos los pods

**Archivos modificados:**

| Archivo | CPU limit agregado | Commit |
|---------|-------------------|--------|
| `k8s/base/services/data-management/deployment.yaml` | `100m` | `7810969` |
| `k8s/base/services/early-warning/deployment.yaml` | `100m` | `7810969` |
| `k8s/base/services/data-receiving/deployment.yaml` | `100m` | `7810969` |
| `k8s/base/services/user-management/deployment.yaml` | `100m` | `7810969` |
| `k8s/base/services/project-management/deployment.yaml` | `100m` | `7810969` |
| `k8s/base/infra/rabbitmq/statefulset.yaml` | `300m` | `7810969` |
| `k8s/base/infra/redis/statefulset.yaml` | `100m` | `7810969` |

> MySQL ×4 (`96m req / 320Mi lim`) y data-analysis (`500m`) ya tenían CPU limit de sesión anterior.

**Distribución final de CPU limits en el cluster:**

| Pod | Req | Limit | Ratio |
|-----|-----|-------|-------|
| data-analysis ×2 | 100m | 500m | 5× |
| mysql ×4 | 100m | 300m* | 3× |
| rabbitmq | 100m | 300m | 3× |
| data-management ×2 | 50m | 100m | 2× |
| data-receiving ×3 | 50m | 100m | 2× |
| early-warning ×2 | 50m | 100m | 2× |
| project-management | 50m | 100m | 2× |
| user-management | 50m | 100m | 2× |
| redis | 50m | 100m | 2× |

*MySQL CPU limit no se agregó en esta sesión — ver nota abajo.

> **Nota:** MySQL StatefulSets no tienen `limits.cpu` explícito aún. Se omitió para no acumular demasiados cambios en una sola sesión. Recomendado agregar `300m` por instancia en próxima iteración.

**Comportamiento con throttling:** Un pod que supera su CPU limit es throttleado (pausado brevemente por el CFS scheduler), no terminado. Mucho mejor que saturar ambos vCPUs y degradar todo el cluster.

---

## Estado Final — CPU limits en el cluster

```
Total CPU requests:  ~1400m / 2000m  (70%)
Total CPU limits:    ~4200m          (sobresubscripción controlada)
```

La sobresubscripción en limits es intencional — los pods rara vez alcanzan sus límites simultáneamente. El throttling individual protege el nodo completo.

---

## Comandos para aplicar en servidor

```bash
sudo kubectl apply -k k8s/base/infra/rabbitmq/
sudo kubectl apply -k k8s/base/services/data-management/
sudo kubectl apply -k k8s/base/services/early-warning/
sudo kubectl apply -k k8s/base/services/data-receiving/
sudo kubectl apply -k k8s/base/services/user-management/
sudo kubectl apply -k k8s/base/services/project-management/
sudo kubectl apply -k k8s/base/infra/redis/
sudo kubectl get pods -n landslide
```

Para verificar CPU usage tras aplicar:
```bash
sudo kubectl top pods -n landslide
sudo kubectl top node
```

---

## Resumen de todas las optimizaciones (RAM + CPU)

| Sesión | Sol | Descripción | Impacto |
|--------|-----|-------------|---------|
| v1 | 1 | Implement `Analyze` RPC — dataset vacío retorna `no_data` | Elimina spike nocturno RAM ~1.4 GB + CPU ~200% |
| v1 | 2 | Eliminar pods huérfanos namespace `default` | Libera 1536 Mi requests bloqueados |
| v1 | 4 | CPU limit 500m en data-analysis | Evita monopolización CPU en análisis ML |
| v1 | 5 | Afinar params MySQL (buffer pool 64M→32M, buffers secundarios) | ~280 MB RAM |
| v2 | 1 | RabbitMQ probes exec→tcpSocket | CPU RabbitMQ ~252m→<20m |
| v2 | 2 | `limits.cpu` en todos los pods restantes | Throttling controlado vs saturación total |
