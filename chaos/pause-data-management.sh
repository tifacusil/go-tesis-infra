#!/usr/bin/env bash
# pause-data-management.sh — pausa (SIGSTOP, no mata) data-management-1 via
# pumba pause, para medir blast radius: ¿nginx round-robin (Sistema A) o
# Traefik (Sistema B) desvian trafico a data-management-2 sin degradacion
# visible al cliente? Se corre una rafaga de requests HTTP contra el gateway
# durante la pausa y se cuentan los codigos de respuesta.
#
# Uso: ./chaos/pause-data-management.sh [duration_seconds] [gateway_url]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/capture.sh"
source "$SCRIPT_DIR/../load-tests/lib/grafana-annotate.sh"

TARGET_CONTAINER="data-management-1"
DURATION="${1:-30}"
GATEWAY_URL="${2:-http://localhost/api/v1/data/health}"
LABEL="pause-data-management"

if ! [[ "$DURATION" =~ ^[0-9]+$ ]]; then
  echo "ERROR: duration_seconds debe ser un entero, recibido: '$DURATION'" >&2
  exit 1
fi

echo "=== Escenario: pause $TARGET_CONTAINER (${DURATION}s) ==="

echo "--- Snapshot pre-fallo ---"
pre_snapshot=$(snapshot_counters "${LABEL}-pre")
cat "$pre_snapshot"

region_id=$(grafana_annotate_region_start "Chaos · pause-data-management (${DURATION}s)" "chaos" "pause-data-management")
trap 'grafana_annotate_region_end "$region_id"' EXIT

echo ""
echo "--- Pausando $TARGET_CONTAINER (pumba pause, SIGSTOP) por ${DURATION}s ---"
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock gaiaadm/pumba:latest \
  pause --duration "${DURATION}s" "$TARGET_CONTAINER" &
pumba_pid=$!

# Confirma que pumba arrancó antes de gastar el ciclo completo de sondeo —
# si docker run falla de inmediato (Docker no corriendo, contenedor
# inexistente), el proceso ya habrá terminado acá y kill -0 lo detecta sin
# esperar los DURATION+5s del loop de abajo.
sleep 1
if ! kill -0 "$pumba_pid" 2>/dev/null; then
  echo "ERROR: pumba pause terminó casi de inmediato — probablemente falló (Docker no disponible, o $TARGET_CONTAINER no existe). El contenedor NO fue pausado; los resultados del sondeo abajo no miden blast radius real." >&2
  wait "$pumba_pid" || true
  exit 1
fi

echo "--- Sondeando $GATEWAY_URL cada 1s durante la pausa (blast radius al cliente) ---"
ok_count=0
fail_count=0
probe_end=$(( $(date +%s) + DURATION + 5 ))
while [[ "$(date +%s)" -lt "$probe_end" ]]; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 2 "$GATEWAY_URL" || echo "000")
  if [[ "$code" == "200" ]]; then
    ok_count=$((ok_count + 1))
  else
    fail_count=$((fail_count + 1))
    echo "  probe failed: http_code=$code"
  fi
  sleep 1
done

pumba_ok="true"
if ! wait "$pumba_pid"; then
  pumba_ok="false"
  echo "ERROR: pumba pause terminó con error — la pausa puede no haber cubierto toda la ventana de sondeo." >&2
fi

echo "--- Snapshot post-recuperacion ---"
post_snapshot=$(snapshot_counters "${LABEL}-post")
cat "$post_snapshot"

echo ""
echo "=== Resumen (blast radius) ==="
echo "Requests OK durante la pausa:     $ok_count"
echo "Requests fallidos durante la pausa: $fail_count"
if [[ "$pumba_ok" != "true" ]]; then
  echo "AVISO: pumba falló durante la corrida — estos conteos NO son confiables como medición de blast radius." >&2
elif [[ "$fail_count" -eq 0 ]]; then
  echo "Blast radius = 0: el balanceador desvio todo el trafico a data-management-2."
else
  echo "Blast radius > 0: hubo requests afectados pese a tener 2 replicas."
fi
echo "Ver snapshots en: $pre_snapshot / $post_snapshot"

if [[ "$pumba_ok" != "true" ]]; then
  exit 1
fi
