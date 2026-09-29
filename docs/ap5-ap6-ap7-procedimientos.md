# AP5, AP6 y AP7 — procedimientos de ejecución

Los tres son pruebas de verificación puntual, no campañas de carga: se ejecutan
en minutos y no requieren cambios en el sistema. Este documento fija los pasos,
qué se registra y qué constituye evidencia suficiente ante un revisor.

Lo verifiqué contra el código desplegado antes de escribirlo; donde una
afirmación del plan original no se sostiene, está marcado explícitamente.

| | Qué verifica | Cambios necesarios | Duración |
|---|---|---|---|
| **AP5** | La comunicación reduce volumen y llamadas por evento | Ninguno en el sistema; **sí en la medición** (ver §AP5.1) | ~30 min |
| **AP6** | Idempotencia: reinyectar un `message_id` no altera el estado | Ninguno — la traza ya existe | ~10 min |
| **AP7** | Mensajes irreprocesables: reintentos acotados → DLQ | Ninguno — pero el mensaje debe diseñarse con cuidado (§AP7.1) | ~15 min |

Requisito común: `SSH_HOST`, `SSH_USER`, `SSH_KEY_PATH`/`SSH_PASSWORD`,
`SUDO_PASSWORD` y `PROMETHEUS_ADDR` como en los escenarios de chaos
(ver [`../chaos/README.md`](../chaos/README.md)).

## Ejecución automatizada

Los tres procedimientos están automatizados. Cada script ejecuta los pasos de su
sección, evalúa los criterios de aceptación y deja la evidencia en
`chaos/results/` (log completo, líneas del evento por servicio y un
`*-summary.env` por corrida para agregar repeticiones):

| Prueba | Script | Sistemas | Veredicto |
|---|---|---|---|
| AP5 | [`chaos/ap5-capture.sh`](../chaos/ap5-capture.sh) | A y B | Medición (sin PASS/FAIL): neto por servidor |
| AP6 | [`chaos/ap6-idempotency.sh`](../chaos/ap6-idempotency.sh) | B | PASS/FAIL por criterio, sale ≠ 0 si alguno falla |
| AP7 | [`chaos/ap7-dead-letter.sh`](../chaos/ap7-dead-letter.sh) | B | PASS/FAIL por criterio, sale ≠ 0 si alguno falla |

Despliegue requerido antes de correrlos:

- **AP6:** go-data-management con `feat/ap6-duplicate-trace`. Agrega la traza
  del duplicado (`insert ignorado, ack` + `dm_messages_ignored_total`).
- **O6** (`netem-delay-ew-um.sh`, no es parte de este documento pero comparte el
  evento): go-early-warning con `feat/o6-o7-alert-path-evidence`.

Las secciones de abajo describen qué hace cada prueba y por qué. Donde el
script se aparta del procedimiento manual original, está marcado con
**Corrección**.

> **Corrección común (evento representativo).** El evento original no traía
> `schema_version` ni `received_at`. early-warning lo aceptaba, pero el binding
> `sensors.#` también lo entrega a `data_management.persist`, que valida el
> contrato y manda los envelopes inválidos a la DLQ. Cada evento de prueba
> mandaba **2 mensajes a `sensors.dead_letter`**: AP7 (criterio "+1") habría
> leído +3, y AP6 no podía verificar la lectura persistida. El evento de
> [`chaos/lib/event.sh`](../chaos/lib/event.sh) lleva el envelope completo
> (`schema_version: "1.0"`, igual que data-receiving) y es válido para ambos
> consumidores. Además, un publish que el broker no enruta (`routed:false`)
> ahora es un error, no un evento perdido en silencio.

---

## AP5 — Volumen transferido y llamadas por evento

**Hipótesis:** la comunicación entre servicios del Sistema B transfiere menos
bytes y hace menos llamadas por evento que el Sistema A.

### AP5.1 — El problema de medición que hay que resolver primero

El plan original dice que se puede medir «desde las métricas de red que ya
recoge Prometheus». **Eso no es cierto con la configuración actual**, y conviene
saberlo antes de la campaña y no durante:

- `node-exporter` está desplegado, pero `node_network_receive_bytes_total` mide
  **el nodo entero**. Con una corrida de carga activa, el tráfico de un evento
  concreto es indistinguible del ruido de fondo.
- **No hay cAdvisor**: el Prometheus del Sistema B scrapea `node`, `mysql`,
  `rabbitmq`, `redis`, `kube-state-metrics` y `microservices`
  ([`configmap.yaml`](../k8s/base/infra/observability/configmap.yaml)), y
  ninguno expone `container_network_*`. No existe atribución de bytes por pod.

Quedan dos caminos. **El recomendado es el segundo**, porque no toca el sistema:

**Opción A — habilitar cAdvisor.** Agregar un job al Prometheus que scrapee
`/metrics/cadvisor` del kubelet. Da `container_network_{receive,transmit}_bytes_total`
por pod. Requiere RBAC para `nodes/metrics` y reiniciar Prometheus: es un cambio
en el sistema bajo prueba, justo antes de medirlo. **No recomendado.**

**Opción B — captura de tráfico durante un evento aislado (recomendada).**
Con el sistema **en reposo** (sin carga), se inyecta un único evento y se captura
el tráfico. Sin carga de fondo, todo lo capturado pertenece al evento.

### AP5.2 — Elegir y declarar el evento

El evento debe ser **el mismo en ambos sistemas** y hay que declarar cuál se
eligió. Recomendado: **una lectura GNSS que cruza umbral y genera una alerta.**

Razón: ejercita la cadena completa (ingesta → cola → persistencia → evaluación →
resolución de suscriptores), que es donde las dos arquitecturas difieren. Una
lectura que no alerta solo mide ingesta y persistencia, y ahí los sistemas son
casi iguales.

Se reutiliza el par de mensajes del driver de chaos
([`netem-delay-ew-um.sh`](../chaos/netem-delay-ew-um.sh), función `_alert_driver`):
una lectura base y una segunda con +100 mm a los 60 s.

### AP5.3 — Procedimiento

1. **Poner el sistema en reposo.** Detener el generador de carga y esperar a que
   la cola se vacíe:

   ```bash
   # debe dar 0
   curl -s "$PROMETHEUS_ADDR/api/v1/query?query=sum(rabbitmq_queue_messages_ready)" | grep -o '"value".*'
   ```

2. **Arrancar la captura en el nodo**, filtrando los puertos de interés (AMQP
   5672, gRPC 50051/9090, MySQL 3306, HTTP 8080):

   ```bash
   ssh $SSH_USER@$SSH_HOST "sudo timeout 120 tcpdump -i any -w /tmp/ap5-B.pcap \
     'port 5672 or port 50051 or port 9090 or port 3306 or port 8080'"
   ```

3. **Inyectar el evento único** (un solo par de lecturas, no el loop):

   ```bash
   ./chaos/publish-event.sh
   ```

   Publica el par de lecturas y **imprime el `message_id` usado**, que es lo que
   hay que registrar en la evidencia. No usa loop: es un evento y solo uno.

4. **Esperar a que el evento termine** (la alerta se persiste y se emite), luego
   cortar la captura.

5. **Contar bytes y llamadas:**

   ```bash
   # Bytes totales por par de hosts y puerto
   ssh $SSH_USER@$SSH_HOST "sudo tcpdump -r /tmp/ap5-B.pcap -nn -q | \
     awk '{print \$3, \$5}' | sort | uniq -c | sort -rn"

   # Volumen total
   ssh $SSH_USER@$SSH_HOST "sudo capinfos -c -d /tmp/ap5-B.pcap"
   ```

6. **Repetir idéntico contra el Sistema A** (`SSH_ORCHESTRATOR=native`,
   `204.168.203.32`), con el mismo evento. `publish-event.sh` y
   `ap5-capture.sh` publican en A por la Management API del host
   (`RABBITMQ_MGMT_USER` / `RABBITMQ_MGMT_PASS`): A usa la misma cola, el mismo
   exchange, el mismo formato y los mismos umbrales de `shangtan`.

> **Corrección (interfaz de captura).** `tcpdump -i any` en el nodo k3s cuenta
> cada paquete entre pods 2 o 3 veces (veth de origen, bridge `cni0`, veth de
> destino); en A, el tráfico entre procesos del mismo host pasa una sola vez por
> `lo`. Comparar así infla B ×2–×3 por un artefacto de captura. El script
> captura en `cni0` en B (en modo promiscuo ve cada trama reenviada una vez) y
> en `lo` en A.
>
> **Corrección (fondo).** "En reposo" no es "sin tráfico": los exporters
> consultan MySQL y Redis en cada scrape, AMQP manda heartbeats, kubelet sondea
> los pods. El script hace una captura de reposo de la misma duración y reporta
> el **neto** (evento − reposo) por servidor. Como el fondo no es constante,
> reportar mediana y rango de ≥ 3 corridas.

### AP5.4 — Qué se reporta

| Métrica | Sistema A | Sistema B |
|---|---|---|
| Bytes transferidos por evento | | |
| Llamadas salientes por evento | | |
| Saltos de red en la cadena | | |

Declarar siempre: **qué evento se eligió**, que el sistema estaba en reposo, y
la duración de la captura. Sin esas tres cosas los números no son comparables.

> **Advertencia de interpretación.** Los dos sistemas no tienen el mismo número
> de servicios ni la misma topología de red. Una diferencia de bytes puede venir
> de la arquitectura (gRPC binario vs REST/JSON) o simplemente de que uno da más
> saltos. Reportar el desglose por salto, no solo el total: un total menor con
> más saltos dice algo distinto que un total menor con los mismos saltos.

---

## AP6 — Idempotencia del procesamiento

**Hipótesis:** reinyectar un mensaje ya procesado, con el mismo `message_id`, no
altera el estado: no duplica la lectura persistida ni reemite la alerta.

### AP6.1 — La traza ya existe (verificado)

El plan original dice que «lo único que puede requerir cambio es el registro».
**No hace falta ningún cambio.** Está implementado en los dos sentidos:

- **Log:** `duplicate_skipped` en
  [`consumer.go:243`](../../go/go-early-warning/internal/earlywarning/consumer/consumer.go#L243),
  con `trace_id` = `message_id` porque el contexto se enriquece en
  [`consumer.go:232`](../../go/go-early-warning/internal/earlywarning/consumer/consumer.go#L232).
  Se puede seguir el duplicado concreto, no solo saber que hubo uno.
- **Métrica:** `ew_duplicates_skipped_total`.

Hay evidencia **positiva** por dos vías independientes, no solo ausencia de
efecto. Es exactamente lo que el plan pedía asegurar.

### AP6.2 — Detalle que condiciona la prueba

La marca de idempotencia se escribe **después** del procesamiento exitoso
(`MarkDone`, [`consumer.go:257`](../../go/go-early-warning/internal/earlywarning/consumer/consumer.go#L257)),
a propósito: un mensaje que falló y se reencoló no debe saltarse en la
redelivery. Consecuencia práctica: **hay que esperar a que el primer mensaje
termine de procesarse antes de reinyectar.** Si se reinyecta de inmediato, el
segundo puede llegar antes de `MarkDone` y procesarse como legítimo — eso no es
un fallo de idempotencia, es la prueba mal ejecutada.

Esperar ~5 s entre inyecciones es suficiente.

### AP6.3 — Procedimiento

1. **Registrar el estado inicial:**

   ```bash
   MID="ap6-$(date +%s)"   # message_id fijo, reutilizado en ambas inyecciones

   # Contadores antes
   curl -s "$PROMETHEUS_ADDR/api/v1/query?query=sum(ew_duplicates_skipped_total)"
   curl -s "$PROMETHEUS_ADDR/api/v1/query?query=sum(ew_alerts_published_total)"

   # Filas en la BD de alertas (ajustar credenciales)
   ssh $SSH_USER@$SSH_HOST "sudo kubectl -n landslide exec mysql-early-warning-0 -- \
     mysql -u root -p\"\$MYSQL_ROOT_PASSWORD\" -N -e \
     'SELECT COUNT(*) FROM early_warning.alerts'"
   ```

2. **Inyectar el evento por primera vez**, con un `message_id` controlado:

   ```bash
   ./chaos/publish-event.sh "$MID"
   ```

   Publica en `sensors.raw` con routing key `sensors.gnss`, igual que lo haría
   data-receiving. El par genera alerta, así que la prueba cubre también «no se
   reemite la alerta». El id que se reinyecta es `${MID}-b`.

3. **Esperar ~5 s** (ver §AP6.2) y verificar que se procesó: `ew_messages_consumed_total`
   subió y aparece `alert_emitted` en el log.

4. **Reinyectar el mismo mensaje**, con el mismo `message_id`:

   ```bash
   SKIP_BASELINE=1 ./chaos/publish-event.sh "$MID"
   ```

   `SKIP_BASELINE=1` omite la primera lectura: republicarla reescribiría la
   línea base del sensor y la segunda podría evaluarse distinto. Lo que se
   reinyecta es exactamente el mensaje que ya se procesó.

5. **Verificar los tres invariantes:**

   ```bash
   # a) El log registra la detección explícita
   ssh $SSH_USER@$SSH_HOST "sudo kubectl -n landslide logs -l app=early-warning --tail=200 \
     | grep duplicate_skipped | grep $MID"

   # b) El contador de duplicados subió exactamente 1
   curl -s "$PROMETHEUS_ADDR/api/v1/query?query=sum(ew_duplicates_skipped_total)"

   # c) Ni las alertas ni las filas cambiaron
   curl -s "$PROMETHEUS_ADDR/api/v1/query?query=sum(ew_alerts_published_total)"
   ssh $SSH_USER@$SSH_HOST "sudo kubectl -n landslide exec mysql-early-warning-0 -- \
     mysql -u root -p\"\$MYSQL_ROOT_PASSWORD\" -N -e \
     'SELECT COUNT(*) FROM early_warning.alerts'"
   ```

### AP6.4 — Criterio de aceptación

| Invariante | Esperado |
|---|---|
| `duplicate_skipped` en el log, con el `message_id` | Aparece exactamente 1 vez |
| `ew_duplicates_skipped_total` | +1 |
| `ew_alerts_published_total` | **sin cambio** |
| Filas en `early_warning.alerts` | **sin cambio** |

Los cuatro deben cumplirse. El primero es la evidencia fuerte: convierte «no
pasó nada» en «el sistema detectó el duplicado y lo descartó deliberadamente».

> **Nota sobre data-management (resuelta).** La misma prueba aplica a la cola
> `data_management.persist`: no se debe duplicar la *lectura* persistida. El
> servicio usaba `INSERT IGNORE` keyed por `message_id` pero **no emitía
> ninguna traza**: un duplicado era indistinguible de un insert exitoso, y solo
> se podía verificar por ausencia de efecto. Con `feat/ap6-duplicate-trace`, el
> repositorio distingue "0 filas afectadas" (`persistence.ErrIgnored`) y el
> consumidor hace ack con `insert ignorado, ack` (con `trace_id`) y
> `dm_messages_ignored_total`. `ap6-idempotency.sh` verifica ambos servicios.
> Se llama "ignorado" y no "duplicado" porque `IGNORE` también descarta, por
> ejemplo, una fila sin partición anual que la reciba; el log no afirma una
> causa que el driver no informa.
>
> **Corrección (reinyección).** `SKIP_BASELINE=1 publish-event.sh` regenera la
> lectura con timestamp nuevo: reinyecta el mismo `message_id`, no el mismo
> mensaje. `ap6-idempotency.sh` guarda el envelope de la primera inyección
> (`ap6-<epoch>-envelope.json`) y lo reinyecta byte a byte.
>
> **Corrección (conteo de filas).** `early_warning.alerts.message_id` es el UUID
> de la *alerta*, no el `message_id` de la lectura. Contar
> `COUNT(*) FROM alerts` sin filtro además mezcla alertas ajenas si hay carga.
> El script cuenta por `sensor_id`, que es único por evento.

---

## AP7 — Mensajes irreprocesables (retry acotado → DLQ)

**Hipótesis:** un mensaje que falla de forma consistente se reintenta un número
acotado de veces y luego se deriva a `sensors.dead_letter`, en vez de
reintentarse indefinidamente.

### AP7.1 — El diseño del mensaje es lo difícil, no la ejecución

El plan dice «se publica un mensaje deliberadamente malformado». **Un mensaje
malformado NO ejercita esta prueba**, y este es el punto en que la prueba se
ejecuta mal con más facilidad. Verificado en el código:

1. **JSON inválido → se descarta sin reintentos.**
   [`consumer.go:212`](../../go/go-early-warning/internal/earlywarning/consumer/consumer.go#L212)
   lo trata como no reintentable: loguea `json_decode_error`, incrementa
   `ew_messages_dropped_total` y hace **ack directo**. No hay reintentos ni DLQ.
   Es correcto (reintentar basura sintáctica no la arregla), pero significa que
   un payload corrupto **no prueba AP7**.

2. **JSON válido que no genera alerta → se procesa bien y se ackea.**
   `process()` solo puede devolver error desde `dispatch()`, y `dispatch()` solo
   se ejecuta **si hubo alerta**
   ([`consumer.go:306-310`](../../go/go-early-warning/internal/earlywarning/consumer/consumer.go#L306-L310)).
   Un mensaje con `project_id` inexistente sale por `unknown_project` como skip
   normal, sin error.

3. **El único fallo reintentable es la persistencia de la alerta.**
   `recordAlert` fallando es lo que devuelve error
   ([`consumer.go:379-381`](../../go/go-early-warning/internal/earlywarning/consumer/consumer.go#L379-L381)).

**Conclusión: para ejercitar AP7 hay que hacer fallar la escritura en MySQL
mientras se procesa un mensaje que SÍ genera alerta.** No hay atajo por el
contenido del mensaje.

### AP7.2 — Cómo provocar el fallo consistente

La forma más limpia, y que además no deja el sistema en un estado raro, es
**cortar la conexión a la BD de early-warning durante la ventana de la prueba**:

```bash
# Escalar a 0 el MySQL de early-warning (solo ese; los demás siguen)
ssh $SSH_USER@$SSH_HOST "sudo kubectl -n landslide scale statefulset mysql-early-warning --replicas=0"
```

Con la BD caída, todo mensaje que genere alerta falla en `recordAlert` de forma
consistente y entra al camino de retry.

> **Alternativa menos invasiva:** revocar el `INSERT` del usuario runtime
> (`svc_early_warning`) sobre `early_warning.alerts`, correr la prueba y
> restituirlo. Evita tumbar la BD, pero deja un cambio de permisos que hay que
> acordarse de revertir. Elegir una y declararla.

> **Corrección (mecanismo de fallo).** Ninguna de las dos opciones de arriba
> sirve como está:
>
> - **Escalar MySQL a 0:** la liveness de early-warning es `GET /health`, que
>   responde 503 sin MySQL. A los ~45 s kubelet reinicia EW: la prueba mide
>   reinicios en vez de reintentos, y los logs del contenedor reiniciado se
>   pierden.
> - **Revocar INSERT:** el grant es a nivel de esquema (`early_warning.*`). No
>   se puede revocar sobre una tabla, y MySQL no aplica cambios de privilegios de
>   esquema a las conexiones ya abiertas del pool.
>
> `ap7-dead-letter.sh` crea un trigger `BEFORE INSERT` sobre
> `early_warning.alerts` que hace `SIGNAL` **solo para el `sensor_id` del
> evento**:
>
> - falla exactamente esa alerta y el resto del tráfico sigue;
> - `/health` sigue sano;
> - el error del log dice `AP7: fallo de persistencia inyectado`;
> - el trap lo elimina al terminar.
>
> Antes de usarlo, el script **autoverifica** que un `INSERT IGNORE` (el que
> hace `RecordAlert`) falle con ese `SIGNAL`, en una transacción que no se
> confirma.
>
> **Corrección (conteo en la DLQ).** Después de la endurance,
> `sensors.dead_letter` puede tener más de un millón de mensajes, y "+1" solo es
> concluyente sin carga. El script enlaza además una cola sonda temporal a
> `sensors.dlx`. Ahí identifica el mensaje por `message_id` y lee su `x-death`
> (cola de origen `early_warning.evaluate`, motivo `rejected`). La cola sonda
> expira sola a los 30 min.

### AP7.3 — Detalle que condiciona el conteo

El contador de reintentos **no viaja en el mensaje**: vive en Redis, keyed por
`message_id`, con TTL corto que lo autolimpia
([`bumpRetry`, consumer.go:395](../../go/go-early-warning/internal/earlywarning/consumer/consumer.go#L395)).
Dos consecuencias:

- **Usar un `message_id` nuevo en cada repetición** de la prueba. Reutilizar uno
  de una corrida anterior arrastra el contador y el mensaje va a la DLQ antes de
  los 3 intentos.
- Si Redis falla, `bumpRetry` devuelve `1` y el mensaje **se reencola para
  siempre**. Si la prueba observa reintentos infinitos, verificar Redis antes de
  reportarlo como fallo del acotamiento.

### AP7.4 — Procedimiento

1. **Registrar el estado inicial** de `sensors.dead_letter`:

   ```bash
   ssh $SSH_USER@$SSH_HOST "sudo kubectl -n landslide exec \$(sudo kubectl -n landslide get pod -l app=rabbitmq -o jsonpath='{.items[0].metadata.name}') -- \
     rabbitmqctl list_queues name messages | grep dead_letter"
   ```

2. **Provocar el fallo** (§AP7.2) y esperar a que el pod de MySQL desaparezca.

3. **Arrancar la captura de logs en vivo**, que es de donde sale el conteo de
   intentos con marca temporal:

   ```bash
   ssh $SSH_USER@$SSH_HOST "sudo kubectl -n landslide logs -f -l app=early-warning" \
     | tee ap7-$(date +%s).log
   ```

4. **Inyectar un evento con `message_id` nuevo** (ver §AP7.3 sobre por qué debe
   ser nuevo):

   ```bash
   ./chaos/publish-event.sh "ap7-$(date +%s)"
   ```

5. **Observar la secuencia** en el log capturado:

   ```
   requeue        attempt=1   err=...
   requeue        attempt=2   err=...
   requeue        attempt=3   err=...
   dead_lettered  attempts=4  err=...
   ```

   Cada línea es JSON estructurado con `timestamp` y `trace_id` = `message_id`,
   así que el conteo y los intervalos quedan registrados sin instrumentación
   adicional.

6. **Confirmar la llegada a la DLQ:**

   ```bash
   ssh $SSH_USER@$SSH_HOST "sudo kubectl -n landslide exec \$(sudo kubectl -n landslide get pod -l app=rabbitmq -o jsonpath='{.items[0].metadata.name}') -- \
     rabbitmqctl list_queues name messages | grep dead_letter"
   ```

7. **Restaurar** el sistema:

   ```bash
   ssh $SSH_USER@$SSH_HOST "sudo kubectl -n landslide scale statefulset mysql-early-warning --replicas=1"
   ```

   Verificar que el pod vuelve a `Ready` y que `/health` de early-warning
   responde 200 antes de dar la prueba por terminada.

### AP7.5 — Criterio de aceptación

| Observable | Esperado |
|---|---|
| Líneas `requeue` con `attempt` | Exactamente 3 (`CONSUMER_MAX_RETRIES=3`) |
| Línea `dead_lettered` con `attempts` | 1, con `attempts=4` |
| `sensors.dead_letter` | +1 mensaje |
| Reintentos posteriores del mismo `message_id` | Ninguno |

El conteo real de intentos y sus marcas temporales salen del log capturado en el
paso 3 — es la evidencia que pide el plan, y no requiere código nuevo.

---

## Repeticiones y registro

Los tres se ejecutan **al menos 3 veces**. Las inyecciones actuales tienen una
sola observación y no admiten ninguna afirmación sobre variabilidad; con tres
corridas se puede reportar mediana y rango.

Convención de archivos, consistente con `chaos/results/`:

| Prueba | Artefacto | Nombre |
|---|---|---|
| AP5 | captura + conteos | `ap5-{A,B}-<epoch>.pcap` / `.txt` |
| AP6 | log + contadores | `ap6-<epoch>.log` |
| AP7 | log de intentos | `ap7-<epoch>.log` |

Para cada corrida declarar: sistema (A/B), fecha y hora UTC, evento elegido
(AP5), `message_id` usado (AP6/AP7) y el mecanismo de fallo (AP7).

## Resumen de desviaciones respecto del plan original

Tres afirmaciones del plan no se sostienen contra el código y la infra actuales:

1. **AP5 no se puede medir con las métricas de Prometheus actuales** — no hay
   cAdvisor, y node-exporter mide el nodo entero. Requiere captura de tráfico
   con el sistema en reposo (§AP5.1).
2. **AP6 no requiere ningún registro adicional** — `duplicate_skipped` y
   `ew_duplicates_skipped_total` ya existen (§AP6.1).
3. **AP7 no se ejercita con un mensaje malformado** — el JSON inválido se
   descarta sin reintentos por diseño. Hay que hacer fallar la persistencia de
   una alerta (§AP7.1).

Y cuatro del procedimiento manual de este mismo documento, corregidas en los
scripts:

4. **El evento representativo ensuciaba la DLQ**: le faltaban `schema_version`
   y `received_at`, y data-management lo mandaba a `sensors.dead_letter`
   (ver "Corrección común").
5. **`tcpdump -i any` en k3s cuenta cada paquete 2–3 veces**, y el fondo no es
   cero en reposo (§AP5.3).
6. **Escalar MySQL a 0 reinicia early-warning por liveness**, y revocar INSERT
   no aplica al pool (§AP7.2).
7. **data-management no dejaba traza del duplicado** (§AP6, nota).
