# Plan de pruebas de carga — metodología de 2 fases

> Define cómo se ejecutan las pruebas de carga sobre los sistemas A (baseline,
> Bai et al. 2020) y B (reescrito, este proyecto) para producir los números de
> throughput, latencia, CPU y memoria que sustentan la comparación empírica.
> Complementa [experimentos-valor-agregado.md](experimentos-valor-agregado.md)
> (métricas no reportadas por ninguno de los dos papers base) y
> [chaos/README.md](../chaos/README.md) (tolerancia a fallos).

---

## 0. Por qué 2 fases y no una sola corrida larga

Una sola prueba larga a una tasa fija no revela **dónde** falla el sistema —
solo si esa tasa específica aguanta. Y una sola prueba corta a tasa creciente
no revela si el sistema **degrada con el tiempo** bajo carga sostenida (fugas
de memoria, saturación gradual de pools de conexión, backlog que crece sin
drenar). Se necesitan las dos, en secuencia:

1. **Fase de descubrimiento** (corridas cortas, carga incremental) → halla la
   tasa máxima de entrada que la arquitectura soporta sin fallar.
2. **Fase de validación de resiliencia** (corrida larga, carga sostenida a esa
   tasa) → confirma que el límite hallado en (1) se sostiene en el tiempo, no
   solo en una ventana de minutos.

Ortiz et al. usan explícitamente una corrida de 12 horas a carga máxima para
"verificar que dicha carga puede ser soportada por periodos de tiempo más
largos" — el mismo razonamiento que separa aquí las dos fases.

---

## 1. Fase de descubrimiento (corridas cortas, 10 min c/u)

**Objetivo:** someter al sistema a cargas incrementales y descubrir la tasa
máxima de entrada que la arquitectura puede soportar antes de fallar.

**Por qué 10 minutos:** metodológicamente es el tiempo mínimo necesario para
que el sistema alcance estado estable tras el warmup y produzca una ventana de
medición representativa (percentiles p50/p95/p99 estables), sin gastar horas
en niveles de carga que ya fallan. Es una prueba de **descubrimiento**, no de
resistencia — su duración corta es intencional.

### 1.1 Diseño de cada corrida

| Fase interna | Duración | Propósito |
|---|---|---|
| `ramp`/warmup silencioso | 3 min | Estabilizar conexiones, pools, JIT/GC, caches antes de medir |
| medición | 7 min | Ventana real de la que se extraen las métricas |
| **Total por nivel** | **10 min** | |

### 1.2 Escalones de carga

Implementados en `load-tests/scenarios/vu-{001,010,050,100,400}.yml`, corridos
en secuencia por `load-tests/run-all.sh`:

```bash
cd tesis-infra/load-tests
TARGET_HOST=http://<host> SYSTEM=B ./run-all.sh
```

| Nivel (req/s) | Archivo |
|---|---|
| 1 | `scenarios/vu-001.yml` |
| 10 | `scenarios/vu-010.yml` |
| 50 | `scenarios/vu-050.yml` |
| 100 | `scenarios/vu-100.yml` |
| 400 | `scenarios/vu-400.yml` |

30s de pausa entre niveles (drenaje de colas/conexiones antes del siguiente
escalón).

### 1.3 Criterio de falla (dónde se detiene el escalamiento)

Un nivel se considera **fallido** — y por tanto el nivel anterior es la "tasa
máxima de entrada" candidata — si durante la ventana de medición (7 min) se
observa cualquiera de:

| Señal | Umbral | Fuente |
|---|---|---|
| Tasa de error HTTP | > 1% de requests con status ≥ 500 o timeout | reporte Artillery (`errors`) |
| Latencia p99 | > 5s sostenido (no picos aislados) | reporte Artillery / `metrics-by-endpoint` |
| Backlog Redis sin drenar | crecimiento sostenido entre pasadas del `RetryWorker` (no serrucho) | `data_receiving_redis_buffer_pending` |
| Cola RabbitMQ sin drenar | `rabbitmq_queue_messages_ready{queue="sensors.raw"}` crece sostenido | Prometheus |
| Caída de instancia | cualquier réplica no pasa `readinessProbe`/health durante la corrida | logs / Consul o K8s |

Si ninguna señal se dispara en el nivel 400, ese es el techo probado (no hay
niveles más altos definidos aún — ver §6 para extender el escalón).

### 1.4 Salida de la fase

La **tasa máxima de entrada** (`SUSTAINED_RATE`) es el último nivel de la
tabla 1.2 que **no** disparó ningún criterio de falla de 1.3. Ese valor
alimenta directamente la Fase 2 (§2).

---

## 2. Fase de validación de resiliencia (corrida de 12 horas)

**Objetivo:** una vez descubierto el límite teórico en la Fase 1, someter al
sistema a esa carga máxima de forma **sostenida durante 12 horas**, para
verificar que dicha carga puede ser soportada por periodos de tiempo más
largos (Ortiz et al.) — no solo en la ventana de 7 minutos de la Fase 1.

Esta fase es **obligatoria**, no opcional: una tasa que aguanta 7 minutos
puede fallar a las 3 horas por fugas de memoria, agotamiento de pools de
conexión, o backlog que crece más lento de lo que se drena (indetectable en
una ventana corta).

### 2.1 Precondición

Requiere `SUSTAINED_RATE` de §1.4 (tasa máxima sin fallas de la Fase 1).

### 2.2 Diseño de la corrida

Implementada en `load-tests/scenarios/vu-sustained-12h.yml`, ejecutada por
`load-tests/run-endurance.sh`, en paralelo con el orquestador de chaos
`chaos/run-during-endurance.sh` (§2.5):

```bash
cd tesis-infra
TARGET_HOST=http://<host> SUSTAINED_RATE=<tasa-fase-1> SYSTEM=B \
  ./load-tests/run-endurance.sh &
./chaos/run-during-endurance.sh &
wait
```

| Fase interna | Duración | Propósito |
|---|---|---|
| ramp-up | 3 min | Igual que Fase 1, para no confundir el arranque con degradación |
| carga sostenida | 12 h (43200s) | Ventana de validación de resiliencia |

Resultado: `load-tests/results/<SYSTEM>/sustained-12h.json`.

### 2.3 Qué observar durante la corrida (no solo al final)

A diferencia de la Fase 1, acá el interés está en la **tendencia**, no solo en
el valor final:

| Métrica | Dónde | Qué buscar |
|---|---|---|
| Throughput / latencia p50/p95/p99 | reporte Artillery + Grafana | estabilidad a lo largo de las 12h, no solo el promedio |
| Memoria residente por instancia | `process_resident_memory_bytes` (Prometheus) | crecimiento monótono sostenido = fuga |
| CPU | `cpu_user_seconds_total` | saturación progresiva |
| Backlog Redis / cola RabbitMQ | igual que §1.3 | debe oscilar en banda estable, no crecer sin cota |
| Reinicios/caídas de instancia | logs, Consul/K8s | cualquier caída invalida "soportado sin falla" |

### 2.4 Criterio de éxito

La corrida se considera **exitosa** (la tasa hallada en Fase 1 es sostenible)
si, durante las 12 horas:

- Ninguna instancia cae o pierde su `readinessProbe`/health.
- La tasa de error se mantiene ≤ 1% de forma estable (sin tendencia
  creciente).
- La memoria residente no muestra crecimiento monótono no acotado (fuga).
- El backlog de Redis y la cola de RabbitMQ oscilan en banda estable.

Si algún criterio falla, la "tasa máxima de entrada" real es menor que la
hallada en Fase 1, y corresponde repetir la Fase 1 con un techo más bajo o
insertar un escalón intermedio antes de repetir la Fase 2.

### 2.5 Chaos durante la corrida (tolerancia a fallos bajo carga sostenida)

La Fase 2 valida que la tasa máxima se sostiene en el tiempo, pero no que el
sistema tolera fallos *mientras* la sostiene — eso lo prueban por separado los
escenarios de `chaos/` (ver `experimentos-valor-agregado.md` §4), pero siempre
contra un sistema en reposo o con carga ligera. Para cerrar esa brecha, la
misma ventana de 12h se usa para inyectar los 3 escenarios de chaos ya
existentes, orquestados por `chaos/run-during-endurance.sh`, corrido en
paralelo a `run-endurance.sh` (§2.2).

**Cadencia — 3 inyecciones espaciadas**, una por escenario, con margen para
que el sistema se recupere por completo entre una y la siguiente antes de
medir el efecto de la próxima (evita confundir el efecto de una inyección con
residuos de la anterior):

| t (offset) | Escenario | Qué mide |
|---|---|---|
| t+2h | `kill-rabbitmq.sh` | MTTR de reconexión AMQP + mensajes perdidos, con tráfico real de fondo (no solo el ping sintético del script) |
| t+6h | `pause-data-management.sh 30` | Blast radius: ¿el balanceador desvía tráfico sin errores visibles, con la cola ya a la tasa máxima sostenida? |
| t+10h | `netem-delay-ew-da.sh 2000 60` | Circuit breaker + continuidad operativa (umbral simple) bajo latencia alta, con el sistema ya "caliente" tras 10h de carga |

**Criterio — aparte del §2.4, no lo invalida.** El §2.4 (éxito de la carga
sostenida) se evalúa igual que si no hubiera chaos: una ventana de MTTR alto
durante una inyección puntual no tumba la validación de la tasa máxima. El
chaos bajo carga sostenida tiene su propio criterio:

| Señal | Umbral | Por qué es criterio aparte |
|---|---|---|
| MTTR (por inyección) | comparable al MTTR medido en `chaos/` sin carga de fondo (±20%) | un MTTR mucho mayor bajo carga sugiere que la recuperación compite por los mismos recursos saturados por el tráfico — señal de acoplamiento, no de que la tasa sea insostenible |
| Continuidad operativa (netem) | `ew_alerts_published_total` sigue creciendo durante el circuito abierto | confirma CLAUDE.md §2.3 (umbral simple) bajo la condición más exigente: carga máxima + latencia alta simultáneas |
| Mensajes perdidos (kill-rabbitmq) | 0, o recuperados vía backlog Redis/DLQ tras reconexión | valida Idempotent Consumer + Publisher Confirms (CLAUDE.md §2.1/2.2) bajo presión, no solo en aislamiento |

Si alguna de estas señales se dispara, se documenta como hallazgo de
tolerancia a fallos bajo carga (relevante para la comparación A vs. B), pero
**no** se repite la Fase 2 solo por esto — a diferencia de una violación del
§2.4, que sí obliga a repetir con un techo más bajo.

---

## 3. Secuencia end-to-end

```
Fase 1 (descubrimiento, ~52 min: 5 × 10min + 4 × 30s pausa)
  vu-001 (10min) → vu-010 (10min) → vu-050 (10min) → vu-100 (10min) → vu-400 (10min)
  ↓
  ¿algún nivel dispara criterio de falla (§1.3)?
    sí → SUSTAINED_RATE = último nivel sin falla
    no → SUSTAINED_RATE = 400 (techo probado; considerar extender escalón, §6)
  ↓
Fase 2 (validación, 12h 3min)
  run-endurance.sh SUSTAINED_RATE=<valor>   [+ en paralelo] chaos/run-during-endurance.sh
                                                              t+2h kill-rabbitmq
                                                              t+6h pause-data-management
                                                              t+10h netem-delay-ew-da
  ↓
  ¿se cumplen los criterios de éxito (§2.4, carga sostenida sin chaos)?
    sí → tasa máxima de entrada confirmada, usable en la comparación A vs B
    no → repetir Fase 1 con techo más bajo / escalón intermedio, luego repetir Fase 2
  ↓
  ¿se cumplen los criterios de chaos bajo carga (§2.5)?
    sí → tolerancia a fallos bajo carga máxima confirmada
    no → documentar hallazgo (no invalida la tasa; sí alimenta la comparación A vs B)
```

---

## 4. Registro en Grafana

El dashboard `Sistem Metrics Dashboard` (`local/infra/grafana/provisioning/dashboards/dashboard.json`,
auto-provisioned) ya expone los paneles A vs B necesarios (CPU, memoria,
throughput, latencia p50-p99, backlog Redis, cola RabbitMQ, gRPC, TCP). Lo que
falta para usarlo como registro de las 2 fases es poder **ubicar en el tiempo**
cada corrida — el dashboard por defecto muestra `now-3h`, y una corrida de 12h
o un escalón de 10 min corrido la semana pasada no se distinguen del resto del
historial sin un punto de referencia.

### 4.1 Anotaciones automáticas por corrida/inyección

`load-tests/lib/grafana-annotate.sh` (helper compartido, mismo patrón que
`chaos/lib/capture.sh`) marca vía la API de anotaciones de Grafana
(`POST /api/annotations`) el inicio y fin de cada ventana relevante. Ya está
integrado en los scripts existentes — no requiere pasos manuales durante la
corrida:

| Script | Anotación | Tags |
|---|---|---|
| `run-all.sh` | una región por cada nivel VU de la Fase 1 | `fase-1`, `sistema-<A\|B>`, `vu-<nivel>` |
| `run-endurance.sh` | una región cubriendo toda la Fase 2 (12h) | `fase-2`, `sistema-<A\|B>`, `sustained-rate-<valor>` |
| `kill-rabbitmq.sh` | una región por la ventana de fallo+recuperación | `chaos`, `kill-rabbitmq` |
| `pause-data-management.sh` | ídem | `chaos`, `pause-data-management` |
| `netem-delay-ew-da.sh` | ídem | `chaos`, `netem-delay-ew-da` |

Con esto, el dashboard muestra líneas/regiones verticales superpuestas a los
paneles existentes marcando exactamente cuándo empezó y terminó cada nivel de
la Fase 1, la ventana completa de la Fase 2, y cada una de las 3 inyecciones
de chaos (§2.3) — visualmente correlacionable con los picos/caídas de
throughput, latencia, backlog, etc. sin adivinar por reloj.

**Configuración requerida** (variables de entorno). Dos formas, elegir una:

- **`load-tests/.env`** (recomendado para uso repetido): copiar
  `load-tests/.env.example` → `load-tests/.env` y completar `GRAFANA_API_TOKEN`.
  `grafana-annotate.sh` lo carga automáticamente si existe — no hace falta
  `export` manual en cada sesión de shell. **Nunca se commitea** (cubierto por
  `.gitignore`, mismo trato que `envs/*.env`).
- **`export` manual** (para una sola corrida puntual), mismo patrón que
  `TARGET_HOST`/`SUSTAINED_RATE`:

  ```bash
  export GRAFANA_URL="http://grafana:3000"            # default si se omite; misma red landslide-net
  export GRAFANA_API_TOKEN="<service-account-token>"  # obligatorio para que se registren anotaciones
  ```

El token se genera una vez en Grafana: **Administration → Users and access →
Service accounts → Add service account** (rol `Editor` alcanza) **→ Add
service account token**. Guardarlo en un gestor de contraseñas, no solo en el
`.env` local. Si `GRAFANA_API_TOKEN` no está seteado (ni por `.env` ni por
`export`), los scripts no fallan — imprimen un aviso y continúan sin anotar
(la anotación es soporte de análisis, no precondición del experimento).

### 4.2 Filtrar el dashboard por fase/corrida

Con las anotaciones cargadas, en Grafana:

1. Ajustar el rango de tiempo del dashboard a la ventana de la corrida de
   interés (ej. las 12h de una corrida de Fase 2 específica).
2. Las anotaciones aparecen como marcadores verticales con su tag — filtrables
   desde **Dashboard settings → Annotations** o pasando `tags=fase-2` /
   `tags=sistema-B` en la query de anotaciones si se agrega una fuente de
   anotaciones adicional (por ahora se usa la anotación nativa `-- Grafana --`
   ya presente en `dashboard.json`, que muestra todas; filtrar por tag es un
   ajuste de UI, no requiere cambiar el JSON).

### 4.3 Persistir los números más allá del retention de Prometheus

Prometheus retiene 30 días (`--storage.tsdb.retention.time=30d`,
`docker-compose.observability.yml`). Para una tesis que puede tomar semanas
en redactarse tras la última corrida, eso no alcanza como archivo final:

- **Reporte HTML de Artillery** (`artillery report <archivo>.json`) — ya
  queda como artefacto local en `load-tests/results/<SYSTEM>/`, independiente
  de Prometheus. Es la fuente primaria de throughput/latencia/errores por
  corrida.
- **Snapshot de Grafana** (ícono compartir → Snapshot, o `POST
  /api/snapshots`) — congela el estado exacto de los paneles (incluidas las
  anotaciones) en una URL/JSON que sobrevive aunque Prometheus rote los datos
  crudos. Tomar uno al terminar cada corrida de Fase 2 (12h) y cada inyección
  de chaos relevante.
- **Export CSV por panel** (menú del panel → Inspect → Data → Download CSV) —
  para los paneles puntuales que alimenten tablas/gráficas del documento de
  tesis.

---

## 5. Ejecución — orden de comandos

Comandos reales, en el orden exacto en que se corren, para una pasada completa
sobre un sistema (`SYSTEM=A` o `SYSTEM=B`). Requiere Artillery instalado
(`npm install -g artillery`), Docker corriendo (Pumba, para los scripts de
`chaos/`), Prometheus accesible (`PROMETHEUS_ADDR`, default
`http://localhost:9090`) y, para que las corridas queden anotadas en Grafana
(§4), `GRAFANA_API_TOKEN` seteado.

```bash
cd tesis-infra

# 0. Habilitar anotaciones en Grafana (§4.1) — opcional pero recomendado;
#    sin esto los scripts corren igual, solo sin marcar el dashboard.
#    Una vez: cp load-tests/.env.example load-tests/.env && editar el token.
#    Se carga solo; no hace falta export en cada sesión.

# 1. Fase de descubrimiento (§1) — ~52 min, bloqueante, corre los 5 escalones
#    en secuencia y termina sola. Revisar cada reporte contra los criterios
#    de falla (§1.3) antes de continuar.
TARGET_HOST=http://<host> SYSTEM=B ./load-tests/run-all.sh

# 2. Determinar SUSTAINED_RATE (§1.4) inspeccionando los reportes de (1):
for VU in 001 010 050 100 400; do
  artillery report "load-tests/results/B/vu-${VU}.json"
done
# → el último nivel sin violar §1.3 es SUSTAINED_RATE (ej. 100)

# 3. Fase de validación de resiliencia (§2) — 12h 3min, bloqueante.
#    run-endurance.sh y el orquestador de chaos deben lanzarse JUNTOS: el
#    chaos depende de coincidir con la ventana de carga sostenida, no de
#    correr después.
TARGET_HOST=http://<host> SUSTAINED_RATE=100 SYSTEM=B \
  ./load-tests/run-endurance.sh &
./chaos/run-during-endurance.sh &
wait

# 4. Revisar resultado de (3) contra los criterios de éxito (§2.4):
artillery report "load-tests/results/B/sustained-12h.json"
# + snapshots de chaos en chaos/results/{kill-rabbitmq,pause-data-management,netem-delay-ew-da}-*
# + paneles Grafana / Prometheus para memoria, backlog Redis, cola RabbitMQ (§2.3)

# 5. Si (4) viola §2.4 → repetir desde (1) con un techo más bajo o un
#    escalón intermedio (ej. agregar vu-075.yml entre 050 y 100), luego
#    repetir (3)-(4). Una violación solo en las ventanas de chaos (§2.5) NO
#    dispara este ciclo — se documenta como hallazgo aparte.
```

Para el escenario burst (comparación steady-state vs. spike, fuera de las 2
fases pero útil como contexto adicional) y los experimentos de valor agregado,
ver `experimentos-valor-agregado.md` — no forman parte del orden obligatorio
de este plan.

---

## 6. Extensiones futuras (fuera de alcance actual)

- Escalón por encima de 400 req/s si esa corrida no dispara ningún criterio de
  falla en la Fase 1 (agregar `vu-800.yml`, etc.).
- Repetir Fase 2 en ambos sistemas (A y B) para comparar degradación relativa,
  no solo el valor absoluto de `SUSTAINED_RATE`.
- Correlacionar la Fase 2 con los experimentos de valor agregado
  (`experimentos-valor-agregado.md`) — en particular backpressure (§2) y
  latencia sensor→alerta (§1), observadas durante la ventana de 12h en vez de
  en corridas cortas aisladas.
