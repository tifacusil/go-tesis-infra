#!/usr/bin/env bash
# grafana-annotate.sh — helper compartido para marcar en Grafana el inicio/fin
# de cada corrida de carga o inyección de chaos, vía la API de anotaciones
# (POST /api/annotations). Sin esto, una corrida de 12h queda indistinguible
# del resto del historial una vez pasa la ventana de "now-3h" del dashboard,
# y el retention de 30d de Prometheus eventualmente borra el contexto.
#
# GRAFANA_URL          default http://grafana:3000 (misma red landslide-net)
# GRAFANA_API_TOKEN    obligatorio — Service Account token de Grafana
#                       (Administration > Service accounts > Add service
#                       account token; scope de Editor alcanza para anotar)
#
# Si GRAFANA_API_TOKEN no está seteado, las funciones no fallan la corrida:
# imprimen un aviso y siguen (la anotación es soporte para el análisis
# posterior, no una precondición del experimento).

GRAFANA_URL="${GRAFANA_URL:-http://grafana:3000}"

# grafana_annotate <text> <tag> [tag...] — anotación puntual (un instante).
grafana_annotate() {
  local text="$1"; shift
  local tags_json="[]"
  if [[ "$#" -gt 0 ]]; then
    tags_json=$(printf '"%s",' "$@")
    tags_json="[${tags_json%,}]"
  fi
  _grafana_post "$(date +%s%3N)" "null" "$text" "$tags_json"
}

# grafana_annotate_region_start <text> <tag> [tag...] — abre una región
# (inicio de una ventana, ej. una corrida completa o una inyección de chaos).
# Imprime el annotation id por stdout — guardarlo para pasarlo a
# grafana_annotate_region_end.
grafana_annotate_region_start() {
  local text="$1"; shift
  local tags_json="[]"
  if [[ "$#" -gt 0 ]]; then
    tags_json=$(printf '"%s",' "$@")
    tags_json="[${tags_json%,}]"
  fi
  _grafana_post "$(date +%s%3N)" "null" "$text" "$tags_json" | python -c "import sys,json; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || echo ""
}

# grafana_annotate_region_end <annotation_id> — cierra la región abierta por
# grafana_annotate_region_start, actualizando su timeEnd al momento actual.
grafana_annotate_region_end() {
  local id="$1"
  if [[ -z "$id" ]]; then
    echo "  (grafana-annotate: sin id de región, se omite el cierre)" >&2
    return 0
  fi
  if [[ -z "${GRAFANA_API_TOKEN:-}" ]]; then
    return 0
  fi
  curl -s -X PATCH "$GRAFANA_URL/api/annotations/$id" \
    -H "Authorization: Bearer $GRAFANA_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"timeEnd\": $(date +%s%3N)}" \
    -o /dev/null || echo "  (grafana-annotate: fallo al cerrar región $id, no bloqueante)" >&2
}

_grafana_post() {
  local time="$1" time_end="$2" text="$3" tags_json="$4"
  if [[ -z "${GRAFANA_API_TOKEN:-}" ]]; then
    echo "  (grafana-annotate: GRAFANA_API_TOKEN no seteado, se omite anotación: $text)" >&2
    echo "{}"
    return 0
  fi
  curl -s -X POST "$GRAFANA_URL/api/annotations" \
    -H "Authorization: Bearer $GRAFANA_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"time\": $time, \"text\": \"$text\", \"tags\": $tags_json}" \
    || echo "  (grafana-annotate: fallo al anotar, no bloqueante: $text)" >&2
}
