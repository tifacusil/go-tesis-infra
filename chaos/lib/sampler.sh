#!/usr/bin/env bash
# sampler.sh — muestreo CONTINUO de métricas durante un escenario de chaos,
# en vez de dos instantáneas pre/post.
#
# Por qué existe: snapshot_counters() de capture.sh compara contadores antes y
# después, y eso alcanza para "cuántos mensajes se perdieron". No alcanza para
# NADA que sea un instante: el tiempo hasta que el breaker abre y el tiempo de
# recuperación son marcas temporales, no diferencias. Sin muestras intermedias
# simplemente no existen — por eso el MTTR del broker quedó sin reportar.
#
# Formato: CSV con una fila por muestra. Se elige CSV y no JSON porque la salida
# se lee tanto a ojo (durante la corrida) como desde pandas/R al analizar, y
# porque una fila por instante se puede appendear sin reescribir el archivo — si
# el escenario muere a mitad, lo muestreado hasta ahí sigue siendo válido.
#
# El muestreo corre en background (sampler_start) y se para por trap
# (sampler_stop). NO usa `set -e`: depende del script que lo fuente, igual que
# capture.sh.

# SAMPLER_METRICS — qué se muestrea, como "columna=expresión PromQL".
# Se puede sobreescribir antes de llamar a sampler_start.
#
# El default cubre lo que el informe exige registrar durante toda la ventana:
# estado del interruptor, tasa de errores de las llamadas salientes, y los
# contadores separados de durabilidad / procesamiento / oportunidad.
_sampler_default_metrics() {
  local target="${1:-user-management}"
  cat <<METRICS
breaker_state=max(ew_circuit_breaker_state{target="$target"})
calls_ok=sum(ew_outbound_calls_total{target="$target",outcome="ok"})
calls_timeout=sum(ew_outbound_calls_total{target="$target",outcome="timeout"})
calls_circuit_open=sum(ew_outbound_calls_total{target="$target",outcome="circuit_open"})
calls_error=sum(ew_outbound_calls_total{target="$target",outcome="error"})
alerts_published=sum(ew_alerts_published_total)
messages_consumed=sum(ew_messages_consumed_total)
messages_dropped=sum(ew_messages_dropped_total)
duplicates_skipped=sum(ew_duplicates_skipped_total)
queue_backlog=sum(rabbitmq_queue_messages_ready{queue="early_warning.evaluate"})
dispatch_degraded_count=sum(ew_alert_dispatch_duration_seconds_count{push_path="resolve_failed"}) or vector(0)
dispatch_degraded_sum=sum(ew_alert_dispatch_duration_seconds_sum{push_path="resolve_failed"}) or vector(0)
dispatch_healthy_count=sum(ew_alert_dispatch_duration_seconds_count{push_path!="resolve_failed"}) or vector(0)
dispatch_healthy_sum=sum(ew_alert_dispatch_duration_seconds_sum{push_path!="resolve_failed"}) or vector(0)
dispatch_p95_1m=histogram_quantile(0.95, sum by (le) (rate(ew_alert_dispatch_duration_seconds_bucket[1m])))
METRICS
}
# Las columnas dispatch_* son la latencia de degradación que pide O6: umbral
# cruzado -> alerta registrada en MySQL (ew_alert_dispatch_duration_seconds).
# Se muestrean _count y _sum crudos, no un promedio: la media exacta de
# cualquier tramo sale de dividir sus deltas (sampler_delta), sin depender de la
# ventana de rate() de Prometheus. push_path="resolve_failed" son las alertas
# emitidas en modo degradado (user-management falló o el breaker estaba abierto).

_sampler_pid=""
_sampler_csv=""
_sampler_stopfile=""

# sampler_start <label> [target] — arranca el muestreo en background.
# Imprime la ruta del CSV.
sampler_start() {
  local label="$1"
  local target="${2:-user-management}"
  local ts
  ts=$(date +%s)
  _sampler_csv="$RESULTS_DIR/${label}-samples-${ts}.csv"
  # El stopfile se deriva del nombre del CSV, para que sampler_stop lo pueda
  # reconstruir aunque sampler_start haya corrido en un subshell.
  _sampler_stopfile="${_sampler_csv}.stop"
  rm -f "$_sampler_stopfile"

  local metrics="${SAMPLER_METRICS:-$(_sampler_default_metrics "$target")}"

  # Cabecera: epoch + iso (UTC, que es como consultan Prometheus y Grafana) +
  # una columna por métrica. t_rel lo agrega el consumidor si quiere offsets.
  local cols="epoch,iso_utc"
  local line name
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    name="${line%%=*}"
    cols+=",$name"
  done <<<"$metrics"
  echo "$cols" > "$_sampler_csv"

  # stdout/stderr del loop se redirigen a /dev/null A PROPOSITO. sampler_start
  # se llama como `csv=$(sampler_start ...)`, y una substitucion de comando no
  # retorna hasta que TODOS los procesos que heredaron su stdout lo cierran: sin
  # esta redireccion el loop en background mantiene abierto el pipe y el script
  # que llama se cuelga para siempre. El loop no imprime nada util igual: sus
  # datos van al CSV.
  _sampler_loop "$metrics" >/dev/null 2>&1 &
  _sampler_pid=$!
  echo "$_sampler_csv"
}

_sampler_loop() {
  local metrics="$1"
  local line name expr row val
  # Se sale por centinela ademas de por senal. `kill` al PID del subshell no
  # alcanza: mientras esta en `sleep`, el subshell no procesa la senal hasta que
  # el sleep termina, y si el kill llega a destiempo el loop sobrevive y sigue
  # escribiendo el CSV despues de que el escenario cerro. Paso exactamente eso
  # al probarlo: el muestreo siguio corriendo tras sampler_stop.
  while [[ ! -f "$_sampler_stopfile" ]]; do
    row="$(date +%s),$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      name="${line%%=*}"
      expr="${line#*=}"
      # prom_query devuelve '' / NaN / ERR sin abortar: se escriben tal cual.
      # Una celda vacía es un dato ("no había serie en ese instante"), y hay que
      # poder distinguirla de un cero real al analizar.
      val=$(prom_query "$expr")
      row+=",${val}"
    done <<<"$metrics"
    echo "$row" >> "$_sampler_csv"
    # La espera se trocea en segundos para que el centinela se note enseguida.
    # Un `sleep $SAMPLE_INTERVAL` entero deja al loop sordo hasta que termina, y
    # con intervalos largos el muestreo sobrevive al final del escenario.
    local waited=0
    while [[ "$waited" -lt "${SAMPLE_INTERVAL:-5}" ]]; do
      if [[ -f "$_sampler_stopfile" ]]; then
        # Borrarlo es el acuse de recibo que sampler_stop espera.
        rm -f "$_sampler_stopfile" 2>/dev/null
        return 0
      fi
      sleep 1
      waited=$(( waited + 1 ))
    done
  done
  rm -f "$_sampler_stopfile" 2>/dev/null
}

# sampler_stop — para el muestreo. Idempotente.
sampler_stop() {
  # Si start corrio en subshell, _sampler_stopfile y _sampler_pid quedaron
  # vacios aca: el stopfile se reconstruye desde el CSV que el llamador si
  # tiene, y el PID simplemente no esta disponible. Por eso el centinela es el
  # mecanismo PRIMARIO de parada y el kill solo un respaldo.
  if [[ -z "$_sampler_stopfile" ]]; then
    local c; c=$(_sampler_resolve_csv)
    [[ -n "$c" ]] && _sampler_stopfile="${c}.stop"
  fi
  [[ -n "$_sampler_stopfile" ]] || return 0
  touch "$_sampler_stopfile" 2>/dev/null

  # Se espera SIEMPRE a que el loop consuma el centinela, tenga o no PID: el
  # loop chequea una vez por segundo, asi que sin esta espera sampler_stop
  # borraria el centinela antes de que lo vea y el muestreo seguiria corriendo
  # despues del escenario. Es lo que pasaba al probarlo (el CSV crecia de 6 a 8
  # filas despues del stop).
  local waited=0
  while [[ "$waited" -lt 5 ]] && [[ -f "$_sampler_stopfile" ]]; do
    sleep 1
    waited=$(( waited + 1 ))
    # El loop borra el centinela al salir (ver _sampler_loop), asi que su
    # desaparicion es el acuse de recibo.
  done

  if [[ -n "$_sampler_pid" ]] && kill -0 "$_sampler_pid" 2>/dev/null; then
    kill "$_sampler_pid" 2>/dev/null || true
    wait "$_sampler_pid" 2>/dev/null || true
  fi
  _sampler_pid=""
  rm -f "$_sampler_stopfile" 2>/dev/null
}

# sampler_csv — ruta del CSV de la corrida actual.
sampler_csv() { echo "$_sampler_csv"; }

# _sampler_resolve_csv — CSV sobre el que operan las funciones de analisis.
# Usa SAMPLER_CSV si esta seteada, si no la global.
#
# Hace falta porque sampler_start se invoca como `csv=$(sampler_start ...)` para
# quedarse con la ruta, y una substitucion de comando corre en un SUBSHELL: la
# asignacion a _sampler_csv se pierde al volver. El script que llama tiene la
# ruta en su propia variable, asi que se la pasa por SAMPLER_CSV. Sin esto las
# funciones de analisis leen "" y devuelven vacio en silencio, que fue
# exactamente lo que paso al probarlo.
_sampler_resolve_csv() { echo "${SAMPLER_CSV:-$_sampler_csv}"; }

# sampler_first_at <columna> <valor> <t0> — primer epoch en que la columna toma
# el valor dado, como offset en segundos desde t0. Vacío si nunca lo toma.
#
# Con esto el "instante de apertura" sale del MISMO CSV que se reporta, en vez
# de depender de que el loop de poll lo haya visto pasar: si el breaker abre y
# cierra entre dos polls, el poll se lo pierde pero la serie queda.
sampler_first_at() {
  local col="$1" want="$2" t0="$3"
  local csv; csv=$(_sampler_resolve_csv)
  [[ -f "$csv" ]] || return 0
  awk -F, -v col="$col" -v want="$want" -v t0="$t0" '
    NR==1 { for (i=1; i<=NF; i++) if ($i == col) idx=i; next }
    idx && $idx == want { print $1 - t0; exit }
  ' "$csv"
}

# sampler_delta <columna> <desde_epoch> <hasta_epoch> — incremento de un
# contador dentro de la ventana: último valor numérico con epoch <= hasta menos
# el primero con epoch >= desde. Vacío si la ventana no tiene dos valores
# numéricos (nunca 0: "no hubo datos" no es "no hubo eventos").
sampler_delta() {
  local col="$1" from="$2" to="$3"
  local csv; csv=$(_sampler_resolve_csv)
  [[ -f "$csv" ]] || return 0
  awk -F, -v col="$col" -v from="$from" -v to="$to" '
    NR==1 { for (i=1; i<=NF; i++) if ($i == col) idx=i; next }
    !idx || $1 < from || $1 > to { next }
    $idx ~ /^-?[0-9.]+([eE][-+]?[0-9]+)?$/ { if (!seen) { first=$idx; seen=1 }; last=$idx; n++ }
    END { if (n >= 2) printf "%.6g\n", last - first }
  ' "$csv"
}

# sampler_max <columna> <desde_epoch> <hasta_epoch> — máximo numérico de la
# columna en la ventana (ej. el peor p95 de despacho). Vacío si no hay datos.
sampler_max() {
  local col="$1" from="$2" to="$3"
  local csv; csv=$(_sampler_resolve_csv)
  [[ -f "$csv" ]] || return 0
  awk -F, -v col="$col" -v from="$from" -v to="$to" '
    NR==1 { for (i=1; i<=NF; i++) if ($i == col) idx=i; next }
    !idx || $1 < from || $1 > to { next }
    $idx ~ /^-?[0-9.]+([eE][-+]?[0-9]+)?$/ { if (!seen || $idx+0 > m) m=$idx+0; seen=1 }
    END { if (seen) printf "%.6g\n", m }
  ' "$csv"
}

# sampler_last_at <columna> <valor> <t0> — último epoch en que la columna toma
# el valor, como offset desde t0 (ej. el último instante con el breaker abierto).
sampler_last_at() {
  local col="$1" want="$2" t0="$3"
  local csv; csv=$(_sampler_resolve_csv)
  [[ -f "$csv" ]] || return 0
  awk -F, -v col="$col" -v want="$want" -v t0="$t0" '
    NR==1 { for (i=1; i<=NF; i++) if ($i == col) idx=i; next }
    idx && $idx == want { last = $1 - t0 }
    END { if (last != "") print last }
  ' "$csv"
}

# sampler_last_value <columna> — último valor no vacío de una columna.
sampler_last_value() {
  local col="$1"
  local csv; csv=$(_sampler_resolve_csv)
  [[ -f "$csv" ]] || return 0
  awk -F, -v col="$col" '
    NR==1 { for (i=1; i<=NF; i++) if ($i == col) idx=i; next }
    idx && $idx != "" && $idx != "NaN" && $idx != "ERR" { v=$idx }
    END { print v }
  ' "$csv"
}
