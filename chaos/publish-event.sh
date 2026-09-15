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
  local req b64
  req=$(REQ_BODY="$body" REQ_RK="$ALERT_ROUTING_KEY" python3 -c 'import json,os; print(json.dumps({"properties":{},"routing_key":os.environ["REQ_RK"],"payload":os.environ["REQ_BODY"],"payload_encoding":"string"}))')
  b64=$(printf '%s' "$req" | base64 | tr -d '\n')
  _sudo_run "pod=\$(kubectl -n $K8S_NAMESPACE get pod -l $RABBITMQ_SELECTOR -o jsonpath='{.items[0].metadata.name}'); \
kubectl -n $K8S_NAMESPACE exec \$pod -- sh -c 'echo $b64 | base64 -d > /tmp/ap-req.json && \
curl -s -u \"\$RABBITMQ_DEFAULT_USER:\$RABBITMQ_DEFAULT_PASS\" -H content-type:application/json \
-X POST http://localhost:15672/api/exchanges/%2F/$ALERT_EXCHANGE/publish -d @/tmp/ap-req.json'"
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
