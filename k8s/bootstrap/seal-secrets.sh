#!/usr/bin/env bash
# Genera los SealedSecret cifrados a partir de un archivo de valores en claro.
#
#   ./seal-secrets.sh secrets.env
#
# Requisitos: kubectl + kubeseal apuntando al cluster con el controller
# sealed-secrets ya instalado (ver README.md). Los valores en claro NO se
# versionan; solo los .yaml cifrados que este script escribe en
# ../overlays/prod/sealed-secrets/.
set -euo pipefail

NS=landslide
ENV_FILE="${1:-secrets.env}"
OUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../overlays/prod/sealed-secrets" && pwd)"

[ -f "$ENV_FILE" ] || { echo "No existe $ENV_FILE (cp secrets.example.env secrets.env y rellenar)"; exit 1; }
command -v kubeseal >/dev/null || { echo "falta kubeseal en PATH"; exit 1; }

# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

# seal NAME key1=val1 key2=val2 ...  → escribe OUT_DIR/NAME.yaml (SealedSecret)
seal() {
  local name="$1"; shift
  local args=()
  local kv
  for kv in "$@"; do args+=(--from-literal="$kv"); done
  kubectl -n "$NS" create secret generic "$name" "${args[@]}" \
    --dry-run=client -o yaml \
    | kubeseal --format yaml \
    > "$OUT_DIR/$name.yaml"
  echo "  sellado: $name.yaml"
}

echo "-> Sellando secrets en $OUT_DIR ..."

# Infra — MySQL (clave que espera el contenedor mysql: MYSQL_ROOT_PASSWORD)
seal mysql-data-management    "MYSQL_ROOT_PASSWORD=$MYSQL_DATA_MANAGEMENT_ROOT_PASSWORD"    "MYSQL_DATABASE=data_management"
seal mysql-user-management    "MYSQL_ROOT_PASSWORD=$MYSQL_USER_MANAGEMENT_ROOT_PASSWORD"    "MYSQL_DATABASE=user_management"
seal mysql-project-management "MYSQL_ROOT_PASSWORD=$MYSQL_PROJECT_MANAGEMENT_ROOT_PASSWORD" "MYSQL_DATABASE=project_management"
seal mysql-early-warning      "MYSQL_ROOT_PASSWORD=$MYSQL_EARLY_WARNING_ROOT_PASSWORD"      "MYSQL_DATABASE=early_warning"

# Infra — Redis / RabbitMQ
seal redis "REDIS_PASSWORD=$REDIS_PASSWORD"
seal rabbitmq \
  "RABBITMQ_DEFAULT_USER=$RABBITMQ_DEFAULT_USER" \
  "RABBITMQ_DEFAULT_PASS=$RABBITMQ_DEFAULT_PASS" \
  "RABBITMQ_ERLANG_COOKIE=$RABBITMQ_ERLANG_COOKIE"

# Servicios (claves = exactamente los env names que lee cada app)
seal data-receiving \
  "RECEIVER__REDIS__CONNECTIONSTRING=$RECEIVER_REDIS_CONNECTIONSTRING" \
  "RECEIVER__RABBITMQ__PASSWORD=$RECEIVER_RABBITMQ_PASSWORD"

seal data-management \
  "RABBITMQ_PASSWORD=$DATA_MGMT_RABBITMQ_PASSWORD" \
  "MYSQL_PASSWORD=$DATA_MGMT_MYSQL_PASSWORD"

seal data-analysis \
  "MYSQL_PASSWORD=$DATA_ANALYSIS_MYSQL_PASSWORD"

seal early-warning \
  "RABBITMQ_PASSWORD=$EW_RABBITMQ_PASSWORD" \
  "REDIS_PASSWORD=$EW_REDIS_PASSWORD" \
  "MYSQL_PASSWORD=$EW_MYSQL_PASSWORD"

seal user-management \
  "DB_PASS=$USER_MGMT_DB_PASS" \
  "DB_ROOT_PASS=$USER_MGMT_DB_ROOT_PASS" \
  "JWT_SECRET=$USER_MGMT_JWT_SECRET" \
  "SEED_ON_STARTUP=$SEED_ON_STARTUP" \
  "SEED_ADMIN_PASSWORD=$SEED_ADMIN_PASSWORD" \
  "SEED_USER_PASSWORD=$SEED_USER_PASSWORD"

seal project-management \
  "DB_PASS=$PROJECT_MGMT_DB_PASS" \
  "DB_ROOT_PASS=$PROJECT_MGMT_DB_ROOT_PASS"

# Observabilidad — mysqld-exporter (usuario exporter creado manualmente en cada MySQL)
seal mysqld-exporter "password=$MYSQLD_EXPORTER_PASSWORD"

echo "[OK] SealedSecret generados. Revisar y commitear $OUT_DIR/*.yaml"
