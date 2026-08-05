#!/usr/bin/env bash
# kill-rabbitmq.sh — mata el broker RabbitMQ y mide: MTTR de reconexión
# (RabbitMQ vuelve a Ready + productores/consumidores reconectan) y mensajes
# perdidos (delta published vs consumed en la ventana del fallo).
#
# AMBOS sistemas corren RabbitMQ, con la misma topología (data_management.persist,
# early_warning.evaluate, sensors.dead_letter), así que el escenario aplica a los
# dos y es comparable. Lo que cambia es CÓMO se inyecta y quién reinicia el broker:
#
#   - Sistema B (SSH_ORCHESTRATOR=k8s): RabbitMQ es un pod de un StatefulSet en
#     k3s. Se inyecta con `kubectl delete pod --force --grace-period=0` (abrupto,
#     equivalente a SIGKILL, sin shutdown ordenado) y el StatefulSet lo recrea.
#   - Sistema A (SSH_ORCHESTRATOR=native): RabbitMQ es la unidad systemd
#     rabbitmq-server. Se inyecta con `systemctl kill -s SIGKILL` (mata todo el
#     cgroup, igual de abrupto) y systemd lo recrea por su Restart=always.
#
# En los dos casos el reinicio del broker lo hace el orquestador del sistema
# (StatefulSet / systemd): se mide cuánto tarda en recuperarse el pipeline
# end-to-end, no solo el proceso.
#
# El fallo se inyecta EN el servidor remoto (no con pumba sobre un Docker local:
# ninguno de los dos servidores expone su runtime a esta máquina, y el Sistema A
# ni siquiera corre los servicios en contenedores).
#
# Uso (Sistema B):
#   SSH_HOST=178.105.104.95 SSH_USER=gotesis SSH_KEY_PATH=~/.ssh/gotesis-key \
#     SUDO_PASSWORD=*** SSH_ORCHESTRATOR=k8s \
#     PROMETHEUS_ADDR=http://178.105.104.95:31083 \
#     ./chaos/kill-rabbitmq.sh
#
# Uso (Sistema A):
#   SSH_HOST=204.168.203.32 SSH_USER=concurso SSH_KEY_PATH=~/.ssh/concurso-key \
#     SUDO_PASSWORD=*** SSH_ORCHESTRATOR=native \
#     PROMETHEUS_ADDR=http://204.168.203.32:9090 \
#     ./chaos/kill-rabbitmq.sh
#
# (SSH_HOST/USER/auth, SUDO_PASSWORD y SSH_ORCHESTRATOR se pueden dejar en
# load-tests/.env — se cargan automáticamente vía grafana-annotate.sh, igual que
# reset-state.sh.)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/capture.sh"
source "$SCRIPT_DIR/lib/ssh.sh"
source "$SCRIPT_DIR/../load-tests/lib/grafana-annotate.sh"

RABBITMQ_SELECTOR="${RABBITMQ_SELECTOR:-app=rabbitmq}"   # Sistema B (k8s)
RABBITMQ_UNIT="${RABBITMQ_UNIT:-rabbitmq-server}"        # Sistema A (native)
LABEL="kill-rabbitmq"
RECOVERY_TIMEOUT="${RECOVERY_TIMEOUT:-180}"

_ssh_require

case "$SSH_ORCHESTRATOR" in
  k8s|native) ;;
  *)
    echo "ERROR: SSH_ORCHESTRATOR='$SSH_ORCHESTRATOR' inválido — usar 'k8s' (Sistema B) o 'native' (Sistema A)." >&2
    exit 1
    ;;
esac

# Un snapshot que no puede consultar Prometheus no mide nada: fallar temprano
# en vez de descubrir que published/consumed son 'ERR' recién en el resumen.
# El default de capture.sh (localhost:9090) casi nunca es correcto acá —
# Prometheus del Sistema B es un NodePort en <host>:31083.
if [[ "$PROMETHEUS_ADDR" == *localhost* || "$PROMETHEUS_ADDR" == *127.0.0.1* ]]; then
  echo "AVISO: PROMETHEUS_ADDR=$PROMETHEUS_ADDR apunta a localhost, pero el sistema bajo prueba es remoto." >&2
  echo "  Setear al Prometheus del Sistema B, ej: PROMETHEUS_ADDR=http://178.105.104.95:31083" >&2
fi
if [[ "$(prom_query 'vector(1)')" != "1" ]]; then
  echo "ERROR: no se pudo consultar Prometheus en $PROMETHEUS_ADDR — los snapshots quedarían vacíos." >&2
  echo "  Confirmar PROMETHEUS_ADDR y que el puerto sea accesible desde esta máquina." >&2
  exit 1
fi

if [[ "$SSH_ORCHESTRATOR" == "k8s" ]]; then
  echo "=== Escenario: kill RabbitMQ (Sistema B / k3s) vía kubectl ==="
  echo "    Servidor:   $SSH_USER@$SSH_HOST (namespace $K8S_NAMESPACE)"
  echo "    Selector:   $RABBITMQ_SELECTOR"
  INSTANCE_KIND="pod"
else
  echo "=== Escenario: kill RabbitMQ (Sistema A / systemd) vía systemctl ==="
  echo "    Servidor:   $SSH_USER@$SSH_HOST"
  echo "    Unidad:     $RABBITMQ_UNIT"
  INSTANCE_KIND="proceso"
fi

# _broker_state — imprime "<id> <ready>", donde <id> identifica la INSTANCIA
# actual del broker y <ready> es True/False. Comparar <id> distingue "la
# instancia vieja todavía figura viva" de "el reemplazo ya está listo", lo que
# evita un MTTR=0 falso en la primera vuelta del loop.
#
#   - k8s:    id = uid del pod (el StatefulSet recrea el pod con un uid NUEVO).
#   - native: id = MainPID de la unidad (systemd reinicia con un PID NUEVO);
#             ready sale de `rabbitmq-diagnostics ping`, que es lo más cercano
#             a la Ready condition del pod (broker respondiendo, no solo el
#             proceso levantado — beam arranca mucho antes de aceptar AMQP).
_broker_state() {
  if [[ "$SSH_ORCHESTRATOR" == "k8s" ]]; then
    _kubectl get pod -l "$RABBITMQ_SELECTOR" -n "$K8S_NAMESPACE" \
      -o 'jsonpath={range .items[*]}{.metadata.uid}{" "}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{end}' \
      2>/dev/null || true
  else
    _sudo_run "pid=\$(systemctl show $RABBITMQ_UNIT -p MainPID --value 2>/dev/null); \
ready=False; rabbitmq-diagnostics -q ping >/dev/null 2>&1 && ready=True; \
echo \"\$pid \$ready\"" 2>/dev/null || true
  fi
}

old_state=$(_broker_state)
old_id="${old_state%% *}"
if [[ -z "$old_id" || "$old_id" == "0" ]]; then
  if [[ "$SSH_ORCHESTRATOR" == "k8s" ]]; then
    echo "ERROR: no se encontró ningún pod con selector '$RABBITMQ_SELECTOR' en $K8S_NAMESPACE (o falló el kubectl remoto/sudo)." >&2
  else
    echo "ERROR: la unidad '$RABBITMQ_UNIT' no está corriendo en $SSH_HOST (MainPID=0), o falló el sudo remoto." >&2
  fi
  echo "  Verificar SSH/SUDO_PASSWORD, SSH_ORCHESTRATOR=$SSH_ORCHESTRATOR y que RabbitMQ corra en este servidor." >&2
  exit 1
fi
echo "    Instancia:  ${INSTANCE_KIND} ${old_id} (Ready=${old_state##* })"

echo ""
echo "--- Snapshot pre-fallo ---"
pre_snapshot_at=$(date +%s)
pre_snapshot=$(snapshot_counters "${LABEL}-pre")
cat "$pre_snapshot"

if [[ "$SSH_ORCHESTRATOR" == "k8s" ]]; then
  SYSTEM_TAG="sistema-B"
else
  SYSTEM_TAG="sistema-A"
fi
region_id=$(grafana_annotate_region_start "Chaos · kill-rabbitmq ($SYSTEM_TAG)" "chaos" "kill-rabbitmq" "$SYSTEM_TAG")
# Cierra la región de Grafana pase lo que pase (kubectl falla, el script se
# interrumpe, etc.) — sin esto una falla antes del cierre normal deja la
# anotación abierta para siempre.
trap 'grafana_annotate_region_end "$region_id"' EXIT

echo ""
fail_start=$(date +%s)
if [[ "$SSH_ORCHESTRATOR" == "k8s" ]]; then
  echo "--- Inyectando fallo (kubectl delete pod --force --grace-period=0) ---"
  if ! _kubectl delete pod -l "$RABBITMQ_SELECTOR" -n "$K8S_NAMESPACE" --force --grace-period=0 >/dev/null 2>&1; then
    echo "ERROR: 'kubectl delete pod' remoto falló (SSH/sudo/kubeconfig, o el pod ya no existe) — el fallo puede no haberse inyectado." >&2
    exit 1
  fi
  echo "    Pod eliminado; el StatefulSet debe recrearlo."
else
  echo "--- Inyectando fallo (systemctl kill -s SIGKILL --kill-whom=main $RABBITMQ_UNIT) ---"
  # SIGKILL al proceso principal (beam.smp), sin shutdown ordenado: equivalente
  # nativo del delete pod --force. NO se usa `systemctl restart` (sería un
  # reinicio limpio y mediría otra cosa).
  #
  # --kill-whom=main y no el default (=all): matando todo el cgroup, systemd
  # devuelve rc=1 con "Failed to send signal SIGKILL to auxiliary processes:
  # Invalid argument" (los hijos de beam: erl_child_setup, inet_gethost...),
  # AUNQUE el broker ya murió y se está reiniciando. Confiar en ese rc hacía
  # que el script abortara con "no se inyectó" habiendo inyectado — un falso
  # negativo peor que no medir. Matar beam alcanza: es el VM de Erlang.
  kill_rc=0
  kill_out=$(_sudo_run "systemctl kill -s SIGKILL --kill-whom=main $RABBITMQ_UNIT" 2>&1) || kill_rc=$?

  # La confirmación de que el fallo entró es que la INSTANCIA cambie (MainPID
  # nuevo) o que la unidad quede momentáneamente sin PID — nunca el rc.
  injected="false"
  for _ in $(seq 1 10); do
    now_id="$(_broker_state)"; now_id="${now_id%% *}"
    if [[ -z "$now_id" || "$now_id" == "0" || "$now_id" != "$old_id" ]]; then
      injected="true"
      break
    fi
    sleep 1
  done
  if [[ "$injected" != "true" ]]; then
    echo "ERROR: el broker sigue con MainPID $old_id tras el kill — el fallo NO se inyectó." >&2
    [[ -n "$kill_out" ]] && echo "  salida de systemctl kill (rc=$kill_rc): $kill_out" >&2
    exit 1
  fi
  if [[ "$kill_rc" -ne 0 ]]; then
    echo "    (systemctl kill devolvió rc=$kill_rc, pero el broker murió igual — se ignora: $kill_out)"
  fi
  echo "    Broker matado (SIGKILL); systemd debe reiniciarlo por su Restart=always."
fi

echo "--- Esperando recuperación (instancia nueva respondiendo) ---"
elapsed=0
recovered="false"
while [[ "$elapsed" -lt "$RECOVERY_TIMEOUT" ]]; do
  state=$(_broker_state)
  new_id="${state%% *}"
  ready="${state##* }"
  # Recuperado solo cuando la instancia es OTRA (uid/PID distinto al que matamos)
  # y está lista — así no contamos como recuperación el instante en que la
  # instancia vieja todavía no fue removida/reemplazada.
  if [[ -n "$new_id" && "$new_id" != "0" && "$new_id" != "$old_id" && "$ready" == "True" ]]; then
    recovered="true"
    break
  fi
  sleep 3
  elapsed=$(( $(date +%s) - fail_start ))
done
mttr="$elapsed"
if [[ "$recovered" == "true" ]]; then
  echo "MTTR (broker respondiendo de nuevo): ${mttr}s"
else
  echo "MTTR: TIMEOUT tras ${RECOVERY_TIMEOUT}s — RabbitMQ NO volvió a responder. Esto es una falla de resiliencia real, no confundir con un MTTR de ${RECOVERY_TIMEOUT}s." >&2
fi

echo "--- Esperando 30s adicionales para que productores/consumidores reconecten ---"
sleep 30

echo "--- Snapshot post-recuperación ---"
post_snapshot_at=$(date +%s)
post_snapshot=$(snapshot_counters "${LABEL}-post")
cat "$post_snapshot"

echo ""
echo "=== Resumen ($SYSTEM_TAG) ==="
if [[ "$recovered" == "true" ]]; then
  echo "MTTR (broker listo de nuevo): ${mttr}s"
else
  echo "MTTR (broker listo de nuevo): TIMEOUT (>${RECOVERY_TIMEOUT}s, no se recuperó)"
fi
echo "Ver snapshots en: $pre_snapshot / $post_snapshot"

# ── Linea de tiempo absoluta ────────────────────────────────────────────────
# El MTTR de arriba es una duracion; para acotar el rango en Grafana y cruzar
# con kube-state-metrics hace falta la hora de reloj de cada fase. UTC ademas de
# local porque Prometheus y Grafana consultan en UTC.
_ts() { local e="$1"; printf '%s  (UTC %s)' "$(date -d "@$e" '+%Y-%m-%d %H:%M:%S %Z')" "$(date -u -d "@$e" '+%H:%M:%S')"; }

echo ""
echo "=== Linea de tiempo ($SYSTEM_TAG) ==="
echo "Snapshot pre-fallo:         $(_ts "$pre_snapshot_at")"
echo "Fallo inyectado:            $(_ts "$fail_start")"
if [[ "$recovered" == "true" ]]; then
  echo "Broker listo de nuevo:      $(_ts "$(( fail_start + mttr ))")  [t+${mttr}s]"
fi
echo "Snapshot post-recuperacion: $(_ts "$post_snapshot_at")"
echo ""
echo "Rango para Grafana/Prometheus (UTC, con 60s de margen a cada lado):"
echo "  from=$(date -u -d "@$(( pre_snapshot_at - 60 ))" '+%Y-%m-%dT%H:%M:%SZ')  to=$(date -u -d "@$(( post_snapshot_at + 60 ))" '+%Y-%m-%dT%H:%M:%SZ')"
echo ""
echo "Mensajes perdidos = (published_pre - consumed_pre) - (published_post - consumed_post) tras estabilizar,"
echo "  o más simple: revisar 'dropped' en ambos snapshots y el backlog Redis (redis_buffer_pending) durante la ventana."

if [[ "$recovered" != "true" ]]; then
  exit 1
fi
