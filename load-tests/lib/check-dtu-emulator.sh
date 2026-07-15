#!/usr/bin/env bash
# check-dtu-emulator.sh — valida ANTES de arrancar una corrida que
# artillery-engine-dtu-tcp realmente puede invocar dtu-emulator. Sin esto,
# un DTU_EMULATOR_PATH mal seteado (o el default equivocado si dtu-emulator
# no está clonado como sibling de este repo) hace que CADA request falle
# silenciosamente por VU — Artillery no aborta, solo acumula errores en el
# reporte final. En una corrida de 12h (run-endurance.sh) eso significa
# descubrir el problema recién al final, con 12h de datos inútiles.
#
# Uso: source este archivo y llamar check_dtu_emulator (no ejecutar aparte).

check_dtu_emulator() {
  local script_dir="$1" # load-tests/ (para resolver el default relativo)
  # OJO: el default DEBE coincidir con el del engine (index.js resuelve
  # __dirname/../../../dtu-emulator = tesis-infra/../dtu-emulator). Desde
  # load-tests/ eso es ../../dtu-emulator — si difieren, este check puede
  # validar una ruta que el engine no va a usar.
  local dtu_path="${DTU_EMULATOR_PATH:-$(cd "$script_dir/../../dtu-emulator" 2>/dev/null && pwd)}"

  if [[ -z "$dtu_path" || ! -d "$dtu_path" ]]; then
    echo "ERROR: no se encontró dtu-emulator." >&2
    echo "  Default esperado: sibling de este checkout (../../dtu-emulator desde tesis-infra)." >&2
    echo "  Si tu clon vive en otro lado, exportar antes de correr:" >&2
    echo "    export DTU_EMULATOR_PATH=/ruta/a/dtu-emulator" >&2
    echo "  Ver load-tests/README-engine.md." >&2
    return 1
  fi

  if [[ ! -d "$dtu_path/src/sender" ]]; then
    echo "ERROR: DTU_EMULATOR_PATH=$dtu_path existe pero no parece ser el repo dtu-emulator (falta src/sender/)." >&2
    return 1
  fi

  local python_bin=""
  local candidate
  for candidate in "${DTU_EMULATOR_PYTHON:-}" python3 python py; do
    [[ -z "$candidate" ]] && continue
    if command -v "$candidate" >/dev/null 2>&1 && [[ "$("$candidate" -c 'print(1)' 2>/dev/null)" == "1" ]]; then
      python_bin="$candidate"
      break
    fi
  done

  if [[ -z "$python_bin" ]]; then
    echo "ERROR: no se encontró un intérprete Python funcional (probado: python3, python, py)." >&2
    echo "  En Windows, 'python3' puede resolver al stub de Microsoft Store (no ejecuta nada real)." >&2
    echo "  Forzar uno explícito: export DTU_EMULATOR_PYTHON=python  (o la ruta completa)" >&2
    return 1
  fi

  if ! PYTHONPATH="$dtu_path/src" "$python_bin" -m sender fixture --help >/dev/null 2>&1; then
    echo "ERROR: '$python_bin -m sender fixture --help' falló contra DTU_EMULATOR_PATH=$dtu_path." >&2
    echo "  Confirmar que el repo esté completo y sin errores de sintaxis." >&2
    return 1
  fi

  # El engine pooled usa el modo `stream` (no `fixture`) — un clon viejo de
  # dtu-emulator sin ese subcomando pasaría el check de arriba y después cada
  # worker del pool moriría al spawnearse, con TODA la corrida fallando.
  if ! PYTHONPATH="$dtu_path/src" "$python_bin" -m sender stream --help >/dev/null 2>&1; then
    echo "ERROR: '$python_bin -m sender stream --help' falló contra DTU_EMULATOR_PATH=$dtu_path." >&2
    echo "  El engine de Artillery usa 'sender stream' (pool de workers persistentes)." >&2
    echo "  Actualizar el clon de dtu-emulator (git pull) — versiones viejas no tienen ese modo." >&2
    return 1
  fi

  echo "  dtu-emulator OK: $dtu_path (python: $python_bin)"
  return 0
}
