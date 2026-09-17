# Fase 1 y Fase 2 — Sistema B (resultados)

> Qué se corrió sobre el Sistema B (Go, k3s, `178.105.104.95`), cómo, y qué dio.
> La metodología está en [`plan-pruebas.md`](plan-pruebas.md); los comandos en
> [`runbook-fases.md`](runbook-fases.md). Este documento es el registro de las
> corridas reales, no el plan.

| | fecha | resultado |
|---|---|---|
| Fase 1 (escalera) | 2026-07-22 | `SUSTAINED_RATE = 100` fps, 0% de error hasta el nivel 100 |
| Fase 2 (endurance 12h + chaos) | 2026-07-27 13:04Z → 2026-07-28 01:07Z | 4.33M frames, 0.013% de error, 3/3 inyecciones sin pérdida |

---

## Fase 1 — Descubrimiento de la tasa sostenida

**Objetivo:** hallar la tasa máxima de entrada que la arquitectura soporta sin
disparar ningún criterio de falla. Ese valor alimenta la Fase 2.

### Diseño de cada corrida

Escenarios en `load-tests/scenarios/vu-{001,010,050,100}.yml`, corridos en
secuencia por `load-tests/run-all.sh`:

| fase interna | duración | propósito |
|---|---|---|
| warmup silencioso | 3 min | estabilizar conexiones, pools, GC, caches |
| medición | 7 min | ventana de la que salen las métricas |
| **total por nivel** | **10 min** | 30s de pausa antes del siguiente nivel |

- **`REPEATS=5` por nivel.** Con una sola corrida no hay forma de separar una
  diferencia real del ruido de esa corrida. `aggregate-results.js` produce
  mediana, media, desvío e IC 95% sobre las 5. Eran 3 hasta el 2026-09-15: con
  n=3 un solo outlier mueve la mediana y el IC sale tan ancho que no permite
  afirmar diferencias entre A y B.
- **Ingesta TCP**, no HTTP: frames binarios DTU contra `data-receiving:5000`.
  Engine `artillery-engine-dtu-tcp`, pool de procesos Python (`dtu-emulator`),
  una conexión TCP persistente por proceso.
- **Flota de 100 sensores** (`DTU_SENSOR_COUNT`), cada uno con su propia serie
  de desplazamiento física (`field.py`). Antes toda la carga salía de un único
  `sensor_id`: colapsaba el sharding del consumidor de early-warning sobre una
  partición y toda la escritura de baseline sobre una sola clave de Redis.
- **`reset-state.sh`** corre solo antes de cada nivel: `FLUSHDB` en Redis
  (buffer de dedup) + `TRUNCATE alerts` en MySQL early-warning. **No** toca
  `mysql-data-management` — esas lecturas persistidas son el dato que se mide.

### Criterios de falla (§1.3 de `plan-pruebas.md`)

Un nivel falla si en la ventana de 7 min se dispara cualquiera:

| señal | umbral |
|---|---|
| tasa de error | > 1% |
| latencia p99 | > 5s sostenido |
| backlog Redis | `data_receiving_redis_buffer_pending` crece monótono (sin serrucho) |
| colas RabbitMQ | `data_management.persist` / `early_warning.evaluate` crecen sin cota |
| caída de instancia | cualquier réplica pierde readiness |

`run-all.sh` muestrea además la CPU de la máquina cliente cada 5s a
`results/B/vu-<nivel>-r<N>.client-cpu.csv`, para no confundir la saturación del
generador con el límite del servidor.

### Resultados (mediana de 3 corridas)

| VU | fps | error | p50 (ms) | p95 (ms) | p99 (ms) | CPU cliente |
|---|---|---|---|---|---|---|
| 1 | 1.0 | 0.0000 | 190.6 | 228.2 | 301.9 | 1.9% |
| 10 | 10.0 | 0.0000 | 190.6 | 223.7 | 262.5 | 14.7% |
| 50 | 49.9 | 0.0000 | 190.6 | 247.2 | 284.3 | 88.7% |
| 100 | 99.8 | 0.0000 | 228.2 | 340.4 | 497.8 | 184.2% |

Cero errores en todos los niveles. **`SUSTAINED_RATE = 100`.**

### Alcance real: ≤100 fps

Los niveles 150/200/300/400 existen en la escalera pero **no son resultados del
sistema**: son la caracterización del instrumento. Por encima de ~100 fps el
cuello de botella es el generador (Artillery + un proceso Python por conexión,
sobre Windows), no el servidor.

Evidencia de que el techo es del generador:

- La cola `early_warning.evaluate` se mantuvo en **0** durante las 5h de la
  escalera: early-warning nunca fue el limitante en ningún escalón.
- Los fallos por encima de 100 son `pool_dispatch_failed`, `WinError 8/10055`,
  `emulator_error` — todos del lado que **genera** la carga, no rechazos del
  servidor.
- Son **intermitentes**: `vu-150 r1` pasó con 0 fallos y `r2`/`r3` fallaron con
  configuración idéntica. Depende del estado transitorio de la máquina cliente
  (sockets en TIME_WAIT, procesos huérfanos), no de la carga nominal.
- Artillery v2 ya reparte los escenarios en worker threads (`node_max` medido
  en 275% a VU=100, sobre un solo proceso): agregar procesos no sube el techo,
  solo multiplica el pool de Python, que es el límite real.

**Framing para la tesis:** 100 fps es un **piso verificado**, no el techo del
servidor. Redactar como "100 fps es la tasa sostenida verificada; el techo real
quedó sin medir por el límite del generador de carga". Nunca "el sistema aguanta
como máximo 100 fps". La comparación A vs B es válida ≤100 fps, donde el cliente
no interfiere.

---

## Fase 2 — Validación de resiliencia (12h + chaos)

**Objetivo:** confirmar que los 100 fps se sostienen en el tiempo, no solo en la
ventana de 7 min de la Fase 1. Detecta lo que una corrida corta no puede: fugas
de memoria, agotamiento de pools, backlog que se drena más lento de lo que
crece.

### Diseño

`load-tests/scenarios/vu-sustained-12h.yml`, vía `run-endurance.sh`:

| fase interna | duración |
|---|---|
| ramp-up 1 → 100 | 3 min |
| carga sostenida a 100 fps | 12 h (43200s) |

Corrido en **dos terminales Git Bash** (más robusto que `& … & wait`: matar una
no arrastra la otra). Terminal 1 = carga; terminal 2 = `chaos/run-during-endurance.sh`,
arrancado apenas la carga entra en régimen.

**El chaos no carga el `.env` de forma confiable** — su loader interno lo
descarta en silencio y el proceso muere con `SSH_ORCHESTRATOR es obligatorio`.
Hay que sourcearlo a mano antes de lanzarlo:

```bash
set -a; . load-tests/.env; set +a
GATEWAY_URL=http://178.105.104.95/api/v1/data/health ./chaos/run-during-endurance.sh
```

**Preflight.** El orquestador valida SSH, sudo remoto, Prometheus, gateway y la
existencia del target **antes** de comprometer 12h. Sin eso, un typo en las
credenciales se descubre recién a las 2h, con las 3 inyecciones perdidas.

**Watcher de conectividad.** Sondea TCP contra `TARGET_HOST` cada 15s (3 fallos
= corte) y anota la ventana en Grafana + `chaos/results/connectivity-*.log`. Un
corte de red desde el cliente se ve en Grafana **igual** que un sistema que dejó
de procesar: throughput a cero. No es hipotético — el 2026-07-16 el Sistema A
quedó inalcanzable 26 min con el host perfectamente vivo.

### Resultado de la carga sostenida

`load-tests/results/B/sustained-12h.json`, ventana
2026-07-27T13:04:49Z → 2026-07-28T01:07:51Z:

| métrica | valor |
|---|---|
| frames enviados | 4,329,095 |
| frames con ACK | 4,328,526 |
| errores (`emulator_error`, lado cliente) | 569 = **0.013%** |
| RTT p50 / p90 / p95 | 278.7 / 399.5 / 497.8 ms |
| RTT p99 / p999 / max | 871.5 / 1300.1 / 3588 ms |
| caídas de instancia | ninguna |

Cumple §2.4: error ≤1% sin tendencia creciente, sin caídas, sin crecimiento
monótono de memoria, backlog en banda estable.

### Chaos durante la corrida (§2.5)

Offsets medidos desde el arranque del orquestador. Snapshots pre/post en
`chaos/results/`.

| t | escenario | observado |
|---|---|---|
| t+2h (15:04Z) | `kill-rabbitmq.sh` | pre: `published=1248669 consumed_ew=2157913 dropped=0 pending=13`. post: `published=1363 consumed_dm=1447 dropped=0 pending=0`. Los contadores bajos del post son **reset del pod del broker al reiniciar**, no pérdida. Los consumidores reconectaron solos (supervisor + backoff, commits 996684b/530f713). |
| t+6h (19:04Z) | `pause-data-management.sh 90` | `consumed_dm` 1444812 → 732170: la réplica pausada reinició y reseteó su contador; la réplica hermana siguió consumiendo. `dropped=0`, `pending=35` estable. **90s no es arbitrario:** la readiness de B recién saca el pod de Endpoints a los ~35s; con una pausa más corta el resultado diría "nunca desvió" por la ventana, no por el sistema. |
| t+10h (23:04Z) | `netem-delay-ew-da.sh 8000 180` | published 2874278 → 2896777 (+22,499 en 214s), `consumed_ew` +11,270, `dropped=0`. Las alertas siguieron publicándose con el circuito abierto = continuidad operativa por umbral simple. **8000ms no es arbitrario:** tiene que superar `DATA_ANALYSIS_TIMEOUT_MS=5000`, o la llamada responde lenta pero OK y el breaker nunca abre. |

### Separación de criterios

§2.4 (carga sostenida) se evalúa **como si el chaos no existiera**. Un MTTR alto
en una inyección puntual es un hallazgo de tolerancia a fallos, se documenta y
alimenta la comparación A vs B — **no** obliga a repetir la Fase 2. Solo una
violación del §2.4 (caída de instancia, tendencia de error creciente, memoria
sin cota, backlog sin cota) obliga a repetir la Fase 1 con un techo más bajo y
después la Fase 2.
