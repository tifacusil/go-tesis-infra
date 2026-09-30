#!/usr/bin/env bash
# ap6-idempotency.sh — AP6: reinyectar un mensaje ya procesado, con el mismo
# message_id, no altera el estado. Automatiza docs/ap5-ap6-ap7-procedimientos.md
# §AP6 y deja la evidencia en chaos/results/ap6-<epoch>*.
#
# Qué hace:
#   1. Publica el evento representativo (lib/event.sh): lectura base + lectura
#      que alerta. sensor_id = <event_id>, message_id de la alerta = <event_id>-b.
#   2. Espera a que EW emita la alerta y data-management persista la lectura.
#   3. Espera SETTLE_SECONDS (AP6.2: la marca de idempotencia se escribe DESPUÉS
#      de procesar; reinyectar antes prueba otra cosa).
#   4. Reinyecta el envelope de la alerta BYTE A BYTE (mismo message_id, mismo
#      timestamp, mismo received_at): es exactamente el mensaje ya procesado.
#   5. Verifica los invariantes en los DOS consumidores del binding sensors.#.
#
# Criterios (todos obligatorios salvo los marcados "solo en reposo"):
#   EW  duplicate_skipped con trace_id=<id>-b ................ exactamente 1
#   EW  alert_emitted con trace_id=<id>-b ..................... exactamente 1 (no reemite)
#   EW  filas en early_warning.alerts del sensor .............. 1
#   DM  filas en data_management.gnss_readings de <id>-b ...... 1
#   DM  "insert ignorado, ack" con trace_id=<id>-b ............ exactamente 1
#   ew_duplicates_skipped_total ............................... +1  (solo en reposo)
#   ew_alerts_published_total tras la reinyección ............. +0  (solo en reposo)
# Los contadores globales solo son concluyentes sin carga de fondo; los
# criterios por trace_id y por fila valen igual con carga, porque el evento
# tiene ids propios.
#
# Requiere DM desplegado con go-data-management feat/ap6-duplicate-trace: sin
# eso el duplicado se descarta igual (INSERT IGNORE), pero sin traza, y el
# criterio "DM insert ignorado" falla. EW no requiere cambios: duplicate_skipped
# ya existía.
#
# Uso (Sistema B):
#   SSH_HOST=178.105.104.95 SSH_USER=gotesis SSH_KEY_PATH=~/.ssh/gotesis-key \
#     SUDO_PASSWORD=*** SSH_ORCHESTRATOR=k8s \
#     PROMETHEUS_ADDR=http://178.105.104.95:31083 \
#     ./chaos/ap6-idempotency.sh [event_id]
#
# Repetir >= 3 veces (un event_id nuevo cada vez; el default ya lo es).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/capture.sh"
source "$SCRIPT_DIR/lib/ssh.sh"
source "$SCRIPT_DIR/lib/event.sh"

EVENT_ID="${1:-ap6-$(date +%s)}"
ALERT_ID="${EVENT_ID}-b"
EW_MYSQL_POD="${EW_MYSQL_POD:-mysql-early-warning-0}"
DM_MYSQL_POD="${DM_MYSQL_POD:-mysql-data-management-0}"
SETTLE_SECONDS="${SETTLE_SECONDS:-5}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-60}"
# Por debajo de esta tasa de consumo (msg/s) se considera el sistema en reposo.
REST_RATE="${REST_RATE:-0.05}"

RUN_TS=$(date +%s)
BASE="$RESULTS_DIR/ap6-${RUN_TS}"

# Con set -e un comando que falla corta el script sin decir cual: esto lo nombra.
trap 'echo "ERROR: fallo el comando de la linea $LINENO de $(basename "$0") (ver la salida de arriba)" >&2' ERR

_ssh_require
# En modo local (CHAOS_LOCAL, corriendo en el nodo de B) el orquestador es k8s
# por definicion: _ssh_require ya verifico que kubectl hable con el cluster.
[[ "$CHAOS_LOCAL" == "1" ]] && SSH_ORCHESTRATOR="${SSH_ORCHESTRATOR:-k8s}"
exec > >(tee -a "${BASE}.log") 2>&1
if [[ "$SSH_ORCHESTRATOR" != "k8s" ]]; then
  echo "ERROR: AP6 verifica la idempotencia de early-warning y data-management del Sistema B" >&2
  echo "  (SSH_ORCHESTRATOR=k8s). El Sistema A no tiene la práctica bajo prueba." >&2
  exit 1
fi
if [[ "$(prom_query 'vector(1)')" != "1" ]]; then
  echo "ERROR: no se pudo consultar Prometheus en $PROMETHEUS_ADDR." >&2
  exit 1
fi

_counter() { prom_query "sum($1) or vector(0)"; }
_delta() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%g\n", b - a }'; }
_ew_rows() { mysql_query "$EW_MYSQL_POD" "SELECT COUNT(*) FROM early_warning.alerts WHERE sensor_id='$EVENT_ID'" | tail -1; }
_dm_rows() { mysql_query "$DM_MYSQL_POD" "SELECT COUNT(*) FROM data_management.gnss_readings WHERE message_id='$ALERT_ID'" | tail -1; }

EW_RAW="${BASE}-ew-raw.tmp"
DM_RAW="${BASE}-dm-raw.tmp"
_fetch_logs() {
  service_logs_since early-warning "$RUN_TS" > "$EW_RAW"
  service_logs_since data-management "$RUN_TS" > "$DM_RAW"
}

# _wait_event <archivo> <app> <evento> <trace_id> <n> — espera a que el evento
# aparezca n veces en los logs del servicio.
_wait_event() {
  local file="$1" app="$2" event="$3" trace="$4" want="$5"
  local deadline=$(( $(date +%s) + WAIT_TIMEOUT ))
  while [[ "$(date +%s)" -lt "$deadline" ]]; do
    service_logs_since "$app" "$RUN_TS" > "$file"
    if [[ "$(count_events "$file" "$event" "$trace")" -ge "$want" ]]; then
      return 0
    fi
    sleep 3
  done
  return 1
}

_cleanup() {
  local rc=$?
  # Evidencia: solo las líneas del evento (sus trace_id y su sensor_id). Los
  # logs completos de la ventana incluyen tráfico ajeno y no aportan.
  [[ -f "$EW_RAW" ]] && grep -F "$EVENT_ID" "$EW_RAW" > "${BASE}-ew.log" || true
  [[ -f "$DM_RAW" ]] && grep -F "$EVENT_ID" "$DM_RAW" > "${BASE}-dm.log" || true
  rm -f "$EW_RAW" "$DM_RAW"
  exit "$rc"
}
trap _cleanup EXIT

echo "=== AP6 — idempotencia (Sistema B) ==="
echo "    event_id:   $EVENT_ID   (sensor_id del evento)"
echo "    message_id: $ALERT_ID   (el que se reinyecta)"
echo "    Evidencia:  ${BASE}*"

# ── Estado inicial ────────────────────────────────────────────────────────────
rate=$(prom_query 'sum(rate(ew_messages_consumed_total[1m])) or vector(0)')
at_rest=$(awk -v r="$rate" -v t="$REST_RATE" 'BEGIN { print ((r+0) < t ? "si" : "no") }')
echo "    Consumo EW: ${rate} msg/s -> en reposo: ${at_rest}"
[[ "$at_rest" == "no" ]] && echo "    AVISO: con carga de fondo los contadores globales son solo informativos."

ew_rows0=$(_ew_rows)
dm_rows0=$(_dm_rows)
if [[ "$ew_rows0" != "0" || "$dm_rows0" != "0" ]]; then
  echo "ERROR: el evento ya tiene filas (EW=${ew_rows0}, DM=${dm_rows0}) — event_id reutilizado," >&2
  echo "  o la consulta a MySQL falló. Usar un event_id nuevo." >&2
  exit 1
fi

# ── 1. Primera inyección ──────────────────────────────────────────────────────
echo ""
echo "--- 1. Inyección del evento ---"
event_publish_pair "$EVENT_ID"
printf '%s\n' "$EVENT_ALERT_BODY" > "${BASE}-envelope.json"
first_at=$(date +%s)
echo "    Publicado a las $(_iso_utc "$first_at"). Envelope reinyectable -> ${BASE}-envelope.json"

echo "--- 2. Esperando alerta en EW y persistencia en DM (máx ${WAIT_TIMEOUT}s) ---"
if ! _wait_event "$EW_RAW" early-warning alert_emitted "$ALERT_ID" 1; then
  echo "ERROR: EW no emitió alert_emitted para $ALERT_ID. Sin la primera alerta no hay nada" >&2
  echo "  que deduplicar: revisar que EVENT_PROJECT='$EVENT_PROJECT' tenga umbrales en EW." >&2
  exit 1
fi
if ! _wait_event "$DM_RAW" data-management persistido "$ALERT_ID" 1; then
  echo "ERROR: data-management no persistió $ALERT_ID (¿rechazo por contrato? ver ${BASE}-dm.log)." >&2
  exit 1
fi
echo "    OK: alerta emitida y lectura persistida."

echo "--- 3. Esperando ${SETTLE_SECONDS}s (la marca de idempotencia se escribe tras procesar) ---"
sleep "$SETTLE_SECONDS"

ew_rows1=$(_ew_rows)
dm_rows1=$(_dm_rows)
dup1=$(_counter ew_duplicates_skipped_total)
alerts1=$(_counter ew_alerts_published_total)
echo "    Tras la primera inyección: filas EW=${ew_rows1} DM=${dm_rows1}"

# ── 4. Reinyección ────────────────────────────────────────────────────────────
echo ""
echo "--- 4. Reinyección del MISMO envelope (message_id=$ALERT_ID) ---"
event_publish "$EVENT_ALERT_BODY"
reinject_at=$(date +%s)
echo "    Reinyectado a las $(_iso_utc "$reinject_at")."

echo "--- 5. Esperando la detección del duplicado (máx ${WAIT_TIMEOUT}s) ---"
_wait_event "$EW_RAW" early-warning duplicate_skipped "$ALERT_ID" 1 || true
_wait_event "$DM_RAW" data-management "insert ignorado, ack" "$ALERT_ID" 1 || true
# Margen para que un reprocesamiento indebido (si lo hubiera) llegue a los logs
# antes de contar: sin esto, "no reemitió" podría ser "todavía no reemitió".
sleep "$SETTLE_SECONDS"
_fetch_logs

dup2=$(_counter ew_duplicates_skipped_total)
alerts2=$(_counter ew_alerts_published_total)
ew_rows2=$(_ew_rows)
dm_rows2=$(_dm_rows)

# ── Veredicto ─────────────────────────────────────────────────────────────────
fails=0
checks=()
_check() {
  local name="$1" want="$2" got="$3" mandatory="${4:-1}" status
  if [[ "$got" == "$want" ]]; then
    status="PASS"
  elif [[ "$mandatory" == "1" ]]; then
    status="FAIL"; fails=$(( fails + 1 ))
  else
    status="INFO"
  fi
  printf '  %-4s  %-52s esperado=%-3s observado=%s\n' "$status" "$name" "$want" "$got"
  checks+=("$name|$want|$got|$status")
}
rest_mandatory=$([[ "$at_rest" == "si" ]] && echo 1 || echo 0)

echo ""
echo "=== Resultado AP6 ==="
_check "EW duplicate_skipped (trace_id)"      1 "$(count_events "$EW_RAW" duplicate_skipped "$ALERT_ID")"
_check "EW alert_emitted (trace_id)"          1 "$(count_events "$EW_RAW" alert_emitted "$ALERT_ID")"
_check "EW filas early_warning.alerts"        1 "$ew_rows2"
_check "DM filas gnss_readings"               1 "$dm_rows2"
_check "DM insert ignorado (trace_id)"        1 "$(count_events "$DM_RAW" "insert ignorado, ack" "$ALERT_ID")"
_check "ew_duplicates_skipped_total (delta)"  1 "$(_delta "$dup1" "$dup2")" "$rest_mandatory"
_check "ew_alerts_published_total (delta)"    0 "$(_delta "$alerts1" "$alerts2")" "$rest_mandatory"

verdict=$([[ "$fails" -eq 0 ]] && echo "CUMPLE" || echo "NO CUMPLE")
{
  echo "test=AP6"
  echo "system=B"
  echo "run_ts=$RUN_TS"
  echo "event_id=$EVENT_ID"
  echo "message_id=$ALERT_ID"
  echo "first_injection_utc=$(_iso_utc "$first_at")"
  echo "reinjection_utc=$(_iso_utc "$reinject_at")"
  echo "at_rest=$at_rest"
  echo "ew_consume_rate=$rate"
  n=0
  for c in "${checks[@]}"; do
    n=$(( n + 1 ))
    echo "check_${n}=$c"
  done
  echo "verdict=$verdict"
} > "${BASE}-summary.env"

echo ""
echo "Veredicto AP6: $verdict"
echo "Evidencia: ${BASE}.log, ${BASE}-ew.log, ${BASE}-dm.log, ${BASE}-envelope.json, ${BASE}-summary.env"
[[ "$fails" -eq 0 ]]
