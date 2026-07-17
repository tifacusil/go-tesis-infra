#!/usr/bin/env bash
# run-during-endurance.sh — orquesta las inyecciones de chaos DURANTE la corrida
# de 12h de load-tests/run-endurance.sh (Fase 2 del plan de pruebas), en vez de
# correrlas contra un sistema en reposo.
#
# Cadencia: inyecciones espaciadas, una por escenario, con margen para que el
# sistema se recupere por completo entre una y la siguiente:
#   t=2h   kill-rabbitmq.sh                (mata el broker, mide MTTR)
#   t=6h   pause-data-management.sh 90     (congela una replica, mide blast radius)
#   t=10h  netem-delay-ew-da.sh 8000 180   (latencia alta, mide circuit breaker) [solo B]
#
# Los offsets se miden desde el arranque de ESTE script, no desde que la carga
# alcanza régimen sostenido — run-endurance.sh tiene 3 min de ramp-up antes de
# la fase sostenida (vu-sustained-12h.yml), así que "t+2h" cae en realidad ~3
# min dentro de la ventana sostenida. Diferencia cosmética.
#
# ── Preflight (lo más importante de este script) ─────────────────────────────
# Antes de esperar la primera inyección se valida TODO lo que necesita: SSH,
# sudo, Prometheus, gateway y que el target exista. Sin esto, un typo en las
# credenciales se descubre recién a las 2h de corrida, con las 3 inyecciones
# perdidas y una ventana de 12h que hay que rehacer desde cero.
#
# ── Por sistema ──────────────────────────────────────────────────────────────
# SSH_ORCHESTRATOR es obligatorio: define contra qué sistema se inyecta y cómo.
#   - native (Sistema A): kill-rabbitmq + pause-data-management. netem-delay se
#     SALTEA: no está implementado para A y, sobre todo, A no tiene circuit
#     breaker — el observable de ese escenario no existe ahí. Saltearlo no
#     cuenta como fallo.
#   - k8s (Sistema B): los 3 escenarios.
#
# Uso: correr en paralelo con run-endurance.sh, apuntando al mismo sistema:
#   TARGET_HOST=<host>:5000 SUSTAINED_RATE=<tasa-fase-1> SYSTEM=B \
#     ./load-tests/run-endurance.sh &
#   SSH_HOST=178.105.104.95 SSH_USER=gotesis SSH_KEY_PATH=~/.ssh/gotesis-key \
#     SUDO_PASSWORD=*** SSH_ORCHESTRATOR=k8s \
#     PROMETHEUS_ADDR=http://178.105.104.95:31083 \
#     ./chaos/run-during-endurance.sh &
#   wait
#
# Los resultados de cada inyección van a chaos/results/ con su timestamp, igual
# que si se corrieran solas — NO invalidan el criterio §2.4 (carga sostenida sin
# fallos inyectados); alimentan el criterio aparte §2.5 (tolerancia a fallos
# bajo carga sostenida).
#
# Una inyección que falla NO aborta las siguientes: perder 1 de 3 por un
# problema puntual es preferible a perder las 2 restantes de una corrida de 12h.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/capture.sh"
source "$SCRIPT_DIR/lib/ssh.sh"
source "$SCRIPT_DIR/../load-tests/lib/grafana-annotate.sh"

# ── Vigilancia de conectividad ───────────────────────────────────────────────
# El generador de carga corre en esta máquina y el sistema bajo prueba está del
# otro lado de Internet. Un corte de red deja un agujero en los datos que, desde
# Grafana, se ve IGUAL que si el sistema hubiera dejado de procesar: throughput
# a cero. Sin evidencia de que fue la red, ese tramo se lee como una falla del
# sistema y contamina la conclusión.
#
# No es hipotético: el 2026-07-16 el Sistema A quedó inalcanzable 26 minutos
# (20:20 -> 20:46 UTC) con el host perfectamente vivo — sshd aceptando
# conexiones de otros, ningún servicio reiniciado, ningún reboot. Simplemente el
# tráfico desde acá no llegaba.
#
# Este watcher no puede evitar el corte, pero deja constancia: anota la ventana
# en Grafana y la escribe a un log, para poder excluir el tramo del análisis en
# vez de discutir si el sistema se cayó.
CONN_PROBE_INTERVAL="${CONN_PROBE_INTERVAL:-15}"
CONN_PROBE_TIMEOUT="${CONN_PROBE_TIMEOUT:-8}"
# 3 fallos (~45s) antes de declarar corte: un timeout suelto es ruido normal de
# Internet y no merece una anotación.
CONN_FAIL_THRESHOLD="${CONN_FAIL_THRESHOLD:-3}"

# Offsets en segundos desde el inicio de esta corrida. Overridables para poder
# probar el orquestador sin esperar 12h (ej. OFFSET_KILL_RABBITMQ=5).
OFFSET_KILL_RABBITMQ="${OFFSET_KILL_RABBITMQ:-$((2 * 3600))}"
OFFSET_PAUSE_DATA_MGMT="${OFFSET_PAUSE_DATA_MGMT:-$((6 * 3600))}"
OFFSET_NETEM_DELAY="${OFFSET_NETEM_DELAY:-$((10 * 3600))}"

# Parámetros de cada escenario. Los defaults NO son arbitrarios:
#   PAUSE_DURATION=90: con menos de ~50s, B cae en zona muerta — su readiness
#     recién saca el pod de Endpoints a los ~35s y el resultado diría "nunca
#     desvió" por la ventana corta, no por el sistema.
#   NETEM_DELAY_MS=8000: tiene que superar DATA_ANALYSIS_TIMEOUT_MS (5000). Un
#     delay menor no produce fallos (la llamada responde lenta pero OK) y el
#     breaker no puede abrir: el escenario "pasaría" sin medir nada.
PAUSE_DURATION="${PAUSE_DURATION:-90}"
NETEM_DELAY_MS="${NETEM_DELAY_MS:-8000}"
NETEM_DURATION="${NETEM_DURATION:-180}"

start_ts=$(date +%s)
failures=0
skipped=0

_ssh_require
case "${SSH_ORCHESTRATOR:-}" in
  native) SYSTEM_TAG="Sistema A (systemd nativo)"; SYSTEM_TAG_SHORT="sistema-A" ;;
  k8s)    SYSTEM_TAG="Sistema B (k3s)";            SYSTEM_TAG_SHORT="sistema-B" ;;
  *)
    echo "ERROR: SSH_ORCHESTRATOR es obligatorio — 'native' (Sistema A) o 'k8s' (Sistema B)." >&2
    echo "  Define contra qué sistema se inyecta y cómo. Sin esto el orquestador no sabe si el" >&2
    echo "  broker es un pod o una unit de systemd, y las inyecciones fallarían a las 2h de corrida." >&2
    exit 1
    ;;
esac

# ── Preflight ────────────────────────────────────────────────────────────────
echo "=== Preflight (antes de comprometer 12h de corrida) ==="
preflight_errors=0
_check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "  OK   $desc"
  else
    echo "  FALLA $desc" >&2
    preflight_errors=$((preflight_errors + 1))
  fi
}

_check "SSH a $SSH_USER@$SSH_HOST" _ssh_run "true"
_check "sudo remoto" _sudo_run "id -u"

if [[ "$(prom_query 'vector(1)')" == "1" ]]; then
  echo "  OK   Prometheus en $PROMETHEUS_ADDR (SYSTEM=${SYSTEM:-?})"
else
  echo "  FALLA Prometheus en $PROMETHEUS_ADDR — los snapshots quedarían vacíos" >&2
  preflight_errors=$((preflight_errors + 1))
fi

# Funcion y no `bash -c "... _sudo_run ..."`: bash -c abre un shell nuevo donde
# las funciones de lib/ssh.sh no existen, y el chequeo daria FALLA siempre.
_check_rabbit_unit() {
  local pid
  pid=$(_sudo_run "systemctl show rabbitmq-server -p MainPID --value" 2>/dev/null | tr -d '\r')
  [[ -n "$pid" && "$pid" != "0" ]]
}

if [[ "$SSH_ORCHESTRATOR" == "native" ]]; then
  _check "unit rabbitmq-server corriendo" _check_rabbit_unit
  gw_url="${GATEWAY_URL:-http://${SSH_HOST}/health/data-management}"
else
  _check "kubectl remoto (namespace $K8S_NAMESPACE)" _kubectl get ns "$K8S_NAMESPACE"
  _check "pods de rabbitmq" _kubectl get pods -l app=rabbitmq -n "$K8S_NAMESPACE"
  gw_url="${GATEWAY_URL:-http://${SSH_HOST}/api/v1/data/health}"
fi

gw_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$gw_url" 2>/dev/null || echo "000")
if [[ "$gw_code" == "200" ]]; then
  echo "  OK   gateway $gw_url"
else
  echo "  AVISO gateway $gw_url -> $gw_code (pause-data-management intentará el túnel SSH)" >&2
fi

if [[ "$preflight_errors" -gt 0 ]]; then
  echo "" >&2
  echo "ERROR: $preflight_errors chequeo(s) de preflight fallaron — se aborta ANTES de arrancar." >&2
  echo "  Arreglar y volver a lanzar: descubrir esto a las 2h significa perder la corrida entera." >&2
  exit 1
fi

CONN_LOG="$RESULTS_DIR/connectivity-$(date +%s).log"

echo ""
echo "=== Orquestador de chaos durante endurance (12h) ==="
echo "    Inicio:  $(date '+%Y-%m-%d %H:%M:%S')"
echo "    Destino: $SYSTEM_TAG — $SSH_USER@$SSH_HOST"
echo "    Conectividad: sondeando ${TARGET_HOST:-$gw_url} cada ${CONN_PROBE_INTERVAL}s -> $CONN_LOG"
echo "    Plan:    t+$((OFFSET_KILL_RABBITMQ / 60))min kill-rabbitmq"
echo "             t+$((OFFSET_PAUSE_DATA_MGMT / 60))min pause-data-management ${PAUSE_DURATION}s"
if [[ "$SSH_ORCHESTRATOR" == "k8s" ]]; then
  echo "             t+$((OFFSET_NETEM_DELAY / 60))min netem-delay-ew-da ${NETEM_DELAY_MS}ms ${NETEM_DURATION}s"
else
  echo "             (netem-delay-ew-da: se saltea — el Sistema A no tiene circuit breaker que medir)"
fi
echo ""

# _conn_probe — ¿está vivo el camino desde ACÁ hasta el sistema bajo prueba?
# Si TARGET_HOST está seteado se prueba TCP contra el puerto de ingesta real —
# exactamente el camino que usa la carga. Si no, se cae al gateway HTTP, que
# vive en el mismo host y sirve igual para detectar un corte de red.
_conn_probe() {
  if [[ -n "${TARGET_HOST:-}" ]]; then
    local h="${TARGET_HOST%%:*}" p="${TARGET_HOST##*:}"
    [[ "$p" == "$h" ]] && p=80
    timeout "$CONN_PROBE_TIMEOUT" bash -c "(echo >/dev/tcp/$h/$p)" >/dev/null 2>&1
  else
    curl -s -o /dev/null --max-time "$CONN_PROBE_TIMEOUT" "$gw_url" >/dev/null 2>&1
  fi
}

# _connectivity_watch — corre en background toda la corrida. Cierra su propia
# región por trap: si el orquestador muere con un corte abierto, una anotación
# sin fin queda para siempre en el dashboard.
_connectivity_watch() {
  local fails=0 region="" lost_at=0 probe_desc
  probe_desc="${TARGET_HOST:-$gw_url}"
  trap '[[ -n "$region" ]] && grafana_annotate_region_end "$region"; exit 0' EXIT INT TERM

  while :; do
    if _conn_probe; then
      if [[ -n "$region" ]]; then
        local dur=$(( $(date +%s) - lost_at ))
        grafana_annotate_region_end "$region"
        # tee al log ademas de stdout: si la corrida de 12h se analiza despues,
        # el log es la fuente de verdad de que tramos hay que excluir.
        echo "[conn] $(date '+%Y-%m-%d %H:%M:%S') RECUPERADA tras ${dur}s ($probe_desc)" | tee -a "$CONN_LOG"
        region=""
      fi
      fails=0
    else
      fails=$((fails + 1))
      if [[ "$fails" -eq "$CONN_FAIL_THRESHOLD" && -z "$region" ]]; then
        lost_at=$(date +%s)
        echo "[conn] $(date '+%Y-%m-%d %H:%M:%S') PERDIDA tras $fails fallos ($probe_desc)" | tee -a "$CONN_LOG"
        echo "  El sistema puede estar sano: esto mide el camino de red desde ESTA máquina." >&2
        region=$(grafana_annotate_region_start \
          "Conectividad perdida con $probe_desc (desde el generador de carga)" \
          "conectividad" "$SYSTEM_TAG_SHORT")
      fi
    fi
    sleep "$CONN_PROBE_INTERVAL"
  done
}

wait_until_offset() {
  local target_offset="$1"
  local now elapsed remaining
  now=$(date +%s)
  elapsed=$(( now - start_ts ))
  remaining=$(( target_offset - elapsed ))
  if [[ "$remaining" -gt 0 ]]; then
    echo "[$(date '+%H:%M:%S')] Esperando ${remaining}s hasta t+$(( target_offset / 60 ))min..."
    sleep "$remaining"
  fi
}

# run_injection <etiqueta> <script...> — corre una inyección sin abortar el
# orquestador si falla; cuenta fallos para el resumen final.
run_injection() {
  local label="$1"; shift
  if ! "$@"; then
    echo "AVISO: la inyección '$label' terminó con error — se continúa con las siguientes programadas." >&2
    failures=$((failures + 1))
  fi
}

# El watcher se arranca ACÁ, después de las definiciones: bash necesita la
# función declarada antes de invocarla, y arrancándolo arriba fallaba con
# "_connectivity_watch: command not found" — en background y sin abortar nada,
# así que la corrida seguía sin vigilancia y el fallo pasaba desapercibido.
_connectivity_watch &
conn_watch_pid=$!
# El watcher es un proceso aparte: si el orquestador termina (bien o mal) hay que
# matarlo, o queda vivo en background hasta que alguien cierre la terminal.
trap 'kill "$conn_watch_pid" 2>/dev/null; wait "$conn_watch_pid" 2>/dev/null' EXIT INT TERM

wait_until_offset "$OFFSET_KILL_RABBITMQ"
echo "--- [t+$((OFFSET_KILL_RABBITMQ / 60))min] kill-rabbitmq.sh ---"
run_injection "kill-rabbitmq" "$SCRIPT_DIR/kill-rabbitmq.sh"

wait_until_offset "$OFFSET_PAUSE_DATA_MGMT"
echo "--- [t+$((OFFSET_PAUSE_DATA_MGMT / 60))min] pause-data-management.sh ${PAUSE_DURATION}s ---"
run_injection "pause-data-management" "$SCRIPT_DIR/pause-data-management.sh" "$PAUSE_DURATION" "${GATEWAY_URL:-}"

if [[ "$SSH_ORCHESTRATOR" == "k8s" ]]; then
  wait_until_offset "$OFFSET_NETEM_DELAY"
  echo "--- [t+$((OFFSET_NETEM_DELAY / 60))min] netem-delay-ew-da.sh ${NETEM_DELAY_MS}ms ${NETEM_DURATION}s ---"
  run_injection "netem-delay-ew-da" "$SCRIPT_DIR/netem-delay-ew-da.sh" "$NETEM_DELAY_MS" "$NETEM_DURATION"
else
  echo "--- netem-delay-ew-da: SALTEADO (Sistema A no tiene circuit breaker) ---"
  skipped=$((skipped + 1))
fi

echo ""
attempted=$(( 3 - skipped ))
if [[ "$failures" -eq 0 ]]; then
  echo "=== $attempted inyecciones completadas sin errores${skipped:+ ($skipped salteada(s))} ==="
else
  echo "=== $attempted inyecciones intentadas, $failures fallaron (ver AVISOs arriba) ==="
fi
echo "    Resultados en chaos/results/ (kill-rabbitmq-*, pause-data-management-*, netem-delay-ew-da-*)"

if [[ "$failures" -gt 0 ]]; then
  exit 1
fi
