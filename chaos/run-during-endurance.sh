#!/usr/bin/env bash
# run-during-endurance.sh — orquesta las 3 inyecciones de chaos existentes
# (kill-rabbitmq, pause-data-management, netem-delay-ew-da) DURANTE la corrida
# de 12h de load-tests/run-endurance.sh (Fase 2 del plan de pruebas), en vez
# de correrlas contra un sistema en reposo.
#
# Cadencia: 3 inyecciones espaciadas, una por escenario, con margen para que
# el sistema se recupere por completo entre una y la siguiente antes de medir
# el efecto de la próxima:
#   t=2h   kill-rabbitmq.sh            (mata el broker, mide MTTR + pérdida)
#   t=6h   pause-data-management.sh 30 (pausa una réplica, mide blast radius)
#   t=10h  netem-delay-ew-da.sh 2000 60 (latencia alta, mide circuit breaker)
#
# Uso: correr en paralelo con run-endurance.sh, apuntando al mismo host/infra:
#   cd tesis-infra
#   TARGET_HOST=http://<host> SUSTAINED_RATE=<tasa-fase-1> SYSTEM=B \
#     ./load-tests/run-endurance.sh &
#   ./chaos/run-during-endurance.sh &
#   wait
#
# Requiere Docker (Pumba) y Prometheus accesibles, igual que cada script
# individual (ver chaos/README.md). Los resultados de cada inyección van a
# chaos/results/ con su timestamp epoch, igual que si se corrieran solas —
# NO invalidan el criterio de éxito §2.4 de la Fase 2 (carga sostenida sin
# fallos inyectados); alimentan el criterio aparte §2.5 (tolerancia a fallos
# bajo carga sostenida).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATEWAY_URL="${GATEWAY_URL:-http://localhost/api/v1/data/health}"

# Offsets en segundos desde el inicio de esta corrida.
OFFSET_KILL_RABBITMQ=$((2 * 3600))
OFFSET_PAUSE_DATA_MGMT=$((6 * 3600))
OFFSET_NETEM_DELAY=$((10 * 3600))

start_ts=$(date +%s)

wait_until_offset() {
  local target_offset="$1"
  local now elapsed remaining
  now=$(date +%s)
  elapsed=$(( now - start_ts ))
  remaining=$(( target_offset - elapsed ))
  if [[ "$remaining" -gt 0 ]]; then
    echo "[$(date '+%H:%M:%S')] Esperando ${remaining}s hasta t+$(( target_offset / 3600 ))h..."
    sleep "$remaining"
  fi
}

echo "=== Orquestador de chaos durante endurance (12h) ==="
echo "    Inicio: $(date '+%Y-%m-%d %H:%M:%S')"
echo "    Inyecciones: t+2h kill-rabbitmq | t+6h pause-data-management | t+10h netem-delay"
echo ""

wait_until_offset "$OFFSET_KILL_RABBITMQ"
echo "--- [t+2h] Disparando kill-rabbitmq.sh ---"
"$SCRIPT_DIR/kill-rabbitmq.sh"

wait_until_offset "$OFFSET_PAUSE_DATA_MGMT"
echo "--- [t+6h] Disparando pause-data-management.sh (30s) ---"
"$SCRIPT_DIR/pause-data-management.sh" 30 "$GATEWAY_URL"

wait_until_offset "$OFFSET_NETEM_DELAY"
echo "--- [t+10h] Disparando netem-delay-ew-da.sh (2000ms, 60s) ---"
"$SCRIPT_DIR/netem-delay-ew-da.sh" 2000 60

echo ""
echo "=== 3 inyecciones completadas ==="
echo "    Ver resultados en chaos/results/ (prefijos kill-rabbitmq-*, pause-data-management-*, netem-delay-ew-da-*)"
