#!/usr/bin/env bash
# event.sh — helpers compartidos por publish-event.sh y las pruebas AP5/AP6/AP7:
# publicar lecturas GNSS sintéticas en sensors.raw (como data-receiving), hablar
# con la Management API de RabbitMQ y consultar el MySQL de un servicio.
#
# Requiere haber sourceado lib/ssh.sh (SSH_ORCHESTRATOR, _ssh_run, _sudo_run,
# _kubectl). No fija `set -euo pipefail`: depende del script que lo sourcea.
#
# ── Por qué el evento lleva schema_version y received_at ─────────────────────
# El binding sensors.# entrega cada lectura a DOS colas: early_warning.evaluate
# y data_management.persist. early-warning no valida el contrato, pero
# data-management sí (envelope.schema.json exige schema_version y received_at),
# y un envelope inválido va directo a sensors.dead_letter. La versión anterior
# del evento no los traía: cada evento de prueba mandaba 2 mensajes a la DLQ por
# data-management, y AP7 — cuyo criterio es "+1 en la DLQ" — habría leído +3 y
# fallado por la razón equivocada. Con el envelope completo, data-management
# persiste la lectura y la DLQ solo recibe lo que la prueba provoca a propósito.
#
# Variables:
#   EVENT_PROJECT       default: shangtan (debe existir en los umbrales de EW;
#                       rojo=20 mm/día en A y en B)
#   EVENT_EXCHANGE      default: sensors.raw
#   EVENT_ROUTING_KEY   default: sensors.gnss (matchea el binding sensors.#)
#   RABBITMQ_SELECTOR   default: app=rabbitmq (Sistema B)
#   RABBITMQ_MGMT_USER  Sistema A: usuario de la Management API (obligatorio)
#   RABBITMQ_MGMT_PASS  Sistema A: password de la Management API (obligatorio)
#   RABBITMQ_MGMT_PORT  default: 15672

EVENT_PROJECT="${EVENT_PROJECT:-${ALERT_PROJECT:-shangtan}}"
EVENT_EXCHANGE="${EVENT_EXCHANGE:-${ALERT_EXCHANGE:-sensors.raw}}"
EVENT_ROUTING_KEY="${EVENT_ROUTING_KEY:-${ALERT_ROUTING_KEY:-sensors.gnss}}"
RABBITMQ_SELECTOR="${RABBITMQ_SELECTOR:-app=rabbitmq}"
RABBITMQ_MGMT_PORT="${RABBITMQ_MGMT_PORT:-15672}"
# Mismo valor que publica data-receiving (internal/parsing/parser.go).
EVENT_SCHEMA_VERSION="${EVENT_SCHEMA_VERSION:-1.0}"

_iso_utc() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; }

# rabbit_api <METHOD> <path> [json_body] — llama a la Management API DESDE el
# servidor (no está expuesta a esta máquina) e imprime la respuesta.
#   - B: python3 dentro del pod de RabbitMQ, con las credenciales de su entorno.
#   - A: python3 en el host, contra localhost, con RABBITMQ_MGMT_USER/PASS.
#
# python3 + urllib y no curl: rabbitmq:3.12.1-management-alpine NO trae curl
# (`sh: curl: not found`, verificado en el servidor el 2026-09-15) ni
# rabbitmqadmin; python3 sí, lo usa el propio broker. Con curl el publish no
# ocurría y la prueba concluía por la razón equivocada.
#
# El script Python se arma acá y viaja en base64 (ver rabbit_exec_py): así
# atraviesa ssh -> sudo -> kubectl exec sin escapar comillas en cada nivel. No
# hace falta python local.
_RABBIT_POD=""

# _rabbit_auth_expr — expresión Python que produce el header Basic: en B sale
# del entorno del pod (RABBITMQ_DEFAULT_*), en A de RABBITMQ_MGMT_USER/PASS.
_rabbit_auth_expr() {
  case "$SSH_ORCHESTRATOR" in
    k8s)
      echo 'base64.b64encode((os.environ["RABBITMQ_DEFAULT_USER"] + ":" + os.environ["RABBITMQ_DEFAULT_PASS"]).encode()).decode()'
      ;;
    native)
      if [[ -z "${RABBITMQ_MGMT_USER:-}" || -z "${RABBITMQ_MGMT_PASS:-}" ]]; then
        echo "ERROR: Sistema A requiere RABBITMQ_MGMT_USER y RABBITMQ_MGMT_PASS (Management API en el host)." >&2
        return 1
      fi
      echo "\"$(printf '%s' "${RABBITMQ_MGMT_USER}:${RABBITMQ_MGMT_PASS}" | base64 | tr -d '\n')\""
      ;;
    *)
      echo "ERROR: SSH_ORCHESTRATOR='${SSH_ORCHESTRATOR:-}' — usar 'k8s' (Sistema B) o 'native' (Sistema A)." >&2
      return 1
      ;;
  esac
}

# _rabbit_mgmt_port — puerto de la Management API visto desde donde corre el
# script: dentro del pod es siempre 15672; en el host de A, configurable.
_rabbit_mgmt_port() {
  if [[ "$SSH_ORCHESTRATOR" == "k8s" ]]; then echo 15672; else echo "$RABBITMQ_MGMT_PORT"; fi
}

# rabbit_pod_exec <comando> — ejecuta un comando en el pod de RabbitMQ (B) o en
# el host (A). El comando no debe tener saltos de línea (ver rabbit_exec_py).
rabbit_pod_exec() {
  local cmd="$1"
  if [[ "$SSH_ORCHESTRATOR" == "k8s" ]]; then
    if [[ -z "$_RABBIT_POD" ]]; then
      _RABBIT_POD=$(_sudo_run "kubectl -n $K8S_NAMESPACE get pod -l $RABBITMQ_SELECTOR -o jsonpath='{.items[0].metadata.name}'")
      if [[ -z "$_RABBIT_POD" ]]; then
        echo "ERROR: no se encontró ningún pod de RabbitMQ con el selector '$RABBITMQ_SELECTOR'." >&2
        return 1
      fi
    fi
    _sudo_run "kubectl -n $K8S_NAMESPACE exec $_RABBIT_POD -- $cmd"
  else
    _ssh_run "$cmd"
  fi
}

# rabbit_exec_py <script> — corre un script Python junto al broker.
#
# El script viaja en base64 dentro de un one-liner, NO citado con printf %q.
# %q escribe un texto multilínea como $'...\n...', que es sintaxis de bash;
# _sudo_run lo ejecuta con `sudo sh -c`, y en el servidor sh es dash, que no
# la entiende: python3 recibía el literal "$import ...\n..." y fallaba con
# SyntaxError (encontrado en la primera corrida de AP5, 2026-09-29). El
# one-liner solo tiene [A-Za-z0-9+/=] y comillas simples, que cualquier sh
# interpreta igual.
rabbit_exec_py() {
  local py="$1"
  rabbit_pod_exec "python3 -u -c 'import base64; exec(base64.b64decode(\"$(printf '%s' "$py" | base64 | tr -d '\n')\"))'"
}

rabbit_api() {
  local method="$1" path="$2" body="${3:-}"
  local b64="" auth_expr
  [[ -n "$body" ]] && b64=$(printf '%s' "$body" | base64 | tr -d '\n')
  auth_expr=$(_rabbit_auth_expr) || return 1

  local py
  py=$(cat <<PYEOF
import base64, os, sys, urllib.error, urllib.request
b64 = "$b64"
data = base64.b64decode(b64) if b64 else None
auth = $auth_expr
r = urllib.request.Request("http://127.0.0.1:$(_rabbit_mgmt_port)$path", data=data, method="$method",
    headers={"Content-Type": "application/json", "Authorization": "Basic " + auth})
try:
    print(urllib.request.urlopen(r, timeout=15).read().decode())
except urllib.error.HTTPError as e:
    print("HTTP %d: %s" % (e.code, e.read().decode()[:300]), file=sys.stderr)
    sys.exit(1)
PYEOF
)
  rabbit_exec_py "$py"
}

# event_reading_json <message_id> <sensor_id> <epoch> <cumulative_mm> — un
# envelope GNSS válido para los DOS consumidores (ver cabecera).
event_reading_json() {
  local mid="$1" sensor="$2" epoch="$3" cum="$4"
  printf '{"schema_version":"%s","message_id":"%s","project_id":"%s","sensor_id":"%s","sensor_type":"gnss","timestamp":"%s","received_at":"%s","payload":{"fix_quality":"rtk_fixed","cumulative_displacement_mm":%s}}' \
    "$EVENT_SCHEMA_VERSION" "$mid" "$EVENT_PROJECT" "$sensor" "$(_iso_utc "$epoch")" "$(_iso_utc "$(date +%s)")" "$cum"
}

# event_publish <json_body> — publica en EVENT_EXCHANGE y verifica que el broker
# lo haya ENRUTADO. La Management API devuelve {"routed":false} cuando ninguna
# cola matchea la routing key: antes eso pasaba en silencio y la prueba seguía
# esperando un evento que nunca llegó a ningún consumidor.
event_publish() {
  local body="$1"
  # El body es JSON armado acá (sin backslashes ni saltos de línea): alcanza con
  # escapar las comillas para meterlo como string en el request.
  local esc="${body//\"/\\\"}"
  local req="{\"properties\":{\"delivery_mode\":2,\"content_type\":\"application/json\"},\"routing_key\":\"${EVENT_ROUTING_KEY}\",\"payload\":\"${esc}\",\"payload_encoding\":\"string\"}"
  local resp
  resp=$(rabbit_api POST "/api/exchanges/%2F/${EVENT_EXCHANGE}/publish" "$req") || true
  if ! grep -qE '"routed"[[:space:]]*:[[:space:]]*true' <<<"$resp"; then
    echo "ERROR: el broker no enrutó la lectura (exchange=${EVENT_EXCHANGE} rk=${EVENT_ROUTING_KEY})." >&2
    echo "  Respuesta de la Management API: ${resp:-<vacía>}" >&2
    echo "  Si es {\"routed\":false}: ninguna cola matchea la routing key en este sistema (EVENT_ROUTING_KEY)." >&2
    return 1
  fi
}

# event_publish_pair <event_id> [skip_baseline] — el evento representativo:
# lectura base (0 mm, hace 60 s) y lectura de alerta (+100 mm, ahora).
# speed = 100/60*86400 = 144000 mm/día, muy por encima del rojo (20).
# Los message_id son <event_id>-a y <event_id>-b; sensor_id = <event_id>, así
# que las filas y logs del evento se filtran sin ambigüedad aun con carga.
# Deja el envelope de la alerta en EVENT_ALERT_BODY, para reinyectarlo idéntico.
event_publish_pair() {
  local event_id="$1" skip_baseline="${2:-0}"
  local now; now=$(date +%s)
  if [[ "$skip_baseline" != "1" ]]; then
    event_publish "$(event_reading_json "${event_id}-a" "$event_id" "$(( now - 60 ))" "0.0")" || return 1
    # La línea base tiene que estar en Redis antes de la segunda lectura: si
    # llegan juntas, la segunda se evalúa contra previous=nil y no alerta.
    sleep 2
  fi
  EVENT_ALERT_BODY=$(event_reading_json "${event_id}-b" "$event_id" "$now" "100.0")
  event_publish "$EVENT_ALERT_BODY"
}

# rabbit_queue_messages <queue> — mensajes (ready + unacked) en una cola.
rabbit_queue_messages() {
  local queue="$1" resp
  resp=$(rabbit_api GET "/api/queues/%2F/${queue}?columns=messages") || return 1
  grep -oE '"messages"[[:space:]]*:[[:space:]]*[0-9]+' <<<"$resp" | head -1 | grep -oE '[0-9]+$'
}

# mysql_query <pod> <sql> — ejecuta SQL como root en el pod MySQL de un servicio
# (Sistema B) y devuelve filas sin cabecera, separadas por tab. La contraseña se
# expande DENTRO del pod: nunca pasa por esta máquina.
mysql_query() {
  local pod="$1" sql="$2"
  _kubectl -n "$K8S_NAMESPACE" exec "$pod" -- sh -c \
    "mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" -N -B --delimiter=// -e \"$sql\" 2>&1 | grep -v 'Using a password on the command line'"
}

# service_logs_since <app_label> <epoch> — logs de TODAS las réplicas de un
# servicio desde un instante, con el pod como prefijo. --tail=-1 es obligatorio:
# con un selector, kubectl devuelve solo 10 líneas por pod por defecto.
service_logs_since() {
  local app="$1" since="$2"
  _kubectl -n "$K8S_NAMESPACE" logs -l "app=$app" --since-time="$(_iso_utc "$since")" \
    --tail=-1 --prefix --max-log-requests=10 2>/dev/null
}

# count_events <archivo_log> <evento> <trace_id> — líneas JSON con ese evento
# ("msg") y ese trace_id.
count_events() {
  local file="$1" event="$2" trace="$3"
  grep -F "\"msg\":\"$event\"" "$file" 2>/dev/null | grep -cF "\"trace_id\":\"$trace\"" || true
}
