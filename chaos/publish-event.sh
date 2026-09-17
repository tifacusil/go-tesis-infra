#!/usr/bin/env bash
# publish-event.sh — publica UN evento representativo (un par de lecturas GNSS
# que cruza umbral y genera una alerta) en la cola de Early Warning, sin loop.
#
# Existe para AP5/AP6/AP7, que necesitan inyectar un evento puntual y no una
# corriente de ellos: netem-delay-ew-um.sh publica en loop mientras dura la
# inyeccion, que sirve para abrir el breaker pero no para medir un evento
# aislado ni para reinyectar un message_id concreto.
#
# Como fuerza la alerta: EW calcula
#   speed_mm_dia = (cum2 - cum1) / dt_segundos * 86400
# La primera lectura solo fija la linea base (previous_none). La segunda, 60s
# despues y con +100mm, da 100/60*86400 = 144000 mm/dia, muy por encima del
# umbral rojo de shangtan (20).
#
# Uso:
#   # Evento nuevo (AP5, AP7): message_id autogenerado
#   ./chaos/publish-event.sh
#
#   # Reinyectar un message_id EXACTO (AP6): mismo id => debe deduplicarse
#   ./chaos/publish-event.sh ap6-1789481234
#
#   # Solo la segunda lectura, sin volver a fijar la linea base (AP6 paso 4)
#   SKIP_BASELINE=1 ./chaos/publish-event.sh ap6-1789481234
#
# Imprime el message_id usado, que es lo que hay que registrar en la evidencia.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/ssh.sh"

EVENT_ID="${1:-ap-$(date +%s)}"
ALERT_PROJECT="${ALERT_PROJECT:-shangtan}"
ALERT_EXCHANGE="${ALERT_EXCHANGE:-sensors.raw}"
ALERT_ROUTING_KEY="${ALERT_ROUTING_KEY:-sensors.gnss}"
RABBITMQ_SELECTOR="${RABBITMQ_SELECTOR:-app=rabbitmq}"
SKIP_BASELINE="${SKIP_BASELINE:-0}"

_ssh_require

# En modo local el orquestador es k8s por definicion: _ssh_require ya verifico
# que kubectl hable con el cluster, asi que exigir la variable seria ruido.
[[ "$CHAOS_LOCAL" == "1" ]] && SSH_ORCHESTRATOR="${SSH_ORCHESTRATOR:-k8s}"
if [[ "$SSH_ORCHESTRATOR" != "k8s" ]]; then
  echo "ERROR: solo implementado para el Sistema B (SSH_ORCHESTRATOR=k8s)." >&2
  exit 1
fi

# Identico a _amqp_publish de netem-delay-ew-um.sh: el request se arma ACA y
# viaja en base64, porque armarlo dentro del pod obligaria a escapar comillas a
# traves de ssh -> sudo -> kubectl exec -> sh -c. No se usa rabbitmqadmin: es un
# script Python que la imagen -alpine no trae.
_amqp_publish() {
  local body="$1"
  # Se publica por la HTTP Management API usando python3 DENTRO del pod.
  #
  # No con rabbitmqadmin: es un script Python que la imagen -alpine no trae.
  # Tampoco con curl: la imagen rabbitmq:3.12.1-management-alpine TAMPOCO lo
  # trae (`sh: curl: not found`, verificado en el servidor el 2026-09-15). La
  # version anterior de esta funcion usaba curl y fallaba en silencio: el
  # publish no ocurria, no habia alertas, y el escenario concluia "el breaker
  # no abrio" por la razon equivocada. python3 si esta (/usr/bin/python3), el
  # propio broker lo usa.
  #
  # El request se arma ACA y viaja en base64: armarlo dentro del pod obligaria
  # a escapar comillas a traves de ssh -> sudo -> kubectl exec -> sh -c, cuatro
  # niveles anidados que se rompen con cualquier caracter del payload. base64
  # atraviesa todas esas capas sin escapar nada.
  local req b64 pod
  req=$(REQ_BODY="$body" REQ_RK="$ALERT_ROUTING_KEY" python3 -c 'import json,os; print(json.dumps({"properties":{},"routing_key":os.environ["REQ_RK"],"payload":os.environ["REQ_BODY"],"payload_encoding":"string"}))' 2>/dev/null)
  # Si python3 local falla (no instalado, o el stub de Microsoft Store en
  # Windows, que existe en PATH y no ejecuta nada), req queda vacio. Sin este
  # chequeo el script seguiria y "publicaria" un request vacio: el broker
  # responderia un error que nadie mira y el escenario concluiria que no hubo
  # alertas, por la razon equivocada.
  if [[ -z "$req" ]]; then
    echo "ERROR: no se pudo armar el request — python3 no ejecutable en esta maquina." >&2
    echo "  Se necesita python3 LOCAL para serializar el JSON antes de enviarlo." >&2
    return 1
  fi
  b64=$(printf '%s' "$req" | base64 | tr -d '\n')

  pod=$(_sudo_run "kubectl -n $K8S_NAMESPACE get pod -l $RABBITMQ_SELECTOR -o jsonpath='{.items[0].metadata.name}'")
  if [[ -z "$pod" ]]; then
    echo "ERROR: no se encontro ningun pod de RabbitMQ con el selector '$RABBITMQ_SELECTOR'." >&2
    return 1
  fi

  # El exchange se interpola en el script Python en vez de pasarse por entorno:
  # `kubectl exec` no tiene --env, y exportarlo del lado del pod requeriria otro
  # nivel de sh -c.
  local py
  py=$(cat <<PYEOF
import base64, json, os, sys, urllib.error, urllib.request
req = base64.b64decode("$b64").decode()
u = os.environ["RABBITMQ_DEFAULT_USER"]; p = os.environ["RABBITMQ_DEFAULT_PASS"]
auth = base64.b64encode(f"{u}:{p}".encode()).decode()
r = urllib.request.Request(
    "http://localhost:15672/api/exchanges/%2F/$ALERT_EXCHANGE/publish",
    data=req.encode(), method="POST",
    headers={"Content-Type": "application/json", "Authorization": "Basic " + auth})
try:
    print(urllib.request.urlopen(r, timeout=15).read().decode())
except urllib.error.HTTPError as e:
    print(f"HTTP {e.code}: {e.read().decode()[:200]}", file=sys.stderr)
    sys.exit(1)
PYEOF
)
  # La respuesta se devuelve tal cual: {"routed":true} confirma que el mensaje
  # entro a una cola. Un {"routed":false} significa que el binding no matcheo la
  # routing key, y eso hay que verlo, no tragarselo.
  _sudo_run "kubectl -n $K8S_NAMESPACE exec $pod -- python3 -c $(printf '%q' "$py")"
}

sensor="${EVENT_ID}"
t1=$(date -u -d "@$(( $(date +%s) - 60 ))" '+%Y-%m-%dT%H:%M:%SZ')
t2=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

echo "=== Evento representativo (Sistema B) ==="
echo "    message_id base:  ${EVENT_ID}-a"
echo "    message_id alerta: ${EVENT_ID}-b   <- el que se reinyecta en AP6"
echo "    project_id:       ${ALERT_PROJECT}"
echo "    sensor_id:        ${sensor}"

if [[ "$SKIP_BASELINE" != "1" ]]; then
  echo "--- Lectura 1/2 (fija la linea base, no alerta) ---"
  _amqp_publish "{\"message_id\":\"${EVENT_ID}-a\",\"project_id\":\"${ALERT_PROJECT}\",\"sensor_id\":\"${sensor}\",\"sensor_type\":\"gnss\",\"timestamp\":\"${t1}\",\"payload\":{\"fix_quality\":\"rtk_fixed\",\"cumulative_displacement_mm\":0.0}}"
  # La linea base tiene que estar escrita en Redis ANTES de la segunda lectura:
  # si llegan juntas, la segunda puede evaluarse contra previous=nil y salir como
  # previous_none, sin alerta.
  sleep 2
else
  echo "--- Lectura 1/2 OMITIDA (SKIP_BASELINE=1) ---"
fi

echo "--- Lectura 2/2 (+100mm en 60s => ~144000 mm/dia, cruza rojo) ---"
_amqp_publish "{\"message_id\":\"${EVENT_ID}-b\",\"project_id\":\"${ALERT_PROJECT}\",\"sensor_id\":\"${sensor}\",\"sensor_type\":\"gnss\",\"timestamp\":\"${t2}\",\"payload\":{\"fix_quality\":\"rtk_fixed\",\"cumulative_displacement_mm\":100.0}}"

echo ""
echo "Publicado. Para la evidencia, registrar: message_id=${EVENT_ID}-b  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "Verificar que alerto:"
echo "  kubectl -n $K8S_NAMESPACE logs -l app=early-warning --tail=100 | grep ${EVENT_ID}"
