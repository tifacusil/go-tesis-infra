#!/usr/bin/env bash
# ssh.sh — helper compartido por los escenarios de chaos para inyectar fallos
# EN EL SERVIDOR remoto (no en un Docker local). Los sistemas bajo prueba no
# corren en la máquina que dispara el chaos:
#
#   - Sistema B: k3s en 178.105.104.95. Los servicios son pods; el fallo se
#     inyecta con kubectl (delete pod) o crictl/tc dentro del nodo. El
#     kubeconfig de k3s es 600 root:root, así que kubectl remoto necesita
#     sudo -S con SUDO_PASSWORD.
#   - Sistema A: procesos systemd nativos en 204.168.203.32 (sin contenedores).
#     El fallo se inyecta con systemctl / tc directo en el host.
#
# Esto reemplaza el patrón viejo `docker run gaiaadm/pumba` sobre el socket
# Docker local: ninguno de los dos servidores de producción expone su runtime
# de contenedores a esta máquina, y el Sistema A ni siquiera usa contenedores.
#
# Uso: source este archivo desde un escenario de chaos y llamar _ssh_run /
# _kubectl. Requiere SSH_HOST + SSH_USER + (SSH_KEY_PATH ó SSH_PASSWORD).
#
# Variables (mismos nombres que load-tests/reset-state.sh, para poder reusar
# el mismo bloque de .env / línea de comando):
#   SSH_HOST         host/IP del servidor (obligatorio)
#   SSH_USER         usuario SSH (obligatorio)
#   SSH_PASSWORD     password SSH (o SSH_KEY_PATH para auth por key)
#   SSH_KEY_PATH     ruta a llave privada SSH, alternativa a SSH_PASSWORD
#   SSH_PORT         default: 22
#   SUDO_PASSWORD    password de sudo remoto, si kubectl/crictl requieren root
#                    para leer el kubeconfig de k3s (típico en Sistema B), o si
#                    systemctl/rabbitmqctl requieren root (típico en Sistema A)
#   K8S_NAMESPACE    default: landslide (solo para _kubectl)
#   SSH_ORCHESTRATOR k8s (Sistema B) | native (Sistema A). Mismos valores que
#                    load-tests/reset-state.sh, para reusar el bloque de .env.

SSH_PORT="${SSH_PORT:-22}"
SUDO_PASSWORD="${SUDO_PASSWORD:-}"
K8S_NAMESPACE="${K8S_NAMESPACE:-landslide}"
SSH_ORCHESTRATOR="${SSH_ORCHESTRATOR:-k8s}"

# _ssh_require — valida que estén las variables mínimas de conexión. Se llama
# al inicio de cada escenario que inyecta remoto, para fallar temprano con un
# mensaje claro en vez de a mitad de la inyección.
_ssh_require() {
  : "${SSH_HOST:?Falta SSH_HOST — el chaos se inyecta en el servidor remoto, no en Docker local. Ej: SSH_HOST=178.105.104.95}"
  : "${SSH_USER:?Falta SSH_USER}"
  if [[ -z "${SSH_PASSWORD:-}${SSH_KEY_PATH:-}" ]]; then
    echo "ERROR: falta SSH_PASSWORD o SSH_KEY_PATH para autenticar contra $SSH_HOST." >&2
    return 1
  fi
}

# _ssh_run <comando remoto> — ejecuta un comando en $SSH_HOST vía $SSH_USER.
# Autentica por SSH_KEY_PATH (preferido) o SSH_PASSWORD (vía sshpass). Usa el
# ssh/sshpass nativos si están en PATH; si no, cae a un contenedor Docker
# efímero con ambos (alpine + apk). Mismo patrón que reset-state.sh.
_ssh_run() {
  local remote_cmd="$1"
  local ssh_opts=(-p "$SSH_PORT" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

  if command -v ssh >/dev/null 2>&1; then
    if [[ -n "${SSH_KEY_PATH:-}" ]]; then
      ssh "${ssh_opts[@]}" -i "$SSH_KEY_PATH" "${SSH_USER}@${SSH_HOST}" -- "$remote_cmd"
    elif command -v sshpass >/dev/null 2>&1; then
      sshpass -p "$SSH_PASSWORD" ssh "${ssh_opts[@]}" "${SSH_USER}@${SSH_HOST}" -- "$remote_cmd"
    else
      echo "ERROR: SSH_PASSWORD seteado pero 'sshpass' no está instalado (necesario para auth SSH no interactiva)." >&2
      echo "  Opciones: usar SSH_KEY_PATH, instalar sshpass (scoop install sshpass), o levantar Docker Desktop (fallback automático)." >&2
      return 127
    fi
  elif command -v docker >/dev/null 2>&1; then
    if [[ -n "${SSH_KEY_PATH:-}" ]]; then
      docker run --rm -v "$(cygpath -u "$SSH_KEY_PATH" 2>/dev/null || echo "$SSH_KEY_PATH")":/key:ro \
        alpine:3 sh -c "apk add --no-cache openssh-client >/dev/null && ssh $(printf '%q' "${ssh_opts[@]}") -i /key ${SSH_USER}@${SSH_HOST} -- $(printf '%q' "$remote_cmd")"
    else
      docker run --rm alpine:3 sh -c \
        "apk add --no-cache openssh-client sshpass >/dev/null && sshpass -p $(printf '%q' "$SSH_PASSWORD") ssh $(printf '%q' "${ssh_opts[@]}") ${SSH_USER}@${SSH_HOST} -- $(printf '%q' "$remote_cmd")"
    fi
  else
    echo "ERROR: ni ssh ni docker disponibles — no se puede conectar a SSH_HOST=$SSH_HOST." >&2
    return 127
  fi
}

# _kubectl <args...> — corre kubectl EN el servidor remoto (donde k3s y su
# kubeconfig viven), con sudo -S si SUDO_PASSWORD está seteado (el kubeconfig
# de k3s es 600 root:root). Devuelve stdout del kubectl remoto tal cual.
#
# Los argumentos se pasan por printf %q para que espacios/comillas en
# selectors o jsonpath sobrevivan al doble parseo (shell local + shell remoto).
_kubectl() {
  local quoted=""
  local a
  for a in "$@"; do
    quoted+=" $(printf '%q' "$a")"
  done
  if [[ -n "$SUDO_PASSWORD" ]]; then
    # sudo -S lee el password de stdin; -p "" evita que imprima el prompt.
    _ssh_run "echo $(printf '%q' "$SUDO_PASSWORD") | sudo -S -p '' kubectl$quoted"
  else
    _ssh_run "kubectl$quoted"
  fi
}

# _sudo_run <comando remoto> — corre un comando como root EN el servidor remoto.
# Es el equivalente de _kubectl para el Sistema A, donde los servicios son
# unidades systemd nativas y la inyección se hace con systemctl / rabbitmqctl /
# tc, todos los cuales requieren root.
#
# A diferencia de _kubectl, recibe la línea de comando ya armada (no argv), para
# poder pasar pipelines. El caller es responsable de citar lo que necesite.
_sudo_run() {
  local remote_cmd="$1"
  if [[ -n "$SUDO_PASSWORD" ]]; then
    _ssh_run "echo $(printf '%q' "$SUDO_PASSWORD") | sudo -S -p '' sh -c $(printf '%q' "$remote_cmd")"
  else
    _ssh_run "sudo -n sh -c $(printf '%q' "$remote_cmd")"
  fi
}
