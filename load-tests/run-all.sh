#!/usr/bin/env bash
# run-all.sh — Corre la escalera de carga (steady-state por nivel de VU).
#
# Ingesta real es TCP (frames binarios DTU), no HTTP — ver README-engine.md.
# TARGET_HOST es "host" o "host:port" de una instancia data-receiving, SIN
# esquema http://.
#
# Uso:
#   TARGET_HOST=192.168.1.X:5000 ./load-tests/run-all.sh
#   TARGET_HOST=192.168.1.X:5000 SYSTEM=B REPEATS=3 ./load-tests/run-all.sh
#
# Variables:
#   TARGET_HOST        host:port de data-receiving (obligatorio, sin http://)
#   SYSTEM             Etiqueta para los reportes: A o B (default: A)
#   REPEATS            Corridas por nivel (default: 3). Ver "repeticiones".
#   VU_LEVELS          Niveles a correr, separados por espacio. Default abajo.
#   DTU_SENSOR_COUNT   Tamaño de la flota de sensores (default 100 en el
#                      engine). Ver README-engine.md.
#
# Resultados: load-tests/results/<SYSTEM>/vu-<nivel>-r<N>.json
#             load-tests/results/<SYSTEM>/vu-<nivel>-r<N>.client-cpu.csv
# Agregar con: node load-tests/aggregate-results.js <SYSTEM>
#
# Artillery debe estar instalado: npm install -g artillery
#
# ── Escalones ───────────────────────────────────────────────────────────────
# Entre 100 y 400 había un salto de 4x sin medir, y el servidor sostuvo ~155
# fps en vu-400 aun en dificultades, así que el techo real cae en algún lugar
# de ese hueco. 150/200/300 lo cierran.
#
# ── Repeticiones ────────────────────────────────────────────────────────────
# Una sola corrida por nivel no permite separar una diferencia real del ruido
# de la corrida. El estudio metodológico base (El Fellah et al. 2026) repite
# cada nivel 3-4 veces y reporta mediana, p90/p95/p99 e intervalos de confianza
# al 95%; aggregate-results.js hace esa parte a partir de los N archivos.

set -euo pipefail

TARGET_HOST="${TARGET_HOST:?Falta TARGET_HOST. Ej: TARGET_HOST=192.168.1.X:5000 ./run-all.sh}"
SYSTEM="${SYSTEM:-A}"
REPEATS="${REPEATS:-3}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results/$SYSTEM"
SCENARIOS_DIR="$SCRIPT_DIR/scenarios"
source "$SCRIPT_DIR/lib/grafana-annotate.sh"
source "$SCRIPT_DIR/lib/check-dtu-emulator.sh"
source "$SCRIPT_DIR/lib/client-cpu.sh"

# El engine dtu-tcp es local (no publicado a npm) — Artillery lo resuelve vía
# `require('artillery-engine-dtu-tcp')`, que necesita NODE_PATH apuntando a
# este directorio. Ver README-engine.md.
export NODE_PATH="$SCRIPT_DIR"

if ! command -v artillery >/dev/null 2>&1; then
  echo "ERROR: 'artillery' no está en PATH. Instalar con: npm install -g artillery" >&2
  echo "  (en Windows/Git Bash, confirmar que el prefix global de npm esté en PATH — 'npm config get prefix')" >&2
  exit 1
fi

echo "Verificando dtu-emulator antes de arrancar..."
if ! check_dtu_emulator "$SCRIPT_DIR"; then
  exit 1
fi

mkdir -p "$RESULTS_DIR"

read -r -a VU_LEVELS <<< "${VU_LEVELS:-001 010 050 100 150 200 300 400}"

echo "=== Artillery load test — Sistema $SYSTEM ==="
echo "    Target:       $TARGET_HOST"
echo "    Niveles:      ${VU_LEVELS[*]}"
echo "    Repeticiones: $REPEATS por nivel"
echo "    Flota:        ${DTU_SENSOR_COUNT:-100 (default del engine)} sensores"
echo "    Results:      $RESULTS_DIR"
echo ""

total=$(( ${#VU_LEVELS[@]} * REPEATS ))
done_runs=0

for VU in "${VU_LEVELS[@]}"; do
  SCENARIO="$SCENARIOS_DIR/vu-${VU}.yml"
  if [[ ! -f "$SCENARIO" ]]; then
    echo "ERROR: no existe $SCENARIO" >&2
    exit 1
  fi

  for (( REP = 1; REP <= REPEATS; REP++ )); do
    OUTPUT="$RESULTS_DIR/vu-${VU}-r${REP}.json"
    CPU_CSV="$RESULTS_DIR/vu-${VU}-r${REP}.client-cpu.csv"
    done_runs=$(( done_runs + 1 ))

    echo "--- [$(date '+%H:%M:%S')] VU=${VU} corrida ${REP}/${REPEATS} (${done_runs}/${total}) ---"
    echo "    Warmup: 3 min | Medición: 7 min"

    "$SCRIPT_DIR/reset-state.sh" || echo "AVISO: reset-state falló, la corrida VU=$VU r$REP puede arrancar con estado residual de la anterior." >&2

    region_id=$(grafana_annotate_region_start "Fase 1 · Sistema $SYSTEM · VU=$VU · r$REP" "fase-1" "sistema-$SYSTEM" "vu-$VU" "r$REP")
    client_cpu_start "$CPU_CSV"
    trap 'client_cpu_stop; grafana_annotate_region_end "$region_id"' EXIT

    TARGET_HOST="$TARGET_HOST" artillery run \
      --output "$OUTPUT" \
      "$SCENARIO"

    client_cpu_stop
    grafana_annotate_region_end "$region_id"
    trap - EXIT

    echo "    Reporte:     $OUTPUT"
    echo "    CPU cliente: $(client_cpu_summary "$CPU_CSV")"
    echo ""

    if (( done_runs < total )); then
      echo "    Esperando 30s antes de la próxima corrida..."
      sleep 30
    fi
  done
done

echo "=== Todas las corridas completadas ==="
echo ""
echo "Agregado (mediana, percentiles, IC 95% sobre las $REPEATS corridas):"
echo "  node $SCRIPT_DIR/aggregate-results.js $SYSTEM"
