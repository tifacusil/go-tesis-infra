#!/usr/bin/env bash
# pause-data-management.sh — congela (SIGSTOP, no mata) UNA instancia de
# data-management y mide el blast radius al cliente: ¿el balanceador desvía el
# tráfico a la instancia sana, y en cuánto tiempo?
#
# SIGSTOP y no SIGKILL a propósito: un proceso muerto cierra sus sockets y el
# balanceador lo detecta al instante (connection refused). Uno congelado sigue
# con el puerto abierto — el kernel acepta el TCP igual — y nunca responde. Es
# el caso peor y el más realista (GC pausado, deadlock, disco colgado), y es el
# que distingue de verdad a un balanceador de otro.
#
# ── Qué mide en cada sistema (no es lo mismo, y ese es el punto) ─────────────
#   - Sistema A (native): nginx round-robin entre 127.0.0.1:8082 y :8086, con
#     `max_fails=3 fail_timeout=10s`. Detección PASIVA: nginx solo se entera de
#     que un upstream está mal cuando un request falla. Y acá no puede: el
#     proxy_connect_timeout es 5s pero NO hay proxy_read_timeout, así que rige
#     el default de 60s. Cada request a la instancia congelada cuelga 60s, y
#     max_fails jamás acumula 3 fallos dentro de una ventana de 10s. Se espera
#     que ~la mitad de los requests (round-robin) cuelguen toda la pausa.
#   - Sistema B (k8s): readiness probe (timeout 5s, period 10s, threshold 3) =>
#     el pod sale de los Endpoints recién a los ~35s. Detección ACTIVA y fuera
#     del path del request, pero MÁS LENTA que la de nginx. A los ~45s el
#     liveness (3x15s) además mata el contenedor y kubelet lo reinicia.
#
# DURATION default = 90s. Antes era 40s, elegido para que B desviara el tráfico
# (~30s estimados) sin cruzar liveness (~45s) — pero medido resultó que B recién
# sale de Endpoints a los ~35s, así que 40s caía en una zona muerta: B no
# alcanzaba a demostrar recuperación y el resumen decía "nunca desvió", que era
# un artefacto de la ventana, no del sistema.
#
# Con 90s se ve la secuencia completa de B: fallos -> readiness lo saca de
# Endpoints (~35s) -> liveness lo reinicia (~45s) -> pod nuevo Ready. En A,
# nginx marca el upstream caído a los ~17s (max_fails=3 en ventana de 10s) y
# nunca reinicia nada. Ojo al comparar: en A se mide "el balanceador desvía", en
# B se termina midiendo "k8s se auto-repara" — son mecanismos distintos, y esa
# diferencia ES el resultado, no un defecto del experimento.
#
# El fallo se inyecta EN el servidor remoto (ninguno de los dos expone su
# runtime a esta máquina; A ni siquiera usa contenedores).
#
# Uso (Sistema B):
#   SSH_HOST=178.105.104.95 SSH_USER=gotesis SSH_KEY_PATH=~/.ssh/gotesis-key \
#     SUDO_PASSWORD=*** SSH_ORCHESTRATOR=k8s \
#     PROMETHEUS_ADDR=http://178.105.104.95:31083 \
#     ./chaos/pause-data-management.sh [duration_seconds] [gateway_url]
#
# Uso (Sistema A):
#   SSH_HOST=204.168.203.32 SSH_USER=concurso SSH_KEY_PATH=~/.ssh/concurso-key \
#     SUDO_PASSWORD=*** SSH_ORCHESTRATOR=native \
#     PROMETHEUS_ADDR=http://204.168.203.32:9090 \
#     ./chaos/pause-data-management.sh [duration_seconds] [gateway_url]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/capture.sh"
source "$SCRIPT_DIR/lib/ssh.sh"
source "$SCRIPT_DIR/lib/gateway-tunnel.sh"
source "$SCRIPT_DIR/../load-tests/lib/grafana-annotate.sh"

DURATION="${1:-90}"
LABEL="pause-data-management"
DM_UNIT="${DM_UNIT:-data-management@8082}"        # Sistema A: instancia a congelar
DM_CONTAINER_NAME="${DM_CONTAINER_NAME:-data-management}" # Sistema B
DM_SELECTOR="${DM_SELECTOR:-app=data-management}"  # Sistema B
PROBE_INTERVAL="${PROBE_INTERVAL:-1}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-3}"

if ! [[ "$DURATION" =~ ^[0-9]+$ ]]; then
  echo "ERROR: duration_seconds debe ser un entero, recibido: '$DURATION'" >&2
  exit 1
fi

_ssh_require
case "$SSH_ORCHESTRATOR" in
  k8s|native) ;;
  *)
    echo "ERROR: SSH_ORCHESTRATOR='$SSH_ORCHESTRATOR' inválido — usar 'k8s' (Sistema B) o 'native' (Sistema A)." >&2
    exit 1
    ;;
esac

if [[ "$SSH_ORCHESTRATOR" == "k8s" ]]; then
  SYSTEM_TAG="sistema-B"
  DEFAULT_HEALTH_PATH="/api/v1/data/health"   # IngressRoute de Traefik (PathPrefix)
  if [[ "$DURATION" -lt 50 ]]; then
    echo "AVISO: DURATION=${DURATION}s — en B la readiness recién saca el pod de Endpoints a los ~35s" >&2
    echo "  (timeout 5s x threshold 3, period 10s). Con menos de ~50s no le da tiempo a desviar el" >&2
    echo "  tráfico y propagarlo a Traefik: el resumen diría 'nunca desvió' por la ventana corta, no" >&2
    echo "  porque el sistema no lo haga. Usar DURATION >= 50 (default 90)." >&2
  fi
else
  SYSTEM_TAG="sistema-A"
  DEFAULT_HEALTH_PATH="/health/data-management"  # nginx: proxy_pass a upstream data_management
fi

# GATEWAY_URL: explícito > env > directo contra SSH_HOST > túnel SSH.
# Los dos gateways son alcanzables directo desde afuera (A: nginx :80,
# B: Traefik LoadBalancer con EXTERNAL-IP en el nodo), así que el túnel quedó
# como fallback y no como el camino normal: agrega latencia y un proceso más
# que puede morir a mitad de la ventana de sondeo.
GATEWAY_HEALTH_PATH="${GATEWAY_HEALTH_PATH:-$DEFAULT_HEALTH_PATH}"
_explicit_url="${2:-${GATEWAY_URL:-}}"
if [[ -n "$_explicit_url" ]]; then
  GATEWAY_URL="$_explicit_url"
else
  GATEWAY_URL="http://${SSH_HOST}${GATEWAY_HEALTH_PATH}"
fi

_probe_code() {
  local code
  # curl ya imprime 000 por -w cuando no hay respuesta (timeout, conn refused),
  # y ademas sale con rc!=0. Un `|| echo 000` encadenado imprimiria AMBOS y el
  # log mostraba "http_code=000000". Se captura y se usa 000 solo si quedo vacio.
  code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout "$PROBE_TIMEOUT" \
    --max-time "$PROBE_TIMEOUT" "$GATEWAY_URL" 2>/dev/null) || true
  echo "${code:-000}"
}

# Pre-check: si el gateway no responde 200 ANTES de inyectar, todos los probes
# fallarían por alcance/URL (no por blast radius) y la medición sería basura
# con aspecto de resultado.
_pre_code=$(_probe_code)
if [[ "$_pre_code" != "200" ]]; then
  echo "  (gateway directo $GATEWAY_URL -> $_pre_code; intentando túnel SSH...)" >&2
  if resolve_gateway_url "" && [[ "$(_probe_code)" == "200" ]]; then
    echo "  (gateway vía túnel: $GATEWAY_URL)"
  else
    echo "ERROR: pre-check del gateway falló (http_code=$_pre_code contra $GATEWAY_URL) — no se inyecta el fallo." >&2
    echo "  Verificar GATEWAY_URL / GATEWAY_HEALTH_PATH (A: /health/data-management, B: /api/v1/data/health)." >&2
    exit 1
  fi
fi
echo "Pre-check gateway OK (200): $GATEWAY_URL"

echo "=== Escenario: pause data-management ($SYSTEM_TAG, ${DURATION}s) ==="
echo "    Servidor:  $SSH_USER@$SSH_HOST"

# _target_pid — PID en el HOST del proceso a congelar.
#   - native: MainPID de la unidad systemd.
#   - k8s:    PID del contenedor via crictl. OJO: hay que usar el go-template
#             {{.info.pid}}; parsear el primer '"pid":' del JSON devuelve 1 (el
#             PID dentro del namespace del contenedor) y congelaríamos el PID 1
#             del HOST, es decir systemd/init del nodo entero.
if [[ "$SSH_ORCHESTRATOR" == "native" ]]; then
  target_pid=$(_sudo_run "systemctl show $DM_UNIT -p MainPID --value" 2>/dev/null | tr -d '\r')
  target_desc="unit $DM_UNIT"
else
  read -r target_pid target_ip <<<"$(_sudo_run "
    id=\$(crictl ps --name $DM_CONTAINER_NAME -q | head -1)
    [ -n \"\$id\" ] || exit 0
    pid=\$(crictl inspect -o go-template --template '{{.info.pid}}' \$id 2>/dev/null)
    ip=\$(nsenter -t \$pid -n ip -4 -o addr show dev eth0 2>/dev/null | grep -oE 'inet [0-9.]+' | cut -d' ' -f2)
    echo \"\$pid \$ip\"" 2>/dev/null | tr -d '\r')"
  target_desc="pod ip $target_ip"
fi

if [[ -z "${target_pid:-}" || "$target_pid" == "0" || "$target_pid" == "1" ]]; then
  echo "ERROR: no se resolvió un PID válido para data-management (obtenido: '${target_pid:-vacío}')." >&2
  echo "  PID 1 o vacío significa que la resolución falló: congelarlo pausaría init del nodo." >&2
  exit 1
fi

# En B, validar que el PID sea de un pod real y no del host: si el netns del
# PID no tiene una IP de pod de data-management, abortar.
if [[ "$SSH_ORCHESTRATOR" == "k8s" ]]; then
  pod_ips=$(_kubectl get pods -l "$DM_SELECTOR" -n "$K8S_NAMESPACE" \
    -o 'jsonpath={range .items[*]}{.status.podIP}{"\n"}{end}' 2>/dev/null || true)
  if [[ -z "$target_ip" ]] || ! grep -qx "$target_ip" <<<"$pod_ips"; then
    echo "ERROR: el netns del PID $target_pid tiene IP '${target_ip:-<ninguna>}', que no es de ningún pod" >&2
    echo "  de data-management (pods: $(tr '\n' ' ' <<<"$pod_ips")). Abortando por seguridad." >&2
    exit 1
  fi
fi
echo "    Target:    pid=$target_pid ($target_desc)"

# _resume — SIGCONT idempotente. Va SIEMPRE por trap: si el script muere con el
# proceso congelado, esa instancia queda frizada para siempre y, en A, la mitad
# del tráfico colgando 60s por request. Es el mismo error que ya cometimos
# dejando netem puesto en producción — acá no se repite.
_resumed="false"
_resume() {
  [[ "$_resumed" == "true" ]] && return 0
  _sudo_run "kill -CONT $target_pid 2>/dev/null || true" >/dev/null 2>&1 || true
  _resumed="true"
}

_cleanup() {
  local rc=$?
  _resume
  [[ -n "${region_id:-}" ]] && grafana_annotate_region_end "$region_id"
  gateway_tunnel_cleanup
  exit "$rc"
}

echo ""
echo "--- Snapshot pre-fallo ---"
pre_snapshot=$(snapshot_counters "${LABEL}-pre")
cat "$pre_snapshot"

region_id=$(grafana_annotate_region_start \
  "Chaos · pause-data-management (${DURATION}s)" "chaos" "pause-data-management" "$SYSTEM_TAG")
trap _cleanup EXIT INT TERM

echo ""
echo "--- Congelando data-management (SIGSTOP a pid $target_pid) por ${DURATION}s ---"
fail_start=$(date +%s)
if ! _sudo_run "kill -STOP $target_pid" >/dev/null 2>&1; then
  echo "ERROR: 'kill -STOP $target_pid' falló — el fallo NO se inyectó." >&2
  exit 1
fi
# Confirmar por el estado real del proceso ('T' = stopped en /proc/<pid>/stat),
# no por el rc de kill: kill devuelve 0 aunque la señal no cambie nada.
proc_state=$(_sudo_run "awk '{print \$3}' /proc/$target_pid/stat 2>/dev/null" 2>/dev/null | tr -d '\r')
if [[ "$proc_state" != "T" ]]; then
  echo "ERROR: el pid $target_pid no quedó en estado 'T' (stopped), sino '${proc_state:-desconocido}'." >&2
  exit 1
fi
echo "    Confirmado: pid $target_pid en estado T (stopped)."

echo ""
echo "--- Sondeando $GATEWAY_URL cada ${PROBE_INTERVAL}s (blast radius al cliente) ---"
ok_count=0
fail_count=0
first_fail_at=""
recovered_at=""
consecutive_ok=0
probe_end=$(( fail_start + DURATION ))
while [[ "$(date +%s)" -lt "$probe_end" ]]; do
  t=$(( $(date +%s) - fail_start ))
  code=$(_probe_code)
  if [[ "$code" == "200" ]]; then
    ok_count=$((ok_count + 1))
    consecutive_ok=$((consecutive_ok + 1))
    # 5 OK seguidos DESPUÉS de haber visto fallos = el balanceador dejó de
    # mandar tráfico a la instancia congelada. Se piden 5 y no 1 porque con
    # round-robin un OK suelto solo significa "esta vez tocó la sana".
    if [[ -n "$first_fail_at" && -z "$recovered_at" && "$consecutive_ok" -ge 5 ]]; then
      recovered_at="$t"
      echo "  -> t+${t}s: tráfico desviado (5 OK seguidos tras fallos)"
    fi
  else
    fail_count=$((fail_count + 1))
    consecutive_ok=0
    if [[ -z "$first_fail_at" ]]; then
      first_fail_at="$t"
      echo "  -> t+${t}s: primer fallo (http_code=$code)"
    fi
  fi
  sleep "$PROBE_INTERVAL"
done

echo ""
echo "--- Descongelando (SIGCONT) ---"
_resume
sleep 5
post_code=$(_probe_code)
echo "    Gateway tras descongelar: $post_code"

echo "--- Snapshot post-recuperacion ---"
post_snapshot=$(snapshot_counters "${LABEL}-post")
cat "$post_snapshot"

total=$(( ok_count + fail_count ))
echo ""
echo "=== Resumen blast radius ($SYSTEM_TAG) ==="
echo "Requests OK durante la pausa:      $ok_count / $total"
echo "Requests fallidos durante la pausa: $fail_count / $total"
if [[ "$total" -gt 0 ]]; then
  echo "Tasa de error:                     $(( fail_count * 100 / total ))%"
fi
echo "Primer fallo:                      ${first_fail_at:-nunca}${first_fail_at:+s}"
echo "Tráfico desviado a la instancia sana: ${recovered_at:-nunca}${recovered_at:+s}"
if [[ -z "$first_fail_at" ]]; then
  echo "Blast radius = 0: el balanceador nunca mandó un request a la instancia congelada."
elif [[ -n "$recovered_at" ]]; then
  echo "Blast radius acotado: falló desde t+${first_fail_at}s hasta t+${recovered_at}s, después se recuperó solo."
else
  echo "Blast radius NO acotado: siguió fallando toda la ventana — el balanceador nunca desvió el tráfico."
fi
echo "Ver snapshots en: $pre_snapshot / $post_snapshot"
