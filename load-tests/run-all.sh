#!/usr/bin/env bash
# run-all.sh — Corre las 5 corridas de Artillery (steady-state por nivel de VU).
#
# Uso:
#   TARGET_HOST=http://192.168.1.X ./load-tests/run-all.sh
#   TARGET_HOST=http://192.168.1.X SYSTEM=B ./load-tests/run-all.sh
#
# Variables:
#   TARGET_HOST   IP/hostname del servidor con Nginx (obligatorio)
#   SYSTEM        Etiqueta para los reportes: A o B (default: A)
#
# Los resultados JSON se guardan en load-tests/results/<SYSTEM>/<nivel>.json
# Artillery debe estar instalado: npm install -g artillery

set -euo pipefail

TARGET_HOST="${TARGET_HOST:?Falta TARGET_HOST. Ej: TARGET_HOST=http://192.168.1.X ./run-all.sh}"
SYSTEM="${SYSTEM:-A}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results/$SYSTEM"
SCENARIOS_DIR="$SCRIPT_DIR/scenarios"

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
  echo "    Warmup: 2 min | Medición: 5 min"

  TARGET_HOST="$TARGET_HOST" artillery run \
    --output "$OUTPUT" \
    "$SCENARIO"

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
