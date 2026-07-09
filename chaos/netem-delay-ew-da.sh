#!/usr/bin/env bash
# netem-delay-ew-da.sh — inyecta latencia de red (pumba netem delay) en
# data-analysis-1 (servidor gRPC que Early Warning llama para analisis
# avanzado), para probar el circuit breaker de Early Warning bajo *latencia
# alta*, no solo bajo caida total. CLAUDE.md §2.3/§4: con el circuito abierto,
# Early Warning debe seguir emitiendo alarmas por umbral simple.
#
# Uso: ./chaos/netem-delay-ew-da.sh [delay_ms] [duration_seconds]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/capture.sh"
source "$SCRIPT_DIR/../load-tests/lib/grafana-annotate.sh"

TARGET_CONTAINER="data-analysis-1"
DELAY_MS="${1:-2000}"
DURATION="${2:-60}"
LABEL="netem-delay-ew-da"

echo "=== Escenario: netem delay ${DELAY_MS}ms en $TARGET_CONTAINER (${DURATION}s) ==="

echo "--- Snapshot pre-fallo (incluye estado de breakers) ---"
pre_snapshot=$(snapshot_counters "${LABEL}-pre")
cat "$pre_snapshot"
prom_query_raw 'ew_circuit_breaker_state' "$RESULTS_DIR/${LABEL}-pre-breakers.json"

region_id=$(grafana_annotate_region_start "Chaos · netem-delay-ew-da (${DELAY_MS}ms, ${DURATION}s)" "chaos" "netem-delay-ew-da")

echo ""
echo "--- Inyectando latencia (pumba netem delay ${DELAY_MS}ms) por ${DURATION}s ---"
fail_start=$(date +%s)
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock gaiaadm/pumba:latest \
  netem --duration "${DURATION}s" delay --time "$DELAY_MS" "$TARGET_CONTAINER" &
pumba_pid=$!

echo "--- Sondeando ew_circuit_breaker_state{target=~\"data-analysis.*\"} cada 2s ---"
poll_end=$(( $(date +%s) + DURATION + 5 ))
opened_at=""
while [[ "$(date +%s)" -lt "$poll_end" ]]; do
  state=$(prom_query 'max(ew_circuit_breaker_state{target=~".*data-analysis.*"})')
  echo "  t+$(( $(date +%s) - fail_start ))s: breaker_state=$state (0=closed 1=open 2=half_open)"
  if [[ "$state" == "1" && -z "$opened_at" ]]; then
    opened_at=$(( $(date +%s) - fail_start ))
    echo "  -> circuito abierto a los ${opened_at}s"
  fi
  sleep 2
done

wait "$pumba_pid"

echo "--- Esperando a que el circuito cierre (MTTR) ---"
mttr=$(wait_for_breaker_closed "data-analysis-1" 120) || true
echo "MTTR (breaker vuelve a closed): ${mttr}s"

echo "--- Snapshot post-recuperacion ---"
post_snapshot=$(snapshot_counters "${LABEL}-post")
cat "$post_snapshot"

grafana_annotate_region_end "$region_id"

echo ""
echo "=== Resumen ==="
echo "Delay inyectado:                  ${DELAY_MS}ms"
echo "Circuito abierto a los:           ${opened_at:-nunca (revisar umbral de fallos consecutivos)}s"
echo "MTTR (breaker cierra):            ${mttr}s"
echo "Continuidad operativa: revisar ew_alerts_published_total durante la ventana —"
echo "  debe seguir creciendo (umbral simple) aunque el breaker este abierto (CLAUDE.md §2.3)."
echo "Ver snapshots en: $pre_snapshot / $post_snapshot"
