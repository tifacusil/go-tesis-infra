#!/usr/bin/env bash
# run-all-burst.sh — Corre los escenarios burst/spike (extension a run-all.sh,
# que solo cubre steady-state). Cada escenario intercala una fase de baseline,
# un spike sostenido y una fase de recovery, para comparar contra el
# comportamiento steady-state ya medido (throughput/latencia/CPU/mem durante
# el spike vs. sostenido). Ver El Fellah et al. (2026), trabajo futuro.
#
# Ingesta real es TCP (frames binarios DTU), no HTTP — ver README-engine.md.
# TARGET_HOST es "host" o "host:port" de una instancia data-receiving, SIN
# esquema http://.
#
# Uso:
#   TARGET_HOST=192.168.1.X:5000 ./load-tests/run-all-burst.sh
#   TARGET_HOST=192.168.1.X:5000 SYSTEM=B ./load-tests/run-all-burst.sh
#
# Variables:
#   TARGET_HOST   host:port de data-receiving (obligatorio, sin http://)
#   SYSTEM        Etiqueta para los reportes: A o B (default: A)
#
# Los resultados JSON se guardan en load-tests/results/<SYSTEM>/burst-<nivel>.json
# Artillery debe estar instalado: npm install -g artillery

set -euo pipefail

TARGET_HOST="${TARGET_HOST:?Falta TARGET_HOST. Ej: TARGET_HOST=192.168.1.X:5000 ./run-all-burst.sh}"
SYSTEM="${SYSTEM:-A}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results/$SYSTEM"
SCENARIOS_DIR="$SCRIPT_DIR/scenarios"
source "$SCRIPT_DIR/lib/grafana-annotate.sh"
source "$SCRIPT_DIR/lib/check-dtu-emulator.sh"

export NODE_PATH="$SCRIPT_DIR"

if ! command -v artillery >/dev/null 2>&1; then
  echo "ERROR: 'artillery' no está en PATH. Instalar con: npm install -g artillery" >&2
  exit 1
fi

echo "Verificando dtu-emulator antes de arrancar..."
if ! check_dtu_emulator "$SCRIPT_DIR"; then
  exit 1
fi

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

  "$SCRIPT_DIR/reset-state.sh" || echo "AVISO: reset-state falló, la corrida $NAME puede arrancar con estado residual de la anterior." >&2

  region_id=$(grafana_annotate_region_start "Burst · Sistema $SYSTEM · $NAME" "burst" "sistema-$SYSTEM" "$NAME")
  trap 'grafana_annotate_region_end "$region_id"' EXIT

  TARGET_HOST="$TARGET_HOST" artillery run \
    --output "$OUTPUT" \
    "$SCENARIO"

  grafana_annotate_region_end "$region_id"
  trap - EXIT

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
