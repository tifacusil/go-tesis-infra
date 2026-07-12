#!/usr/bin/env bash
# reset-state.sh — limpia estado acumulado por corridas previas de load-test
# ANTES de arrancar una fase/nivel nuevo, para que cada medición empiece de
# cero y no se contamine con:
#   - Redis: buffer de dedup sensor_buffer:* (data-receiving) sin drenar
#   - MySQL early-warning: tabla `alerts` — cada frame que cruza umbral
#     durante la carga real genera una fila persistente (nunca rota sola),
#     ensuciando throughput/latencia medidos y sesgando la comparación A vs B
#     si el volumen de alertas difiere entre corridas.
#
# NO limpia mysql-data-management (las lecturas persistidas SON el dato que
# se está midiendo, no un efecto secundario a descartar).
#
# La máquina que corre Artillery casi nunca corre en el mismo servidor/
# cluster que el sistema bajo prueba — Redis y MySQL en k8s son ClusterIP
# (sin exposición externa, correcto por seguridad: no queremos un Redis/
# MySQL de infra alcanzable desde fuera del cluster todo el tiempo). Este
# script soporta 4 formas de llegar a ellos, en este orden de prioridad:
#
#   1. SSH al servidor (SSH_HOST seteado) — el caso más común: la máquina
#      que corre Artillery es una laptop sin kubectl configurado, pero
#      el operador SÍ tiene acceso SSH al servidor donde el cluster corre
#      (o desde donde kubectl sí alcanza al cluster). Todo el trabajo
#      (kubectl exec para leer credenciales, kubectl exec para correr
#      redis-cli/mysql DENTRO de un pod) se ejecuta remoto vía un solo
#      comando ssh — no hace falta port-forward ni kubectl local.
#   2. kubectl local (si responde) — la máquina que corre esto SÍ tiene
#      kubectl configurado contra el cluster: port-forward temporal +
#      redis-cli/mysql client locales.
#   3. Docker Compose (local) — kubectl no disponible pero sí docker: los
#      contenedores están en la misma red que el operador, exec directo.
#   4. Conexión directa por red (REDIS_HOST/MYSQL_EW_HOST) — para cuando
#      ninguno de los anteriores aplica pero hay otra vía de red (VPN, un
#      túnel ya armado a mano).
#
# redis-cli/mysql client no tienen que estar instalados en la máquina: si no
# están en PATH, se usa un contenedor Docker efímero (mismo patrón que
# chaos/*.sh con pumba) — ver _redis_cli/_mysql_cli más abajo. Mismo criterio
# para sshpass (necesario para pasar SSH_PASSWORD sin prompt interactivo).
#
# Uso:
#   ./load-tests/reset-state.sh
#
# Variables:
#   SSH_HOST            host/IP del servidor (activa modo SSH)
#   SSH_USER             usuario SSH (obligatorio si SSH_HOST está seteado)
#   SSH_PASSWORD          password SSH (o SSH_KEY_PATH para auth por key)
#   SSH_KEY_PATH          ruta a llave privada SSH, alternativa a SSH_PASSWORD
#   SSH_PORT              default: 22
#   SSH_ORCHESTRATOR      "k8s" (default) o "native". Sistema B corre en k8s
#                         (kubectl exec dentro del server); Sistema A corre
#                         redis/mysql como procesos nativos systemd, sin
#                         contenedores ni k8s — con "native" el reset pega
#                         directo a localhost:6379/3306 DENTRO del server,
#                         sin kubectl.
#   K8S_NAMESPACE       default: landslide (solo aplica con SSH_ORCHESTRATOR=k8s)
#   REDIS_PASSWORD      SSH_ORCHESTRATOR=native, o conexión directa sin SSH
#   MYSQL_EW_PASSWORD   SSH_ORCHESTRATOR=native, o conexión directa sin SSH
#   REDIS_HOST          conexión directa, sin SSH/kubectl/docker
#   REDIS_PORT          default: 6379
#   MYSQL_EW_HOST       conexión directa, sin SSH/kubectl/docker
#   MYSQL_EW_PORT       default: 3306
#   MYSQL_EW_USER       default: root
#   MYSQL_EW_DATABASE   default: early_warning
#
# IMPORTANTE — nunca commitear SSH_PASSWORD/MYSQL_EW_PASSWORD/etc. Van en
# load-tests/.env (gitignored), nunca en un script o archivo trackeado.
set -euo pipefail

K8S_NAMESPACE="${K8S_NAMESPACE:-landslide}"
SSH_PORT="${SSH_PORT:-22}"
_pf_pids=()

# _ssh_run <comando remoto> — ejecuta un comando en $SSH_HOST vía $SSH_USER,
# autenticando por SSH_KEY_PATH (preferido) o SSH_PASSWORD (vía sshpass).
# Usa el ssh/sshpass nativos si están en PATH; si no, cae a un contenedor
# Docker efímero con ambos instalados (alpine trae openssh-client, sshpass
# se agrega vía apk en el mismo `docker run` — sin necesitar una imagen
# custom publicada).
_ssh_run() {
  local remote_cmd="$1"
  local ssh_opts=(-p "$SSH_PORT" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

  if command -v ssh >/dev/null 2>&1; then
    if [[ -n "${SSH_KEY_PATH:-}" ]]; then
      ssh "${ssh_opts[@]}" -i "$SSH_KEY_PATH" "${SSH_USER}@${SSH_HOST}" -- "$remote_cmd"
    elif command -v sshpass >/dev/null 2>&1; then
      sshpass -p "$SSH_PASSWORD" ssh "${ssh_opts[@]}" "${SSH_USER}@${SSH_HOST}" -- "$remote_cmd"
    else
      echo "ERROR: SSH_PASSWORD seteado pero 'sshpass' no está instalado (necesario para auth SSH no interactiva)." >&2
      echo "  No existe en Chocolatey. Opciones:" >&2
      echo "    - Windows con scoop:  scoop install sshpass" >&2
      echo "    - Usar SSH_KEY_PATH en vez de SSH_PASSWORD (más seguro, sin instalar nada extra)" >&2
      echo "    - Instalar/levantar Docker Desktop (fallback automático, sin instalar sshpass en la máquina)" >&2
      return 127
    fi
  elif command -v docker >/dev/null 2>&1; then
    if [[ -n "${SSH_KEY_PATH:-}" ]]; then
      docker run --rm -v "$(cygpath -u "$SSH_KEY_PATH" 2>/dev/null || echo "$SSH_KEY_PATH")":/key:ro \
        alpine:3 sh -c "apk add --no-cache openssh-client >/dev/null && ssh $(printf '%q' "${ssh_opts[@]}") -i /key ${SSH_USER}@${SSH_HOST} -- $(printf '%q' "$remote_cmd")"
    else
      docker run --rm alpine:3 sh -c \
        "apk add --no-cache openssh-client sshpass >/dev/null && sshpass -p $(printf '%q' "$SSH_PASSWORD") ssh $(printf '%q' "${ssh_opts[@]}") ${SSH_USER}@${SSH_HOST} -- $(printf '%q' "$remote_cmd")"
    fi
  else
    echo "ERROR: ni ssh ni docker disponibles — no se puede conectar a SSH_HOST=$SSH_HOST." >&2
    return 127
  fi
}

# _redis_cli / _mysql_cli — usan el binario nativo si está en PATH, si no
# caen a un contenedor Docker efímero (mismo patrón que chaos/*.sh con
# pumba: no exigir instalación global de clientes DB en la máquina que
# corre Artillery).
#
# NO se usa --network host: solo funciona en Docker Desktop sobre Linux
# nativo, no en Windows/Mac (que es el caso real acá — Docker Desktop corre
# dentro de una VM). En su lugar se reescribe 127.0.0.1/localhost a
# host.docker.internal, el DNS especial que Docker Desktop expone en las
# 3 plataformas para que un contenedor alcance al host — así el fallback
# funciona igual para pegarle al port-forward de kubectl (que escucha en
# el host) sin depender de una feature que no existe en Windows.
_rewrite_localhost_for_docker() {
  local args=() a
  for a in "$@"; do
    case "$a" in
      # Forma con espacio: "-h" "127.0.0.1" (dos argv separados)
      127.0.0.1|localhost) args+=("host.docker.internal") ;;
      # Forma pegada de mysql client: "-h127.0.0.1" (un solo argv)
      -h127.0.0.1|-hlocalhost) args+=("-hhost.docker.internal") ;;
      *) args+=("$a") ;;
    esac
  done
  printf '%s\n' "${args[@]}"
}

_redis_cli() {
  if command -v redis-cli >/dev/null 2>&1; then
    redis-cli "$@"
  elif command -v docker >/dev/null 2>&1; then
    local rewritten=()
    while IFS= read -r line; do rewritten+=("$line"); done < <(_rewrite_localhost_for_docker "$@")
    docker run --rm redis:7-alpine redis-cli "${rewritten[@]}"
  else
    echo "ERROR: ni redis-cli ni docker disponibles. Instalar redis-cli:" >&2
    echo "  Windows (choco):  choco install redis-64" >&2
    echo "  o instalar Docker Desktop (se usa un contenedor efímero automáticamente)." >&2
    return 127
  fi
}

_mysql_cli() {
  if command -v mysql >/dev/null 2>&1; then
    mysql "$@"
  elif command -v docker >/dev/null 2>&1; then
    local rewritten=()
    while IFS= read -r line; do rewritten+=("$line"); done < <(_rewrite_localhost_for_docker "$@")
    docker run --rm mysql:8 mysql "${rewritten[@]}"
  else
    echo "ERROR: ni mysql client ni docker disponibles. Instalar mysql client:" >&2
    echo "  Windows (choco):  choco install mysql-cli" >&2
    echo "  o instalar Docker Desktop (se usa un contenedor efímero automáticamente)." >&2
    return 127
  fi
}

_cleanup_port_forwards() {
  local pid
  for pid in "${_pf_pids[@]:-}"; do
    [[ -n "$pid" ]] && kill "$pid" >/dev/null 2>&1 || true
  done
}
trap _cleanup_port_forwards EXIT

echo "=== reset-state: limpiando Redis + tabla alerts antes de la corrida ==="

# _reset_ssh_native — mismo transporte SSH, pero sin kubectl: redis-cli/mysql
# corren directo dentro del servidor contra localhost (procesos nativos
# systemd, ej. Sistema A baseline). Credenciales vienen de REDIS_PASSWORD/
# MYSQL_EW_PASSWORD (no hay pod del que leerlas — se pasan a mano).
_reset_ssh_native() {
  echo "--- Entorno: SSH a $SSH_USER@$SSH_HOST (procesos nativos, sin k8s) ---"

  local redis_result
  local redis_port="${REDIS_PORT:-6379}"
  if [[ -n "${REDIS_PASSWORD:-}" ]]; then
    redis_result=$(_ssh_run "redis-cli -p '$redis_port' -a '$REDIS_PASSWORD' --no-auth-warning FLUSHDB >/dev/null && echo OK") || redis_result="SSH_ERROR"
  else
    redis_result=$(_ssh_run "redis-cli -p '$redis_port' FLUSHDB >/dev/null && echo OK") || redis_result="SSH_ERROR"
  fi
  redis_result=$(echo "$redis_result" | grep -v '^\s*$' | tail -n1)
  case "$redis_result" in
    SSH_ERROR) echo "ERROR: falló el comando SSH remoto para Redis — se omite flush." >&2 ;;
    OK) echo "Redis: FLUSHDB OK (vía SSH nativo a $SSH_HOST:$redis_port)" ;;
    *) echo "AVISO: respuesta inesperada del reset de Redis vía SSH: $redis_result" >&2 ;;
  esac

  if [[ -z "${MYSQL_EW_PASSWORD:-}" ]]; then
    echo "ERROR: SSH_ORCHESTRATOR=native requiere MYSQL_EW_PASSWORD (no hay pod del que leerla) — no se puede truncar alerts." >&2
    return 1
  fi
  local mysql_db="${MYSQL_EW_DATABASE:-early_warning}"
  local mysql_port="${MYSQL_EW_PORT:-3306}"
  local mysql_user="${MYSQL_EW_USER:-root}"
  local mysql_result
  mysql_result=$(_ssh_run "mysql -u'$mysql_user' -p'$MYSQL_EW_PASSWORD' -P '$mysql_port' -h 127.0.0.1 '$mysql_db' -e 'TRUNCATE TABLE alerts;' >/dev/null 2>&1 && echo OK") || mysql_result="SSH_ERROR"
  mysql_result=$(echo "$mysql_result" | grep -v '^\s*$' | tail -n1)
  case "$mysql_result" in
    SSH_ERROR) echo "ERROR: falló el comando SSH remoto para MySQL — se omite truncate." >&2; return 1 ;;
    OK) echo "MySQL early_warning.alerts: TRUNCATE OK (vía SSH nativo a $SSH_HOST:$mysql_port)" ;;
    *) echo "AVISO: respuesta inesperada del reset de MySQL vía SSH: $mysql_result" >&2 ;;
  esac
}

# _reset_ssh — todo el trabajo corre DENTRO del servidor (kubectl exec
# directo, sin port-forward: ahí kubectl ya está configurado y en la misma
# red que los pods). Un solo comando SSH por servicio; las credenciales se
# leen y se usan en la misma sesión remota, nunca cruzan la red en claro
# hacia la máquina cliente más que dentro del túnel SSH ya cifrado.
_reset_ssh() {
  if [[ "${SSH_ORCHESTRATOR:-k8s}" == "native" ]]; then
    _reset_ssh_native
    return $?
  fi

  echo "--- Entorno: SSH a $SSH_USER@$SSH_HOST (namespace $K8S_NAMESPACE en el servidor) ---"

  if ! _ssh_run "command -v kubectl >/dev/null 2>&1"; then
    echo "ERROR: kubectl no está disponible en $SSH_HOST (o la conexión SSH falló) — no se pudo limpiar estado." >&2
    echo "  Si este servidor NO usa k8s, setear SSH_ORCHESTRATOR=native." >&2
    return 1
  fi

  local redis_result
  redis_result=$(_ssh_run "
    set -eu
    pod=\$(kubectl get pod -n '$K8S_NAMESPACE' -l app=redis -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -z \"\$pod\" ]; then echo 'NOPOD'; exit 0; fi
    pass=\$(kubectl exec -n '$K8S_NAMESPACE' \"\$pod\" -- printenv REDIS_PASSWORD 2>/dev/null || true)
    if [ -n \"\$pass\" ]; then
      kubectl exec -n '$K8S_NAMESPACE' \"\$pod\" -- redis-cli -a \"\$pass\" --no-auth-warning FLUSHDB >/dev/null
    else
      kubectl exec -n '$K8S_NAMESPACE' \"\$pod\" -- redis-cli FLUSHDB >/dev/null
    fi
    echo \"OK:\$pod\"
  ") || redis_result="SSH_ERROR"
  # redis-cli imprime "OK" en su propia línea al éxito de FLUSHDB — ya
  # redirigido a /dev/null arriba, pero por si acaso queda algo más en el
  # bloque remoto (warnings, etc.), nos quedamos solo con la última línea
  # no vacía, que es siempre nuestro propio marcador "OK:$pod".
  redis_result=$(echo "$redis_result" | grep -v '^\s*$' | tail -n1)

  case "$redis_result" in
    NOPOD) echo "AVISO: no se encontró pod de Redis (label app=redis) en $K8S_NAMESPACE — se omite flush." >&2 ;;
    SSH_ERROR) echo "ERROR: falló el comando SSH remoto para Redis — se omite flush." >&2 ;;
    OK:*) echo "Redis: FLUSHDB OK (${redis_result#OK:}, vía SSH a $SSH_HOST)" ;;
    *) echo "AVISO: respuesta inesperada del reset de Redis vía SSH: $redis_result" >&2 ;;
  esac

  local mysql_result
  mysql_result=$(_ssh_run "
    set -eu
    pod=\$(kubectl get pod -n '$K8S_NAMESPACE' -l app=mysql-early-warning -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -z \"\$pod\" ]; then echo 'NOPOD'; exit 0; fi
    rootpass=\$(kubectl exec -n '$K8S_NAMESPACE' \"\$pod\" -- printenv MYSQL_ROOT_PASSWORD 2>/dev/null || true)
    if [ -z \"\$rootpass\" ]; then echo 'NOPASS'; exit 0; fi
    db=\$(kubectl exec -n '$K8S_NAMESPACE' \"\$pod\" -- printenv MYSQL_DATABASE 2>/dev/null || echo early_warning)
    kubectl exec -n '$K8S_NAMESPACE' \"\$pod\" -- mysql -uroot -p\"\$rootpass\" \"\$db\" -e 'TRUNCATE TABLE alerts;' >/dev/null 2>&1
    echo \"OK:\$pod\"
  ") || mysql_result="SSH_ERROR"
  # Mismo criterio que Redis: quedarnos solo con la última línea no vacía
  # (el warning "Using a password on the command line..." de mysql client
  # va a stderr normalmente, pero por robustez lo tratamos igual).
  mysql_result=$(echo "$mysql_result" | grep -v '^\s*$' | tail -n1)

  case "$mysql_result" in
    NOPOD) echo "AVISO: no se encontró pod de mysql-early-warning en $K8S_NAMESPACE — se omite truncate." >&2 ;;
    NOPASS) echo "ERROR: no se pudo leer MYSQL_ROOT_PASSWORD del pod remoto — no se puede truncar alerts de forma segura." >&2; return 1 ;;
    SSH_ERROR) echo "ERROR: falló el comando SSH remoto para MySQL — se omite truncate." >&2; return 1 ;;
    OK:*) echo "MySQL early_warning.alerts: TRUNCATE OK (${mysql_result#OK:}, vía SSH a $SSH_HOST)" ;;
    *) echo "AVISO: respuesta inesperada del reset de MySQL vía SSH: $mysql_result" >&2 ;;
  esac
}

# _wait_port_forward <local_port> <timeout_seconds> — espera a que el
# port-forward realmente acepte conexiones antes de usarlo (kubectl
# port-forward arranca async, un uso inmediato puede fallar por carrera).
_wait_port_forward() {
  local port="$1" timeout="${2:-10}" waited=0
  while ! (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; do
    exec 3>&- 2>/dev/null || true
    sleep 0.5
    waited=$((waited + 1))
    if [[ "$waited" -ge $((timeout * 2)) ]]; then
      return 1
    fi
  done
  exec 3>&- 2>/dev/null || true
  return 0
}

_reset_k8s() {
  echo "--- Entorno detectado: Kubernetes (namespace $K8S_NAMESPACE), vía port-forward ---"

  local redis_pod
  redis_pod=$(kubectl get pod -n "$K8S_NAMESPACE" -l app=redis -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -z "$redis_pod" ]]; then
    echo "AVISO: no se encontró pod de Redis (label app=redis) en $K8S_NAMESPACE — se omite flush." >&2
  else
    local redis_password local_port
    redis_password=$(kubectl exec -n "$K8S_NAMESPACE" "$redis_pod" -- printenv REDIS_PASSWORD 2>/dev/null || true)
    local_port=16379
    kubectl port-forward -n "$K8S_NAMESPACE" "pod/$redis_pod" "${local_port}:6379" >/dev/null 2>&1 &
    _pf_pids+=("$!")
    if ! _wait_port_forward "$local_port" 10; then
      echo "ERROR: port-forward a Redis ($redis_pod) no respondió a tiempo — se omite flush." >&2
    else
      if [[ -n "$redis_password" ]]; then
        _redis_cli -h 127.0.0.1 -p "$local_port" -a "$redis_password" --no-auth-warning FLUSHDB
      else
        _redis_cli -h 127.0.0.1 -p "$local_port" FLUSHDB
      fi
      echo "Redis: FLUSHDB OK ($redis_pod, vía port-forward local:$local_port)"
    fi
  fi

  local mysql_pod
  mysql_pod=$(kubectl get pod -n "$K8S_NAMESPACE" -l app=mysql-early-warning -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -z "$mysql_pod" ]]; then
    echo "AVISO: no se encontró pod de mysql-early-warning en $K8S_NAMESPACE — se omite truncate." >&2
  else
    local mysql_root_password mysql_database local_port
    mysql_root_password=$(kubectl exec -n "$K8S_NAMESPACE" "$mysql_pod" -- printenv MYSQL_ROOT_PASSWORD 2>/dev/null || true)
    mysql_database=$(kubectl exec -n "$K8S_NAMESPACE" "$mysql_pod" -- printenv MYSQL_DATABASE 2>/dev/null || echo "early_warning")
    if [[ -z "$mysql_root_password" ]]; then
      echo "ERROR: no se pudo leer MYSQL_ROOT_PASSWORD del pod $mysql_pod — no se puede truncar alerts de forma segura." >&2
      return 1
    fi
    local_port=13306
    kubectl port-forward -n "$K8S_NAMESPACE" "pod/$mysql_pod" "${local_port}:3306" >/dev/null 2>&1 &
    _pf_pids+=("$!")
    if ! _wait_port_forward "$local_port" 10; then
      echo "ERROR: port-forward a mysql-early-warning ($mysql_pod) no respondió a tiempo — se omite truncate." >&2
      return 1
    fi
    _mysql_cli -h 127.0.0.1 -P "$local_port" -u root -p"$mysql_root_password" "$mysql_database" -e "TRUNCATE TABLE alerts;"
    echo "MySQL early_warning.alerts: TRUNCATE OK ($mysql_pod, vía port-forward local:$local_port)"
  fi
}

_reset_docker() {
  echo "--- Entorno detectado: Docker Compose (local) ---"

  if ! docker ps --format '{{.Names}}' | grep -q '^redis$'; then
    echo "AVISO: contenedor 'redis' no está corriendo — se omite flush." >&2
  else
    local redis_password
    redis_password=$(docker exec redis printenv REDIS_PASSWORD 2>/dev/null || true)
    if [[ -n "$redis_password" ]]; then
      docker exec redis redis-cli -a "$redis_password" --no-auth-warning FLUSHDB
    else
      docker exec redis redis-cli FLUSHDB
    fi
    echo "Redis: FLUSHDB OK"
  fi

  if ! docker ps --format '{{.Names}}' | grep -q '^mysql-early-warning$'; then
    echo "AVISO: contenedor 'mysql-early-warning' no está corriendo — se omite truncate." >&2
  else
    local mysql_root_password mysql_database
    mysql_root_password=$(docker exec mysql-early-warning printenv MYSQL_ROOT_PASSWORD 2>/dev/null || true)
    mysql_database=$(docker exec mysql-early-warning printenv MYSQL_DATABASE 2>/dev/null || echo "early_warning")
    if [[ -z "$mysql_root_password" ]]; then
      echo "ERROR: no se pudo leer MYSQL_ROOT_PASSWORD del contenedor mysql-early-warning — no se puede truncar alerts de forma segura." >&2
      return 1
    fi
    docker exec mysql-early-warning \
      mysql -uroot -p"$mysql_root_password" "$mysql_database" -e "TRUNCATE TABLE alerts;"
    echo "MySQL early_warning.alerts: TRUNCATE OK"
  fi
}

# _reset_direct — conexión directa por red, sin kubectl/docker: para cuando
# la máquina cliente tiene host:puerto alcanzable de otra forma (VPN, red
# compartida, un port-forward manual ya corriendo en otra terminal). Se usa
# solo si el operador seteó explícitamente REDIS_HOST o MYSQL_EW_HOST.
_reset_direct() {
  echo "--- Conexión directa por red (REDIS_HOST/MYSQL_EW_HOST seteados) ---"

  if [[ -n "${REDIS_HOST:-}" ]]; then
    local redis_port="${REDIS_PORT:-6379}"
    if [[ -n "${REDIS_PASSWORD:-}" ]]; then
      _redis_cli -h "$REDIS_HOST" -p "$redis_port" -a "$REDIS_PASSWORD" --no-auth-warning FLUSHDB
    else
      _redis_cli -h "$REDIS_HOST" -p "$redis_port" FLUSHDB
    fi
    echo "Redis: FLUSHDB OK ($REDIS_HOST:$redis_port)"
  else
    echo "AVISO: REDIS_HOST no seteado — se omite flush de Redis." >&2
  fi

  if [[ -n "${MYSQL_EW_HOST:-}" ]]; then
    local mysql_port="${MYSQL_EW_PORT:-3306}" mysql_user="${MYSQL_EW_USER:-root}" mysql_db="${MYSQL_EW_DATABASE:-early_warning}"
    if [[ -z "${MYSQL_EW_PASSWORD:-}" ]]; then
      echo "ERROR: MYSQL_EW_HOST seteado pero falta MYSQL_EW_PASSWORD — no se puede truncar alerts de forma segura." >&2
      return 1
    fi
    _mysql_cli -h"$MYSQL_EW_HOST" -P"$mysql_port" -u"$mysql_user" -p"$MYSQL_EW_PASSWORD" "$mysql_db" -e "TRUNCATE TABLE alerts;"
    echo "MySQL early_warning.alerts: TRUNCATE OK ($MYSQL_EW_HOST:$mysql_port)"
  else
    echo "AVISO: MYSQL_EW_HOST no seteado — se omite truncate de alerts." >&2
  fi
}

if [[ -n "${SSH_HOST:-}" ]]; then
  : "${SSH_USER:?SSH_HOST seteado pero falta SSH_USER}"
  if [[ -z "${SSH_PASSWORD:-}${SSH_KEY_PATH:-}" ]]; then
    echo "ERROR: SSH_HOST seteado pero falta SSH_PASSWORD o SSH_KEY_PATH." >&2
    exit 1
  fi
  _reset_ssh
elif [[ -n "${REDIS_HOST:-}${MYSQL_EW_HOST:-}" ]]; then
  _reset_direct
elif command -v kubectl >/dev/null 2>&1 && kubectl get ns "$K8S_NAMESPACE" >/dev/null 2>&1; then
  _reset_k8s
elif command -v docker >/dev/null 2>&1; then
  _reset_docker
else
  echo "ERROR: ni SSH_HOST, ni kubectl (namespace $K8S_NAMESPACE), ni docker disponibles, y no se setearon REDIS_HOST/MYSQL_EW_HOST — no se pudo limpiar estado." >&2
  exit 1
fi

echo "=== reset-state completado ==="
