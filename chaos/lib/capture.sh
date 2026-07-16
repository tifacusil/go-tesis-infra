#!/usr/bin/env bash
# capture.sh — helpers compartidos por los escenarios de chaos: consulta
# Prometheus (instant query) y guarda snapshots crudos para el analisis MTTR /
# mensajes perdidos / blast radius.
#
# PROMETHEUS_ADDR debe apuntar al Prometheus del sistema bajo prueba. Si no
# está seteado, se resuelve desde SYSTEM (A/B, las direcciones conocidas de
# cada sistema de la tesis); solo sin ambos cae al localhost:9090 del stack
# local de observabilidad (local/infra/docker-compose.observability.yml) —
# que NO es donde viven las métricas de una corrida real contra el servidor.
#
# Nota: este archivo NO fija `set -euo pipefail` — depende del script que lo
# fuente. `prom_query` se usa casi siempre dentro de `state=$(prom_query ...)`
# (sustitución de comando como valor asignado), que bash exime de `set -e`
# incluso con `pipefail` activo: un fallo de curl/python ahí NO aborta el
# script que llama, solo produce un valor vacío/'NaN'. Por eso _pq_python()
# valida explícitamente el intérprete antes de usarlo, en vez de confiar en
# que `set -e` capture el problema.

# Resolución de PROMETHEUS_ADDR: explícito > por sistema (SYSTEM=A/B) >
# localhost. Las métricas de chaos (data_receiving_messages_published_total,
# ew_circuit_breaker_state, ew_alerts_published_total) están confirmadas en
# ambos Prometheus.
if [[ -z "${PROMETHEUS_ADDR:-}" ]]; then
  case "${SYSTEM:-}" in
    A) PROMETHEUS_ADDR="http://204.168.203.32:9090" ;;
    B) PROMETHEUS_ADDR="http://178.105.104.95:31083" ;;
    "") PROMETHEUS_ADDR="http://localhost:9090"
        echo "  (capture: ni PROMETHEUS_ADDR ni SYSTEM seteados — usando $PROMETHEUS_ADDR, que solo sirve para el stack local. Para una corrida real: export SYSTEM=A|B o PROMETHEUS_ADDR=http://<host>:<puerto>)" >&2 ;;
    *) PROMETHEUS_ADDR="http://localhost:9090"
       echo "  (capture: SYSTEM='$SYSTEM' desconocido (esperado A o B) — usando $PROMETHEUS_ADDR)" >&2 ;;
  esac
fi
echo "  (capture: PROMETHEUS_ADDR=$PROMETHEUS_ADDR)" >&2
RESULTS_DIR="${RESULTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/results}"
mkdir -p "$RESULTS_DIR"

# _pq_python — resuelve un intérprete Python que REALMENTE ejecute.
# command -v no alcanza: en Windows, `python`/`python3` puede resolver al
# stub de Microsoft Store (un ejecutable real en PATH que solo imprime un
# prompt de instalación a stderr y sale con error al primer argumento) — hay
# que probar una ejecución real. Cachea el resultado en PQ_PYTHON_BIN tras
# la primera resolución exitosa.
_pq_python() {
  if [[ -n "${PQ_PYTHON_BIN:-}" ]]; then
    echo "$PQ_PYTHON_BIN"
    return 0
  fi
  local candidate
  for candidate in python3 python py; do
    if command -v "$candidate" >/dev/null 2>&1 && [[ "$("$candidate" -c 'print(1)' 2>/dev/null)" == "1" ]]; then
      PQ_PYTHON_BIN="$candidate"
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

# prom_query <promql> — imprime el primer valor escalar de una instant query.
# Si Python no está disponible o curl/parseo falla, imprime 'ERR' (nunca
# vacío) para que el caller pueda distinguir "el breaker está en 0" de
# "no pude preguntarle a Prometheus".
prom_query() {
  local query="$1" py body
  py=$(_pq_python) || { echo "  (prom_query: no se encontró python3/python/py en PATH)" >&2; echo "ERR"; return 1; }
  body=$(curl -s --get --connect-timeout 3 --max-time 10 "$PROMETHEUS_ADDR/api/v1/query" --data-urlencode "query=$query") || {
    echo "  (prom_query: curl falló contactando $PROMETHEUS_ADDR)" >&2
    echo "ERR"
    return 1
  }
  echo "$body" | "$py" -c "import sys,json
try:
    d = json.load(sys.stdin)
    r = d['data']['result']
    print(r[0]['value'][1] if r else 'NaN')
except Exception:
    print('ERR')
" 2>/dev/null || { echo "ERR"; return 1; }
}

# prom_query_raw <promql> <out_file> — guarda la respuesta cruda (todas las series).
prom_query_raw() {
  local query="$1" out="$2"
  curl -s --get "$PROMETHEUS_ADDR/api/v1/query" --data-urlencode "query=$query" -o "$out"
}

# wait_for_breaker_closed <target> <timeout_seconds> — poll hasta que
# ew_circuit_breaker_state{target="..."} vuelva a 0 (closed). Imprime el
# numero de segundos transcurridos (MTTR) por stdout en éxito.
# Distingue dos fallos: TIMEOUT_<n>s (el breaker nunca cerró — señal real del
# sistema bajo prueba) vs ERR_PROM_UNREACHABLE (no se pudo consultar
# Prometheus/python — falla de tooling, no del breaker; no confundir ambas).
wait_for_breaker_closed() {
  local target="$1" timeout="${2:-120}"
  local start=$(date +%s)
  local elapsed=0
  local consecutive_errs=0
  while [[ "$elapsed" -lt "$timeout" ]]; do
    local state
    state=$(prom_query "ew_circuit_breaker_state{target=\"$target\"}")
    if [[ "$state" == "0" ]]; then
      echo "$elapsed"
      return 0
    elif [[ "$state" == "ERR" ]]; then
      consecutive_errs=$((consecutive_errs + 1))
      if [[ "$consecutive_errs" -ge 5 ]]; then
        echo "ERR_PROM_UNREACHABLE" >&2
        echo "ERR_PROM_UNREACHABLE"
        return 1
      fi
    else
      consecutive_errs=0
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
