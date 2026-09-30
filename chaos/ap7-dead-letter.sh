#!/usr/bin/env bash
# ap7-dead-letter.sh — AP7: un mensaje que falla de forma consistente se
# reintenta un número ACOTADO de veces y luego va a sensors.dead_letter.
# Automatiza docs/ap5-ap6-ap7-procedimientos.md §AP7 y deja la evidencia en
# chaos/results/ap7-<epoch>*.
#
# ── Cómo se provoca el fallo (y por qué no se tumba MySQL) ──────────────────
# El único error reintentable de EW es la persistencia de la alerta (AP7.1). El
# procedimiento proponía escalar mysql-early-warning a 0, pero la liveness de EW
# es GET /health, que responde 503 sin MySQL: a los ~45 s kubelet reinicia EW,
# la prueba mide reinicios en vez de reintentos y los logs del contenedor muerto
# se pierden. Revocar INSERT tampoco sirve: el grant es a nivel de esquema
# (early_warning.*) y MySQL no aplica esos cambios a las conexiones ya abiertas
# del pool.
#
# Se usa un trigger BEFORE INSERT sobre early_warning.alerts que hace SIGNAL
# solo para el sensor_id del evento:
#   - falla exactamente la alerta de la prueba; el resto del tráfico no se toca;
#   - /health sigue sano (Ping no inserta), EW no se reinicia;
#   - el error queda en el log con un texto que lo identifica como inyectado;
#   - se revierte con DROP TRIGGER (en el trap, pase lo que pase).
# Antes de usarlo se AUTOVERIFICA: RecordAlert usa INSERT IGNORE, y si IGNORE
# absorbiera el SIGNAL la fila se descartaría en silencio y no habría reintento.
#
# ── Cómo se identifica el mensaje en la DLQ ──────────────────────────────────
# sensors.dead_letter puede tener millones de mensajes (la endurance derivó >1M)
# y no se puede recorrer. Se enlaza una cola sonda temporal a sensors.dlx con
# '#': recibe una copia de todo lo que se deriva DURANTE la prueba, y ahí se
# busca el message_id y su cabecera x-death (cola de origen, motivo, conteo).
# La cola sonda expira sola a los 30 min aunque el script muera.
#
# Criterios:
#   requeue con trace_id=<id>-b ................ exactamente CONSUMER_MAX_RETRIES (3)
#   attempt de esos requeue .................... 1,2,3
#   dead_lettered .............................. 1, con attempts = 4
#   el mensaje llega a sensors.dlx ............. 1 (x-death: early_warning.evaluate, rejected)
#   requeue posteriores al dead_lettered ....... 0 (esperando QUIET_SECONDS)
#   filas del sensor en early_warning.alerts ... 0
#   sensors.dead_letter (delta) ................ +1 (solo en reposo)
# Se registran además, como hallazgo, los intervalos entre intentos (backoff) y
# los efectos laterales de cada intento (publicación/push antes del INSERT).
#
# Uso (Sistema B):
#   SSH_HOST=178.105.104.95 SSH_USER=gotesis SSH_KEY_PATH=~/.ssh/gotesis-key \
#     SUDO_PASSWORD=*** SSH_ORCHESTRATOR=k8s \
#     PROMETHEUS_ADDR=http://178.105.104.95:31083 \
#     ./chaos/ap7-dead-letter.sh [event_id]
#
# Usar un event_id NUEVO en cada repetición (el default ya lo es): el contador
# de reintentos vive en Redis keyed por message_id (AP7.3).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/capture.sh"
source "$SCRIPT_DIR/lib/ssh.sh"
source "$SCRIPT_DIR/lib/event.sh"

EVENT_ID="${1:-ap7-$(date +%s)}"
ALERT_ID="${EVENT_ID}-b"
MAX_RETRIES="${CONSUMER_MAX_RETRIES:-3}"
EW_MYSQL_POD="${EW_MYSQL_POD:-mysql-early-warning-0}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-90}"
QUIET_SECONDS="${QUIET_SECONDS:-15}"
REST_RATE="${REST_RATE:-0.05}"

RUN_TS=$(date +%s)
BASE="$RESULTS_DIR/ap7-${RUN_TS}"
TRIGGER="ap7_block_${RUN_TS}"
PROBE_QUEUE="ap7.probe.${RUN_TS}"
EW_RAW="${BASE}-ew-raw.tmp"

# Con set -e un comando que falla corta el script sin decir cual: esto lo nombra.
trap 'echo "ERROR: fallo el comando de la linea $LINENO de $(basename "$0") (ver la salida de arriba)" >&2' ERR

_ssh_require
# En modo local (CHAOS_LOCAL, corriendo en el nodo de B) el orquestador es k8s
# por definicion: _ssh_require ya verifico que kubectl hable con el cluster.
[[ "$CHAOS_LOCAL" == "1" ]] && SSH_ORCHESTRATOR="${SSH_ORCHESTRATOR:-k8s}"
exec > >(tee -a "${BASE}.log") 2>&1
if [[ "$SSH_ORCHESTRATOR" != "k8s" ]]; then
  echo "ERROR: AP7 verifica el retry acotado -> DLQ de early-warning del Sistema B (SSH_ORCHESTRATOR=k8s)." >&2
  exit 1
fi
if [[ "$(prom_query 'vector(1)')" != "1" ]]; then
  echo "ERROR: no se pudo consultar Prometheus en $PROMETHEUS_ADDR." >&2
  exit 1
fi
PY=$(_pq_python) || { echo "ERROR: hace falta python/py local para analizar los logs." >&2; exit 1; }

_ew_rows() { mysql_query "$EW_MYSQL_POD" "SELECT COUNT(*) FROM early_warning.alerts WHERE sensor_id='$EVENT_ID'" | tail -1; }

trigger_created=0
probe_created=0
_cleanup() {
  local rc=$?
  echo ""
  echo "--- Limpieza: trigger y cola sonda ---"
  if [[ "$trigger_created" == "1" ]]; then
    mysql_query "$EW_MYSQL_POD" "DROP TRIGGER IF EXISTS early_warning.$TRIGGER" >/dev/null || true
    if mysql_query "$EW_MYSQL_POD" "SHOW TRIGGERS FROM early_warning LIKE 'alerts'" | grep -q "$TRIGGER"; then
      echo "ERROR CRÍTICO: el trigger $TRIGGER sigue activo. Quitarlo a mano:" >&2
      echo "  kubectl -n $K8S_NAMESPACE exec $EW_MYSQL_POD -- sh -c 'mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" -e \"DROP TRIGGER early_warning.$TRIGGER\"'" >&2
      rc=1
    else
      echo "    Trigger $TRIGGER eliminado."
    fi
  fi
  if [[ "$probe_created" == "1" ]]; then
    rabbit_api DELETE "/api/queues/%2F/${PROBE_QUEUE}" >/dev/null 2>&1 || true
    echo "    Cola sonda $PROBE_QUEUE eliminada (expira sola a los 30 min si esto falló)."
  fi
  [[ -f "$EW_RAW" ]] && grep -F "$EVENT_ID" "$EW_RAW" > "${BASE}-ew.log" || true
  rm -f "$EW_RAW"
  exit "$rc"
}
trap _cleanup EXIT

echo "=== AP7 — retry acotado -> dead letter (Sistema B) ==="
echo "    event_id:   $EVENT_ID   (sensor_id del evento)"
echo "    message_id: $ALERT_ID   (el que debe terminar en la DLQ)"
echo "    Reintentos: CONSUMER_MAX_RETRIES=$MAX_RETRIES"
echo "    Evidencia:  ${BASE}*"

rate=$(prom_query 'sum(rate(ew_messages_consumed_total[1m])) or vector(0)')
at_rest=$(awk -v r="$rate" -v t="$REST_RATE" 'BEGIN { print ((r+0) < t ? "si" : "no") }')
echo "    Consumo EW: ${rate} msg/s -> en reposo: ${at_rest}"
[[ "$at_rest" == "no" ]] && echo "    AVISO: con carga de fondo el delta de sensors.dead_letter es solo informativo."

# ── Preparación del fallo ─────────────────────────────────────────────────────
echo ""
echo "--- 1. Trigger de fallo sobre early_warning.alerts (solo sensor_id=$EVENT_ID) ---"
# Triggers de corridas anteriores que no llegaron a limpiarse (script cortado,
# o el fallo de mysql_query del 2026-09-29). Cada uno solo afecta al sensor de
# su propia corrida, pero no deben quedar en la base.
stale=$(mysql_query "$EW_MYSQL_POD" "SELECT TRIGGER_NAME FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA='early_warning' AND TRIGGER_NAME LIKE 'ap7_block_%'")
if [[ "$stale" == *ERROR* ]]; then
  echo "ERROR: no se pudo consultar MySQL de early-warning: $stale" >&2
  exit 1
fi
for t in $stale; do
  mysql_query "$EW_MYSQL_POD" "DROP TRIGGER IF EXISTS early_warning.$t" >/dev/null
  echo "    Eliminado trigger viejo: $t"
done

# Se marca ANTES de crearlo: si el script muere entre el CREATE y la marca, la
# limpieza igual intenta el DROP (IF EXISTS, así que no falla si no existe).
trigger_created=1
out=$(mysql_query "$EW_MYSQL_POD" "CREATE TRIGGER early_warning.$TRIGGER BEFORE INSERT ON early_warning.alerts FOR EACH ROW BEGIN IF NEW.sensor_id = '$EVENT_ID' THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'AP7: fallo de persistencia inyectado'; END IF; END")
if [[ "$out" == *ERROR* ]]; then
  echo "ERROR: no se pudo crear el trigger: $out" >&2
  exit 1
fi

# Autoverificación: el mismo INSERT IGNORE que hace RecordAlert, en una
# transacción que no se confirma. Tiene que FALLAR con el SIGNAL; si pasa, IGNORE
# lo absorbió y la prueba no ejercitaría ningún reintento.
selftest=$(mysql_query "$EW_MYSQL_POD" "START TRANSACTION// INSERT IGNORE INTO early_warning.alerts (created_at, message_id, project_id, sensor_id, alert_level, alert_timestamp) VALUES (UTC_TIMESTAMP(), 'ap7-selftest-$RUN_TS', '$EVENT_PROJECT', '$EVENT_ID', 'red', UTC_TIMESTAMP())// ROLLBACK")
if [[ "$selftest" != *"AP7: fallo de persistencia inyectado"* ]]; then
  echo "ERROR: el INSERT IGNORE de prueba NO falló (salida: ${selftest:-<vacía>})." >&2
  echo "  El trigger no bloquea la escritura que hace EW: la prueba no ejercitaría reintentos." >&2
  exit 1
fi
echo "    Autoverificado: INSERT IGNORE sobre el sensor falla con el SIGNAL inyectado."

echo "--- 2. Cola sonda $PROBE_QUEUE enlazada a sensors.dlx ---"
rabbit_api PUT "/api/queues/%2F/${PROBE_QUEUE}" '{"durable":false,"auto_delete":false,"arguments":{"x-expires":1800000}}' >/dev/null
probe_created=1
rabbit_api POST "/api/bindings/%2F/e/sensors.dlx/q/${PROBE_QUEUE}" '{"routing_key":"#","arguments":{}}' >/dev/null
if ! rabbit_api GET "/api/queues/%2F/${PROBE_QUEUE}/bindings" | grep -qE '"source"[[:space:]]*:[[:space:]]*"sensors\.dlx"'; then
  echo "ERROR: la cola sonda no quedó enlazada a sensors.dlx." >&2
  exit 1
fi
echo "    OK."

dlq0=$(rabbit_queue_messages sensors.dead_letter || echo "")
echo "    sensors.dead_letter antes: ${dlq0:-?} mensajes"

# ── Inyección ─────────────────────────────────────────────────────────────────
echo ""
echo "--- 3. Inyección del evento ---"
event_publish_pair "$EVENT_ID"
inject_at=$(date +%s)
echo "    Publicado a las $(_iso_utc "$inject_at")."

echo "--- 4. Esperando dead_lettered para $ALERT_ID (máx ${WAIT_TIMEOUT}s) ---"
deadline=$(( inject_at + WAIT_TIMEOUT ))
dead_seen=0
while [[ "$(date +%s)" -lt "$deadline" ]]; do
  service_logs_since early-warning "$RUN_TS" > "$EW_RAW"
  if [[ "$(count_events "$EW_RAW" dead_lettered "$ALERT_ID")" -ge 1 ]]; then
    dead_seen=1
    break
  fi
  sleep 3
done
if [[ "$dead_seen" == "0" ]]; then
  echo "    AVISO: no apareció dead_lettered en ${WAIT_TIMEOUT}s. Si hay requeue sin fin, verificar" \
       "Redis (bumpRetry devuelve 1 si Redis falla, AP7.3)."
fi

echo "--- 5. Ventana de silencio (${QUIET_SECONDS}s): no debe haber más reintentos ---"
sleep "$QUIET_SECONDS"
service_logs_since early-warning "$RUN_TS" > "$EW_RAW"
ew_rows=$(_ew_rows)
dlq1=$(rabbit_queue_messages sensors.dead_letter || echo "")

# ── Análisis ─────────────────────────────────────────────────────────────────
# Secuencia de intentos desde los logs JSON (con el pod que atendió cada uno),
# intervalos entre intentos y efectos laterales por intento.
analysis=$(TRACE="$ALERT_ID" "$PY" - "$EW_RAW" <<'PY'
import json, os, re, sys
from datetime import datetime
trace = os.environ["TRACE"]

def parse_time(s):
    # slog escribe RFC3339Nano (hasta 9 decimales); fromisoformat de Python
    # < 3.11 acepta como mucho 6. Se trunca a microsegundos.
    s = s.replace("Z", "+00:00")
    s = re.sub(r"(\.\d{6})\d+", r"\1", s)
    return datetime.fromisoformat(s)

rows = []
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    i = line.find("{")
    if i < 0:
        continue
    pod = line[:i].strip().strip("[]").split("/")[1] if line.startswith("[pod/") else ""
    try:
        j = json.loads(line[i:])
    except ValueError:
        continue
    if j.get("trace_id") != trace:
        continue
    t = parse_time(j["time"])
    rows.append((t, j.get("msg"), j, pod))
rows.sort(key=lambda r: r[0])
requeues = [r for r in rows if r[1] == "requeue"]
dead = [r for r in rows if r[1] == "dead_lettered"]
side = [r for r in rows if r[1] in ("push_delivered", "push_skipped_no_tokens", "push_flow_failed")]
emitted = [r for r in rows if r[1] == "alert_emitted"]
failed = [r for r in rows if r[1] == "db_record_failed"]
attempts = [str(r[2].get("attempt")) for r in requeues]
after_dead = [r for r in requeues if dead and r[0] > dead[0][0]]
marks = [r[0] for r in failed]
gaps = [f"{(b - a).total_seconds() * 1000:.0f}" for a, b in zip(marks, marks[1:])]
print(f"requeue_count={len(requeues)}")
print(f"requeue_attempts={','.join(attempts)}")
print(f"dead_lettered_count={len(dead)}")
print(f"dead_lettered_attempts={dead[0][2].get('attempts') if dead else ''}")
print(f"requeue_after_dead={len(after_dead)}")
print(f"db_record_failed_count={len(failed)}")
print(f"alert_emitted_count={len(emitted)}")
print(f"push_side_effects={len(side)}")
print(f"attempt_gaps_ms={','.join(gaps)}")
print(f"pods={','.join(sorted({r[3] for r in failed if r[3]}))}")
for t, msg, j, pod in rows:
    extra = j.get("attempt", j.get("attempts", ""))
    err = j.get("err", "")
    print(f"timeline={t.isoformat()} {pod} {msg} {extra} {err}".rstrip())
PY
) || true
_get() { grep -m1 "^$1=" <<<"$analysis" | cut -d= -f2- || true; }

PROBE_RAW="${BASE}-probe.tmp"
rabbit_api POST "/api/queues/%2F/${PROBE_QUEUE}/get" \
  '{"count":500,"ackmode":"ack_requeue_false","encoding":"auto","truncate":50000}' > "$PROBE_RAW" || echo "[]" > "$PROBE_RAW"
probe_analysis=$(MID="$ALERT_ID" "$PY" - "$PROBE_RAW" <<'PY'
import json, os, sys
mid = os.environ["MID"]
try:
    msgs = json.load(open(sys.argv[1], encoding="utf-8"))
except ValueError:
    msgs = []
needle = '"message_id":"%s"' % mid
hit = [m for m in msgs if needle in (m.get("payload") or "")]
print("probe_total=%d" % len(msgs))
print("probe_found=%d" % len(hit))
if hit:
    headers = hit[0].get("properties", {}).get("headers") or {}
    deaths = headers.get("x-death") or []
    d = deaths[0] if deaths else {}
    print("xdeath_queue=%s" % d.get("queue", ""))
    print("xdeath_reason=%s" % d.get("reason", ""))
    print("xdeath_count=%s" % d.get("count", ""))
PY
) || true
rm -f "$PROBE_RAW"
_pget() { grep -m1 "^$1=" <<<"$probe_analysis" | cut -d= -f2- || true; }

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
  printf '  %-4s  %-46s esperado=%-24s observado=%s\n' "$status" "$name" "$want" "$got"
  checks+=("$name|$want|$got|$status")
}
want_attempts=$(seq -s, 1 "$MAX_RETRIES")
dlq_delta=""
[[ -n "$dlq0" && -n "$dlq1" ]] && dlq_delta=$(( dlq1 - dlq0 ))
rest_mandatory=$([[ "$at_rest" == "si" ]] && echo 1 || echo 0)

echo ""
echo "=== Línea de tiempo del mensaje $ALERT_ID ==="
grep '^timeline=' <<<"$analysis" | cut -d= -f2- | sed 's/^/  /' || echo "  (sin líneas con trace_id=$ALERT_ID)"

echo ""
echo "=== Resultado AP7 ==="
_check "requeue (cantidad)"                   "$MAX_RETRIES"              "$(_get requeue_count)"
_check "requeue (attempt)"                    "$want_attempts"            "$(_get requeue_attempts)"
_check "dead_lettered (cantidad)"             1                           "$(_get dead_lettered_count)"
_check "dead_lettered (attempts)"             "$(( MAX_RETRIES + 1 ))"    "$(_get dead_lettered_attempts)"
_check "mensaje en sensors.dlx (sonda)"       1                           "$(_pget probe_found)"
_check "x-death queue"                        early_warning.evaluate      "$(_pget xdeath_queue)"
_check "x-death reason"                       rejected                    "$(_pget xdeath_reason)"
_check "requeue tras dead_lettered"           0                           "$(_get requeue_after_dead)"
_check "filas del sensor en alerts"           0                           "$ew_rows"
_check "sensors.dead_letter (delta)"          1                           "${dlq_delta:-?}" "$rest_mandatory"

echo ""
echo "Observaciones (no son criterio de AP7, pero son evidencia del mecanismo):"
echo "  Intervalo entre intentos (ms):   $(_get attempt_gaps_ms)   (CLAUDE.md §4 pide backoff 1s/5s/30s)"
echo "  Efectos laterales push_* por el mensaje: $(_get push_side_effects) en $(_get db_record_failed_count) intentos fallidos"
echo "    (la alerta se publica y se resuelve el push ANTES del INSERT; cada reintento los repite)"
echo "  Réplicas que atendieron intentos: $(_get pods)"
probe_total=$(_pget probe_total)
probe_found=$(_pget probe_found)
echo "  Otros mensajes derivados a la DLX durante la prueba: $(( ${probe_total:-0} - ${probe_found:-0} ))"

verdict=$([[ "$fails" -eq 0 ]] && echo "CUMPLE" || echo "NO CUMPLE")
{
  echo "test=AP7"
  echo "system=B"
  echo "run_ts=$RUN_TS"
  echo "event_id=$EVENT_ID"
  echo "message_id=$ALERT_ID"
  echo "injection_utc=$(_iso_utc "$inject_at")"
  echo "failure_mechanism=trigger BEFORE INSERT early_warning.alerts (SIGNAL 45000, sensor_id=$EVENT_ID)"
  echo "consumer_max_retries=$MAX_RETRIES"
  echo "at_rest=$at_rest"
  echo "ew_consume_rate=$rate"
  echo "dlq_before=$dlq0"
  echo "dlq_after=$dlq1"
  grep -v '^timeline=' <<<"$analysis" || true
  echo "$probe_analysis"
  n=0
  for c in "${checks[@]}"; do
    n=$(( n + 1 ))
    echo "check_${n}=$c"
  done
  echo "verdict=$verdict"
} > "${BASE}-summary.env"

echo ""
echo "Veredicto AP7: $verdict"
echo "Evidencia: ${BASE}.log, ${BASE}-ew.log, ${BASE}-summary.env"
[[ "$fails" -eq 0 ]]
