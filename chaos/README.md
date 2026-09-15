# Chaos / fault-injection — tolerancia a fallos cuantificada

Bai et al. (2020) afirma tolerancia a fallos sin medirla; El Fellah et al. (2026)
tampoco la prueba empíricamente. Esta carpeta inyecta fallos controlados sobre
la infra Docker Compose (`local/infra`, `local/services/*`) y captura:

- **MTTR** (mean time to recovery): timestamp del fallo inyectado → timestamp en
  que el circuit breaker vuelve a `closed` (`ew_circuit_breaker_state == 0`) o el
  servicio vuelve a responder su `/health`.
- **Mensajes perdidos**: delta entre `data_receiving_messages_published_total`
  (productor) y `ew_messages_consumed_total` (consumidor) antes/durante/después
  de la ventana de fallo.
- **Blast radius**: qué otros servicios degradan durante el fallo, visible en
  `ew_circuit_breaker_state{target}` por target y en el panel Grafana "estado
  de breakers" (pendiente de agregar cuando el experimento corra la primera vez
  y se sepa qué targets aparecen).

## Herramienta: SSH + herramientas del nodo

**Ya no se usa Pumba.** Los sistemas bajo prueba no corren en la máquina que
dispara el chaos: el Sistema B es k3s/containerd en un servidor remoto y el
Sistema A son procesos systemd nativos. Ninguno expone su runtime de
contenedores a esta máquina, así que `docker run gaiaadm/pumba` sobre el socket
Docker local no alcanzaba nada.

Los escenarios inyectan por SSH con las herramientas del propio nodo
(`lib/ssh.sh`): `kubectl`/`crictl` para matar o pausar pods, y `tc netem` dentro
del netns del pod (vía `nsenter`) para la latencia. En el Sistema A, `systemctl`
y `tc` directo sobre el host.

## Escenarios

| Script | Acción | Objetivo |
|---|---|---|
| `kill-rabbitmq.sh` | `pumba kill` sobre `rabbitmq-1` | Mide MTTR de reconexión de productores/consumidores AMQP y mensajes perdidos en el tramo sin broker |
| `pause-data-management.sh` | `pumba pause` sobre `data-management-1` | Mide blast radius: ¿el balanceador (nginx round-robin) desvía tráfico a `data-management-2` sin errores visibles al cliente? |
| `netem-delay-ew-da.sh` | `pumba netem delay` entre `early-warning-*` y `data-analysis-1` | Prueba el circuit breaker bajo latencia alta (no solo bajo down total) — CLAUDE.md §2.3: con el circuito abierto, Early Warning debe seguir alertando por umbral simple |
| `publish-event.sh` | Publica **un** evento representativo (par de lecturas GNSS que cruza umbral) | Utilitario para AP5/AP6/AP7, no es un escenario de fallo. Ver [`../docs/ap5-ap6-ap7-procedimientos.md`](../docs/ap5-ap6-ap7-procedimientos.md) |
| `netem-delay-ew-um.sh` | `tc netem delay` en los pods de `user-management` (vía SSH + nsenter) | Abre el breaker sobre la **ruta de alertas**, la única dependencia síncrona que puede ejercitarlo. Muestreo continuo + contadores de llamadas salientes. Ver sección dedicada abajo |

## Uso

Requiere la infra levantada (`make -C local/infra up` + los `docker-compose.yml`
de cada servicio) y Docker Desktop corriendo (para montar `/var/run/docker.sock`).

```bash
# Captura métricas 60s antes, durante el fallo, y 120s después de la recuperación
./chaos/kill-rabbitmq.sh
./chaos/pause-data-management.sh
./chaos/netem-delay-ew-da.sh 2000  # 2000ms de delay agregado
```

Cada script imprime un resumen (MTTR, mensajes publicados vs consumidos,
estado de breakers por target) y guarda snapshots en `chaos/results/`:

- `kill-rabbitmq.sh` y `pause-data-management.sh` escriben snapshots de
  contadores como texto plano `<escenario>-{pre,post}-<timestamp epoch>.snapshot`
  (no JSON — `key=value` por línea, ver `lib/capture.sh`'s `snapshot_counters`).
- `netem-delay-ew-da.sh` además guarda el estado crudo de Prometheus
  (respuesta completa de la query `ew_circuit_breaker_state`) como
  `netem-delay-ew-da-pre-breakers.json` — es el único de los tres que
  produce JSON.

## Nota sobre Sistema A (baseline)

Estos escenarios aplican igual al stack baseline (Sistema A, si corre en la
misma red `landslide-net` con nginx round-robin) — el propósito es comparar
MTTR/pérdida/blast-radius entre ambos sistemas bajo el mismo fallo inyectado,
no solo caracterizar el Sistema B en aislamiento.

---

## Escenario del circuit breaker sobre la ruta de alertas

`netem-delay-ew-um.sh` inyecta latencia contra **user-management**, no contra
data-analysis. La diferencia no es cosmética:

| | `netem-delay-ew-da.sh` | `netem-delay-ew-um.sh` |
|---|---|---|
| Ruta degradada | Reportes (`POST /reports/generate` → `api.enrich`) | **Alertas** (`consumer.dispatch` → `subs.TokensFor`) |
| Driver | Requests HTTP de reporte | Publica lecturas GNSS en `sensors.raw` vía AMQP |
| Qué demuestra | El breaker abre en una ruta secundaria | El sistema **sigue alertando** con una dependencia caída (CLAUDE.md §2.3) |

user-management es la **única** dependencia síncrona de la ruta de alertas, así
que es el único breaker cuya apertura se lee como continuidad operativa. Un
reporte lento no compromete la función de alerta temprana; una resolución de
suscriptores caída sí.

### Las dos condiciones que deben cumplirse a la vez

El breaker cuenta **fallos, no latencia**. Una llamada lenta que responde dentro
del timeout es un éxito y *resetea* el contador (`grpcx.onResult`). De ahí salen
dos condiciones, y el script valida ambas antes de inyectar:

1. **El delay debe agotar el timeout con margen.** Con
   `USER_MANAGEMENT_TIMEOUT_MS=5000`, un delay de 5100ms es frágil: basta una
   variación de red para que una llamada entre por debajo y reinicie la cuenta.
   El default es 9000ms y el script aborta si `DELAY_MS <= timeout`.

2. **Debe haber alertas durante la ventana.** user-management solo se invoca al
   emitir una alerta. Si no cruza ningún umbral, no hay llamadas, no hay fallos,
   y el breaker sigue cerrado aunque el delay esté perfectamente puesto. Por eso
   el script **no depende del generador de carga**: publica él mismo pares de
   lecturas GNSS que cruzan umbral rojo de forma determinista, y **verifica la
   tasa de alertas antes de inyectar** — si no llega al umbral de fallos, aborta
   en vez de producir un "no abrió" que no significa nada.

La inyección igual debe hacerse con el sistema **en régimen**, no al arranque:
en los primeros minutos ningún sensor tiene línea base y no se emiten alertas.

### Cómo se fuerzan las alertas

EW calcula `speed_mm_dia = (cum₂ − cum₁) / dt_segundos × 86400`. El driver
publica dos lecturas por sensor: la primera fija la línea base, la segunda llega
60s después con +100mm → 144000 mm/día, muy por encima del umbral rojo de
`shangtan` (20). Cada par produce una alerta, y cada alerta un `Invoke` a
user-management. Se usan sensores distintos por ronda para que las líneas base
no se pisen.

Los mensajes van a `sensors.raw` con routing key `sensors.gnss`, igual que los
publicaría data-receiving: publicar directo a la cola saltearía el binding y no
probaría el mismo camino.

### Muestreo continuo, no instantáneas

El tiempo hasta la apertura y el de recuperación son **instantes**, no
diferencias de contadores: sin marcas intermedias no existen — por eso el MTTR
del broker quedó sin reportar. `lib/sampler.sh` escribe una serie temporal CSV
cada `SAMPLE_INTERVAL` segundos durante todo el escenario, en paralelo a los
snapshots (que se conservan para comparar con las corridas viejas).

El CSV queda en `chaos/results/<escenario>-samples-<epoch>.csv` con una fila por
muestra: `epoch, iso_utc`, estado del breaker, las cuatro categorías de llamadas
salientes, alertas publicadas, consumidos, descartados, duplicados y backlog de
la cola. Se versiona igual que los `.snapshot` — es evidencia.

`sampler_first_at` lee el instante de apertura del CSV, no del loop de poll: si
el breaker abre y cierra entre dos consultas, el poll se lo pierde pero la serie
no.

### Qué se reporta si el breaker NO abre

Se reporta igual, **con el porqué**. `ew_outbound_calls_total{target="user-management"}`
separa `ok` / `timeout` / `circuit_open` / `error`, así que un breaker cerrado se
lee sin ambigüedad, y el script imprime el diagnóstico:

| Contadores | Diagnóstico |
|---|---|
| Sin serie | No hubo alertas: la ruta nunca llamó (el driver falló) |
| `ok` alto, `timeout` = 0 | Hubo llamadas, el delay no se aplicó al tráfico gRPC |
| `timeout` > 0 pero < umbral | Alguna llamada exitosa reseteó el contador entre medio |
| `timeout` ≥ umbral, gauge = 0 | Hallazgo real sobre el mecanismo |

"El interruptor no abrió" acompañado de "hubo 12 invocaciones, todas con timeout
agotado" es un hallazgo. Sin ese dato no se concluye nada.

### Requisito de versión

Este escenario necesita el EW con el fix de instrumentación
(`go-early-warning`, rama `fix/breaker-metric-user-management`): antes de él, el
gauge `ew_circuit_breaker_state` solo se alimentaba para `data-analysis` y la
serie de user-management **no existía**. El script avisa si no la encuentra.

### Uso

```bash
SSH_HOST=178.105.104.95 SSH_USER=gotesis SSH_KEY_PATH=~/.ssh/gotesis-key \
  SUDO_PASSWORD=*** SSH_ORCHESTRATOR=k8s \
  PROMETHEUS_ADDR=http://178.105.104.95:31083 \
  ./chaos/netem-delay-ew-um.sh 9000 240
```

**Repetir al menos 3 veces.** Todas las inyecciones actuales tienen una sola
observación y no admiten ninguna afirmación sobre variabilidad. Los CSV llevan
timestamp, así que las corridas no se pisan.
