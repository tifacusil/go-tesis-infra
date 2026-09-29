#!/usr/bin/env bash
# publish-event.sh — publica UN evento representativo (un par de lecturas GNSS
# que cruza umbral y genera una alerta) en sensors.raw, sin loop.
#
# Existe para AP5/AP6/AP7, que necesitan inyectar un evento puntual y no una
# corriente de ellos: netem-delay-ew-um.sh publica en loop mientras dura la
# inyeccion, que sirve para abrir el breaker pero no para medir un evento
# aislado ni para reinyectar un message_id concreto. Las pruebas ap5-*.sh,
# ap6-*.sh y ap7-*.sh usan la misma logica (lib/event.sh) y ademas registran la
# evidencia; este script queda para inyecciones manuales.
#
# Como fuerza la alerta: EW calcula
#   speed_mm_dia = (cum2 - cum1) / dt_segundos * 86400
# La primera lectura solo fija la linea base (previous_none). La segunda, 60s
# despues y con +100mm, da 100/60*86400 = 144000 mm/dia, muy por encima del
# umbral rojo de shangtan (20), que es el mismo en A y en B.
#
# Funciona en los dos sistemas (AP5 exige el MISMO evento en A y en B):
#   - B (SSH_ORCHESTRATOR=k8s): Management API dentro del pod de RabbitMQ.
#   - A (SSH_ORCHESTRATOR=native): Management API del host, con
#     RABBITMQ_MGMT_USER / RABBITMQ_MGMT_PASS.
#
# Uso:
#   # Evento nuevo: message_id autogenerado
#   ./chaos/publish-event.sh
#
#   # Reinyectar un message_id (AP6): mismo id => debe deduplicarse. Ojo: la
#   # lectura se regenera con timestamp nuevo; ap6-idempotency.sh reinyecta el
#   # envelope byte a byte, que es la prueba estricta.
#   SKIP_BASELINE=1 ./chaos/publish-event.sh ap6-1789481234
#
# Imprime el message_id usado, que es lo que hay que registrar en la evidencia.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/ssh.sh"
source "$SCRIPT_DIR/lib/event.sh"

EVENT_ID="${1:-ap-$(date +%s)}"
SKIP_BASELINE="${SKIP_BASELINE:-0}"

_ssh_require

# En modo local (CHAOS_LOCAL, corriendo en el nodo de B) el orquestador es k8s
# por definicion: _ssh_require ya verifico que kubectl hable con el cluster.
[[ "$CHAOS_LOCAL" == "1" ]] && SSH_ORCHESTRATOR="${SSH_ORCHESTRATOR:-k8s}"
case "$SSH_ORCHESTRATOR" in
  k8s)    sys="B" ;;
  native) sys="A" ;;
  *)
    echo "ERROR: SSH_ORCHESTRATOR es obligatorio — 'k8s' (Sistema B) o 'native' (Sistema A)." >&2
    exit 1
    ;;
esac

echo "=== Evento representativo (Sistema $sys) ==="
echo "    message_id base:   ${EVENT_ID}-a"
echo "    message_id alerta: ${EVENT_ID}-b   <- el que se reinyecta en AP6"
echo "    project_id:        ${EVENT_PROJECT}"
echo "    sensor_id:         ${EVENT_ID}"
[[ "$SKIP_BASELINE" == "1" ]] && echo "    (SKIP_BASELINE=1: solo la lectura de alerta)"

event_publish_pair "$EVENT_ID" "$SKIP_BASELINE"

echo ""
echo "Publicado y enrutado. Registrar: message_id=${EVENT_ID}-b  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
if [[ "$sys" == "B" ]]; then
  echo "Verificar que alerto:"
  echo "  kubectl -n $K8S_NAMESPACE logs -l app=early-warning --tail=-1 --since=5m | grep ${EVENT_ID}"
fi
