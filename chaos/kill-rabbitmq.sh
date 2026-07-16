#!/usr/bin/env bash
# kill-rabbitmq.sh — mata el broker RabbitMQ y mide: MTTR de reconexión
# (RabbitMQ vuelve a Ready + productores/consumidores reconectan) y mensajes
# perdidos (delta published vs consumed en la ventana del fallo).
#
# RabbitMQ SOLO existe en el Sistema B (k3s) — el Sistema A (procesos systemd
# nativos) no usa broker AMQP, así que este escenario aplica únicamente a B.
#
# El fallo se inyecta EN el servidor remoto vía kubectl (no con pumba sobre un
# Docker local: 178.105.104.95 corre k3s/containerd, no Docker, y no expone su
# runtime a esta máquina). Se hace `kubectl delete pod --force --grace-period=0`
# sobre el pod del StatefulSet: eso lo elimina de forma abrupta (equivalente a
# SIGKILL, sin shutdown ordenado) y el StatefulSet lo recrea solo — esto mide
# cuánto tarda en recuperarse el pipeline end-to-end, no solo el proceso.
#
# Uso (Sistema B):
#   SSH_HOST=178.105.104.95 SSH_USER=gotesis SSH_KEY_PATH=~/.ssh/gotesis-key \
#     SUDO_PASSWORD=*** PROMETHEUS_ADDR=http://178.105.104.95:31083 \
#     ./chaos/kill-rabbitmq.sh
#
# (SSH_HOST/USER/auth y SUDO_PASSWORD se pueden dejar en load-tests/.env — se
# cargan automáticamente vía grafana-annotate.sh, igual que reset-state.sh.)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/capture.sh"
source "$SCRIPT_DIR/lib/ssh.sh"
source "$SCRIPT_DIR/../load-tests/lib/grafana-annotate.sh"

RABBITMQ_SELECTOR="${RABBITMQ_SELECTOR:-app=rabbitmq}"
LABEL="kill-rabbitmq"
RECOVERY_TIMEOUT="${RECOVERY_TIMEOUT:-180}"

_ssh_require

# Un snapshot que no puede consultar Prometheus no mide nada: fallar temprano
# en vez de descubrir que published/consumed son 'ERR' recién en el resumen.
# El default de capture.sh (localhost:9090) casi nunca es correcto acá —
# Prometheus del Sistema B es un NodePort en <host>:31083.
if [[ "$PROMETHEUS_ADDR" == *localhost* || "$PROMETHEUS_ADDR" == *127.0.0.1* ]]; then
  echo "AVISO: PROMETHEUS_ADDR=$PROMETHEUS_ADDR apunta a localhost, pero el sistema bajo prueba es remoto." >&2
  echo "  Setear al Prometheus del Sistema B, ej: PROMETHEUS_ADDR=http://178.105.104.95:31083" >&2
fi
if [[ "$(prom_query 'vector(1)')" != "1" ]]; then
  echo "ERROR: no se pudo consultar Prometheus en $PROMETHEUS_ADDR — los snapshots quedarían vacíos." >&2
  echo "  Confirmar PROMETHEUS_ADDR y que el puerto sea accesible desde esta máquina." >&2
  exit 1
fi

echo "=== Escenario: kill RabbitMQ (Sistema B / k3s) vía kubectl ==="
echo "    Servidor:   $SSH_USER@$SSH_HOST (namespace $K8S_NAMESPACE)"
echo "    Selector:   $RABBITMQ_SELECTOR"

# jsonpath del pod que matchea el selector: "<uid> <Ready-status>". El StatefulSet
# recrea el pod con un uid NUEVO, así que comparar uid distingue "el pod viejo
# todavía figura Ready" de "el reemplazo ya está Ready" (evita un MTTR=0 falso).
_pod_uid_ready() {
  _kubectl get pod -l "$RABBITMQ_SELECTOR" -n "$K8S_NAMESPACE" \
    -o 'jsonpath={range .items[*]}{.metadata.uid}{" "}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{end}' \
    2>/dev/null || true
}

old_state=$(_pod_uid_ready)
old_uid="${old_state%% *}"
if [[ -z "$old_uid" ]]; then
  echo "ERROR: no se encontró ningún pod con selector '$RABBITMQ_SELECTOR' en $K8S_NAMESPACE (o falló el kubectl remoto/sudo)." >&2
  echo "  Verificar SSH/SUDO_PASSWORD y que RabbitMQ corra en este servidor (solo Sistema B)." >&2
  exit 1
fi
echo "    Pod actual: uid ${old_uid} (Ready=${old_state##* })"

echo ""
echo "--- Snapshot pre-fallo ---"
pre_snapshot=$(snapshot_counters "${LABEL}-pre")
cat "$pre_snapshot"

region_id=$(grafana_annotate_region_start "Chaos · kill-rabbitmq (Sistema B)" "chaos" "kill-rabbitmq" "sistema-B")
# Cierra la región de Grafana pase lo que pase (kubectl falla, el script se
# interrumpe, etc.) — sin esto una falla antes del cierre normal deja la
# anotación abierta para siempre.
trap 'grafana_annotate_region_end "$region_id"' EXIT

echo ""
echo "--- Inyectando fallo (kubectl delete pod --force --grace-period=0) ---"
fail_start=$(date +%s)
if ! _kubectl delete pod -l "$RABBITMQ_SELECTOR" -n "$K8S_NAMESPACE" --force --grace-period=0 >/dev/null 2>&1; then
  echo "ERROR: 'kubectl delete pod' remoto falló (SSH/sudo/kubeconfig, o el pod ya no existe) — el fallo puede no haberse inyectado." >&2
  exit 1
fi
echo "    Pod eliminado; el StatefulSet debe recrearlo."

echo "--- Esperando recuperación (pod reemplazo Ready) ---"
elapsed=0
recovered="false"
while [[ "$elapsed" -lt "$RECOVERY_TIMEOUT" ]]; do
  state=$(_pod_uid_ready)
  new_uid="${state%% *}"
  ready="${state##* }"
  # Recuperado solo cuando el pod es OTRO (uid distinto al que matamos) y está
  # Ready — así no contamos como recuperación el instante en que el pod viejo
  # aún no fue removido de la API.
  if [[ -n "$new_uid" && "$new_uid" != "$old_uid" && "$ready" == "True" ]]; then
    recovered="true"
    break
  fi
  sleep 3
  elapsed=$(( $(date +%s) - fail_start ))
done
mttr="$elapsed"
if [[ "$recovered" == "true" ]]; then
  echo "MTTR (pod reemplazo Ready): ${mttr}s"
else
  echo "MTTR: TIMEOUT tras ${RECOVERY_TIMEOUT}s — RabbitMQ NO volvió a Ready. Esto es una falla de resiliencia real, no confundir con un MTTR de ${RECOVERY_TIMEOUT}s." >&2
fi

echo "--- Esperando 30s adicionales para que productores/consumidores reconecten ---"
sleep 30

echo "--- Snapshot post-recuperación ---"
post_snapshot=$(snapshot_counters "${LABEL}-post")
cat "$post_snapshot"

echo ""
echo "=== Resumen ==="
if [[ "$recovered" == "true" ]]; then
  echo "MTTR (pod Ready de nuevo):    ${mttr}s"
else
  echo "MTTR (pod Ready de nuevo):    TIMEOUT (>${RECOVERY_TIMEOUT}s, no se recuperó)"
fi
echo "Ver snapshots en: $pre_snapshot / $post_snapshot"
echo "Mensajes perdidos = (published_pre - consumed_pre) - (published_post - consumed_post) tras estabilizar,"
echo "  o más simple: revisar 'dropped' en ambos snapshots y el backlog Redis (redis_buffer_pending) durante la ventana."

if [[ "$recovered" != "true" ]]; then
  exit 1
fi
