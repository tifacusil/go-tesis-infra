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
METRICS
}

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
