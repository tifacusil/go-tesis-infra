#!/usr/bin/env bash
# grafana-annotate.sh — helper compartido para marcar en Grafana el inicio/fin
# de cada corrida de carga o inyección de chaos, vía la API de anotaciones
# (POST /api/annotations). Sin esto, una corrida de 12h queda indistinguible
# del resto del historial una vez pasa la ventana de "now-3h" del dashboard,
# y el retention de 30d de Prometheus eventualmente borra el contexto.
#
# GRAFANA_URL          default http://localhost:3000 — Grafana corre local
#                       (en la máquina donde se ejecutan estos scripts), no
#                       en el servidor remoto donde vive TARGET_HOST/Prometheus.
#                       Ajustar solo si Grafana corre en otro host/puerto.
# GRAFANA_API_TOKEN    obligatorio — Service Account token de Grafana
#                       (Administration > Service accounts > Add service
#                       account token; scope de Editor alcanza para anotar)
#
# Si GRAFANA_API_TOKEN no está seteado, las funciones no fallan la corrida:
# imprimen un aviso y siguen (la anotación es soporte para el análisis
# posterior, no una precondición del experimento).
#
# Carga load-tests/.env si existe (ver load-tests/.env.example), sin
# pisar variables ya exportadas en el entorno (ej. por CI o export manual).
# Se valida la sintaxis con `bash -n` antes de sourcearlo: un .env malformado
# (comilla sin cerrar, etc.) NO debe abortar el script que llama vía `set -e`
# — esta librería es de soporte, no debe poder tumbar una corrida de 12h por
# un typo en un token.

_grafana_annotate_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_grafana_annotate_env_file="$(cd "$_grafana_annotate_lib_dir/.." && pwd)/.env"
if [[ -f "$_grafana_annotate_env_file" ]]; then
  if bash -n "$_grafana_annotate_env_file" 2>/dev/null; then
    set -a
    # shellcheck source=/dev/null
    source "$_grafana_annotate_env_file"
    set +a
  else
    echo "  (grafana-annotate: load-tests/.env tiene un error de sintaxis, se ignora — revisar comillas/caracteres especiales)" >&2
  fi
fi

GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"

# _grafana_python — resuelve un intérprete Python que REALMENTE ejecute.
# command -v no alcanza: en Windows, `python`/`python3` puede resolver al
# stub de Microsoft Store (un ejecutable real que está en PATH, pero que
# solo imprime un prompt de instalación a stderr y sale con código de error
# al primer argumento) — hay que probar una ejecución real, no solo
# existencia en PATH. Cacheado tras la primera resolución exitosa.
_grafana_python() {
  if [[ -n "${GA_PYTHON_BIN:-}" ]]; then
    echo "$GA_PYTHON_BIN"
    return 0
  fi
  local candidate
  for candidate in python3 python py; do
    if command -v "$candidate" >/dev/null 2>&1 && [[ "$("$candidate" -c 'print(1)' 2>/dev/null)" == "1" ]]; then
      GA_PYTHON_BIN="$candidate"
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

# _json_escape <string> — escapa backslash y comillas dobles para poder
# interpolar el valor crudo dentro de un literal JSON armado a mano. No
# escapa caracteres de control (\n, \t) porque ninguno de los valores que
# pasan por acá (SYSTEM, VU, nombres de contenedor) los contiene en la
# práctica — si algún día se pasa texto libre con saltos de línea, extender
# esta función antes de reusarla para eso.
_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  echo "$s"
}

# grafana_annotate <text> <tag> [tag...] — anotación puntual (un instante).
grafana_annotate() {
  local text="$1"; shift
  local tags_json
  tags_json=$(_tags_to_json "$@")
  _grafana_post "$(date +%s%3N)" "null" "$text" "$tags_json"
}

# grafana_annotate_region_start <text> <tag> [tag...] — abre una región
# (inicio de una ventana, ej. una corrida completa o una inyección de chaos).
# Imprime el annotation id por stdout — guardarlo para pasarlo a
# grafana_annotate_region_end. Imprime "" si no se pudo crear la anotación
# (sin token, POST falló, o no hay python para extraer el id) — en todos
# esos casos ya se avisó por stderr en el punto donde ocurrió, así que acá
# no hace falta un mensaje adicional.
grafana_annotate_region_start() {
  local text="$1"; shift
  local tags_json
  tags_json=$(_tags_to_json "$@")
  local body
  body=$(_grafana_post "$(date +%s%3N)" "null" "$text" "$tags_json")
  local py
  py=$(_grafana_python) || { echo "  (grafana-annotate: no se encontró python3/python/py, no se puede extraer el id de la anotación)" >&2; echo ""; return 0; }
  echo "$body" | "$py" -c "import sys,json
try:
    d = json.load(sys.stdin)
    print(d.get('id',''))
except Exception:
    print('')
" 2>/dev/null || echo ""
}

# grafana_annotate_region_end <annotation_id> — cierra la región abierta por
# grafana_annotate_region_start, actualizando su timeEnd al momento actual.
grafana_annotate_region_end() {
  local id="$1"
  if [[ -z "${GRAFANA_API_TOKEN:-}" ]]; then
    echo "  (grafana-annotate: GRAFANA_API_TOKEN no seteado, se omite cierre de región)" >&2
    return 0
  fi
  if [[ -z "$id" ]]; then
    echo "  (grafana-annotate: sin id de región, se omite el cierre — ver aviso anterior sobre por qué la apertura no devolvió id)" >&2
    return 0
  fi
  local http_code
  http_code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 5 \
    -X PATCH "$GRAFANA_URL/api/annotations/$id" \
    -H "Authorization: Bearer $GRAFANA_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"timeEnd\": $(date +%s%3N)}") || http_code="curl_error(${?})"
  if [[ "$http_code" != "200" ]]; then
    echo "  (grafana-annotate: fallo al cerrar región $id, no bloqueante — GRAFANA_URL=$GRAFANA_URL http_code=$http_code)" >&2
  fi
}

# _tags_to_json <tag> [tag...] — arma un array JSON escapando cada tag.
_tags_to_json() {
  if [[ "$#" -eq 0 ]]; then
    echo "[]"
    return 0
  fi
  local out="" tag
  for tag in "$@"; do
    out+="\"$(_json_escape "$tag")\","
  done
  echo "[${out%,}]"
}

_grafana_post() {
  local time="$1" time_end="$2" text="$3" tags_json="$4"
  if [[ -z "${GRAFANA_API_TOKEN:-}" ]]; then
    echo "  (grafana-annotate: GRAFANA_API_TOKEN no seteado, se omite anotación: $text)" >&2
    echo "{}"
    return 0
  fi
  local escaped_text body http_code
  escaped_text="$(_json_escape "$text")"
  body=$(curl -s -w '\n%{http_code}' --connect-timeout 3 --max-time 5 \
    -X POST "$GRAFANA_URL/api/annotations" \
    -H "Authorization: Bearer $GRAFANA_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"time\": $time, \"text\": \"$escaped_text\", \"tags\": $tags_json}") || body=$'\ncurl_error'
  http_code="${body##*$'\n'}"
  body="${body%$'\n'*}"
  if [[ "$http_code" != "200" ]]; then
    echo "  (grafana-annotate: fallo al anotar, no bloqueante — GRAFANA_URL=$GRAFANA_URL http_code=$http_code body=$body texto=\"$text\")" >&2
    echo "{}"
    return 0
  fi
  echo "$body"
}
