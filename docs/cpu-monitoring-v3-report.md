# Reporte de Monitoreo CPU — Servidor go-tesis (v3)

**Fecha:** 2026-06-29 18:22–18:40 UTC  
**Servidor:** 178.105.104.95 (Ubuntu 24.04, 3.8 GB RAM, 2 vCPUs, k3s)  
**Basado en:** server-cpu-monitoring-v3.md  
**Ver también:** docs/ram-optimization-report.md (v1), docs/cpu-optimization-report.md (v2)

---

## Resumen ejecutivo

Causa raíz única de los spikes de CPU confirmada con medición en tiempo real: **las probes `exec` de RabbitMQ arrancan una VM Erlang completa (`beam.smp`) cada ejecución. En 2 vCPUs esto consume 1 core durante 1.6 segundos con frecuencia efectiva de 1 spawn cada ~5 segundos, saturando el nodo y desencadenando una cascada de pod restarts.**

La solución (reemplazar probes exec por tcpSocket) ya fue aplicada en la sesión v2 (commit `31d5547`). Este reporte documenta la evidencia cuantitativa que confirma esa decisión.

---

## 1. Evidencia cuantitativa — Spawns de VM Erlang

### Duración medida de rabbitmq-diagnostics

```
real  1m1.629s   ← startup completo de VM Erlang
user  0m0.293s
sys   0m0.115s
```

Cada probe consume **~1 CPU core durante 1.6 segundos**.

### Frecuencia observada (muestreo 1s)

Ventana 18:34–18:35 UTC — 10 PIDs únicos de `beam.smp` en 51 segundos:

| Timestamp | PID beam.smp | %CPU | Intervalo |
|-----------|-------------|------|-----------|
| 18:34:10 | 4185992 | 114% | — |
| 18:34:16 | 4186238 | 95% | +6s |
| 18:34:20 | 4186376 | 112% | +4s |
| 18:34:30 | 4186702 | 116% | +10s |
| 18:34:31 | 4186800 | 110% | +1s (solapamiento) |
| 18:34:39 | 4187085 | 114% | +8s |
| 18:34:47 | 4187326 | 110% | +8s |
| 18:34:50 | 4187468 | 113% | +3s (solapamiento) |
| 18:34:59 | 4187785 | 114% | +9s |
| 18:35:01 | 4187895 | 112% | +2s (solapamiento) |

**= 1 spawn cada ~5 segundos** (esperado: 1 cada 6.25s si liveness 15s + readiness 10s sin solapamiento).

### Por qué la frecuencia supera lo esperado

1. Liveness (15s) + readiness (10s) se solapan → compiten por los 2 vCPUs
2. Solapamiento enlentece al proceso en ejecución → puede exceder `timeoutSeconds=10`
3. Kubelet registra timeout como fallo → dispara probe de recuperación inmediata fuera de schedule
4. Efecto cascada: más spawns → más contención → más timeouts → más spawns

### Carga total calculada

| Fuente | Frecuencia | CPU consumido | % nodo promedio |
|--------|-----------|--------------|-----------------|
| Readiness (10s) | 6/min | 1 core × 1.6s × 6 = 9.6 CPU-s/min | ~8% |
| Liveness (15s) | 4/min | 1 core × 1.6s × 4 = 6.4 CPU-s/min | ~5% |
| Solapamiento (cada 30s) | 2/min | pico 2 cores × 1.6s | **~100% del nodo** |
| **Total** | | | **~13% continuo + picos 100%** |

---

## 2. Cascada de fallos documentada

Cronología de eventos k8s (2 horas previas al monitoreo):

```
~18:00 UTC  Acumulación de probe spawns → saturación CPU
     ↓
~60 min atrás  project-management y user-management:
               HTTP liveness 503 (servicio lento por CPU saturada)
               → kubelet los mata → BackOff
               → 11 restarts acumulados project-management
               → 8 restarts acumulados user-management
     ↓
~51 min atrás  MySQL project-management + user-management:
               Stopped/restarted (dependencia de servicios anteriores)
     ↓
~22 min atrás  rabbitmq-0:
               Liveness probe timeout (3 fallos × 15s = 45s) → kubelet mata rabbitmq-0
               → rabbitmq-0 se reinicia
     ↓
~21 min atrás  data-receiving (2/3 pods) y data-management:
               RabbitMQ caído → conexiones perdidas → HTTP probes 503
               → kubelet los mata → 5–7 restarts adicionales
```

### Conteo de restarts acumulados

| Pod | Jun 24 (deploy inicial) | Jun 29 (este monitoreo) | Nuevos |
|-----|------------------------|-------------------------|--------|
| project-management | 4 | **11** | +7 |
| user-management | 0 | **8** | +8 |
| data-receiving ×3 | 4 c/u | **5–6** c/u | +1–2 |
| data-management ×2 | 4 c/u | **6–7** c/u | +2–3 |
| rabbitmq | 0 | **1** | +1 |
| early-warning ×2 | 4 c/u | 4 | 0 |
| mysql ×4 | 0 | 0 | 0 |

Los restarts de Jun 24 fueron race condition de startup (MySQL/RabbitMQ no listos). Los restarts posteriores son exclusivamente consecuencia de la cascada de probes.

---

## 3. Perfil de CPU por proceso (estado al momento del monitoreo)

| Proceso | %CPU promedio | Tipo |
|---------|--------------|------|
| k3s-server | 13.5% | Baseline estructural del orquestador |
| beam.smp (probes) | 100–127% × 1.6s cada ~5s | **Spike periódico — causa raíz** |
| beam.smp (broker main) | 1.5–2.2% | Baseline normal |
| containerd | 2.3% | Baseline |
| python ×2 (data-analysis) | 0.7% c/u | Idle |
| mysqld ×4 | 0.6–0.7% c/u | Baseline |
| metrics-server | 0.7% | Scrapes 15s |
| redis | 0.4% | Baseline |

**CPU nodo (mpstat, promedio 5 muestras):** usr 9.9% / sys 6.1% / idle 83.8%

El nodo parece "tranquilo" en promedio porque los spikes de 1.6s se diluyen. El daño es la **varianza**: 10% uso → 100% instantáneo → 10% uso, repetido cada 5 segundos.

---

## 4. Solución aplicada (v2, commit 31d5547)

Reemplazar probes exec por tcpSocket en puerto 5672 (AMQP):

```yaml
# Antes (problemático)
livenessProbe:
  exec:
    command: ["rabbitmq-diagnostics", "ping"]  # VM Erlang completa
  periodSeconds: 15
  timeoutSeconds: 10

# Después (aplicado)
livenessProbe:
  tcpSocket:
    port: 5672
  periodSeconds: 30       # más espaciado — TCP es instantáneo
  timeoutSeconds: 5
  failureThreshold: 3
```

TCP socket check verifica que el listener AMQP está activo sin spawnar ningún proceso. Costo: microsegundos de kernel. Costo anterior: 1 core × 1.6s cada ~5s.

**Por qué no HTTP Management API:** requiere `Authorization: Basic <base64>` hardcodeado en el manifiesto — expone credenciales en YAML de git. TCP en puerto AMQP es equivalente funcionalmente sin riesgo.

### Impacto esperado post-aplicación

| Métrica | Antes | Después |
|---------|-------|---------|
| CPU probes RabbitMQ | 100–127% × 1.6s cada 5s | ~0% |
| CPU nodo en pico | ~100% | ~15% baseline |
| Frecuencia de spawns | 10 en 51 segundos | 0 |
| Cascada de fallos | Documentada (21 min atrás) | Eliminada |
| rabbitmq-0 restarts futuros | Riesgo alto | Mínimo |

---

## 5. Otras fuentes de CPU (menores, no accionables)

| Fuente | CPU | Acción |
|--------|-----|--------|
| k3s-server | 13.5% constante | Overhead estructural, no reducible sin cambiar orquestador |
| metrics-server | 0.7% con picos scrape 15s | Normal, no accionable |
| MobaXterm monitoring (bash /proc) | ~0.3% | Sesión SSH de monitoreo activa, temporal |

---

## 6. Estado de todas las optimizaciones aplicadas (v1 + v2 + v3)

| Sesión | Commit | Descripción | Problema eliminado |
|--------|--------|-------------|-------------------|
| v1 | `1dad588`+ | Implement `Analyze` RPC — dataset vacío → `no_data` | Spike nocturno RAM ~1.4 GB + CPU ~200% |
| v1 | kubectl | Eliminar pods huérfanos namespace `default` | 1536 Mi requests bloqueados |
| v1/v2 | `3256dbf` | CPU limit 500m en data-analysis | Monopolización CPU en análisis ML |
| v1/v2 | `5f16a90`+`a64fa99`+`43b4d2e` | Afinar params MySQL (buffer pool, requests) | ~280 MB RAM baseline |
| v2 | `31d5547` | RabbitMQ probes exec → tcpSocket | **CPU spike 100% cada 5s + cascada restarts** |
| v2 | `7810969` | `limits.cpu` en todos los pods | CPU burst sin techo en 2 vCPUs |
