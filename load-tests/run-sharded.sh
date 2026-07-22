#!/usr/bin/env bash
# run-sharded.sh — corre UN nivel de VU repartido entre N procesos Artillery.
#
# El engine de Artillery es Node, de un solo hilo. En la escalera del
# 2026-07-22 eso puso el techo en el generador, no en el sistema: a partir de
# ~112 fps el event loop se saturaba y aparecían `pool_dispatch_failed` — un
# fallo del cliente que se veía igual que un rechazo del servidor (ver
# docs/ladder-b-2026-07-22.md §2). Un solo core del cliente no alcanza para
# empujar al sistema hasta su verdadero techo.
#
# Esto lanza SHARDS procesos artillery en paralelo, cada uno con arrivalRate =
# total/SHARDS, y le da a cada uno un rango disjunto de la flota de sensores
# (DTU_SENSOR_BASE) para que dos procesos nunca toquen el mismo sensor. N
# event loops en N cores empujan N veces más antes de saturarse.
#
# Uso:
#   TARGET_HOST=178.105.104.95:5000 RATE=300 SHARDS=4 ./load-tests/run-sharded.sh
#
# Variables:
#   TARGET_HOST      host:port de data-receiving (obligatorio, sin http://)
#   RATE             frames/s totales objetivo (obligatorio)
#   SHARDS           procesos artillery en paralelo (default: 4)
#   DURATION         segundos de la fase de medición (default: 420)
#   WARMUP           segundos de calentamiento previos (default: 60)
#   FLEET            tamaño total de la flota, repartida entre shards (default: 100)
#   POOL_PER_SHARD   conexiones Python persistentes por shard. Cada una es un
#                    intérprete Python entero con su conexión TCP, así que el
#                    total (SHARDS × POOL_PER_SHARD) es lo que puede reventar la
#                    RAM del cliente: un intento con 4×40=160 procesos agotó la
#                    memoria (WinError 8) y disparó un loop de respawn de >1000
#                    procesos. El pool solo necesita ~rate·RTT conexiones para no
#                    encolar; a RTT ~0.3s eso es ~1/3 del rate. Default:
#                    ceil(rate_del_shard × 0.4), mínimo 4.
#   RTT_FACTOR       fracción del rate usada para el pool default (default 0.4).
#   SYSTEM           etiqueta de resultados (default: B)
#   LABEL            subcarpeta bajo results/<SYSTEM>/ (default: sharded)
#
# Resultados: results/<SYSTEM>/<LABEL>/rate<RATE>-s<SHARDS>-shard<K>.json
#             + .client-cpu.csv (una sola serie para toda la corrida)
# Agregado:   node load-tests/aggregate-sharded.js <SYSTEM>/<LABEL>

set -euo pipefail

TARGET_HOST="${TARGET_HOST:?Falta TARGET_HOST. Ej: TARGET_HOST=178.105.104.95:5000}"
RATE="${RATE:?Falta RATE (frames/s totales). Ej: RATE=300}"
SHARDS="${SHARDS:-4}"
DURATION="${DURATION:-420}"
WARMUP="${WARMUP:-60}"
FLEET="${FLEET:-100}"
SYSTEM="${SYSTEM:-B}"
LABEL="${LABEL:-sharded}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results/$SYSTEM/$LABEL"
SCENARIO="$SCRIPT_DIR/scenarios/vu-sharded.yml"
source "$SCRIPT_DIR/lib/check-dtu-emulator.sh"
source "$SCRIPT_DIR/lib/client-cpu.sh"

export NODE_PATH="$SCRIPT_DIR"

command -v artillery >/dev/null 2>&1 || { echo "ERROR: 'artillery' no está en PATH." >&2; exit 1; }
check_dtu_emulator "$SCRIPT_DIR" || exit 1

# Reparto entero: los primeros (RATE mod SHARDS) shards llevan un frame/s de
# más, para que la suma dé exactamente RATE y no una aproximación.
base_rate=$(( RATE / SHARDS ))
extra=$(( RATE % SHARDS ))
per_shard_fleet=$(( FLEET / SHARDS ))
if (( per_shard_fleet < 1 )); then
  echo "ERROR: FLEET=$FLEET < SHARDS=$SHARDS; cada shard necesita al menos 1 sensor." >&2
  exit 1
fi

mkdir -p "$RESULTS_DIR"
"$SCRIPT_DIR/reset-state.sh" || echo "AVISO: reset-state falló; la corrida puede arrancar con estado residual." >&2

echo "=== sharded — Sistema $SYSTEM ==="
echo "    Target:   $TARGET_HOST"
echo "    Rate:     $RATE fps totales en $SHARDS procesos (~$base_rate c/u)"
echo "    Flota:    $FLEET sensores, $per_shard_fleet por shard"
echo "    Ventana:  ${WARMUP}s warmup + ${DURATION}s medición"
echo ""

CPU_CSV="$RESULTS_DIR/rate${RATE}-s${SHARDS}.client-cpu.csv"
client_cpu_start "$CPU_CSV"

pids=()
for (( k = 0; k < SHARDS; k++ )); do
  rate=$base_rate
  (( k < extra )) && rate=$(( base_rate + 1 ))
  out="$RESULTS_DIR/rate${RATE}-s${SHARDS}-shard${k}.json"
  overrides=$(printf '{"config":{"phases":[{"duration":%d,"arrivalRate":%d,"name":"warmup"},{"duration":%d,"arrivalRate":%d,"name":"measure"}]}}' \
    "$WARMUP" "$rate" "$DURATION" "$rate")

  # Pool default = rate·RTT_FACTOR (no rate): suficiente para no encolar sin
  # abrir un intérprete Python por frame/s. Ver cabecera.
  if [[ -n "${POOL_PER_SHARD:-}" ]]; then
    pool="$POOL_PER_SHARD"
  else
    pool=$(awk -v r="$rate" -v f="${RTT_FACTOR:-0.4}" 'BEGIN{p=int(r*f); if(p<4)p=4; print p}')
  fi
  DTU_SENSOR_COUNT="$per_shard_fleet" \
  DTU_SENSOR_BASE="$(( k * per_shard_fleet ))" \
  DTU_ENGINE_POOL_SIZE="$pool" \
  TARGET_HOST="$TARGET_HOST" \
    artillery run --quiet --output "$out" --overrides "$overrides" "$SCENARIO" &
  pids+=("$!")
  echo "    shard $k: rate=$rate, pool=$pool, sensores [$(( k * per_shard_fleet )), $(( k * per_shard_fleet + per_shard_fleet ))), pid=${pids[-1]}"
done

echo ""
echo "    esperando $SHARDS shards..."
rc=0
for pid in "${pids[@]}"; do
  wait "$pid" || rc=1
done

client_cpu_stop

echo ""
echo "=== corrida completada (rc=$rc) ==="
echo "    CPU cliente: $(client_cpu_summary "$CPU_CSV")"
echo ""
echo "Agregado:"
echo "  node $SCRIPT_DIR/aggregate-sharded.js $SYSTEM/$LABEL"
exit "$rc"
