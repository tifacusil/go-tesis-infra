#!/usr/bin/env bash
# run-all-burst.sh — Corre los escenarios burst/spike (extension a run-all.sh,
# que solo cubre steady-state). Cada escenario intercala una fase de baseline,
# un spike sostenido y una fase de recovery, para comparar contra el
# comportamiento steady-state ya medido (throughput/latencia/CPU/mem durante
# el spike vs. sostenido). Ver El Fellah et al. (2026), trabajo futuro.
#
# Uso:
#   TARGET_HOST=http://192.168.1.X ./load-tests/run-all-burst.sh
#   TARGET_HOST=http://192.168.1.X SYSTEM=B ./load-tests/run-all-burst.sh
#
# Variables:
#   TARGET_HOST   IP/hostname del servidor con Nginx/Traefik (obligatorio)
#   SYSTEM        Etiqueta para los reportes: A o B (default: A)
#
# Los resultados JSON se guardan en load-tests/results/<SYSTEM>/burst-<nivel>.json
# Artillery debe estar instalado: npm install -g artillery

set -euo pipefail

TARGET_HOST="${TARGET_HOST:?Falta TARGET_HOST. Ej: TARGET_HOST=http://192.168.1.X ./run-all-burst.sh}"
SYSTEM="${SYSTEM:-A}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results/$SYSTEM"
SCENARIOS_DIR="$SCRIPT_DIR/scenarios"

mkdir -p "$RESULTS_DIR"

BURST_SCENARIOS=(burst-10to100 burst-50to400)

echo "=== Artillery burst/spike test — Sistema $SYSTEM ==="
echo "    Target:  $TARGET_HOST"
echo "    Results: $RESULTS_DIR"
echo ""

for NAME in "${BURST_SCENARIOS[@]}"; do
  SCENARIO="$SCENARIOS_DIR/vu-${NAME}.yml"
  OUTPUT="$RESULTS_DIR/${NAME}.json"

  echo "--- [$(date '+%H:%M:%S')] Corrida ${NAME} ---"

  TARGET_HOST="$TARGET_HOST" artillery run \
    --output "$OUTPUT" \
    "$SCENARIO"

  echo "    Reporte: $OUTPUT"
  echo ""

  if [[ "$NAME" != "${BURST_SCENARIOS[-1]}" ]]; then
    echo "    Esperando 30s antes de la próxima corrida..."
    sleep 30
  fi
done

echo "=== Todas las corridas burst completadas ==="
echo ""
echo "Para generar reportes HTML:"
for NAME in "${BURST_SCENARIOS[@]}"; do
  echo "  artillery report $RESULTS_DIR/${NAME}.json"
done
