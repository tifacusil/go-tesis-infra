#!/usr/bin/env bash
# run-endurance.sh — Fase 2 (validación de resiliencia): carga máxima sostenida
# por 12 horas, a la tasa descubierta en Fase 1 (run-all.sh, escalones 001..400).
#
# Ingesta real es TCP (frames binarios DTU), no HTTP — ver README-engine.md.
# TARGET_HOST es "host" o "host:port" de una instancia data-receiving, SIN
# esquema http://.
#
# Uso:
#   TARGET_HOST=192.168.1.X:5000 SUSTAINED_RATE=100 ./load-tests/run-endurance.sh
#   TARGET_HOST=192.168.1.X:5000 SUSTAINED_RATE=100 SYSTEM=B ./load-tests/run-endurance.sh
#
# Variables:
#   TARGET_HOST     host:port de data-receiving (obligatorio, sin http://)
#   SUSTAINED_RATE  Tasa máxima de entrada (req/s) hallada en Fase 1, sin fallas (obligatorio)
#   SYSTEM          Etiqueta para los reportes: A o B (default: A)
#
# Resultado JSON: load-tests/results/<SYSTEM>/sustained-12h.json
# Artillery debe estar instalado: npm install -g artillery
#
# Referencia metodológica: Ortiz et al., carga máxima sostenida 12h para
# verificar que la tasa descubierta en la fase de escalones se soporta en
# periodos de tiempo más largos (no solo en ráfagas cortas de 10 min).

set -euo pipefail

TARGET_HOST="${TARGET_HOST:?Falta TARGET_HOST. Ej: TARGET_HOST=192.168.1.X:5000 ./run-endurance.sh}"
SUSTAINED_RATE="${SUSTAINED_RATE:?Falta SUSTAINED_RATE (tasa máxima hallada en Fase 1). Ej: SUSTAINED_RATE=100 ./run-endurance.sh}"
SYSTEM="${SYSTEM:-A}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results/$SYSTEM"
SCENARIO="$SCRIPT_DIR/scenarios/vu-sustained-12h.yml"
OUTPUT="$RESULTS_DIR/sustained-12h.json"
source "$SCRIPT_DIR/lib/grafana-annotate.sh"

export NODE_PATH="$SCRIPT_DIR"

if ! command -v artillery >/dev/null 2>&1; then
  echo "ERROR: 'artillery' no está en PATH. Instalar con: npm install -g artillery" >&2
  exit 1
fi

mkdir -p "$RESULTS_DIR"

echo "=== Artillery endurance test (12h) — Sistema $SYSTEM ==="
echo "    Target:         $TARGET_HOST"
echo "    Tasa sostenida: ${SUSTAINED_RATE} req/s"
echo "    Duración:       3 min ramp-up + 12h sostenidas"
echo "    Resultado:      $OUTPUT"
echo ""
echo "    Corrida inicia [$(date '+%Y-%m-%d %H:%M:%S')], termina ~$(date -d '+12 hours 3 minutes' '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '(+12h 3min)')"
echo "    Monitorear en paralelo: Grafana (throughput/latencia/CPU/mem), colas RabbitMQ, backlog Redis."
echo ""

"$SCRIPT_DIR/reset-state.sh" || echo "AVISO: reset-state falló, la corrida de 12h puede arrancar con estado residual (Redis backlog / alerts) de una corrida anterior." >&2

region_id=$(grafana_annotate_region_start "Fase 2 · Sistema $SYSTEM · sostenida ${SUSTAINED_RATE}req/s (12h)" "fase-2" "sistema-$SYSTEM" "sustained-rate-$SUSTAINED_RATE")
# Si la corrida de 12h muere a mitad de camino, igual queremos cerrar la
# anotación de Grafana con la hora real de corte, no dejarla abierta para
# siempre — de ahí el trap en vez de solo la llamada al final.
trap 'grafana_annotate_region_end "$region_id"' EXIT

TARGET_HOST="$TARGET_HOST" SUSTAINED_RATE="$SUSTAINED_RATE" artillery run \
  --output "$OUTPUT" \
  "$SCENARIO"

grafana_annotate_region_end "$region_id"
trap - EXIT

echo ""
echo "=== Corrida de 12h completada ==="
echo "    Reporte: artillery report $OUTPUT"
