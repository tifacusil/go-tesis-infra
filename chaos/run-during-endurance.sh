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
# Los offsets se miden desde el arranque de ESTE script, no desde que la
# carga alcanza régimen sostenido — run-endurance.sh tiene 3 min de ramp-up
# antes de la fase sostenida (vu-sustained-12h.yml), así que "t+2h" cae en
# realidad ~3 min dentro de la ventana sostenida, no exactamente a las 2h00m00s
# de carga plena. Diferencia cosmética, no afecta la validez del experimento.
#
# Uso: correr en paralelo con run-endurance.sh, apuntando al mismo host/infra:
#   cd tesis-infra
#   TARGET_HOST=<host>:5000 SUSTAINED_RATE=<tasa-fase-1> SYSTEM=B \
#     ./load-tests/run-endurance.sh &
#   ./chaos/run-during-endurance.sh &   # GATEWAY_URL opcional — ver abajo
#   wait
#
# GATEWAY_URL: setearlo solo si el gateway HTTP es alcanzable directo (Sistema
# A). Para Sistema B (Traefik :80 no expuesto, solo TCP 5000 hacia afuera),
# dejarlo sin setear y tener SSH_HOST/SSH_USER + SSH_KEY_PATH|SSH_PASSWORD en
# load-tests/.env: pause-data-management.sh abre un túnel SSH automático al
# :80 del server para el sondeo — ver chaos/lib/gateway-tunnel.sh.
#
# Requiere Docker (Pumba) y Prometheus accesibles, igual que cada script
# individual (ver chaos/README.md). Los resultados de cada inyección van a
# chaos/results/ con su timestamp epoch, igual que si se corrieran solas —
# NO invalidan el criterio de éxito §2.4 de la Fase 2 (carga sostenida sin
# fallos inyectados); alimentan el criterio aparte §2.5 (tolerancia a fallos
# bajo carga sostenida).
#
# Una inyección que falla (Docker caído, contenedor renombrado, etc.) NO
# aborta las siguientes — se registra el fallo y se sigue con el próximo
# horario. Perder 1 de 3 inyecciones por un problema de infra puntual es
# preferible a perder las 3 restantes de una corrida de 12h por un solo
# fallo en la primera.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Sin default acá: se pasa vacío y pause-data-management.sh resuelve solo
# (GATEWAY_URL explícito > túnel SSH automático si SSH_HOST está seteado >
# localhost del stack local) — ver chaos/lib/gateway-tunnel.sh.
GATEWAY_URL="${GATEWAY_URL:-}"

# Offsets en segundos desde el inicio de esta corrida.
OFFSET_KILL_RABBITMQ=$((2 * 3600))
OFFSET_PAUSE_DATA_MGMT=$((6 * 3600))
OFFSET_NETEM_DELAY=$((10 * 3600))

start_ts=$(date +%s)
failures=0

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

# run_injection <etiqueta> <script...> — corre una inyección sin abortar el
# orquestador si falla; cuenta fallos para el resumen final.
run_injection() {
  local label="$1"; shift
  if ! "$@"; then
    echo "AVISO: la inyección '$label' terminó con error — se continúa con las siguientes programadas. Ver salida arriba para la causa." >&2
    failures=$((failures + 1))
  fi
}

echo "=== Orquestador de chaos durante endurance (12h) ==="
echo "    Inicio: $(date '+%Y-%m-%d %H:%M:%S')"
echo "    Inyecciones: t+2h kill-rabbitmq | t+6h pause-data-management | t+10h netem-delay"
echo ""

wait_until_offset "$OFFSET_KILL_RABBITMQ"
echo "--- [t+2h] Disparando kill-rabbitmq.sh ---"
run_injection "kill-rabbitmq" "$SCRIPT_DIR/kill-rabbitmq.sh"

wait_until_offset "$OFFSET_PAUSE_DATA_MGMT"
echo "--- [t+6h] Disparando pause-data-management.sh (30s) ---"
run_injection "pause-data-management" "$SCRIPT_DIR/pause-data-management.sh" 30 "$GATEWAY_URL"

wait_until_offset "$OFFSET_NETEM_DELAY"
echo "--- [t+10h] Disparando netem-delay-ew-da.sh (2000ms, 60s) ---"
run_injection "netem-delay-ew-da" "$SCRIPT_DIR/netem-delay-ew-da.sh" 2000 60

echo ""
if [[ "$failures" -eq 0 ]]; then
  echo "=== 3 inyecciones completadas sin errores ==="
else
  echo "=== 3 inyecciones intentadas, $failures fallaron (ver AVISOs arriba) ==="
fi
echo "    Ver resultados en chaos/results/ (prefijos kill-rabbitmq-*, pause-data-management-*, netem-delay-ew-da-*)"

if [[ "$failures" -gt 0 ]]; then
  exit 1
fi
