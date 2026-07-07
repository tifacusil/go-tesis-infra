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

TARGET_CONTAINER="rabbitmq-1"
LABEL="kill-rabbitmq"

echo "=== Escenario: kill $TARGET_CONTAINER ==="

echo "--- Snapshot pre-fallo ---"
pre_snapshot=$(snapshot_counters "${LABEL}-pre")
cat "$pre_snapshot"

echo ""
echo "--- Inyectando fallo (pumba kill, SIGKILL) ---"
fail_start=$(date +%s)
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock gaiaadm/pumba:latest \
  kill --signal SIGKILL "$TARGET_CONTAINER"

echo "--- Esperando recuperacion (rabbitmq-diagnostics ping via healthcheck Docker) ---"
timeout=180
elapsed=0
while [[ "$elapsed" -lt "$timeout" ]]; do
  status=$(docker inspect "$TARGET_CONTAINER" --format '{{.State.Health.Status}}' 2>/dev/null || echo "unknown")
  if [[ "$status" == "healthy" ]]; then
    break
  fi
  sleep 2
  elapsed=$(( $(date +%s) - fail_start ))
done
mttr_container="$elapsed"
echo "MTTR contenedor (healthy de nuevo): ${mttr_container}s"

echo "--- Esperando 30s adicionales para que productores/consumidores reconecten ---"
sleep 30

echo "--- Snapshot post-recuperacion ---"
post_snapshot=$(snapshot_counters "${LABEL}-post")
cat "$post_snapshot"

echo ""
echo "=== Resumen ==="
echo "MTTR (contenedor healthy):    ${mttr_container}s"
echo "Ver snapshots en: $pre_snapshot / $post_snapshot"
echo "Mensajes perdidos = (published_pre - consumed_pre) - (published_post - consumed_post) tras estabilizar,"
echo "  o mas simple: revisar 'dropped' en ambos snapshots y el backlog Redis (redis_buffer_pending) durante la ventana."
