# Diagnóstico: por qué el Sistema B rinde 4x menos que el Sistema A

**Fecha:** 2026-07-21 / 2026-07-22
**Alcance:** Fase 1 del `plan-pruebas.md` (ladder de VU), servicio `early-warning` de ambos sistemas.

---

## 1. Resumen ejecutivo

El ladder de carga da `SUSTAINED_RATE` = **400 fps para A** y **100 fps para B**, con el
mismo test y el mismo hardware (2 cores, 3819 MB). La investigación descartó con
mediciones las explicaciones obvias (CPU, RabbitMQ, cliente de carga, lenguaje,
algoritmo) y encontró que la diferencia se origina en **alertas espurias causadas por
mensajes que llegan fuera de orden**.

Hallazgos principales:

1. **Los motores de umbral de A y B son equivalentes** — test diferencial: 28/30 casos
   idénticos.
2. **El corpus del benchmark no simula un sensor**: `cumulative_displacement_mm` es
   `uniform(0, 3000)` por frame, con un único `sensor_id`. Todas las alertas de ambos
   sistemas son `red`, con velocidades de hasta 259 km/día.
3. **Un mensaje fuera de orden hacía retroceder el baseline**, lo que provocaba que el
   mensaje siguiente evaluara contra una lectura vieja y cruzara el umbral sin motivo.
   Bajo desorden, la tasa de alerta escalaba **43x**.
4. Ese defecto **lo introdujo el commit `b7fbe66` en el Sistema A**, y el port a Go lo
   copió. Corregido en ambos sistemas.

---

## 2. Punto de partida

Resultados del ladder (`load-tests/results/`):

| nivel | A: acked | B: acked | B: RTT p99 |
|---|---|---|---|
| vu-001 | 600/600 | 600/600 | 308 ms |
| vu-010 | 6000/6000 | 6000/6000 | 252 ms |
| vu-050 | 30000/30000 | 30000/30000 | 273 ms |
| vu-100 | 60000/60000 | 60000/60000 | 416 ms |
| vu-400 | **240000/240000** | **28959/240000** | 3072 ms |

Señales de `plan-pruebas.md` §1.3 para B en vu-400, confirmadas vía Prometheus:

- `early_warning.evaluate`: backlog final **37,388**, sin drenar.
- `data_receiving_redis_buffer_pending`: final **1130**.
- Pods sin reinicios en ningún nivel.

---

## 3. Hipótesis descartadas

Cada una con la medición que la descarta.

### 3.1 No es CPU

| | A | B |
|---|---|---|
| CPU de `early-warning` | 0.29 cores | **0.13 cores** |
| CPU del nodo | **100% / 100%** | 84% / 79% |

B falla con los pods **al 6.5% de un core** y 37k mensajes esperando. A satura sus dos
cores y entrega 400/s. Añadir CPU no era el arreglo.

### 3.2 No es RabbitMQ

Pese a que B tiene `limits.cpu: 300m` / `512Mi` y A corre nativo con watermark de 1.6 GB:

| cola (B, vu-400) | `consumer_utilisation` |
|---|---|
| `early_warning.evaluate` | **0.019** |
| `data_management.persist` | **1.000** |

Utilisation bajo significa que **el consumidor** limita, no el broker (definición de
RabbitMQ). En el mismo broker capado, `data_management.persist` drenó 155/s sin
problemas. Las colas son idénticas en ambos sistemas (`durable=true`,
`messages_persistent=0`).

### 3.3 No es el cliente de carga

En vu-400 el servidor ingirió **111,783 frames** (154.8/s) mientras el cliente reportaba
**28,959** acked. `errors.pool_dispatch_failed` es consecuencia, no causa: el pool tiene
400 slots y con RTT de 2.5 s su capacidad es `400 / 2.5 = 160/s`, que coincide con los
154.8/s medidos.

### 3.4 No es el test ni el emulador

`git log`: el engine y los escenarios no cambian desde **2026-07-15**, el `dtu-emulator`
desde **2026-07-13**. A corrió el 18-jul y B el 21-jul. Es literalmente el mismo test.

### 3.5 No es el lenguaje ni el diseño del consumidor

Ambos usan el **mismo diseño serial**:

- A: `on_message` de pika `BlockingConnection`, `prefetch_count=20`, 2 instancias.
- B: idéntico antes del worker pool.

### 3.6 No es el motor de umbral

Test diferencial sobre 30 casos borde (dt=0, dt<0, gap > `MAX_DT`, umbral exacto, campos
faltantes, proyecto desconocido, offset `+00:00`, delta negativo, sub-segundo):
**28/30 idénticos**. Umbrales iguales (`shangtan` 20/15/10, `lingzhan` 15/10/5),
`MAX_DT_SECONDS`=7200 en ambos.

Los 2 casos que difieren son sub-segundo, y **el motor Go puro coincide exacto con
Python**: la diferencia aparece solo al pasar el baseline por Redis (ver §6.2).

---

## 4. Dónde estaba realmente el costo

Latencia por mensaje: **A 4.97 ms, B 19.5 ms**. Descomposición en B:

| componente | costo |
|---|---|
| evaluación del umbral (CPU pura) | **0.006 ms** |
| entrega de cada alerta | **161.3 ms** |
| aporte de las alertas por mensaje | **8.2 ms** de los 19.5 |

El motor no cuesta nada. El costo es el camino de alerta: gRPC a user-management, push
FCM, INSERT en MySQL y dos escrituras Redis — todo **en línea**, bloqueando el consumidor
serial.

Y B lo pagaba **10x más seguido**:

| | A | B |
|---|---|---|
| mensajes procesados | 241,756 | 60,667 |
| alertas | 1,188 | 3,066 |
| **tasa** | **0.49%** | **5.05%** |

---

## 5. Causa raíz: desorden de llegada

### 5.1 El experimento

Harness aislado: motor de umbral y cache **reales** contra Redis, sin RabbitMQ, MySQL ni
FCM (el camino de alerta se sustituye por un sleep). Corpus generado con
`build_envelope()` del `dtu-emulator` real. Se varía concurrencia y desorden por
separado.

Control con **1 hilo, sin ventana** — o sea, sin ningún race:

| desorden | tasa de alerta |
|---|---|
| 0 | 0.29% |
| 20 | 0.75% |
| 200 | **8.00%** |
| 2000 | **21.50%** |

**Factor 27x sin una sola línea de concurrencia.** El desorden domina.

Ajuste contra lo medido en producción:

| escenario | desorden que lo reproduce | medido |
|---|---|---|
| A | ≈25 | 0.50% |
| B | ≈87 | 3.61% |

Ratio 3.5x, coherente con que B estaba saturado (`redis_buffer_pending`=1130) y A no.

### 5.2 El mecanismo

En `Evaluate`, la rama `dt <= 0` devolvía `ShouldStoreCurrent: true`:

```
baseline = 10:00:05
llega    = 10:00:03   (tardío)

ANTES:  el baseline retrocede a 10:00:03
        el mensaje siguiente (10:00:05) ve dt = 2s → evalúa → alerta red falsa

AHORA:  se descarta, el baseline sigue en 10:00:05
        el mensaje siguiente (10:00:05) ve dt = 0 → skip, correcto
```

Cada frame desordenado **habilitaba una evaluación extra** que debía haber sido `dt=0`.
Y con `cumulative_displacement_mm` aleatorio, cualquier evaluación con `dt>0` cruza el
umbral ~50% de las veces.

El desorden no es hipotético: son 3 instancias de `data-receiving` publicando en paralelo
más el buffer Redis de reintento, y **crece justo cuando el sistema se satura**.

### 5.3 El origen del defecto

El commit `b7fbe66` del Sistema A, titulado *"fix(threshold_engine): correct handling of
non-positive dt_seconds"*, hizo:

```diff
- return EvalResult(False, None, None, {... "skip_reason": "out_of_order_or_duplicate_timestamp"})
+ return EvalResult(True, store_current, None, {... "note": "non_positive_dt_overwrite_baseline"})
```

**A hacía lo correcto originalmente.** Ese commit lo rompió y el port a Go copió la
versión ya rota. Las correcciones aplicadas son por tanto una **restauración**, no una
divergencia respecto del original.

---

## 6. El corpus del benchmark

Hallazgo colateral, y probablemente el más importante para la validez de la tesis.

`dtu-emulator/src/sender/randomizer.py:55`:

```python
cumul = rng.uniform(0.0, 3000.0)
```

- `cumulative_displacement_mm` **no es acumulativo**: es un valor independiente en
  [0, 3000] por frame. El delta entre lecturas es uniforme en [-3000, +3000].
- Con `dt=1s`, `speed` llega a **259,200,000 mm/día** (259 km/día). Medido en MySQL:
  A max 251,009,461 / B max 257,449,475.
- Umbral `blue` = 10 mm/día ⇒ basta un delta de 0.000116 mm ⇒ **cualquier evaluación con
  `dt>0` alerta ~50% de las veces**.
- `fix_quality` es aleatorio ponderado (`rtk_fixed` 0.90).
- El timestamp usa `"%Y-%m-%dT%H:%M:%SZ"` ⇒ **resolución de 1 segundo**; a 400 fps hay
  ~400 frames por valor de timestamp, casi todos con `dt=0`.
- Identidad fija: `project_id=shangtan`, `sensor_id=GXZM-DB03`. **Un solo sensor.**

**Todas las alertas de ambos sistemas son `red`.** El ladder ejecuta el camino más caro
del sistema con una frecuencia que en campo sería excepcional, y el sensor único impide
cualquier paralelización correcta del consumidor.

---

## 7. Cambios aplicados

| repo | commit | qué |
|---|---|---|
| `go-early-warning` | `8ad71d8` | worker pool + sharding por `sensor_id` en el consumidor |
| `go-early-warning` | `6d7ae50` | gofmt del test + eliminación de `handle()` sin uso (fallos de CI) |
| `go-early-warning` | `89f660c` | **`dt<=0` ya no retrocede el baseline** |
| `early-warning-service` (A) | `5c777ee` | **mismo fix; revierte `b7fbe66`** |
| `go-tesis-infra` | `0036583` | `CONSUMER_WORKERS=1` en el deployment |

### 7.1 Sobre el worker pool (`8ad71d8`)

Se implementó concurrencia con sharding por `sensor_id` — necesario para la correctitud,
porque la evaluación es stateful por sensor (read-modify-write del baseline en Redis).

**No rindió y se dejó desactivado.** Con un único `sensor_id` en la carga, todo hashea al
mismo shard: 1 worker activo, 7 dormidos. Medido: 102.6 vs 101.7 msg/s, **cero mejora**.
Además ensancha el race entre réplicas (el sharding no cruza pods): la tasa de alerta
subió de 3.61% a 5.12%.

Por eso `CONSUMER_WORKERS=1` en `0036583`. Subirlo solo tiene sentido con carga
multi-sensor.

---

## 8. Verificación

### 8.1 Del fix del baseline, en el harness

Mismo barrido, con el motor parcheado:

| desorden | antes | después |
|---|---|---|
| 0 | 0.29% | 0.23% |
| 200 | **8.00%** | **0.23%** |
| 2000 | **21.50%** | **0.29%** |

De variar 43x con el desorden a no variar.

### 8.2 Del Sistema A, en el servidor

Test funcional en el venv real, tras aplicar el parche:

```
fuera de orden   -> store=False alert=None skip=out_of_order_or_duplicate_timestamp
mismo timestamp  -> store=False alert=None
normal 30mm/dia  -> store=True  alert=red speed=30.0
bajo umbral      -> store=True  alert=None
```

`diff` contra el backup: solo la línea 119. `py_compile` OK. Ambas instancias
reiniciadas, `active`, 2 consumers reconectados, 0 tracebacks.
Backup: `/opt/early-warning-service/threshold_engine.py.bak-20260722-035957`.

### 8.3 Del Sistema B, en el clúster

Verificación end-to-end publicando a la cola real:

1. Baseline en `04:20:00Z`, `cum=100`.
2. Mensaje más viejo: `04:19:00Z`, `cum=900`.
3. Estado en Redis: `{"cumulative_displacement_mm":100,"timestamp":"2026-07-22T04:20:00Z"}`.

El baseline **no retrocedió** y no se generó ninguna alerta. Clave de prueba eliminada.

---

## 9. Estado final

| | fix en repo | fix corriendo |
|---|---|---|
| A (Python) | `5c777ee` | ✅ |
| B (Go) | `89f660c` | ✅ |

`CONSUMER_WORKERS=1` en B, en paridad con el consumo serial de A.

---

## 10. Pendiente

1. **Corregir el corpus del emulador** (§6). Es lo que más pesa: mientras
   `cumulative_displacement_mm` sea ruido blanco y haya un solo sensor, cualquier
   `SUSTAINED_RATE` medido está dominado por un camino irreal, y el worker pool no puede
   rendir. Requiere re-correr también el ladder de A para mantener comparabilidad.
2. **`cache.go:78`**: `Format(time.RFC3339)` pierde el sub-segundo del baseline; el
   original Python guarda `isoformat()` completo. Fix: `RFC3339Nano`. Inactivo mientras
   los timestamps de origen tengan resolución de segundo, pero es una divergencia real.
3. **Lock por sensor en Redis** (o `WATCH`/Lua). El sharding por sensor no cruza
   réplicas, así que el race entre pods sigue abierto. Es el prerequisito para subir
   `CONSUMER_WORKERS` con seguridad.
4. **Escalones intermedios en el ladder** (150, 200, 300). Entre 100 y 400 hay un salto
   de 4x sin medir; el servidor sostuvo ~155 fps en vu-400 aun en dificultades, así que
   `SUSTAINED_RATE=100` es un piso conservador, no un techo medido (`plan-pruebas.md` §6
   ya contempla extender la escalera).
5. **Instrumentar la CPU de la máquina cliente** durante cada nivel, para descartar el
   límite falso del engine con evidencia y no con aritmética.

---

## 11. Efecto esperado del fix sobre el rendimiento

Bajar la tasa de alerta de ~5% a ~0.5% quita ~7.4 ms de los 19.5 ms por mensaje:
throughput estimado **102 → ~160 msg/s** (factor 1.6x).

**No alcanza 400.** El multiplicador grande sigue siendo el corpus multi-sensor, que
habilitaría el worker pool ya implementado (8 workers × ~51/s ≈ 408/s).

Los ~11 ms restantes por mensaje son I/O de fondo: Redis pod-a-pod contra localhost en A,
más las dos operaciones extra de idempotencia que A no tiene.

---

## 12. Reproducibilidad

Los harnesses del diagnóstico (test diferencial de motores, generador de corpus con el
emulador real, y el barrido de desorden contra Redis) se construyeron en el scratchpad de
la sesión y **no están versionados**. Para rehacerlos:

- **Test diferencial**: el harness Go debe vivir **dentro** del módulo
  (`cmd/<nombre>/`), porque `threshold` es un paquete `internal/`.
- **Barrido de desorden**: motor y cache reales + un Redis efímero; el camino de alerta
  se sustituye por un sleep; el desorden se modela desplazando cada frame una cantidad
  aleatoria de hasta *k* posiciones.

Nota operativa sobre el repo de A: `git fetch`/`pull` **fallan desde el servidor**
(`Host key verification failed` — sin credenciales SSH para GitHub), el working tree está
sucio y ~6 commits atrás de origin, y `/opt/early-warning-service` es `root:root`
(requiere sudo y `git -c safe.directory=...`). Para modificarlo: clonar por HTTPS desde
la máquina local y aplicar el archivo en `/opt` por separado.
