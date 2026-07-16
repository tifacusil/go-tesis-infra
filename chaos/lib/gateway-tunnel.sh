#!/usr/bin/env bash
# gateway-tunnel.sh — resuelve GATEWAY_URL para los escenarios de chaos que
# sondean el gateway HTTP (hoy: pause-data-management.sh).
#
# Sistema A: nginx expuesto → GATEWAY_URL directo (o el default localhost).
# Sistema B: Traefik solo escucha en el :80 del nodo — hacia afuera únicamente
# TCP 5000 (ingesta) es alcanzable desde la laptop. Solución: túnel SSH
# local-forward (ssh -N -L) al localhost:80 del server, y el sondeo pega al
# extremo local del túnel. El IngressRoute (k8s/base/ingress.yaml) rutea solo
# por PathPrefix, sin regla de Host, así que "Host: 127.0.0.1" funciona igual.
# La latencia laptop→server es constante durante toda la ventana de sondeo,
# no contamina el conteo OK/fail del blast radius.
#
# Uso (desde el script que sondea):
#   source "$SCRIPT_DIR/lib/gateway-tunnel.sh"
#   resolve_gateway_url "${2:-}" || exit 1
#   ...
#   trap '...; gateway_tunnel_cleanup' EXIT   # encadenar al trap EXIT propio
#
# resolve_gateway_url [url_explicita]:
#   1. URL explícita (argumento) → se usa tal cual, sin túnel.
#   2. GATEWAY_URL ya en el entorno → se usa tal cual, sin túnel.
#   3. SSH_HOST seteado (típico: ya está en load-tests/.env para reset-state)
#      → abre túnel y setea GATEWAY_URL=http://127.0.0.1:<puerto-local>/...
#   4. Nada seteado → default http://localhost/api/v1/data/health (stack
#      Docker Compose local).
#
# Variables:
#   SSH_HOST / SSH_USER / SSH_PORT / SSH_KEY_PATH / SSH_PASSWORD
#       mismas credenciales que load-tests/reset-state.sh (viven en
#       load-tests/.env, que grafana-annotate.sh ya carga con set -a).
#   GATEWAY_TUNNEL_LOCAL_PORT   puerto local del túnel (default 18080)
#   GATEWAY_TUNNEL_REMOTE       destino remoto del forward (default localhost:80)
#   GATEWAY_HEALTH_PATH         path del health endpoint (default /api/v1/data/health)
#
# IMPORTANTE: este archivo NO registra su propio trap EXIT — bash solo guarda
# UN trap por señal, y los escenarios de chaos ya usan trap EXIT para cerrar
# la anotación de Grafana; registrar otro acá lo pisaría silenciosamente. El
# caller debe encadenar gateway_tunnel_cleanup en su propio trap.

_gateway_tunnel_pid=""

resolve_gateway_url() {
  local explicit="${1:-}"
  local health_path="${GATEWAY_HEALTH_PATH:-/api/v1/data/health}"

  if [[ -n "$explicit" ]]; then
    GATEWAY_URL="$explicit"
    return 0
  fi
  if [[ -n "${GATEWAY_URL:-}" ]]; then
    return 0
  fi
  if [[ -z "${SSH_HOST:-}" ]]; then
    GATEWAY_URL="http://localhost${health_path}"
    return 0
  fi

  : "${SSH_USER:?SSH_HOST seteado pero falta SSH_USER}"
  local lport="${GATEWAY_TUNNEL_LOCAL_PORT:-18080}"
  local remote="${GATEWAY_TUNNEL_REMOTE:-localhost:80}"
  # ExitOnForwardFailure: si el bind local o el forward remoto fallan, ssh
  # muere en vez de quedarse conectado sin túnel — el loop de espera de abajo
  # lo detecta con kill -0 en vez de esperar el timeout completo.
  local ssh_opts=(-p "${SSH_PORT:-22}" -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=10 -o ExitOnForwardFailure=yes -N -L "${lport}:${remote}")

  if ! command -v ssh >/dev/null 2>&1; then
    echo "ERROR: ssh no está en PATH — no se puede abrir túnel al gateway de $SSH_HOST." >&2
    return 1
  fi

  echo "  (gateway-tunnel: abriendo ssh -L ${lport}:${remote} hacia ${SSH_USER}@${SSH_HOST}...)"
  if [[ -n "${SSH_KEY_PATH:-}" ]]; then
    ssh "${ssh_opts[@]}" -i "$SSH_KEY_PATH" "${SSH_USER}@${SSH_HOST}" &
  elif [[ -n "${SSH_PASSWORD:-}" ]] && command -v sshpass >/dev/null 2>&1; then
    sshpass -p "$SSH_PASSWORD" ssh "${ssh_opts[@]}" "${SSH_USER}@${SSH_HOST}" &
  else
    echo "ERROR: falta SSH_KEY_PATH (o SSH_PASSWORD + sshpass instalado) para el túnel al gateway." >&2
    echo "  Alternativa: exportar GATEWAY_URL directo si el gateway es alcanzable por otra vía." >&2
    return 1
  fi
  _gateway_tunnel_pid=$!

  # Esperar a que el forward acepte conexiones (ssh arranca async — mismo
  # patrón que _wait_port_forward en load-tests/reset-state.sh).
  local waited=0
  while ! (exec 3<>"/dev/tcp/127.0.0.1/$lport") 2>/dev/null; do
    exec 3>&- 2>/dev/null || true
    if ! kill -0 "$_gateway_tunnel_pid" 2>/dev/null; then
      echo "ERROR: el túnel SSH murió al arrancar — auth fallida, o ${remote} no escucha en el server." >&2
      _gateway_tunnel_pid=""
      return 1
    fi
    sleep 0.5
    waited=$((waited + 1))
    if [[ "$waited" -ge 30 ]]; then
      echo "ERROR: el túnel SSH no aceptó conexiones en 15s — se aborta." >&2
      gateway_tunnel_cleanup
      return 1
    fi
  done
  exec 3>&- 2>/dev/null || true

  GATEWAY_URL="http://127.0.0.1:${lport}${health_path}"
  echo "  (gateway-tunnel: GATEWAY_URL=$GATEWAY_URL — túnel pid $_gateway_tunnel_pid)"
  return 0
}

gateway_tunnel_cleanup() {
  if [[ -n "$_gateway_tunnel_pid" ]]; then
    kill "$_gateway_tunnel_pid" 2>/dev/null || true
    _gateway_tunnel_pid=""
  fi
}
