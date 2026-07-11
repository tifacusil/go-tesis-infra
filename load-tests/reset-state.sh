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
# La máquina que corre Artillery NO corre en el mismo servidor/cluster que
# el sistema bajo prueba — Redis y MySQL en k8s son ClusterIP (sin
# exposición externa, correcto por seguridad: no queremos un Redis/MySQL
# de infra alcanzable desde fuera del cluster todo el tiempo). Por eso este
# script abre un `kubectl port-forward` temporal solo durante el reset, se
# conecta por localhost con redis-cli/mysql client, y lo cierra al
# terminar — no requiere exponer nada de forma permanente.
#
# redis-cli/mysql client no tienen que estar instalados en la máquina: si no
# están en PATH, se usa un contenedor Docker efímero (mismo patrón que
# chaos/*.sh con pumba) — ver _redis_cli/_mysql_cli más abajo.
#
# Entorno detectado automáticamente:
#   - Kubernetes (namespace $K8S_NAMESPACE) si kubectl responde: port-forward
#     + redis-cli/mysql client locales.
#   - Docker Compose (local) si no hay kubectl pero sí docker: kubectl exec
#     directo, sin port-forward (el contenedor SÍ está en la misma red que
#     el operador cuando se corre localmente).
#
# Uso:
#   ./load-tests/reset-state.sh
#
# Variables (todas opcionales; con kubectl las credenciales se leen del pod
# real, no hace falta pasarlas a mano):
#   K8S_NAMESPACE       default: landslide
#   REDIS_HOST          override si NO se usa kubectl (conexión directa)
#   REDIS_PORT          default: 6379
#   REDIS_PASSWORD      override si NO se usa kubectl
#   MYSQL_EW_HOST       override si NO se usa kubectl
#   MYSQL_EW_PORT       default: 3306
#   MYSQL_EW_USER       default: root
#   MYSQL_EW_PASSWORD   override si NO se usa kubectl
#   MYSQL_EW_DATABASE   default: early_warning
set -euo pipefail

K8S_NAMESPACE="${K8S_NAMESPACE:-landslide}"
_pf_pids=()

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

if [[ -n "${REDIS_HOST:-}${MYSQL_EW_HOST:-}" ]]; then
  _reset_direct
elif command -v kubectl >/dev/null 2>&1 && kubectl get ns "$K8S_NAMESPACE" >/dev/null 2>&1; then
  _reset_k8s
elif command -v docker >/dev/null 2>&1; then
  _reset_docker
else
  echo "ERROR: ni kubectl (namespace $K8S_NAMESPACE) ni docker disponibles, y no se setearon REDIS_HOST/MYSQL_EW_HOST — no se pudo limpiar estado." >&2
  exit 1
fi

echo "=== reset-state completado ==="
