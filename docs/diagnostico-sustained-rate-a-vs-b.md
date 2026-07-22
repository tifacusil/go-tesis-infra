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

**Estado al 2026-07-22:** las seis correcciones que el diagnóstico dejó pendientes están
aplicadas (§10) — corpus de flota, sub-segundo del baseline, compare-and-set contra el
race entre réplicas, escalones intermedios, repeticiones con IC 95%, y CPU del cliente
instrumentada. Los números de §2 son del corpus viejo y **ya no son comparables**: hace
falta re-correr el ladder completo en ambos sistemas (§10.7).

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

El contraste con el estudio base (Bai et al. 2020), que fija el régimen de operación real,
está en §13. **Corregido en §10.1**: el corpus del ladder ya no es este.

---

## 7. Cambios aplicados

| repo | commit | qué |
|---|---|---|
| `go-early-warning` | `8ad71d8` | worker pool + sharding por `sensor_id` en el consumidor |
| `go-early-warning` | `6d7ae50` | gofmt del test + eliminación de `handle()` sin uso (fallos de CI) |
| `go-early-warning` | `89f660c` | **`dt<=0` ya no retrocede el baseline** |
| `early-warning-service` (A) | `5c777ee` | **mismo fix; revierte `b7fbe66`** |
| `go-tesis-infra` | `0036583` | `CONSUMER_WORKERS=1` en el deployment |

La segunda tanda (corpus, CAS del baseline, escalones, repeticiones, CPU del cliente) está
en §10.

### 7.1 Sobre el worker pool (`8ad71d8`)

Se implementó concurrencia con sharding por `sensor_id` — necesario para la correctitud,
porque la evaluación es stateful por sensor (read-modify-write del baseline en Redis).

**No rindió y se dejó desactivado.** Con un único `sensor_id` en la carga, todo hashea al
mismo shard: 1 worker activo, 7 dormidos. Medido: 102.6 vs 101.7 msg/s, **cero mejora**.
Además ensancha el race entre réplicas (el sharding no cruza pods): la tasa de alerta
subió de 3.61% a 5.12%.

Por eso `CONSUMER_WORKERS=1` en `0036583`. Subirlo solo tiene sentido con carga
multi-sensor — que es lo que habilita §10.1, con el race entre réplicas ya cerrado por
§10.3. Sigue en 1 hasta medirlo de nuevo.

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

## 10. Segunda tanda de correcciones

Los seis pendientes que dejó el diagnóstico, todos aplicados el 2026-07-22.

### 10.1 Corpus del emulador (`dtu-emulator@9e32f0c`, `go-tesis-infra@fdcfbc2`)

Lo que más pesaba. `src/sender/field.py` modela una **flota**: cada sensor es una función
determinista de su id, con una tasa de reptación por debajo del umbral más bajo, eventos
de deformación ocasionales que lo cruzan, y desplazamiento acumulado **monótono** — la
magnitud que Bai et al. grafican en la Figura 8a. La lectura *i* lleva el timestamp que el
sensor habría estampado en su *i*-ésima muestra horaria, contado desde la ventana de
monitoreo del paper.

`(sensor_id, reading_index)` determina la lectura por completo, así que cualquier worker
del pool puede servir cualquier sensor y un respawn retoma la misma serie; las cachés por
sensor son memoización, no estado.

La identidad la asigna el **engine**, que reparte cada `send` entre `DTU_SENSOR_COUNT`
sensores round-robin (100 por defecto) y lleva el contador de lecturas — es el único
proceso que ve la corrida entera. `DTU_SENSOR_COUNT=0` restaura el corpus previo.

Medido sobre 100 sensores × 1,000 lecturas con los umbrales de Shangtan:

| | antes | después |
|---|---|---|
| tasa de alerta | ~50% de las evaluaciones | **1.03%** |
| distribución | 100% `red` | blue 0.30% / orange 0.16% / red 0.57% |
| velocidad máxima | 259,200,000 mm/día | **50.5 mm/día** |
| sensores | 1 | 100 (configurable) |

Verificado extremo a extremo contra un servidor TCP falso que decodifica los frames:
6 sensores, 10 frames cada uno, acumulado monótono por sensor y timestamps horarios con
offset propio.

### 10.2 Sub-segundo del baseline (`go-early-warning@534d884`)

`Format(time.RFC3339)` → `RFC3339Nano` en `cache.go`. Inactivo mientras los timestamps de
origen tengan resolución de segundo (el corpus nuevo también la tiene), pero era una
divergencia real contra el `isoformat()` del original.

### 10.3 Race del baseline entre réplicas (`go-early-warning@534d884`)

`SetLastReading` pasa a ser un **compare-and-set en Lua**: la escritura solo aterriza si
la almacenada es más vieja.

Es una guarda, no un lock. Codifica el invariante ("el baseline nunca retrocede en el
tiempo") en el único lugar que puede imponerlo atómicamente, cuesta el mismo round trip
que el `SET` plano, y no deja lease que renovar ni que se filtre si un pod muere a mitad
de la evaluación. Lo que **no** evita es que dos réplicas evalúen contra el mismo baseline
apenas viejo; eso da una velocidad promediada sobre una ventana más larga, que es
conservador, y converge apenas aterriza una de las escrituras.

La comparación es sobre `timestamp_unix_us`, no sobre el string ISO: los timestamps con
sub-segundo **no ordenan lexicográficamente** (`"…:00Z"` > `"…:00.5Z"` como texto, y al
revés en el tiempo). Los microsegundos son más finos que el formato de cable (que lleva
milisegundos) y siguen siendo exactos como *double* de Lua/cjson.

Verificado contra el Redis real del Sistema B (`kubectl exec` en `redis-0`): 8 casos,
incluidos "mismo timestamp", "un microsegundo más viejo", "un microsegundo más nuevo",
entrada legacy sin score y entrada corrupta. El test de integración equivalente queda en
`cache_integration_test.go`, con el mismo patrón de build tag y `EW_REDIS_ADDR` que
`pkg/idempotency`.

Es el prerequisito para subir `CONSUMER_WORKERS` con seguridad.

### 10.4 Escalones intermedios (`go-tesis-infra@556439d`)

`scenarios/vu-{150,200,300}.yml`. El hueco de 4x entre 100 y 400 queda cerrado.

### 10.5 CPU de la máquina cliente (`go-tesis-infra@556439d`)

`run-all.sh` la muestrea cada 5s a `vu-<nivel>-r<N>.client-cpu.csv`. Existe porque la
conclusión de §3.3 se sostuvo con aritmética y no con evidencia.

En Windows la muestra sale de `Win32_PerfFormattedData_PerfOS_Processor` y no de
`Get-Counter`: este último toma la ruta del contador con los nombres **localizados**
(`\Procesador(_Total)\% de tiempo de procesador` en un Windows en español), así que la
ruta en inglés falla con *"El objeto especificado no se encontró"*.

### 10.6 Repeticiones y estadística (`go-tesis-infra@556439d`)

`REPEATS` (default 3) corre cada nivel N veces a `vu-<nivel>-r<N>.json`, y
`aggregate-results.js` reporta mediana, media, desvío e intervalo de confianza al 95% de
throughput, tasa de error, RTT p50/p90/p95/p99 y CPU del cliente.

Con 3 corridas el multiplicador *t* es **4.303**, no 1.96: el intervalo sale ancho a
propósito, y ese ancho *es* el resultado — dice cuánto no se puede afirmar con 3 corridas.

Verificado contra los resultados históricos: reproduce B vu-400 = 40.1 fps con 87.9% de
error, y A vu-400 = 398.7 fps.

### 10.7 Lo que queda

- **Re-correr el ladder completo en ambos sistemas.** Los números de §2 se midieron con el
  corpus viejo; no son comparables con nada que se mida ahora. Con `REPEATS=3` y 8
  escalones son ~4h15 por sistema. **B ya está hecho** (2026-07-22): resultados y análisis
  en [`ladder-b-2026-07-22.md`](ladder-b-2026-07-22.md). Falta A, sin tocar el corpus en
  el medio.
- **Barrer el tamaño de flota** hacia los 3,233 sensores del paper, ahora que
  `DTU_SENSOR_COUNT` lo permite. A tasas de llegada bajas una flota grande implica que la
  mayoría de los frames son la *primera* lectura de su sensor, que no tiene baseline
  contra el cual evaluar.
- **Subir `CONSUMER_WORKERS` en B.** Está en 1 por el corpus de un solo sensor; con flota
  y con el CAS de §10.3 ya tiene sentido volver a medirlo.
- **Portear §10.2 y §10.3 al Sistema A**, que tiene el mismo `set_last_reading`
  incondicional (`redis_cache.py:99`) y también corre 2 instancias sobre la misma cola.
  Sin esto los dos sistemas dejan de ser equivalentes en esa dimensión.

---

## 11. Efecto esperado sobre el rendimiento

Bajar la tasa de alerta de ~5% a ~0.5% quita ~7.4 ms de los 19.5 ms por mensaje:
throughput estimado **102 → ~160 msg/s** (factor 1.6x).

**No alcanza 400 por sí solo.** El multiplicador grande es el corpus multi-sensor
(§10.1), que habilita el worker pool ya implementado: 8 workers × ~51/s ≈ 408/s.

Los ~11 ms restantes por mensaje son I/O de fondo: Redis pod-a-pod contra localhost en A,
más las dos operaciones extra de idempotencia que A no tiene.

Con el corpus corregido la tasa de alerta medida es 1.03% (§10.1), así que el término del
camino de alerta pasa de ~7.8 ms/mensaje a ~1.7 ms. **Nada de esto está medido todavía en
el sistema**: son proyecciones sobre el modelo de costo de §4, y sólo el ladder re-corrido
(§10.7) las confirma o las refuta.

---

## 12. Reproducibilidad

El corpus de §10.1 sí está versionado y cubierto por tests
(`dtu-emulator/tests/test_field.py`), igual que el agregador de §10.6.

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

---

## 13. Contraste con los estudios base

Dos referencias sostienen el trabajo: **Bai et al. (2020)** aporta el sistema que se
replica, y **El Fellah et al. (2026)** aporta el método experimental.

### 13.1. Bai et al. (2020) — el sistema replicado

> *The design and application of landslide monitoring and early warning system based on
> microservice architecture.* Geomatics, Natural Hazards and Risk, 11(1), 928–948.
> doi:10.1080/19475705.2020.1766580

El Sistema A es una réplica fiel. Todo lo que aparece "mágicamente" en el código sale de
ahí:

| en el código | en el paper |
|---|---|
| umbrales `shangtan` 20/15/10 mm/día | Tabla 4 |
| umbrales `lingzhan` 15/10/5 mm/día | Tabla 5 |
| `sensor_id: GXZM-DB03` | GNSS GXZM-DB01–DB08 del área de Shangtan (§3.2.2) |
| data-receiving en C#, 3 instancias | Tabla 2 |
| data-management Spring Boot, 2 instancias | Tabla 2 |
| early-warning en Python, 2 instancias | Tabla 2 |
| Consul, Nginx con polling, RabbitMQ, Redis | §2.3, §2.4 |

`MAX_DT_SECONDS=7200` también queda explicado: es el doble del intervalo de muestreo
nominal.

**El régimen de operación real, y el conflicto con el benchmark.** §2.2 del paper:
*"the measurement is performed every hour by default. When the accelerated deformation of
the landslide is detected, the sampling interval can be shortened"* — en el caso Lingzhan
lo bajaron a 15 minutos durante la emergencia.

Con los **3,233 sensores** que el sistema tenía conectados en 2019 (Figura 5):

| régimen | carga total del sistema |
|---|---|
| 1 muestra/hora (nominal) | **0.90 mensajes/s** |
| 1 muestra/15 min (emergencia) | **3.6 mensajes/s** |
| crecimiento real de 2019 (9.0 M registros/año) | **0.29 mensajes/s** |

**El ladder emite 400 mensajes/s de un solo sensor**: ~1.4 millones de veces la tasa por
sensor del paper, y ~450x la carga total del sistema completo que Bai describe.

Esto explica de raíz el problema de §6. Con muestreo horario, un delta de 1.25 mm produce
30 mm/día — cruza `red` con sentido físico. Con 400 frames/s el `dt` es de milisegundos y
cualquier ruido produce millones de mm/día. El generador no está mal calibrado por
descuido: **opera en un régimen que el estudio base nunca contempla.**

**Consecuencia para la lectura del resultado.** `SUSTAINED_RATE = 100 fps` en B no
significa "B aguanta poco". Es **~110x la carga nominal** del sistema de Bai y **~28x su
modo de emergencia**. Ambos sistemas exceden por dos órdenes de magnitud el caso de uso
documentado en la literatura que replican.

### 13.2. El Fellah et al. (2026) — el método experimental

> *Analysis of microservices-based IoT systems: deployment challenges, industry
> practices, and performance insights.* Internet of Things, 36, 101867.
> doi:10.1016/j.iot.2025.101867

De aquí sale el diseño del ladder: niveles de VU **1, 10, 50, 100, 400** (§5.3), carga con
**Artillery**, CPU y memoria con **Prometheus** y **Grafana** (Tabla 6), y las métricas
throughput / latencia / CPU / memoria. Los escalones no son arbitrarios.

**Diferencias de nuestro montaje que conviene declarar:**

| aspecto | El Fellah et al. | este trabajo |
|---|---|---|
| corridas por configuración | **3–4 independientes** | **1** |
| estadística reportada | mediana, p90/p95/p99, IC 95% | percentiles de una corrida |
| requests por escenario | 10,000 | hasta 240,000 |
| hardware | Raspberry Pi 4B, 4 cores / 4 GB | 2 cores / 3.8 GB |
| eje de comparación | **monolito vs. microservicios** | **microservicios-A vs. microservicios-B** |

Las dos primeras filas son la brecha metodológica a cubrir (ver §10.6). La última es
importante para la redacción: el eje de comparación **no es el mismo**, así que las
conclusiones de El Fellah (throughput +134%, latencia −49%, memoria −7/13%, CPU mayor) no
se heredan a este trabajo y conviene decirlo explícitamente.

**Precedente útil.** En §6 (threats to validity) los autores reconocen que *"Scenario 2
may suffer gateway saturation overshadowing downstream effects"* — exactamente el
fenómeno del `pool_dispatch_failed` diagnosticado en §3.3: la saturación del punto de
entrada enmascara el comportamiento de los servicios de aguas abajo. Es citable como
antecedente reconocido del problema.

También reconocen no aplicar tests estadísticos (Tabla 8) y no hacer análisis de ablación
por práctica individual, ambas señaladas como limitaciones propias.
