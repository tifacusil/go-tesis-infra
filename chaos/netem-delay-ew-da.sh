#!/usr/bin/env bash
# netem-delay-ew-da.sh — inyecta latencia de red (tc netem) en los pods de
# data-analysis (servidor gRPC que Early Warning llama para análisis avanzado),
# para probar el circuit breaker de Early Warning bajo *latencia alta*, no solo
# bajo caída total. CLAUDE.md §2.3/§4: con el circuito abierto, Early Warning
# debe seguir emitiendo alarmas por umbral simple.
#
# ── Por qué la versión anterior no medía nada ────────────────────────────────
# 1. Inyectaba con `pumba` sobre el Docker LOCAL y el contenedor "data-analysis-1"
#    (nombres de docker-compose). El Sistema B corre k3s/containerd en un
#    servidor remoto: ese contenedor no existe acá. Ahora se inyecta vía SSH con
#    tc netem dentro del netns de cada pod (nsenter).
# 2. El delay default era 2000ms, pero el breaker de EW usa un timeout por
#    llamada de DATA_ANALYSIS_TIMEOUT_MS (default 5000ms, y el deployment de B
#    NO lo sobreescribe). Un delay de 2s sobre un timeout de 5s NO produce
#    fallos: la llamada responde lenta pero OK, onResult(true) resetea el
#    contador y el breaker se queda CLOSED — es imposible que abra. Ahora el
#    default es 8000ms y el script aborta si DELAY_MS <= el timeout.
# 3. Nada ejercitaba el breaker: `ew_circuit_breaker_state` es un GaugeVec y su
#    ÚNICO setter está en el path de /reports/generate (api.go). Los hijos de un
#    GaugeVec se crean lazy, así que sin requests de reporte la serie NO EXISTE
#    en Prometheus. La carga de endurance solo empuja tramas por TCP y nunca
#    toca ese path => el poll leía NaN y devolvía TIMEOUT, o peor: si el breaker
#    figuraba closed, `wait_for_breaker_closed` devolvía MTTR=0 (falso pass).
#    Ahora el script genera tráfico de reportes él mismo mientras inyecta.
#
# ── Cómo abre el breaker (para entender los tiempos) ─────────────────────────
# Con los defaults de B: Timeout=5s, MaxRetries=2 (=3 intentos), backoff 1s/5s,
# FailThreshold=5 fallos CONSECUTIVOS, OpenFor=30s.
#   - Un delay > 5s hace que cada intento corte por DeadlineExceeded (que
#     grpcx.retryable() sí reintenta) => un Invoke ≈ 5+1+5+5+5 ≈ 21s y cuenta
#     como UN fallo.
#   - Hacen falta 5 Invokes fallidos => ~105s en serie. Por eso el driver manda
#     REPORT_CONCURRENCY requests en paralelo (default 5): así los 5 fallos
#     caen juntos y el breaker abre en ~21s en vez de ~105s.
#   - DURATION default 180s: alcanza para abrir y observar, con margen.
#
# Uso (Sistema B):
#   SSH_HOST=178.105.104.95 SSH_USER=gotesis SSH_KEY_PATH=~/.ssh/gotesis-key \
#     SUDO_PASSWORD=*** SSH_ORCHESTRATOR=k8s \
#     PROMETHEUS_ADDR=http://178.105.104.95:31083 \
#     ./chaos/netem-delay-ew-da.sh [delay_ms] [duration_seconds]
#
# Sistema A todavía no: no tiene circuit breaker, así que el observable no puede
# ser el breaker — hay que medir propagación (latencia/errores) en vez de
# contención. Ver el bloque `native` más abajo.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/capture.sh"
source "$SCRIPT_DIR/lib/ssh.sh"
source "$SCRIPT_DIR/../load-tests/lib/grafana-annotate.sh"

DELAY_MS="${1:-8000}"
DURATION="${2:-180}"
LABEL="netem-delay-ew-da"

# Deben reflejar la config REAL del EW bajo prueba (deployment de B no setea
# ninguna, así que valen los defaults del código en cmd/early-warning/main.go).
DA_TIMEOUT_MS="${DATA_ANALYSIS_TIMEOUT_MS:-5000}"
FAIL_THRESHOLD="${CIRCUIT_BREAKER_FAILURE_THRESHOLD:-5}"
DA_CONTAINER_NAME="${DA_CONTAINER_NAME:-data-analysis}"
NETEM_IFACE="${NETEM_IFACE:-eth0}"
DA_GRPC_PORT="${DA_GRPC_PORT:-50051}"

# NETEM_SCOPE — QUÉ fallo se modela. No es un detalle de implementación: cambia
# qué mide el escenario, y los dos son válidos pero distintos.
#
#   grpc (default): delay SOLO al tráfico que sale del puerto gRPC (50051), o
#     sea las respuestas a Early Warning. Modela "el path ew->da está degradado,
#     data-analysis sano". Las probes de kubelet (HTTP :8080) NO se tocan, así
#     que el pod sigue Ready y el breaker abre por LATENCIA, con el peer vivo.
#     Es el único escenario que mide para qué existe un circuit breaker (§2.3):
#     degradar a umbral simple mientras el peer responde lento.
#
#   all: delay a TODO el egress del pod. Modela "la red del pod está degradada"
#     (NIC/CNI saturada, vecino ruidoso). Es un fallo real, pero como el delay
#     también pega a las respuestas de las probes (kubelet las corta a 5s),
#     kubelet mata el contenedor a los ~45s por liveness. Entonces el breaker
#     abre porque el peer se cayó — que es lo mismo que ya mide
#     pause-data-management. El escenario colapsa sobre el otro y el "abrió a
#     los 73s" mezcla latencia con peer caído: no es un dato limpio.
#
# Con scope=all es IMPOSIBLE separarlos: el timeout de la probe (5s) y el
# timeout gRPC del breaker (5s) son el mismo umbral, así que cualquier delay que
# abra el breaker mata al pod. Por eso el default es grpc.
NETEM_SCOPE="${NETEM_SCOPE:-grpc}"

# Driver de reportes: sin esto el breaker nunca se ejercita y la serie del gauge
# ni siquiera existe (ver punto 3 arriba).
EW_SVC="${EW_SVC:-10.43.48.22:8080}"          # ClusterIP de early-warning (ruteable desde el nodo)
REPORT_PROJECT="${REPORT_PROJECT:-chaos-probe}" # project_id dedicado: identifica/limpia las filas que deja
REPORT_CONCURRENCY="${REPORT_CONCURRENCY:-5}"
REPORT_TIMEOUT="${REPORT_TIMEOUT:-60}"

_ssh_require

case "$NETEM_SCOPE" in
  grpc|all) ;;
  *)
    echo "ERROR: NETEM_SCOPE='$NETEM_SCOPE' inválido — usar 'grpc' (path ew->da degradado, peer sano)" >&2
    echo "  o 'all' (red del pod degradada; kubelet mata el pod y el escenario mide lo mismo que pause)." >&2
    exit 1
    ;;
esac

if [[ "$SSH_ORCHESTRATOR" != "k8s" ]]; then
  echo "ERROR: este escenario solo está implementado para el Sistema B (SSH_ORCHESTRATOR=k8s)." >&2
  echo "  El Sistema A no tiene circuit breaker: inyectarle el mismo delay no mide contención" >&2
  echo "  sino propagación (latencia/errores end-to-end). Necesita otro observable, no este poll." >&2
  exit 1
fi

# Guarda dura: un delay por debajo del timeout por llamada NO puede abrir el
# breaker (la llamada responde lenta pero exitosa). Sin esto el script "pasa"
# sin medir nada, que es exactamente el bug que tenía.
if [[ "$DELAY_MS" -le "$DA_TIMEOUT_MS" ]]; then
  echo "ERROR: DELAY_MS=${DELAY_MS}ms <= timeout por llamada (${DA_TIMEOUT_MS}ms)." >&2
  echo "  Con ese delay las llamadas a data-analysis responden lentas pero OK, el breaker" >&2
  echo "  nunca abre y el escenario reporta un falso 'todo bien'. Usar DELAY_MS > ${DA_TIMEOUT_MS}" >&2
  echo "  (ej: $(( DA_TIMEOUT_MS + 3000 ))), o bajar DATA_ANALYSIS_TIMEOUT_MS en el deployment." >&2
  exit 1
fi

if [[ "$(prom_query 'vector(1)')" != "1" ]]; then
  echo "ERROR: no se pudo consultar Prometheus en $PROMETHEUS_ADDR — los snapshots quedarían vacíos." >&2
  exit 1
fi

echo "=== Escenario: netem delay ${DELAY_MS}ms en $DA_CONTAINER_NAME (Sistema B / k3s) ==="
echo "    Servidor:      $SSH_USER@$SSH_HOST (namespace $K8S_NAMESPACE)"
echo "    Delay:         ${DELAY_MS}ms  (timeout por llamada: ${DA_TIMEOUT_MS}ms => cada intento corta)"
echo "    Duración:      ${DURATION}s"
if [[ "$NETEM_SCOPE" == "grpc" ]]; then
  echo "    Scope:         grpc — solo el puerto $DA_GRPC_PORT (respuestas a EW). Las probes de"
  echo "                   kubelet no se tocan: data-analysis sigue vivo y el breaker abre por"
  echo "                   LATENCIA, con el peer respondiendo lento."
else
  echo "    Scope:         all — TODO el egress del pod. AVISO: el delay también pega a las probes"
  echo "                   de kubelet (timeout 5s), así que data-analysis morirá por liveness a los"
  echo "                   ~45s y el breaker abrirá por peer caído, no por latencia. Mide lo mismo"
  echo "                   que pause-data-management; el número no es un dato limpio de latencia."
fi
echo "    Driver:        POST http://${EW_SVC}/reports/generate (project_id=${REPORT_PROJECT}, x${REPORT_CONCURRENCY})"

# _da_targets — imprime "<host_pid> <pod_ip>" por cada contenedor data-analysis.
#
# OJO con el PID: hay que usar `crictl inspect -o go-template {{.info.pid}}`, que
# devuelve el PID en el HOST. Parsear el primer '"pid":' del JSON devuelve 1 (el
# PID dentro del pid-namespace del contenedor) y `nsenter -t 1 -n` entra al netns
# del HOST => el netem se aplicaría a TODO el tráfico del nodo en vez de al pod.
# Con una corrida de endurance activa eso sería catastrófico, así que además de
# usar el template correcto se valida la IP del netns contra la IP del pod.
_da_targets() {
  _sudo_run "for id in \$(crictl ps --name $DA_CONTAINER_NAME -q); do
    pid=\$(crictl inspect -o go-template --template '{{.info.pid}}' \$id 2>/dev/null)
    [ -n \"\$pid\" ] || continue
    ip=\$(nsenter -t \$pid -n ip -4 -o addr show dev $NETEM_IFACE 2>/dev/null | grep -oE 'inet [0-9.]+' | cut -d' ' -f2)
    echo \"\$pid \$ip\"
  done"
}

# IPs reales de los pods según la API: si el netns donde vamos a inyectar no
# tiene una de estas IPs, NO es el pod (sería el host) y abortamos.
pod_ips=$(_kubectl get pods -l "app=$DA_CONTAINER_NAME" -n "$K8S_NAMESPACE" \
  -o 'jsonpath={range .items[*]}{.status.podIP}{"\n"}{end}' 2>/dev/null || true)
if [[ -z "$pod_ips" ]]; then
  echo "ERROR: no se pudieron listar las IPs de los pods '$DA_CONTAINER_NAME' en $K8S_NAMESPACE." >&2
  exit 1
fi

targets=$(_da_targets)
if [[ -z "$targets" ]]; then
  echo "ERROR: no se encontró ningún contenedor '$DA_CONTAINER_NAME' corriendo en el nodo." >&2
  exit 1
fi

injected_pids=()
while read -r pid ip; do
  [[ -n "$pid" ]] || continue
  if [[ -z "$ip" ]] || ! grep -qx "$ip" <<<"$pod_ips"; then
    echo "ERROR: el netns del PID $pid tiene IP '${ip:-<ninguna>}', que NO es la IP de ningún pod" >&2
    echo "  de $DA_CONTAINER_NAME (pods: $(tr '\n' ' ' <<<"$pod_ips")). Abortando: inyectar ahí podría" >&2
    echo "  aplicar el delay al netns del HOST y degradar todo el nodo." >&2
    exit 1
  fi
  injected_pids+=("$pid")
  echo "    Target:        pid=$pid pod_ip=$ip"
done <<<"$targets"

# _netem_clear — quita el qdisc de todos los netns donde lo pusimos. Idempotente
# (|| true): si ya no está, no importa. Se llama SIEMPRE por trap: dejar 8s de
# delay puesto en producción sería peor que no haber corrido el escenario.
_netem_clear() {
  # Los PIDs se RE-RESUELVEN acá, no se reusan los de la inyección. El delay
  # puede tumbar las probes del propio data-analysis (kubelet las cronometra a
  # 5s) y hacer que kubelet reinicie el contenedor: entonces el PID guardado al
  # inyectar ya no existe, pero el netns del pod SÍ sobrevive — lo dueña el
  # sandbox (pause), no el contenedor — y se queda con el netem puesto.
  # Limpiar por PID muerto falla, el `|| true` se lo traga, y quedan 8s de
  # delay en producción. Paso exactamente eso el 2026-07-16.
  #
  # Se barren los netns de los contenedores Y de los sandboxes: si el
  # contenedor está en crashloop puede no aparecer en `crictl ps` justo ahora,
  # pero su sandbox sigue vivo con el netns intacto.
  local pid ip
  while read -r pid ip; do
    [[ -n "$pid" ]] || continue
    _sudo_run "nsenter -t $pid -n tc qdisc del dev $NETEM_IFACE root" >/dev/null 2>&1 || true
  done <<<"$(_da_targets)"

  while read -r pid; do
    [[ -n "$pid" ]] || continue
    _sudo_run "nsenter -t $pid -n tc qdisc del dev $NETEM_IFACE root" >/dev/null 2>&1 || true
  done <<<"$(_da_sandbox_pids)"
}

# _da_sandbox_pids — PIDs de los sandboxes (contenedores pause) de data-analysis.
# El netns vive acá y sobrevive a los reinicios del contenedor de la app.
_da_sandbox_pids() {
  _sudo_run "for p in \$(crictl pods --name $DA_CONTAINER_NAME -q 2>/dev/null); do
    crictl inspectp -o go-template --template '{{.info.pid}}' \$p 2>/dev/null
  done" 2>/dev/null || true
}

# _netem_verify_gone — comprueba que NINGÚN netns de data-analysis quedó con
# netem. No alcanza con "corrí el cleanup": si falla, hay que gritarlo con el
# comando manual, porque un delay olvidado envenena las horas restantes de una
# corrida de 12h y los datos siguen pareciendo válidos.
_netem_verify_gone() {
  local dirty=""
  local pid ip
  while read -r pid ip; do
    [[ -n "$pid" ]] || continue
    if _sudo_run "nsenter -t $pid -n tc qdisc show dev $NETEM_IFACE" 2>/dev/null | grep -q netem; then
      dirty+=" $pid"
    fi
  done <<<"$(_da_targets)"

  if [[ -n "$dirty" ]]; then
    echo "" >&2
    echo "ERROR CRÍTICO: quedó netem puesto en el/los netns:$dirty" >&2
    echo "  El Sistema B está DEGRADADO ahora mismo. Quitarlo a mano en $SSH_HOST:" >&2
    echo "    for id in \$(crictl ps --name $DA_CONTAINER_NAME -q); do" >&2
    echo "      pid=\$(crictl inspect -o go-template --template '{{.info.pid}}' \$id)" >&2
    echo "      nsenter -t \$pid -n tc qdisc del dev $NETEM_IFACE root" >&2
    echo "    done" >&2
    return 1
  fi
  echo "    Verificado: no quedó netem en ningún netns de $DA_CONTAINER_NAME."
  return 0
}

_cleanup() {
  local rc=$?
  echo ""
  echo "--- Limpieza: quitando netem y parando el driver ---"
  _driver_stop
  _netem_clear
  # Si el netem sobrevive a la limpieza, el exit code TIENE que reflejarlo
  # aunque el escenario en sí haya salido bien: dejar el sistema degradado es
  # peor que un escenario fallido, y el orquestador de 12h solo mira el rc.
  if ! _netem_verify_gone; then
    rc=1
  fi
  [[ -n "${region_id:-}" ]] && grafana_annotate_region_end "$region_id"
  exit "$rc"
}

driver_pid=""
_driver_stop() {
  if [[ -n "$driver_pid" ]] && kill -0 "$driver_pid" 2>/dev/null; then
    kill "$driver_pid" 2>/dev/null || true
    wait "$driver_pid" 2>/dev/null || true
  fi
}

# _driver — genera reportes en loop desde el NODO (la ClusterIP de early-warning
# no es ruteable desde esta máquina). Cada ronda manda REPORT_CONCURRENCY
# requests en paralelo para que los fallos consecutivos se acumulen rápido.
_driver() {
  _sudo_run "end=\$(( \$(date +%s) + $DURATION + 20 ));
  while [ \$(date +%s) -lt \$end ]; do
    i=0
    while [ \$i -lt $REPORT_CONCURRENCY ]; do
      curl -s -o /dev/null --max-time $REPORT_TIMEOUT -X POST \
        'http://${EW_SVC}/reports/generate?project_id=${REPORT_PROJECT}&period=daily' &
      i=\$(( i + 1 ))
    done
    wait
  done" >/dev/null 2>&1 || true
}

echo ""
echo "--- Snapshot pre-fallo (incluye estado de breakers) ---"
pre_snapshot=$(snapshot_counters "${LABEL}-pre")
cat "$pre_snapshot"
prom_query_raw 'ew_circuit_breaker_state' "$RESULTS_DIR/${LABEL}-pre-breakers.json"

region_id=$(grafana_annotate_region_start \
  "Chaos · netem-delay-ew-da (${DELAY_MS}ms, ${DURATION}s)" "chaos" "netem-delay-ew-da" "sistema-B")
trap _cleanup EXIT INT TERM

echo ""
echo "--- Arrancando driver de reportes (ejercita el breaker y crea la serie del gauge) ---"
_driver &
driver_pid=$!

echo "--- Inyectando latencia (tc netem delay ${DELAY_MS}ms, scope=$NETEM_SCOPE) en ${#injected_pids[@]} pod(s) ---"
fail_start=$(date +%s)
for pid in "${injected_pids[@]}"; do
  if [[ "$NETEM_SCOPE" == "all" ]]; then
    inject_cmd="nsenter -t $pid -n tc qdisc add dev $NETEM_IFACE root netem delay ${DELAY_MS}ms"
  else
    # prio con priomap todo-ceros: TODO el tráfico por defecto (incluidas las
    # respuestas a las probes de kubelet en :8080) cae en la banda 1:1, que no
    # tiene netem. Solo lo que matchea el filtro va a 1:4, que sí lo tiene.
    # Sin el priomap explícito, el default reparte por TOS y parte del tráfico
    # caería en la banda con delay — degradando las probes sin querer, que es
    # justo lo que este scope evita.
    # match ip sport 50051 = paquetes que SALEN del servidor gRPC, o sea las
    # respuestas a Early Warning. El request de ida no se toca: alcanza con
    # demorar una pata para que el RTT supere el timeout.
    inject_cmd="nsenter -t $pid -n tc qdisc add dev $NETEM_IFACE root handle 1: prio bands 4 priomap 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 && \
nsenter -t $pid -n tc qdisc add dev $NETEM_IFACE parent 1:4 handle 40: netem delay ${DELAY_MS}ms && \
nsenter -t $pid -n tc filter add dev $NETEM_IFACE protocol ip parent 1: prio 1 u32 match ip sport $DA_GRPC_PORT 0xffff flowid 1:4"
  fi
  if ! _sudo_run "$inject_cmd" >/dev/null 2>&1; then
    echo "ERROR: falló 'tc qdisc add' en el netns del pid $pid — la latencia NO fue inyectada." >&2
    exit 1
  fi
done
echo "    Delay aplicado. Verificando qdisc:"
for pid in "${injected_pids[@]}"; do
  echo -n "      pid=$pid: "
  _sudo_run "nsenter -t $pid -n tc qdisc show dev $NETEM_IFACE" 2>/dev/null | head -1
done

echo ""
echo "--- Sondeando ew_circuit_breaker_state{target=\"data-analysis\"} cada 5s ---"
poll_end=$(( fail_start + DURATION ))
opened_at=""
poll_errs=0
while [[ "$(date +%s)" -lt "$poll_end" ]]; do
  state=$(prom_query 'max(ew_circuit_breaker_state{target="data-analysis"})')
  echo "  t+$(( $(date +%s) - fail_start ))s: breaker_state=$state (0=closed 1=open 2=half_open, NaN=serie inexistente, ERR=fallo de Prometheus)"
  if [[ "$state" == "ERR" ]]; then
    poll_errs=$((poll_errs + 1))
  elif [[ "$state" == "1" && -z "$opened_at" ]]; then
    opened_at=$(( $(date +%s) - fail_start ))
    echo "  -> circuito ABIERTO a los ${opened_at}s"
  fi
  sleep 5
done
if [[ "$poll_errs" -gt 0 ]]; then
  echo "  AVISO: $poll_errs consultas fallaron (Prometheus/python) — 'nunca abrió' podría ser falso negativo." >&2
fi

echo ""
echo "--- Quitando la latencia (fin de la ventana de fallo) ---"
_netem_clear
_netem_verify_gone || exit 1
_driver_stop
driver_pid=""

echo "--- Esperando a que el circuito cierre (MTTR) ---"
# El driver sigue hace falta para que el breaker pase por half-open y cierre:
# sin llamadas, el gauge no se actualiza nunca y el MTTR sería un timeout falso.
_driver &
driver_pid=$!
set +e
mttr=$(wait_for_breaker_closed "data-analysis" 120)
mttr_status=$?
set -e
_driver_stop
driver_pid=""

if [[ "$mttr" == "ERR_PROM_UNREACHABLE" ]]; then
  echo "MTTR (breaker vuelve a closed): NO SE PUDO DETERMINAR — Prometheus/python inalcanzable." >&2
elif [[ "$mttr_status" -ne 0 ]]; then
  echo "MTTR (breaker vuelve a closed): ${mttr} — TIMEOUT REAL, el breaker no cerró en 120s." >&2
else
  echo "MTTR (breaker vuelve a closed): ${mttr}s"
fi

echo ""
echo "--- Snapshot post-recuperacion ---"
post_snapshot=$(snapshot_counters "${LABEL}-post")
cat "$post_snapshot"

echo ""
echo "=== Resumen (sistema-B) ==="
echo "Delay inyectado:              ${DELAY_MS}ms (timeout por llamada ${DA_TIMEOUT_MS}ms, umbral ${FAIL_THRESHOLD} fallos)"
echo "Circuito abierto a los:       ${opened_at:-nunca}s"
echo "MTTR (breaker cierra):        ${mttr}"
echo "Continuidad operativa: revisar ew_alerts_published_total durante la ventana —"
echo "  debe seguir creciendo (umbral simple) aunque el breaker esté abierto (CLAUDE.md §2.3)."
echo "Ver snapshots en: $pre_snapshot / $post_snapshot"
echo "Nota: el driver deja filas de reporte con project_id='${REPORT_PROJECT}' en la DB de EW."

# Si el breaker NUNCA abrió con un delay > timeout, o no cerró después, es una
# falla real del escenario o de la resiliencia: exit != 0 para que se note.
if [[ -z "$opened_at" ]]; then
  echo "ERROR: el breaker nunca abrió pese a un delay (${DELAY_MS}ms) mayor al timeout (${DA_TIMEOUT_MS}ms)." >&2
  echo "  Revisar que el driver esté llegando a EW y que EW realmente llame a data-analysis." >&2
  exit 1
fi
if [[ "$mttr" != "ERR_PROM_UNREACHABLE" && "$mttr_status" -ne 0 ]]; then
  exit 1
fi
