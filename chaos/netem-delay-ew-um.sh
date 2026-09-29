#!/usr/bin/env bash
# netem-delay-ew-um.sh — inyecta latencia de red (tc netem) en los pods de
# user-management (servidor gRPC que Early Warning llama para resolver los
# suscriptores de una alerta), para abrir el circuit breaker de EW sobre la
# RUTA DE ALERTAS. CLAUDE.md §2.3/§4.
#
# ── Por qué este escenario y no netem-delay-ew-da.sh ─────────────────────────
# El escenario contra data-analysis degrada la ruta de REPORTES
# (POST /reports/generate -> api.enrich). Esa ruta sí tiene breaker, pero no es
# la ruta que el sistema usa para alertar: un reporte lento no compromete la
# función de alerta temprana. user-management es la ÚNICA dependencia síncrona
# de la ruta de alertas (consumer.dispatch -> subs.TokensFor), así que es el
# único breaker cuya apertura se puede leer como "el sistema siguió alertando
# con una dependencia caída", que es lo que §2.3 exige demostrar.
#
# ── Las dos condiciones que tienen que cumplirse a la vez ────────────────────
# El breaker cuenta FALLOS, no latencia. Una llamada lenta que responde dentro
# del timeout es un éxito y RESETEA el contador (grpcx.onResult). Entonces:
#
#   1. El delay tiene que agotar el timeout con margen. Con
#      USER_MANAGEMENT_TIMEOUT_MS=5000, un delay de 5100ms es frágil: basta una
#      variación de red para que una llamada entre por debajo y reinicie la
#      cuenta. Default acá: 9000ms. El script aborta si DELAY_MS <= timeout.
#
#   2. Tiene que HABER alertas durante la ventana. user-management solo se llama
#      al emitir una alerta. Si en la ventana no cruza ningún umbral, no hay
#      invocaciones, no hay fallos, y el breaker sigue cerrado aunque el delay
#      esté perfectamente puesto. Es el mismo mecanismo por el que una corrida
#      corta no alerta: en los primeros minutos ningún sensor tiene línea base.
#
# Por (2) este script NO depende del generador de carga: publica él mismo pares
# de lecturas GNSS en early_warning.evaluate con un salto de desplazamiento que
# cruza umbral rojo de forma determinista (ver _alert_driver). La inyección
# igual debe hacerse con el sistema en régimen, no al arranque.
#
# ── Por qué se muestrea en continuo y no con snapshots pre/post ──────────────
# El tiempo hasta la apertura y el de recuperación son instantes, no diferencias
# de contadores: sin marcas intermedias no existen. Este script escribe una
# serie temporal (CSV) cada SAMPLE_INTERVAL segundos durante TODO el escenario,
# además de los snapshots, que se conservan para comparar con las corridas
# viejas.
#
# ── Qué se reporta si el breaker NO abre ─────────────────────────────────────
# Se reporta igual, con el porqué. ew_outbound_calls_total{target="user-management"}
# separa ok / timeout / circuit_open / error, así que un breaker cerrado se lee
# sin ambigüedad:
#   - sin serie            -> no hubo alertas, la ruta nunca llamó (driver falló)
#   - outcome="ok" alto    -> hubo llamadas, el delay no bastó para el timeout
#   - timeout >= threshold -> hallazgo real sobre el mecanismo
# Esa métrica la agrega go-early-warning en fix/breaker-metric-user-management;
# sin ese fix, la serie del gauge para user-management NO EXISTE y este script
# aborta en la precondición.
#
# Uso (Sistema B):
#   SSH_HOST=178.105.104.95 SSH_USER=gotesis SSH_KEY_PATH=~/.ssh/gotesis-key \
#     SUDO_PASSWORD=*** SSH_ORCHESTRATOR=k8s \
#     PROMETHEUS_ADDR=http://178.105.104.95:31083 \
#     ./chaos/netem-delay-ew-um.sh [delay_ms] [duration_seconds]
#
# Repetir >= 3 veces: una sola observación no admite ninguna afirmación sobre
# variabilidad. Los CSV quedan con timestamp, así que las corridas no se pisan.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/capture.sh"
source "$SCRIPT_DIR/lib/ssh.sh"
source "$SCRIPT_DIR/lib/sampler.sh"
source "$SCRIPT_DIR/../load-tests/lib/grafana-annotate.sh"

DELAY_MS="${1:-9000}"
DURATION="${2:-240}"
LABEL="netem-delay-ew-um"
BREAKER_TARGET="user-management"

# Deben reflejar la config REAL del EW bajo prueba. El deployment de B no setea
# ninguna, así que valen los defaults de cmd/early-warning/main.go.
UM_TIMEOUT_MS="${USER_MANAGEMENT_TIMEOUT_MS:-5000}"
FAIL_THRESHOLD="${CIRCUIT_BREAKER_FAILURE_THRESHOLD:-5}"
UM_CONTAINER_NAME="${UM_CONTAINER_NAME:-user-management}"
NETEM_IFACE="${NETEM_IFACE:-eth0}"
UM_GRPC_PORT="${UM_GRPC_PORT:-9090}"
NETEM_SCOPE="${NETEM_SCOPE:-grpc}"
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-5}"

# Driver de alertas: publica pares de lecturas GNSS en la cola de EW. Sin esto
# no hay alertas => no hay llamadas a user-management => el breaker no abre.
RABBITMQ_SELECTOR="${RABBITMQ_SELECTOR:-app=rabbitmq}"
ALERT_PROJECT="${ALERT_PROJECT:-shangtan}"   # debe existir en defaultLevels() de EW
# El epoch en el prefijo es obligatorio para repetir el escenario: los
# message_id son <prefijo>-r<ronda>-s<i>-a/b, y EW marca cada uno como procesado
# durante IDEMPOTENCY_TTL (1h en B). Con un prefijo fijo, la siguiente corrida
# dentro de esa ventana repetia los mismos ids, EW los descartaba todos como
# duplicate_skipped, no habia alertas y la precondicion abortaba — justo en las
# repeticiones que O6 exige. Tambien evita heredar las lineas base de Redis de
# la corrida anterior.
ALERT_SENSOR_PREFIX="${ALERT_SENSOR_PREFIX:-chaos-um-$(date +%s)}"
ALERT_ROUND_SLEEP="${ALERT_ROUND_SLEEP:-3}"
# Sensores distintos por ronda: el breaker necesita fallos CONSECUTIVOS, y cada
# alerta es un Invoke. Con FAIL_THRESHOLD sensores por ronda, una sola ronda ya
# puede acumular el umbral.
ALERT_SENSORS_PER_ROUND="${ALERT_SENSORS_PER_ROUND:-$FAIL_THRESHOLD}"
# Exchange/routing key: los mensajes se publican en sensors.raw con una routing
# key que matchea el binding "sensors.#" hacia early_warning.evaluate, igual que
# lo haria data-receiving. Publicar directo a la cola saltearia el binding y no
# probaria el mismo camino.
ALERT_EXCHANGE="${ALERT_EXCHANGE:-sensors.raw}"
ALERT_ROUTING_KEY="${ALERT_ROUTING_KEY:-sensors.gnss}"
EVENT_PROJECT="$ALERT_PROJECT"
EVENT_EXCHANGE="$ALERT_EXCHANGE"
EVENT_ROUTING_KEY="$ALERT_ROUTING_KEY"
source "$SCRIPT_DIR/lib/event.sh"

# Todo lo que imprime la corrida queda también en chaos/results/. Antes solo el
# CSV y los snapshots sobrevivían a la terminal: el instante de apertura, el
# tiempo de recuperación y el diagnóstico se perdían al cerrarla, y son
# justamente lo que O6 pide reportar.

_ssh_require
RUN_TS=$(date +%s)
RUN_LOG="$RESULTS_DIR/${LABEL}-run-${RUN_TS}.log"
exec > >(tee -a "$RUN_LOG") 2>&1
echo "    (log de la corrida -> $RUN_LOG)"

case "$NETEM_SCOPE" in
  grpc|all) ;;
  *)
    echo "ERROR: NETEM_SCOPE='$NETEM_SCOPE' inválido — usar 'grpc' (path ew->um degradado, peer sano)" >&2
    echo "  o 'all' (red del pod degradada; kubelet mata el pod y el escenario mide peer caído)." >&2
    exit 1
    ;;
esac

# En modo local el orquestador es k8s por definicion: _ssh_require ya verifico
# que kubectl hable con el cluster, asi que exigir la variable seria ruido.
[[ "$CHAOS_LOCAL" == "1" ]] && SSH_ORCHESTRATOR="${SSH_ORCHESTRATOR:-k8s}"
if [[ "$SSH_ORCHESTRATOR" != "k8s" ]]; then
  echo "ERROR: este escenario solo está implementado para el Sistema B (SSH_ORCHESTRATOR=k8s)." >&2
  echo "  El Sistema A no tiene circuit breaker: el observable tendría que ser otro." >&2
  exit 1
fi

# Guarda dura (condición 1): un delay por debajo del timeout NO puede abrir el
# breaker — la llamada responde lenta pero exitosa y resetea el contador.
if [[ "$DELAY_MS" -le "$UM_TIMEOUT_MS" ]]; then
  echo "ERROR: DELAY_MS=${DELAY_MS}ms <= timeout por llamada (${UM_TIMEOUT_MS}ms)." >&2
  echo "  Con ese delay las llamadas a user-management responden lentas pero OK: el breaker" >&2
  echo "  nunca abre y el escenario reporta un falso 'todo bien'. Usar DELAY_MS > ${UM_TIMEOUT_MS}" >&2
  echo "  con margen amplio (ej: $(( UM_TIMEOUT_MS + 4000 )))." >&2
  exit 1
fi

if [[ "$(prom_query 'vector(1)')" != "1" ]]; then
  echo "ERROR: no se pudo consultar Prometheus en $PROMETHEUS_ADDR — el muestreo quedaría vacío." >&2
  exit 1
fi

# Precondición: la métrica del breaker de user-management tiene que EXISTIR.
# Si no, este escenario no puede medir nada y hay que desplegar el EW con el fix
# de instrumentación. Distinguirlo acá evita 240s de corrida para nada.
if [[ "$(prom_query "count(ew_outbound_calls_total{target=\"$BREAKER_TARGET\"}) or vector(0)")" == "0" ]]; then
  echo "AVISO: ew_outbound_calls_total{target=\"$BREAKER_TARGET\"} todavía no tiene series." >&2
  echo "  Es esperable si EW aún no emitió ninguna alerta desde su último arranque; el driver" >&2
  echo "  de este script las va a provocar. Pero si el EW desplegado NO tiene el fix de" >&2
  echo "  instrumentación (go-early-warning fix/breaker-metric-user-management), la serie no" >&2
  echo "  va a aparecer nunca y el escenario no podrá concluir. Verificar la imagen desplegada." >&2
fi

echo "=== Escenario: netem delay ${DELAY_MS}ms en $UM_CONTAINER_NAME (Sistema B / k3s) ==="
echo "    Servidor:      $SSH_USER@$SSH_HOST (namespace $K8S_NAMESPACE)"
echo "    Delay:         ${DELAY_MS}ms  (timeout por llamada: ${UM_TIMEOUT_MS}ms => cada intento corta)"
echo "    Duración:      ${DURATION}s   (muestreo cada ${SAMPLE_INTERVAL}s)"
echo "    Umbral:        ${FAIL_THRESHOLD} fallos consecutivos para abrir"
if [[ "$NETEM_SCOPE" == "grpc" ]]; then
  echo "    Scope:         grpc — solo el puerto $UM_GRPC_PORT (respuestas a EW). Las probes de"
  echo "                   kubelet no se tocan: user-management sigue vivo y el breaker abre por"
  echo "                   LATENCIA, con el peer respondiendo lento."
else
  echo "    Scope:         all — TODO el egress del pod. AVISO: el delay también pega a las probes"
  echo "                   de kubelet, así que user-management morirá por liveness y el breaker"
  echo "                   abrirá por peer caído, no por latencia."
fi
echo "    Driver:        alertas GNSS via AMQP (project=${ALERT_PROJECT}, ${ALERT_SENSORS_PER_ROUND} sensores/ronda)"

# ── Resolución de targets (mismo patrón endurecido que netem-delay-ew-da.sh) ──
# El PID debe salir de `crictl inspect -o go-template {{.info.pid}}`: parsear el
# primer '"pid":' del JSON devuelve 1 (el PID dentro del pid-namespace) y
# `nsenter -t 1 -n` entra al netns del HOST => el netem degradaría TODO el nodo.
_um_targets() {
  _sudo_run "for id in \$(crictl ps --name $UM_CONTAINER_NAME -q); do
    pid=\$(crictl inspect -o go-template --template '{{.info.pid}}' \$id 2>/dev/null)
    [ -n \"\$pid\" ] || continue
    ip=\$(nsenter -t \$pid -n ip -4 -o addr show dev $NETEM_IFACE 2>/dev/null | grep -oE 'inet [0-9.]+' | cut -d' ' -f2)
    echo \"\$pid \$ip\"
  done"
}

# El netns lo dueña el sandbox (pause) y sobrevive a los reinicios del
# contenedor: hay que barrerlo también al limpiar.
_um_sandbox_pids() {
  _sudo_run "for p in \$(crictl pods --name $UM_CONTAINER_NAME -q 2>/dev/null); do
    crictl inspectp -o go-template --template '{{.info.pid}}' \$p 2>/dev/null
  done" 2>/dev/null || true
}

pod_ips=$(_kubectl get pods -l "app=$UM_CONTAINER_NAME" -n "$K8S_NAMESPACE" \
  -o 'jsonpath={range .items[*]}{.status.podIP}{"\n"}{end}' 2>/dev/null || true)
if [[ -z "$pod_ips" ]]; then
  echo "ERROR: no se pudieron listar las IPs de los pods '$UM_CONTAINER_NAME' en $K8S_NAMESPACE." >&2
  exit 1
fi

targets=$(_um_targets)
if [[ -z "$targets" ]]; then
  echo "ERROR: no se encontró ningún contenedor '$UM_CONTAINER_NAME' corriendo en el nodo." >&2
  exit 1
fi

injected_pids=()
while read -r pid ip; do
  [[ -n "$pid" ]] || continue
  if [[ -z "$ip" ]] || ! grep -qx "$ip" <<<"$pod_ips"; then
    echo "ERROR: el netns del PID $pid tiene IP '${ip:-<ninguna>}', que NO es la IP de ningún pod" >&2
    echo "  de $UM_CONTAINER_NAME (pods: $(tr '\n' ' ' <<<"$pod_ips")). Abortando: inyectar ahí podría" >&2
    echo "  aplicar el delay al netns del HOST y degradar todo el nodo." >&2
    exit 1
  fi
  injected_pids+=("$pid")
  echo "    Target:        pid=$pid pod_ip=$ip"
done <<<"$targets"

# ── Driver de alertas ────────────────────────────────────────────────────────
# Publica pares de lecturas GNSS por sensor en sensors.raw vía la Management API
# de RabbitMQ (lib/event.sh: python3 dentro del pod; la imagen -alpine no trae
# curl ni rabbitmqadmin).
#
# Cómo fuerza una alerta de forma determinista: EW calcula
#   speed_mm_dia = (cum_2 - cum_1) / dt_segundos * 86400
# La primera lectura solo fija la línea base (previous_none). La segunda, 60s
# después y con +100mm, da 100/60*86400 = 144000 mm/día, muy por encima del
# umbral rojo de shangtan (20). Cada par => una alerta => un Invoke a
# user-management. Sensor distinto por ronda para que no se pisen las líneas base.
#
# Los envelopes llevan schema_version y received_at (event_reading_json): sin
# ellos data-management los rechazaba por contrato y cada ronda mandaba
# 2 x ALERT_SENSORS_PER_ROUND mensajes a sensors.dead_letter, ensuciando la DLQ
# durante una prueba que no tiene nada que ver con ella.
_alert_driver() {
  local round=0
  local end=$(( $(date +%s) + DURATION + 30 ))
  while [[ "$(date +%s)" -lt "$end" ]]; do
    round=$(( round + 1 ))
    local i=0
    while [[ "$i" -lt "$ALERT_SENSORS_PER_ROUND" ]]; do
      local sensor="${ALERT_SENSOR_PREFIX}-r${round}-s${i}"
      local now; now=$(date +%s)
      # Lectura 1: fija la línea base. Lectura 2: +100mm en 60s => cruza rojo.
      # Un publish fallido no corta el driver: la verificación de tasa previa
      # y los contadores del resumen ya delatan un driver que no alerta.
      event_publish "$(event_reading_json "${sensor}-a" "$sensor" "$(( now - 60 ))" "0.0")" >/dev/null 2>&1 || true
      event_publish "$(event_reading_json "${sensor}-b" "$sensor" "$now" "100.0")" >/dev/null 2>&1 || true
      i=$(( i + 1 ))
    done
    sleep "$ALERT_ROUND_SLEEP"
  done
}

driver_pid=""
_driver_stop() {
  if [[ -n "$driver_pid" ]] && kill -0 "$driver_pid" 2>/dev/null; then
    kill "$driver_pid" 2>/dev/null || true
    wait "$driver_pid" 2>/dev/null || true
  fi
  driver_pid=""
}

_netem_clear() {
  # PIDs RE-resueltos, no los guardados: si kubelet reinició el contenedor, el
  # PID viejo no existe pero el netns del sandbox sigue con el netem puesto.
  local pid ip
  while read -r pid ip; do
    [[ -n "$pid" ]] || continue
    _sudo_run "nsenter -t $pid -n tc qdisc del dev $NETEM_IFACE root" >/dev/null 2>&1 || true
  done <<<"$(_um_targets)"
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    _sudo_run "nsenter -t $pid -n tc qdisc del dev $NETEM_IFACE root" >/dev/null 2>&1 || true
  done <<<"$(_um_sandbox_pids)"
}

_netem_verify_gone() {
  local dirty="" pid ip
  while read -r pid ip; do
    [[ -n "$pid" ]] || continue
    if _sudo_run "nsenter -t $pid -n tc qdisc show dev $NETEM_IFACE" 2>/dev/null | grep -q netem; then
      dirty+=" $pid"
    fi
  done <<<"$(_um_targets)"
  if [[ -n "$dirty" ]]; then
    echo "" >&2
    echo "ERROR CRÍTICO: quedó netem puesto en el/los netns:$dirty" >&2
    echo "  El Sistema B está DEGRADADO ahora mismo. Quitarlo a mano en $SSH_HOST:" >&2
    echo "    for id in \$(crictl ps --name $UM_CONTAINER_NAME -q); do" >&2
    echo "      pid=\$(crictl inspect -o go-template --template '{{.info.pid}}' \$id)" >&2
    echo "      nsenter -t \$pid -n tc qdisc del dev $NETEM_IFACE root" >&2
    echo "    done" >&2
    return 1
  fi
  echo "    Verificado: no quedó netem en ningún netns de $UM_CONTAINER_NAME."
  return 0
}

_cleanup() {
  local rc=$?
  echo ""
  echo "--- Limpieza: parando driver y muestreo, quitando netem ---"
  _driver_stop
  sampler_stop
  _netem_clear
  # Dejar el sistema degradado es peor que un escenario fallido: el rc tiene que
  # reflejarlo aunque el escenario haya salido bien.
  if ! _netem_verify_gone; then
    rc=1
  fi
  [[ -n "${region_id:-}" ]] && grafana_annotate_region_end "$region_id"
  exit "$rc"
}

# -- Verificacion PREVIA de tasa de alertas ----------------------------------
# La inyeccion no puede hacerse al arranque: si el sistema no esta emitiendo
# alertas, no hay llamadas a user-management y el breaker no puede abrir. Se
# mide la tasa ANTES de inyectar, con el driver ya corriendo, para que un "no
# abrio" nunca se confunda con "no habia trafico".
echo ""
echo "--- Arrancando driver de alertas y verificando que EW este alertando ---"
_alert_driver &
driver_pid=$!

verify_window=$(( SAMPLE_INTERVAL * 4 ))
alerts_before=$(prom_query 'sum(ew_alerts_published_total) or vector(0)')
sleep "$verify_window"
alerts_after=$(prom_query 'sum(ew_alerts_published_total) or vector(0)')
alerts_delta=$(awk -v a="${alerts_after:-0}" -v b="${alerts_before:-0}" 'BEGIN{d=a-b; print (d<0?0:d)}' 2>/dev/null || echo 0)
echo "    Alertas emitidas en ${verify_window}s de verificacion: ${alerts_delta}"

if awk -v d="${alerts_delta:-0}" -v n="$FAIL_THRESHOLD" 'BEGIN{exit !(d < n)}'; then
  echo "" >&2
  echo "ERROR: el sistema emitio ${alerts_delta} alertas en la ventana de verificacion, y hacen" >&2
  echo "  falta al menos ${FAIL_THRESHOLD} fallos CONSECUTIVOS para abrir el breaker." >&2
  echo "  Inyectar ahora produciria un 'el breaker no abrio' que no dice nada sobre la" >&2
  echo "  resiliencia, solo que no hubo trafico: el mismo defecto que invalido el escenario" >&2
  echo "  contra data-analysis. Revisar:" >&2
  echo "    - que el driver este publicando: ./chaos/publish-event.sh debe responder 'enrutado'" >&2
  echo "    - que ALERT_PROJECT='${ALERT_PROJECT}' exista en defaultLevels() de EW" >&2
  echo "    - que el sistema este en regimen (no recien arrancado)" >&2
  echo "  Subir ALERT_SENSORS_PER_ROUND o bajar ALERT_ROUND_SLEEP si hace falta mas tasa." >&2
  # El driver corre en background y el trap de limpieza todavia no esta puesto:
  # sin esto seguiria publicando pares de lecturas hasta DURATION+30s.
  _driver_stop
  exit 1
fi

# -- Precondicion: latencia de despacho instrumentada -------------------------
# O6 pide la latencia de la alerta en modo degradado. Sale de
# ew_alert_dispatch_duration_seconds (go-early-warning
# feat/o6-o7-alert-path-evidence). Con alertas ya confirmadas arriba, si la serie
# no existe es que el EW desplegado no tiene esa instrumentacion: la corrida
# mediria apertura y recuperacion pero no la degradacion, y O6 quedaria abierta.
dispatch_series=$(prom_query 'count(ew_alert_dispatch_duration_seconds_count) or vector(0)')
if [[ "$dispatch_series" == "0" || "$dispatch_series" == "ERR" ]]; then
  echo "" >&2
  echo "ERROR: ew_alert_dispatch_duration_seconds no tiene series pese a que EW esta alertando." >&2
  echo "  El EW desplegado no mide la latencia de despacho: desplegar go-early-warning con" >&2
  echo "  feat/o6-o7-alert-path-evidence antes de correr este escenario." >&2
  _driver_stop
  exit 1
fi

# Linea base SANA de la misma metrica, para comparar la degradacion contra algo.
# Ventana de 2m: con scrape de 15s, la ventana de verificacion (~20s) sola no
# alcanza para un increase() confiable.
healthy_dispatch_mean=$(prom_query 'sum(increase(ew_alert_dispatch_duration_seconds_sum[2m])) / sum(increase(ew_alert_dispatch_duration_seconds_count[2m]))')
echo "    Latencia de despacho sana (media 2m, pre-fallo): ${healthy_dispatch_mean}s"

echo ""
echo "--- Snapshot pre-fallo + arranque del muestreo continuo ---"
pre_snapshot_at=$(date +%s)
pre_snapshot=$(snapshot_counters "${LABEL}-pre")
cat "$pre_snapshot"
prom_query_raw 'ew_circuit_breaker_state' "$RESULTS_DIR/${LABEL}-pre-breakers.json"

csv=$(sampler_start "$LABEL" "$BREAKER_TARGET")
# sampler_start corre en $(...) -> subshell, asi que sus globals se pierden.
# SAMPLER_CSV se lo devuelve a las funciones de analisis y a sampler_stop.
export SAMPLER_CSV="$csv"
echo "    Muestreo continuo -> $csv"

region_id=$(grafana_annotate_region_start \
  "Chaos - netem-delay-ew-um (${DELAY_MS}ms, ${DURATION}s)" "chaos" "netem-delay-ew-um" "sistema-B")
trap _cleanup EXIT INT TERM

echo ""
echo "--- Inyectando latencia (tc netem delay ${DELAY_MS}ms, scope=$NETEM_SCOPE) en ${#injected_pids[@]} pod(s) ---"
fail_start=$(date +%s)
for pid in "${injected_pids[@]}"; do
  if [[ "$NETEM_SCOPE" == "all" ]]; then
    inject_cmd="nsenter -t $pid -n tc qdisc add dev $NETEM_IFACE root netem delay ${DELAY_MS}ms"
  else
    # priomap todo-ceros: TODO el trafico cae por defecto en 1:1 (sin netem),
    # incluidas las respuestas a las probes de kubelet. Solo lo que matchea el
    # filtro va a 1:4. Sin el priomap explicito el default reparte por TOS y
    # parte del trafico caeria en la banda con delay, degradando las probes.
    # match ip sport <grpc> = los paquetes que SALEN del servidor gRPC, o sea
    # las respuestas a EW: alcanza con demorar una pata para pasar el timeout.
    inject_cmd="nsenter -t $pid -n tc qdisc add dev $NETEM_IFACE root handle 1: prio bands 4 priomap 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 && \
nsenter -t $pid -n tc qdisc add dev $NETEM_IFACE parent 1:4 handle 40: netem delay ${DELAY_MS}ms && \
nsenter -t $pid -n tc filter add dev $NETEM_IFACE protocol ip parent 1: prio 1 u32 match ip sport $UM_GRPC_PORT 0xffff flowid 1:4"
  fi
  if ! _sudo_run "$inject_cmd" >/dev/null 2>&1; then
    echo "ERROR: fallo 'tc qdisc add' en el netns del pid $pid - la latencia NO fue inyectada." >&2
    exit 1
  fi
done
echo "    Delay aplicado. Verificando qdisc:"
for pid in "${injected_pids[@]}"; do
  echo -n "      pid=$pid: "
  _sudo_run "nsenter -t $pid -n tc qdisc show dev $NETEM_IFACE" 2>/dev/null | head -1
done

echo ""
echo "--- Ventana de fallo (${DURATION}s). El muestreo corre en paralelo ---"
poll_end=$(( fail_start + DURATION ))
opened_at=""
while [[ "$(date +%s)" -lt "$poll_end" ]]; do
  state=$(prom_query "max(ew_circuit_breaker_state{target=\"$BREAKER_TARGET\"})")
  to=$(prom_query "sum(ew_outbound_calls_total{target=\"$BREAKER_TARGET\",outcome=\"timeout\"}) or vector(0)")
  ok=$(prom_query "sum(ew_outbound_calls_total{target=\"$BREAKER_TARGET\",outcome=\"ok\"}) or vector(0)")
  echo "  t+$(( $(date +%s) - fail_start ))s: breaker=$state  timeouts=$to  ok=$ok"
  if [[ "$state" == "1" && -z "$opened_at" ]]; then
    opened_at=$(( $(date +%s) - fail_start ))
    echo "  -> circuito ABIERTO a los ${opened_at}s"
  fi
  sleep "$SAMPLE_INTERVAL"
done

echo ""
echo "--- Quitando la latencia (fin de la ventana de fallo) ---"
recovery_start=$(date +%s)
_netem_clear
_netem_verify_gone || exit 1

echo "--- Esperando a que el circuito cierre (tiempo de recuperacion) ---"
# El driver sigue corriendo a proposito: sin llamadas el breaker no pasa por
# half-open, el gauge no se actualiza y el tiempo de recuperacion seria un
# timeout falso.
set +e
mttr=$(wait_for_breaker_closed "$BREAKER_TARGET" 120)
mttr_status=$?
set -e
_driver_stop
sampler_stop

echo ""
echo "--- Snapshot post-recuperacion ---"
post_snapshot_at=$(date +%s)
post_snapshot=$(snapshot_counters "${LABEL}-post")
cat "$post_snapshot"

# -- Instante de apertura leido del CSV --------------------------------------
# El poll puede perderse la transicion si abre y cierra entre dos consultas; el
# CSV tiene la serie completa, asi que es la fuente mas fiable de las dos.
csv_opened_at=$(sampler_first_at "breaker_state" "1" "$fail_start")
[[ -z "$opened_at" && -n "$csv_opened_at" ]] && opened_at="$csv_opened_at"

calls_ok=$(sampler_last_value "calls_ok")
calls_timeout=$(sampler_last_value "calls_timeout")
calls_circuit_open=$(sampler_last_value "calls_circuit_open")
calls_error=$(sampler_last_value "calls_error")

# -- Degradacion y continuidad, leidas del CSV -------------------------------
# Tres tramos, porque la latencia de la ruta de alertas cambia de regimen:
#   1. [delay, apertura): user-management no responde y el breaker sigue
#      cerrado. Cada alerta espera timeout x intentos + backoff ANTES de
#      registrarse (la consulta de suscriptores va antes del INSERT).
#   2. [apertura, ultimo instante abierto]: el breaker rechaza sin llamar; la
#      alerta se registra sin push. Es la continuidad que exige CLAUDE.md 2.3.
#   3. Todo el fallo: total de alertas en modo degradado y su media.
# La latencia se observa al REGISTRAR la alerta, asi que una alerta que empezo
# en el tramo 1 y termino tras la apertura cuenta en el tramo 2: el tramo 2
# puede arrastrar algunas lentas al principio. Por eso tambien va el p95 maximo.
_ratio() { awk -v n="$1" -v d="$2" 'BEGIN { if (n != "" && d != "" && d+0 > 0) printf "%.3f\n", n/d }'; }
_window_mean() {
  _ratio "$(sampler_delta dispatch_degraded_sum "$1" "$2")" "$(sampler_delta dispatch_degraded_count "$1" "$2")"
}

degraded_alerts=$(sampler_delta dispatch_degraded_count "$fail_start" "$recovery_start")
degraded_mean=$(_window_mean "$fail_start" "$recovery_start")
p95_max=$(sampler_max dispatch_p95_1m "$fail_start" "$recovery_start")

mean_before_open=""
mean_while_open=""
alerts_while_open=""
continuity="n/a (el breaker no abrio)"
if [[ -n "$opened_at" ]]; then
  open_abs=$(( fail_start + opened_at ))
  last_open_rel=$(sampler_last_at "breaker_state" "1" "$fail_start")
  last_open_abs=$(( fail_start + ${last_open_rel:-$opened_at} ))
  mean_before_open=$(_window_mean "$fail_start" "$open_abs")
  mean_while_open=$(_window_mean "$open_abs" "$last_open_abs")
  alerts_while_open=$(sampler_delta alerts_published "$open_abs" "$last_open_abs")
  if [[ -z "$alerts_while_open" ]]; then
    continuity="sin datos (breaker abierto menos de dos muestras; bajar SAMPLE_INTERVAL)"
  elif awk -v a="$alerts_while_open" 'BEGIN { exit !(a > 0) }'; then
    continuity="verificada"
  else
    continuity="NO verificada"
  fi
fi

summary_file="$RESULTS_DIR/${LABEL}-summary-${fail_start}.env"
{
  echo "system=B"
  echo "fail_start=$fail_start"
  echo "fail_start_utc=$(date -u -d "@$fail_start" '+%Y-%m-%dT%H:%M:%SZ')"
  echo "delay_ms=$DELAY_MS"
  echo "duration_s=$DURATION"
  echo "netem_scope=$NETEM_SCOPE"
  echo "um_timeout_ms=$UM_TIMEOUT_MS"
  echo "fail_threshold=$FAIL_THRESHOLD"
  echo "alerts_in_verify_window=$alerts_delta"
  echo "breaker_opened_after_s=${opened_at:-}"
  echo "recovery_s=$mttr"
  echo "calls_ok=${calls_ok:-}"
  echo "calls_timeout=${calls_timeout:-}"
  echo "calls_circuit_open=${calls_circuit_open:-}"
  echo "calls_error=${calls_error:-}"
  echo "dispatch_mean_healthy_s=${healthy_dispatch_mean:-}"
  echo "degraded_alerts=${degraded_alerts:-}"
  echo "dispatch_mean_degraded_s=${degraded_mean:-}"
  echo "dispatch_mean_before_open_s=${mean_before_open:-}"
  echo "dispatch_mean_while_open_s=${mean_while_open:-}"
  echo "dispatch_p95_max_s=${p95_max:-}"
  echo "alerts_while_open=${alerts_while_open:-}"
  echo "continuity=$continuity"
  echo "samples_csv=$(basename "$csv")"
  echo "run_log=$(basename "$RUN_LOG")"
} > "$summary_file"

echo ""
echo "=== Resumen (sistema-B) ==="
echo "Delay inyectado:              ${DELAY_MS}ms (timeout ${UM_TIMEOUT_MS}ms, umbral ${FAIL_THRESHOLD} fallos)"
echo "Alertas en verificacion:      ${alerts_delta} (precondicion: >= ${FAIL_THRESHOLD})"
echo "Circuito abierto a los:       ${opened_at:-nunca}s"
echo "Tiempo de recuperacion:       ${mttr}"
echo "Llamadas salientes a $BREAKER_TARGET (acumulado):"
echo "  ok=${calls_ok:-0}  timeout=${calls_timeout:-0}  circuit_open=${calls_circuit_open:-0}  error=${calls_error:-0}"
echo "Latencia de despacho (umbral cruzado -> alerta registrada):"
echo "  sana, pre-fallo (media 2m):        ${healthy_dispatch_mean:-sin datos}s"
echo "  degradada, breaker cerrado:        ${mean_before_open:-sin datos}s"
echo "  degradada, breaker abierto:        ${mean_while_open:-sin datos}s"
echo "  degradada, todo el fallo:          ${degraded_mean:-sin datos}s  (${degraded_alerts:-0} alertas sin push)"
echo "  p95 maximo en la ventana (1m):     ${p95_max:-sin datos}s"
echo "Continuidad operativa:        ${continuity} (${alerts_while_open:-0} alertas registradas con el breaker abierto)"
echo "Serie temporal completa:      $csv"
echo "Snapshots:                    $pre_snapshot / $post_snapshot"
echo "Resumen por corrida:          $summary_file"

_ts() { local e="$1"; printf '%s  (UTC %s)' "$(date -d "@$e" '+%Y-%m-%d %H:%M:%S %Z')" "$(date -u -d "@$e" '+%H:%M:%S')"; }

echo ""
echo "=== Linea de tiempo (sistema-B) ==="
echo "Snapshot pre-fallo:         $(_ts "$pre_snapshot_at")"
echo "Delay inyectado:            $(_ts "$fail_start")"
[[ -n "${opened_at:-}" ]] && echo "Circuito abierto:           $(_ts "$(( fail_start + opened_at ))")  [t+${opened_at}s]"
echo "Delay retirado:             $(_ts "$recovery_start")"
echo "Snapshot post-recuperacion: $(_ts "$post_snapshot_at")"
echo ""
echo "Rango para Grafana/Prometheus (UTC, con 60s de margen a cada lado):"
echo "  from=$(date -u -d "@$(( pre_snapshot_at - 60 ))" '+%Y-%m-%dT%H:%M:%SZ')  to=$(date -u -d "@$(( post_snapshot_at + 60 ))" '+%Y-%m-%dT%H:%M:%SZ')"

# -- Diagnostico de un breaker que no abrio ----------------------------------
# "No abrio" se reporta igual, pero con el porque: el contador de salientes
# distingue "el delay no basto" de "la ruta nunca llamo". Sin eso vuelve a ser
# un dato del que no se concluye nada.
if [[ -z "$opened_at" ]]; then
  echo "" >&2
  echo "ERROR: el breaker nunca abrio pese a un delay (${DELAY_MS}ms) mayor al timeout (${UM_TIMEOUT_MS}ms)." >&2
  if [[ "${calls_timeout:-0}" == "0" && "${calls_ok:-0}" != "0" ]]; then
    echo "  DIAGNOSTICO: hubo ${calls_ok} llamadas y NINGUNA agoto el timeout => el delay no se" >&2
    echo "  aplico al trafico gRPC. Revisar UM_GRPC_PORT=${UM_GRPC_PORT} (es el puerto real?) y" >&2
    echo "  el filtro tc, o usar NETEM_SCOPE=all para descartar todo el egress." >&2
  elif [[ "${calls_ok:-0}" == "0" && "${calls_timeout:-0}" == "0" ]]; then
    echo "  DIAGNOSTICO: CERO llamadas salientes a $BREAKER_TARGET durante la ventana => la ruta" >&2
    echo "  de alertas no se ejecuto. El driver no logro que EW emitiera alertas (o EW no tiene" >&2
    echo "  el fix de instrumentacion y la metrica no existe)." >&2
  else
    echo "  DIAGNOSTICO: hubo ${calls_timeout} timeouts pero no llegaron a ${FAIL_THRESHOLD}" >&2
    echo "  CONSECUTIVOS: alguna llamada exitosa reseteo el contador entre medio. Subir el delay" >&2
    echo "  o la tasa de alertas (ALERT_SENSORS_PER_ROUND)." >&2
  fi
  exit 1
fi
if [[ "$continuity" == "NO verificada" ]]; then
  echo "" >&2
  echo "ERROR: el breaker estuvo abierto y EW no registro ninguna alerta en ese tramo." >&2
  echo "  CLAUDE.md 2.3 exige que la ruta de alertas siga emitiendo por umbral simple con la" >&2
  echo "  dependencia caida. Revisar en el log de EW los db_record_failed / requeue del tramo." >&2
  exit 1
fi
if [[ "$mttr" != "ERR_PROM_UNREACHABLE" && "$mttr_status" -ne 0 ]]; then
  exit 1
fi
