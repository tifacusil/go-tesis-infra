#!/usr/bin/env bash
# pause-data-management.sh — pausa (SIGSTOP, no mata) data-management-1 via
# pumba pause, para medir blast radius: ¿nginx round-robin (Sistema A) o
# Traefik (Sistema B) desvian trafico a data-management-2 sin degradacion
# visible al cliente? Se corre una rafaga de requests HTTP contra el gateway
# durante la pausa y se cuentan los codigos de respuesta.
#
# Uso: ./chaos/pause-data-management.sh [duration_seconds] [gateway_url]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/capture.sh"

TARGET_CONTAINER="data-management-1"
DURATION="${1:-30}"
GATEWAY_URL="${2:-http://localhost/api/v1/data/health}"
LABEL="pause-data-management"

echo "=== Escenario: pause $TARGET_CONTAINER (${DURATION}s) ==="

echo "--- Snapshot pre-fallo ---"
pre_snapshot=$(snapshot_counters "${LABEL}-pre")
cat "$pre_snapshot"

echo ""
echo "--- Pausando $TARGET_CONTAINER (pumba pause, SIGSTOP) por ${DURATION}s ---"
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock gaiaadm/pumba:latest \
  pause --duration "${DURATION}s" "$TARGET_CONTAINER" &
pumba_pid=$!

echo "--- Sondeando $GATEWAY_URL cada 1s durante la pausa (blast radius al cliente) ---"
ok_count=0
fail_count=0
probe_end=$(( $(date +%s) + DURATION + 5 ))
while [[ "$(date +%s)" -lt "$probe_end" ]]; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$GATEWAY_URL" || echo "000")
  if [[ "$code" == "200" ]]; then
    ok_count=$((ok_count + 1))
  else
    fail_count=$((fail_count + 1))
    echo "  probe failed: http_code=$code"
  fi
  sleep 1
done

wait "$pumba_pid"

echo "--- Snapshot post-recuperacion ---"
post_snapshot=$(snapshot_counters "${LABEL}-post")
cat "$post_snapshot"

echo ""
echo "=== Resumen (blast radius) ==="
echo "Requests OK durante la pausa:     $ok_count"
echo "Requests fallidos durante la pausa: $fail_count"
if [[ "$fail_count" -eq 0 ]]; then
  echo "Blast radius = 0: el balanceador desvio todo el trafico a data-management-2."
else
  echo "Blast radius > 0: hubo requests afectados pese a tener 2 replicas."
fi
echo "Ver snapshots en: $pre_snapshot / $post_snapshot"
