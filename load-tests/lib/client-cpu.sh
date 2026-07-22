#!/usr/bin/env bash
# client-cpu.sh — muestrea la CPU de la MÁQUINA CLIENTE durante una corrida.
#
# Por qué existe: en vu-400 el servidor ingirió 111,783 frames mientras el
# cliente reportó 28,959, y la conclusión de "el cliente no es el cuello de
# botella" se sostuvo con aritmética (pool de 400 slots / 2.5s de RTT = 160/s,
# contra 154.8/s medidos) en vez de con evidencia. Un techo del generador de
# carga se ve igual que un techo del servidor en los números de Artillery, así
# que hay que medirlo aparte.
#
# Uso (source este archivo):
#   client_cpu_start /ruta/salida.csv
#   ... corrida ...
#   client_cpu_stop
#
# Salida CSV: unix_ts,cpu_percent   (cpu_percent = uso total de la máquina)
#
# El muestreador corre en background y nunca aborta la corrida: si no hay
# ninguna fuente de CPU disponible avisa una vez y no escribe nada.

CLIENT_CPU_INTERVAL="${CLIENT_CPU_INTERVAL:-5}"
_client_cpu_pid=""

# _client_cpu_sample — imprime el uso de CPU total, 0-100, o nada si no puede.
# Se resuelve por plataforma en cada muestra (no se cachea) para que el fallo
# de una fuente no deje la serie entera vacía.
_client_cpu_sample() {
  if command -v powershell.exe >/dev/null 2>&1; then
    # Windows: la clase de performance data, no Get-Counter. Get-Counter toma
    # la ruta del contador con los nombres LOCALIZADOS ('\Procesador(_Total)\%
    # de tiempo de procesador' en un Windows en español), así que la ruta en
    # inglés falla con "El objeto especificado no se encontró". El nombre de la
    # clase CIM es el mismo en cualquier idioma.
    powershell.exe -NoProfile -NonInteractive -Command \
      "(Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter \"Name='_Total'\").PercentProcessorTime" \
      2>/dev/null | tr -d '\r' | awk 'NF{printf "%.1f\n", $1; exit}'
    return
  fi
  if command -v mpstat >/dev/null 2>&1; then
    mpstat 1 1 2>/dev/null | awk '/Average|Promedio/ {printf "%.1f\n", 100 - $NF; exit}'
    return
  fi
  if [[ -r /proc/stat ]]; then
    # Dos lecturas de /proc/stat separadas 1s: el delta de jiffies idle sobre
    # el total es lo único portable sin herramientas extra.
    local a b
    a=$(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8, $5}' /proc/stat)
    sleep 1
    b=$(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8, $5}' /proc/stat)
    awk -v a="$a" -v b="$b" 'BEGIN {
      split(a, x, " "); split(b, y, " ");
      dt = y[1] - x[1]; di = y[2] - x[2];
      if (dt > 0) printf "%.1f\n", 100 * (dt - di) / dt;
    }'
    return
  fi
}

client_cpu_start() {
  local out="$1"
  if [[ -z "$(_client_cpu_sample)" ]]; then
    echo "AVISO: sin fuente de CPU disponible en esta máquina; no se instrumenta el cliente." >&2
    return 0
  fi
  mkdir -p "$(dirname "$out")"
  echo "unix_ts,cpu_percent" > "$out"
  (
    while :; do
      local value
      value=$(_client_cpu_sample)
      [[ -n "$value" ]] && echo "$(date +%s),$value" >> "$out"
      sleep "$CLIENT_CPU_INTERVAL"
    done
  ) &
  _client_cpu_pid=$!
}

client_cpu_stop() {
  [[ -z "$_client_cpu_pid" ]] && return 0
  kill "$_client_cpu_pid" 2>/dev/null || true
  wait "$_client_cpu_pid" 2>/dev/null || true
  _client_cpu_pid=""
}

# client_cpu_summary <csv> — media / máximo, para el resumen al final del nivel.
client_cpu_summary() {
  local csv="$1"
  [[ -s "$csv" ]] || { echo "sin datos"; return 0; }
  awk -F, 'NR > 1 { n++; s += $2; if ($2 > max) max = $2 }
           END { if (n) printf "media %.1f%% / max %.1f%% (n=%d)", s / n, max, n; else print "sin datos" }' "$csv"
}
