#!/usr/bin/env bash
# ap5-capture.sh — AP5: bytes y llamadas por evento, MISMO evento en A y en B.
# Automatiza docs/ap5-ap6-ap7-procedimientos.md §AP5 y deja la evidencia en
# chaos/results/ap5-<A|B>-<epoch>*.
#
# Qué hace, con el sistema en reposo:
#   1. Captura REPOSO: CAP_SECONDS sin inyectar nada.
#   2. Captura EVENTO: CAP_SECONDS, inyectando el evento representativo
#      (lib/event.sh: lectura base + lectura que alerta) al comienzo.
#   3. Agrega por servidor (ip:puerto de servicio) paquetes, bytes de payload TCP
#      y escrituras cliente->servidor, y reporta el NETO = evento - reposo.
#
# ── Por qué dos capturas y no una ────────────────────────────────────────────
# "En reposo" no es "sin tráfico": los exporters de Prometheus consultan MySQL y
# Redis en cada scrape, AMQP manda heartbeats, kubelet sondea los pods. En una
# ventana de segundos eso pesa tanto como el evento. La captura de reposo, de la
# misma duración, estima ese fondo; lo que se atribuye al evento es el neto.
# El fondo no es constante (un scrape de más o de menos): por eso se repite la
# prueba y se reporta mediana y rango, no una sola corrida.
#
# ── Por qué NO -i any en el Sistema B ────────────────────────────────────────
# En el nodo k3s el tráfico entre pods atraviesa veth(origen) -> cni0 -> veth
# (destino). Con -i any tcpdump ve el mismo paquete en 2 o 3 interfaces, y B
# saldría inflado x2-x3 frente a A por un artefacto de captura. Se captura en
# el bridge cni0: en modo promiscuo recibe una copia de cada trama reenviada
# entre puertos, exactamente una vez. En A (procesos nativos en un host) el
# tráfico entre servicios va por lo, también una vez.
#
# Qué NO entra en la captura (y está bien que no entre): la publicación del
# evento, que viaja por la Management API (puerto 15672, fuera del filtro) o por
# kubectl exec dentro del pod de RabbitMQ; y SSH. En A, un servicio que hable
# con MySQL por socket unix tampoco aparece: declararlo si fuera el caso.
#
# "Llamadas" se aproxima por escrituras cliente->servidor (segmentos con datos
# hacia el puerto de servicio): con conexiones persistentes (pool MySQL, canal
# AMQP, gRPC HTTP/2) no hay un SYN por llamada. Es un proxy, y así se reporta.
#
# Variables:
#   CAP_SECONDS   duración de cada captura (default 30)
#   AP5_IFACE     interfaz (default: A=lo, B=cni0)
#   AP5_PORTS     puertos de servicio a capturar (default por sistema, abajo)
#   AP5_FORCE     1 = capturar aunque el sistema no esté en reposo (se marca)
#
# Uso:
#   # Sistema B
#   SSH_HOST=178.105.104.95 SSH_USER=gotesis SSH_KEY_PATH=~/.ssh/gotesis-key \
#     SUDO_PASSWORD=*** SSH_ORCHESTRATOR=k8s ./chaos/ap5-capture.sh
#   # Sistema A
#   SSH_HOST=204.168.203.32 SSH_USER=... SUDO_PASSWORD=*** SSH_ORCHESTRATOR=native \
#     RABBITMQ_MGMT_USER=... RABBITMQ_MGMT_PASS=... ./chaos/ap5-capture.sh
#
# Repetir >= 3 veces por sistema.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/capture.sh"
source "$SCRIPT_DIR/lib/ssh.sh"
source "$SCRIPT_DIR/lib/event.sh"

_ssh_require
# En modo local (CHAOS_LOCAL, corriendo en el nodo de B) el orquestador es k8s
# por definicion: _ssh_require ya verifico que kubectl hable con el cluster.
[[ "$CHAOS_LOCAL" == "1" ]] && SSH_ORCHESTRATOR="${SSH_ORCHESTRATOR:-k8s}"
case "$SSH_ORCHESTRATOR" in
  k8s)
    SYS="B"
    DEFAULT_IFACE="cni0"
    # AMQP, MySQL (EW y DM), Redis, gRPC user-management (9090) y data-analysis
    # (50051). Sin 8080: el evento no usa HTTP entre servicios en B, y ahí caen
    # los scrapes de /metrics y las probes de kubelet.
    DEFAULT_PORTS="5672 3306 6379 9090 50051"
    ;;
  native)
    SYS="A"
    DEFAULT_IFACE="lo"
    # AMQP, MySQL (compartido), Redis y user-management HTTP (8085). Sin 9090:
    # en A es Prometheus.
    DEFAULT_PORTS="5672 3306 6379 8085"
    ;;
  *)
    echo "ERROR: SSH_ORCHESTRATOR es obligatorio — 'k8s' (Sistema B) o 'native' (Sistema A)." >&2
    exit 1
    ;;
esac
CAP_SECONDS="${CAP_SECONDS:-30}"
AP5_IFACE="${AP5_IFACE:-$DEFAULT_IFACE}"
AP5_PORTS="${AP5_PORTS:-$DEFAULT_PORTS}"
AP5_FORCE="${AP5_FORCE:-0}"

RUN_TS=$(date +%s)
BASE="$RESULTS_DIR/ap5-${SYS}-${RUN_TS}"
EVENT_ID="ap5-${SYS,,}-${RUN_TS}"
exec > >(tee -a "${BASE}.log") 2>&1

filter="tcp and ($(sed -E 's/([0-9]+)/port \1/g; s/ port/ or port/g' <<<"$AP5_PORTS"))"

echo "=== AP5 — volumen por evento (Sistema $SYS) ==="
echo "    Interfaz:   $AP5_IFACE"
echo "    Filtro:     $filter"
echo "    Ventanas:   reposo ${CAP_SECONDS}s + evento ${CAP_SECONDS}s"
echo "    Evento:     $EVENT_ID (lectura base + lectura que alerta, project=$EVENT_PROJECT)"
echo "    Evidencia:  ${BASE}*"

# ── Reposo ────────────────────────────────────────────────────────────────────
# Desde la Management API, igual en A y en B: mensajes en cola y tasa de
# publicación. Con carga activa, el tráfico del evento se pierde en el ruido.
overview=$(rabbit_api GET "/api/overview?columns=queue_totals,message_stats" || echo "")
# Primero la respuesta: sin ella ready/pub_rate quedan vacíos y el cálculo de
# abajo concluiría "en reposo: si" sobre datos que no existen.
if ! grep -q '"queue_totals"' <<<"$overview"; then
  echo "ERROR: no se pudo consultar la Management API de RabbitMQ (respuesta: ${overview:-<vacía>})." >&2
  exit 1
fi
ready=$(grep -oE '"messages_ready"[[:space:]]*:[[:space:]]*[0-9]+' <<<"$overview" | head -1 | grep -oE '[0-9]+$' || true)
pub_rate=$(grep -oE '"publish_details"[[:space:]]*:[[:space:]]*\{[[:space:]]*"rate"[[:space:]]*:[[:space:]]*[0-9.]+' <<<"$overview" | head -1 | grep -oE '[0-9.]+$' || true)
at_rest=$(awk -v r="${ready:-0}" -v p="${pub_rate:-0}" 'BEGIN { print (r+0 == 0 && p+0 < 0.5 ? "si" : "no") }')
echo "    Colas: ${ready:-?} listos, publicación ${pub_rate:-0} msg/s -> en reposo: $at_rest"
if [[ "$at_rest" != "si" && "$AP5_FORCE" != "1" ]]; then
  echo "ERROR: el sistema no está en reposo. Detener el generador de carga y esperar a que" >&2
  echo "  las colas se vacíen (o AP5_FORCE=1 para capturar igual; queda marcado)." >&2
  exit 1
fi

# ── Mapa ip -> nombre (solo B) ────────────────────────────────────────────────
MAP_FILE="${BASE}-hosts.tmp"
: > "$MAP_FILE"
if [[ "$SYS" == "B" ]]; then
  _kubectl get pods -n "$K8S_NAMESPACE" -o 'jsonpath={range .items[*]}{.status.podIP}{" "}{.metadata.name}{"\n"}{end}' >> "$MAP_FILE" 2>/dev/null || true
  _kubectl get svc -n "$K8S_NAMESPACE" -o 'jsonpath={range .items[*]}{.spec.clusterIP}{" "}svc/{.metadata.name}{"\n"}{end}' >> "$MAP_FILE" 2>/dev/null || true
fi

# _capture <fase> — captura CAP_SECONDS en el servidor; en la fase "evento"
# inyecta al comienzo. Deja el texto de tcpdump en ${BASE}-<fase>.txt y el pcap
# en ${BASE}-<fase>.pcap.
_capture() {
  local phase="$1"
  local remote="/tmp/ap5-${SYS}-${RUN_TS}-${phase}.pcap"
  echo ""
  echo "--- Captura: $phase (${CAP_SECONDS}s) ---"
  # -s 128: solo cabeceras; el largo de payload que imprime -q sale del header
  # IP, así que no se pierde precisión y el pcap queda chico.
  _sudo_run "timeout $CAP_SECONDS tcpdump -i $AP5_IFACE -nn -s 128 -U -w $remote '$filter' 2>/dev/null; true" &
  local cap_pid=$!
  sleep 3   # que tcpdump esté escuchando antes de inyectar
  local started; started=$(date +%s)
  if [[ "$phase" == "evento" ]]; then
    event_publish_pair "$EVENT_ID"
    echo "    Evento publicado a las $(_iso_utc "$(date +%s)")."
  fi
  wait "$cap_pid" || true
  echo "    Captura cerrada (inicio $(_iso_utc "$started"))."
  _sudo_run "tcpdump -nn -q -r $remote 2>/dev/null" > "${BASE}-${phase}.txt" || true
  _sudo_run "cat $remote" > "${BASE}-${phase}.pcap" || true
  _sudo_run "rm -f $remote" >/dev/null 2>&1 || true
  echo "    $(wc -l < "${BASE}-${phase}.txt") paquetes."
}

# _aggregate <txt> — por servidor: "servidor paquetes bytes escrituras_c2s".
# El servidor es el extremo cuyo puerto está en AP5_PORTS.
_aggregate() {
  awk -v ports="$AP5_PORTS" '
    BEGIN { n = split(ports, p, " "); for (i = 1; i <= n; i++) isport[p[i]] = 1 }
    {
      for (i = 1; i <= NF; i++) if ($i == "IP") break
      if (i > NF) next
      src = $(i+1); dst = $(i+3); sub(/:$/, "", dst)
      len = $NF + 0
      sp = src; sub(/.*\./, "", sp)
      dp = dst; sub(/.*\./, "", dp)
      if (isport[dp])      { srv = dst; c2s = 1 }
      else if (isport[sp]) { srv = src; c2s = 0 }
      else next
      pk[srv]++; by[srv] += len
      if (c2s && len > 0) wr[srv]++
    }
    END { for (s in pk) printf "%s %d %d %d\n", s, pk[s], by[s], wr[s] + 0 }
  ' "$1" | sort
}

# _name <ip.puerto> — nombre legible del servidor.
_name() {
  local ep="$1" ip port name
  ip="${ep%.*}"; port="${ep##*.}"
  name=$(awk -v ip="$ip" '$1 == ip { print $2; exit }' "$MAP_FILE")
  if [[ -z "$name" ]]; then
    case "$port" in
      5672) name="rabbitmq" ;; 3306) name="mysql" ;; 6379) name="redis" ;;
      9090) name="user-management" ;; 8085) name="user-management" ;;
      50051) name="data-analysis" ;; *) name="?" ;;
    esac
  fi
  echo "$name:$port"
}

_capture reposo
_capture evento

_aggregate "${BASE}-reposo.txt" > "${BASE}-reposo.agg"
_aggregate "${BASE}-evento.txt" > "${BASE}-evento.agg"

# ── Neto por servidor ─────────────────────────────────────────────────────────
echo ""
echo "=== Tráfico por servidor (payload TCP) — Sistema $SYS ==="
printf '  %-44s %9s %9s %9s %9s %11s\n' "servidor" "pkt_ev" "B_ev" "B_rep" "B_neto" "escr_neto"
net_bytes=0; net_pkts=0; net_writes=0; hops=0; ev_bytes=0; idle_bytes=0
while read -r srv; do
  # awk y no grep: el servidor lleva puntos, que en una regex matchean cualquier cosa.
  read -r ep eb ew <<<"$(awk -v s="$srv" '$1 == s { print $2, $3, $4; f=1 } END { if (!f) print 0, 0, 0 }' "${BASE}-evento.agg")"
  read -r ip ib iw <<<"$(awk -v s="$srv" '$1 == s { print $2, $3, $4; f=1 } END { if (!f) print 0, 0, 0 }' "${BASE}-reposo.agg")"
  nb=$(( eb - ib )); np=$(( ep - ip )); nw=$(( ew - iw ))
  printf '  %-44s %9d %9d %9d %9d %11d\n' "$(_name "$srv") ($srv)" "$ep" "$eb" "$ib" "$nb" "$nw"
  ev_bytes=$(( ev_bytes + eb )); idle_bytes=$(( idle_bytes + ib ))
  net_bytes=$(( net_bytes + nb )); net_pkts=$(( net_pkts + np )); net_writes=$(( net_writes + nw ))
  if (( nb > 0 )); then hops=$(( hops + 1 )); fi
done < <(cat "${BASE}-evento.agg" "${BASE}-reposo.agg" | awk '{ print $1 }' | sort -u)
echo "  -----"
echo "  Total evento: ${ev_bytes} B | reposo: ${idle_bytes} B | NETO atribuible al evento: ${net_bytes} B, ${net_pkts} paquetes"
echo "  Escrituras cliente->servidor netas (proxy de llamadas): ${net_writes}"
echo "  Servidores con tráfico neto > 0 (saltos): ${hops}"

{
  echo "test=AP5"
  echo "system=$SYS"
  echo "run_ts=$RUN_TS"
  echo "event_id=$EVENT_ID"
  echo "event=par GNSS base+alerta (project=$EVENT_PROJECT, +100mm/60s)"
  echo "iface=$AP5_IFACE"
  echo "ports=$AP5_PORTS"
  echo "window_s=$CAP_SECONDS"
  echo "at_rest=$at_rest"
  echo "event_bytes=$ev_bytes"
  echo "idle_bytes=$idle_bytes"
  echo "net_bytes=$net_bytes"
  echo "net_packets=$net_pkts"
  echo "net_client_writes=$net_writes"
  echo "hops=$hops"
} > "${BASE}-summary.env"
rm -f "$MAP_FILE"

echo ""
echo "Evidencia: ${BASE}-{reposo,evento}.{pcap,txt,agg}, ${BASE}.log, ${BASE}-summary.env"
echo "Declarar al reportar: evento elegido, sistema en reposo ($at_rest), duración (${CAP_SECONDS}s x 2)."
