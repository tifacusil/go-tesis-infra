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
# Por qué NO alcanza el total de la máquina: el engine de Artillery es Node, y
# Node es de un solo hilo. En esta máquina (16 cores lógicos) un event loop
# saturado es 6.25% del total — indistinguible de "cliente ocioso" si solo se
# mira el agregado. Fue exactamente lo que pasó: la escalera del 2026-07-22
# midió 16.2% de media en vu-150 y se concluyó que el cliente no era el techo,
# cuando las corridas r2/r3 de ese mismo nivel fallaron con 19,951 y 10,895
# `pool_dispatch_failed`, que es un error del generador, no del servidor.
#
# Por eso se muestrean tres cosas:
#   cpu_percent     uso total de la máquina, 0-100
#   node_percent    suma de los procesos node (engine Artillery); 100 = 1 core
#   python_percent  suma de los procesos python (pool de dtu-emulator)
#
# node_percent cerca de 100 significa event loop saturado, y ahí las cifras de
# la corrida miden el generador.
#
# Uso (source este archivo):
#   client_cpu_start /ruta/salida.csv
#   ... corrida ...
#   client_cpu_stop
#
# El muestreador corre en background y nunca aborta la corrida: si no hay
# ninguna fuente de CPU disponible avisa una vez y no escribe nada.

CLIENT_CPU_INTERVAL="${CLIENT_CPU_INTERVAL:-5}"
_client_cpu_pid=""

# _client_cpu_sample — imprime "total,node,python" o nada si no puede medir.
# Se resuelve por plataforma en cada muestra (no se cachea) para que el fallo
# de una fuente no deje la serie entera vacía.
_client_cpu_sample() {
  if command -v powershell.exe >/dev/null 2>&1; then
    # Windows: las clases de performance data, no Get-Counter. Get-Counter toma
    # la ruta del contador con los nombres LOCALIZADOS ('\Procesador(_Total)\%
    # de tiempo de procesador' en un Windows en español), así que la ruta en
    # inglés falla con "El objeto especificado no se encontró". El nombre de la
    # clase CIM es el mismo en cualquier idioma.
    #
    # PercentProcessorTime por proceso está normalizado a 100 por core: un
    # proceso de un solo hilo saturado da ~100, no ~6.
    powershell.exe -NoProfile -NonInteractive -Command '
      $t = (Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor | Where-Object { $_.Name -eq "_Total" }).PercentProcessorTime
      $procs = Get-CimInstance Win32_PerfFormattedData_PerfProc_Process
      $n = ($procs | Where-Object { $_.Name -like "node*" } | Measure-Object PercentProcessorTime -Sum).Sum
      $p = ($procs | Where-Object { $_.Name -like "python*" -or $_.Name -like "py*" } | Measure-Object PercentProcessorTime -Sum).Sum
      "{0},{1},{2}" -f [int]$t, [int]$n, [int]$p' 2>/dev/null | tr -d '\r' | awk 'NF{print;exit}'
    return
  fi
  if [[ -r /proc/stat ]]; then
    # Dos lecturas de /proc/stat separadas 1s: el delta de jiffies idle sobre
    # el total es lo único portable sin herramientas extra. Por proceso se usa
    # `ps`, cuyo %cpu ya viene normalizado a 100 por core.
    local a b total
    a=$(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8, $5}' /proc/stat)
    sleep 1
    b=$(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8, $5}' /proc/stat)
    total=$(awk -v a="$a" -v b="$b" 'BEGIN {
      split(a, x, " "); split(b, y, " ");
      dt = y[1] - x[1]; di = y[2] - x[2];
      if (dt > 0) printf "%.0f", 100 * (dt - di) / dt; else printf "0";
    }')
    local node py
    node=$(ps -eo comm,pcpu --no-headers 2>/dev/null | awk '$1 ~ /^node/ {s += $2} END {printf "%.0f", s}')
    py=$(ps -eo comm,pcpu --no-headers 2>/dev/null | awk '$1 ~ /^python/ {s += $2} END {printf "%.0f", s}')
    echo "${total},${node:-0},${py:-0}"
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
  echo "unix_ts,cpu_percent,node_percent,python_percent" > "$out"
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

# client_cpu_summary <csv> — resumen para el final del nivel. node max es el
# número que decide si la corrida midió el servidor o el generador.
client_cpu_summary() {
  local csv="$1"
  [[ -s "$csv" ]] || { echo "sin datos"; return 0; }
  awk -F, 'NR > 1 {
             n++; s += $2; if ($2 > tmax) tmax = $2;
             ns += $3; if ($3 > nmax) nmax = $3;
             ps += $4;
           }
           END {
             if (!n) { print "sin datos"; exit }
             printf "total media %.0f%% / max %.0f%% · node media %.0f%% max %.0f%% · python media %.0f%% (n=%d)",
                    s/n, tmax, ns/n, nmax, ps/n, n
           }' "$csv"
}
