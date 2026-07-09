#!/usr/bin/env bash
# kill-rabbitmq.sh — mata el contenedor rabbitmq-1 (SIGKILL via pumba kill) y
# mide: MTTR de reconexion (rabbitmq-1 vuelve a healthy + consumidores
# reconectan), y mensajes perdidos (delta published vs consumed en la ventana
# del fallo). docker-compose ya tiene `restart: unless-stopped`, asi que el
# propio Docker reinicia el contenedor; esto mide cuanto tarda en recuperarse
# el pipeline end-to-end, no solo el proceso.
#
# Uso: ./chaos/kill-rabbitmq.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/capture.sh"
source "$SCRIPT_DIR/../load-tests/lib/grafana-annotate.sh"

TARGET_CONTAINER="rabbitmq-1"
LABEL="kill-rabbitmq"

echo "=== Escenario: kill $TARGET_CONTAINER ==="

echo "--- Snapshot pre-fallo ---"
pre_snapshot=$(snapshot_counters "${LABEL}-pre")
cat "$pre_snapshot"

region_id=$(grafana_annotate_region_start "Chaos · kill-rabbitmq" "chaos" "kill-rabbitmq")
# Cierra la región de Grafana pase lo que pase (docker run falla, el script
# se interrumpe, etc.) — sin esto una falla antes de la línea de cierre normal
# deja la anotación abierta para siempre.
trap 'grafana_annotate_region_end "$region_id"' EXIT

echo ""
echo "--- Inyectando fallo (pumba kill, SIGKILL) ---"
fail_start=$(date +%s)
if ! docker run --rm -v /var/run/docker.sock:/var/run/docker.sock gaiaadm/pumba:latest \
  kill --signal SIGKILL "$TARGET_CONTAINER"; then
  echo "ERROR: pumba kill falló (Docker no disponible, o $TARGET_CONTAINER no existe) — el fallo puede no haberse inyectado." >&2
  exit 1
fi

echo "--- Esperando recuperacion (rabbitmq-diagnostics ping via healthcheck Docker) ---"
timeout=180
elapsed=0
recovered="false"
while [[ "$elapsed" -lt "$timeout" ]]; do
  status=$(docker inspect "$TARGET_CONTAINER" --format '{{.State.Health.Status}}' 2>/dev/null || echo "unknown")
  if [[ "$status" == "healthy" ]]; then
    recovered="true"
    break
  fi
  sleep 2
  elapsed=$(( $(date +%s) - fail_start ))
done
mttr_container="$elapsed"
if [[ "$recovered" == "true" ]]; then
  echo "MTTR contenedor (healthy de nuevo): ${mttr_container}s"
else
  echo "MTTR contenedor: TIMEOUT tras ${timeout}s — $TARGET_CONTAINER NO volvió a healthy. Esto es una falla de resiliencia real, no confundir con un MTTR de ${timeout}s." >&2
fi

echo "--- Esperando 30s adicionales para que productores/consumidores reconecten ---"
sleep 30

echo "--- Snapshot post-recuperacion ---"
post_snapshot=$(snapshot_counters "${LABEL}-post")
cat "$post_snapshot"

echo ""
echo "=== Resumen ==="
if [[ "$recovered" == "true" ]]; then
  echo "MTTR (contenedor healthy):    ${mttr_container}s"
else
  echo "MTTR (contenedor healthy):    TIMEOUT (>${timeout}s, no se recuperó)"
fi
echo "Ver snapshots en: $pre_snapshot / $post_snapshot"
echo "Mensajes perdidos = (published_pre - consumed_pre) - (published_post - consumed_post) tras estabilizar,"
echo "  o mas simple: revisar 'dropped' en ambos snapshots y el backlog Redis (redis_buffer_pending) durante la ventana."

if [[ "$recovered" != "true" ]]; then
  exit 1
fi
