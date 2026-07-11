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
# Detecta automáticamente el entorno: k8s (namespace landslide) si kubectl
# está disponible y responde, si no docker compose (contenedores locales).
#
# Uso:
#   ./load-tests/reset-state.sh
#
# Variables (solo si hace falta override; por default lee las mismas envs
# que ya usan los servicios):
#   K8S_NAMESPACE   default: landslide
set -euo pipefail

K8S_NAMESPACE="${K8S_NAMESPACE:-landslide}"

echo "=== reset-state: limpiando Redis + tabla alerts antes de la corrida ==="

_reset_k8s() {
  echo "--- Entorno detectado: Kubernetes (namespace $K8S_NAMESPACE) ---"

  local redis_pod
  redis_pod=$(kubectl get pod -n "$K8S_NAMESPACE" -l app=redis -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -z "$redis_pod" ]]; then
    echo "AVISO: no se encontró pod de Redis (label app=redis) en $K8S_NAMESPACE — se omite flush." >&2
  else
    local redis_password
    redis_password=$(kubectl exec -n "$K8S_NAMESPACE" "$redis_pod" -- printenv REDIS_PASSWORD 2>/dev/null || true)
    if [[ -n "$redis_password" ]]; then
      kubectl exec -n "$K8S_NAMESPACE" "$redis_pod" -- redis-cli -a "$redis_password" --no-auth-warning FLUSHDB
    else
      kubectl exec -n "$K8S_NAMESPACE" "$redis_pod" -- redis-cli FLUSHDB
    fi
    echo "Redis: FLUSHDB OK ($redis_pod)"
  fi

  local mysql_pod
  mysql_pod=$(kubectl get pod -n "$K8S_NAMESPACE" -l app=mysql-early-warning -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -z "$mysql_pod" ]]; then
    echo "AVISO: no se encontró pod de mysql-early-warning en $K8S_NAMESPACE — se omite truncate." >&2
  else
    local mysql_root_password mysql_database
    mysql_root_password=$(kubectl exec -n "$K8S_NAMESPACE" "$mysql_pod" -- printenv MYSQL_ROOT_PASSWORD 2>/dev/null || true)
    mysql_database=$(kubectl exec -n "$K8S_NAMESPACE" "$mysql_pod" -- printenv MYSQL_DATABASE 2>/dev/null || echo "early_warning")
    if [[ -z "$mysql_root_password" ]]; then
      echo "ERROR: no se pudo leer MYSQL_ROOT_PASSWORD del pod $mysql_pod — no se puede truncar alerts de forma segura." >&2
      return 1
    fi
    kubectl exec -n "$K8S_NAMESPACE" "$mysql_pod" -- \
      mysql -uroot -p"$mysql_root_password" "$mysql_database" -e "TRUNCATE TABLE alerts;"
    echo "MySQL early_warning.alerts: TRUNCATE OK ($mysql_pod)"
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

if command -v kubectl >/dev/null 2>&1 && kubectl get ns "$K8S_NAMESPACE" >/dev/null 2>&1; then
  _reset_k8s
elif command -v docker >/dev/null 2>&1; then
  _reset_docker
else
  echo "ERROR: ni kubectl (namespace $K8S_NAMESPACE) ni docker disponibles — no se pudo limpiar estado." >&2
  exit 1
fi

echo "=== reset-state completado ==="
