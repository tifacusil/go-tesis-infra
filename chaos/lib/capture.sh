#!/usr/bin/env bash
# capture.sh — helpers compartidos por los escenarios de chaos: consulta
# Prometheus (instant query) y guarda snapshots crudos para el analisis MTTR /
# mensajes perdidos / blast radius.
#
# PROMETHEUS_ADDR (default http://localhost:9090) debe apuntar al Prometheus
# de local/infra/docker-compose.observability.yml.

PROMETHEUS_ADDR="${PROMETHEUS_ADDR:-http://localhost:9090}"
RESULTS_DIR="${RESULTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/results}"
mkdir -p "$RESULTS_DIR"

# prom_query <promql> — imprime el primer valor escalar de una instant query.
prom_query() {
  local query="$1"
  curl -s --get "$PROMETHEUS_ADDR/api/v1/query" --data-urlencode "query=$query" \
    | python -c "import sys,json; d=json.load(sys.stdin); r=d['data']['result']; print(r[0]['value'][1] if r else 'NaN')"
}

# prom_query_raw <promql> <out_file> — guarda la respuesta cruda (todas las series).
prom_query_raw() {
  local query="$1" out="$2"
  curl -s --get "$PROMETHEUS_ADDR/api/v1/query" --data-urlencode "query=$query" -o "$out"
}

# wait_for_breaker_closed <target> <timeout_seconds> — poll hasta que
# ew_circuit_breaker_state{target="..."} vuelva a 0 (closed). Imprime el
# numero de segundos transcurridos (MTTR) por stdout.
wait_for_breaker_closed() {
  local target="$1" timeout="${2:-120}"
  local start=$(date +%s)
  local elapsed=0
  while [[ "$elapsed" -lt "$timeout" ]]; do
    local state
    state=$(prom_query "ew_circuit_breaker_state{target=\"$target\"}")
    if [[ "$state" == "0" ]]; then
      echo "$elapsed"
      return 0
    fi
    sleep 2
    elapsed=$(( $(date +%s) - start ))
  done
  echo "TIMEOUT_${timeout}s"
  return 1
}

# wait_for_health <url> <timeout_seconds> — poll hasta que el endpoint /health
# responda 200. Imprime el numero de segundos transcurridos (MTTR).
wait_for_health() {
  local url="$1" timeout="${2:-120}"
  local start=$(date +%s)
  local elapsed=0
  while [[ "$elapsed" -lt "$timeout" ]]; do
    if curl -s -o /dev/null -w '%{http_code}' "$url" | grep -q '^200$'; then
      echo "$elapsed"
      return 0
    fi
    sleep 2
    elapsed=$(( $(date +%s) - start ))
  done
  echo "TIMEOUT_${timeout}s"
  return 1
}

# snapshot_counters <label> — guarda published/consumed/breaker-state actuales,
# para comparar antes/despues y estimar mensajes perdidos.
snapshot_counters() {
  local label="$1"
  local ts
  ts=$(date +%s)
  {
    echo "timestamp=$ts"
    echo "published=$(prom_query 'sum(data_receiving_messages_published_total)')"
    echo "consumed=$(prom_query 'sum(ew_messages_consumed_total)')"
    echo "dropped=$(prom_query 'sum(ew_messages_dropped_total)')"
    echo "redis_buffer_pending=$(prom_query 'sum(data_receiving_redis_buffer_pending)')"
  } > "$RESULTS_DIR/${label}-${ts}.snapshot"
  echo "$RESULTS_DIR/${label}-${ts}.snapshot"
}
