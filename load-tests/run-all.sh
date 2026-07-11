#!/usr/bin/env bash
# run-all.sh — Corre las 5 corridas de Artillery (steady-state por nivel de VU).
#
# Ingesta real es TCP (frames binarios DTU), no HTTP — ver README-engine.md.
# TARGET_HOST es "host" o "host:port" de una instancia data-receiving, SIN
# esquema http://.
#
# Uso:
#   TARGET_HOST=192.168.1.X:5000 ./load-tests/run-all.sh
#   TARGET_HOST=192.168.1.X:5000 SYSTEM=B ./load-tests/run-all.sh
#
# Variables:
#   TARGET_HOST   host:port de data-receiving (obligatorio, sin http://)
#   SYSTEM        Etiqueta para los reportes: A o B (default: A)
#
# Los resultados JSON se guardan en load-tests/results/<SYSTEM>/<nivel>.json
# Artillery debe estar instalado: npm install -g artillery

set -euo pipefail

TARGET_HOST="${TARGET_HOST:?Falta TARGET_HOST. Ej: TARGET_HOST=192.168.1.X:5000 ./run-all.sh}"
SYSTEM="${SYSTEM:-A}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results/$SYSTEM"
SCENARIOS_DIR="$SCRIPT_DIR/scenarios"
source "$SCRIPT_DIR/lib/grafana-annotate.sh"

# El engine dtu-tcp es local (no publicado a npm) — Artillery lo resuelve vía
# `require('artillery-engine-dtu-tcp')`, que necesita NODE_PATH apuntando a
# este directorio. Ver README-engine.md.
export NODE_PATH="$SCRIPT_DIR"

if ! command -v artillery >/dev/null 2>&1; then
  echo "ERROR: 'artillery' no está en PATH. Instalar con: npm install -g artillery" >&2
  echo "  (en Windows/Git Bash, confirmar que el prefix global de npm esté en PATH — 'npm config get prefix')" >&2
  exit 1
fi

mkdir -p "$RESULTS_DIR"

VU_LEVELS=(001 010 050 100 400)

echo "=== Artillery load test — Sistema $SYSTEM ==="
echo "    Target:  $TARGET_HOST"
echo "    Results: $RESULTS_DIR"
echo ""

for VU in "${VU_LEVELS[@]}"; do
  SCENARIO="$SCENARIOS_DIR/vu-${VU}.yml"
  OUTPUT="$RESULTS_DIR/vu-${VU}.json"

  echo "--- [$(date '+%H:%M:%S')] Corrida VU=${VU} ---"
  echo "    Warmup: 3 min | Medición: 7 min"

  "$SCRIPT_DIR/reset-state.sh" || echo "AVISO: reset-state falló, la corrida VU=$VU puede arrancar con estado residual de la anterior." >&2

  region_id=$(grafana_annotate_region_start "Fase 1 · Sistema $SYSTEM · VU=$VU" "fase-1" "sistema-$SYSTEM" "vu-$VU")
  trap 'grafana_annotate_region_end "$region_id"' EXIT

  TARGET_HOST="$TARGET_HOST" artillery run \
    --output "$OUTPUT" \
    "$SCENARIO"

  grafana_annotate_region_end "$region_id"
  trap - EXIT

  echo "    Reporte: $OUTPUT"
  echo ""

  if [[ "$VU" != "400" ]]; then
    echo "    Esperando 30s antes de la próxima corrida..."
    sleep 30
  fi
done

echo "=== Todas las corridas completadas ==="
echo ""
echo "Para generar reportes HTML:"
for VU in "${VU_LEVELS[@]}"; do
  echo "  artillery report $RESULTS_DIR/vu-${VU}.json"
done
