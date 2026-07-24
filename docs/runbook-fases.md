# Runbook — Fase 1 y Fase 2, A y B

Comandos listos para correr las dos fases en los dos sistemas, desde esta
máquina cliente. Correr en **Git Bash** (no PowerShell), desde la raíz del repo:

```
cd /c/Users/Adrian/Desktop/TESIS/go-tesis-infra
```

Datos de los sistemas:

| sistema | TARGET_HOST | SSH_ORCHESTRATOR | gateway (chaos) |
|---|---|---|---|
| A (Java/Python, systemd) | `204.168.203.32:5100` | `native` | `http://204.168.203.32/health/data-management` |
| B (Go, k3s) | `178.105.104.95:5000` | `k8s` | `http://178.105.104.95/api/v1/data/health` |

**Regla de oro:** un solo bloque activo en `load-tests/.env`, y tiene que ser el
del sistema que estás corriendo. `reset-state` (Fase 1 y 2) y el chaos leen
`SSH_*`/`REDIS_*`/`MYSQL_*` del `.env`. Bloque ≠ target = reseteás/inyectás en el
sistema equivocado. Verificar SIEMPRE antes:

```
grep -E "^SSH_HOST|^SSH_ORCHESTRATOR|^SYSTEM" load-tests/.env
```

Para cambiar de sistema: comentar un bloque, descomentar el otro en
`load-tests/.env`.

---

## Antes de cada corrida

Matar Python/Node huérfano (si quedó de una corrida anterior; contamina la CPU
del cliente y agota recursos):

```
powershell.exe -Command "Get-Process python,node -EA SilentlyContinue | Stop-Process -Force"
```

---

## FASE 1 — Descubrimiento (~2h15 por sistema)

Solo niveles ≤100: arriba de eso el generador (no el servidor) es el techo en
esta máquina. No agregar 150+.

### A  (`.env` bloque A activo)

```
grep -E "^SSH_HOST|^SSH_ORCHESTRATOR|^SYSTEM" load-tests/.env   # debe decir A / native

VU_LEVELS="001 010 050 100" REPEATS=3 \
  TARGET_HOST=204.168.203.32:5100 SYSTEM=A \
  ./load-tests/run-all.sh
```

### B  (editar `.env`: comentar A, descomentar B)

```
grep -E "^SSH_HOST|^SSH_ORCHESTRATOR|^SYSTEM" load-tests/.env   # debe decir B / k8s

VU_LEVELS="001 010 050 100" REPEATS=3 \
  TARGET_HOST=178.105.104.95:5000 SYSTEM=B \
  ./load-tests/run-all.sh
```

### Resultados

```
node load-tests/aggregate-results.js A
node load-tests/aggregate-results.js B
```

Salida en `load-tests/results/A/` y `results/B/` (un `.json` + `.client-cpu.csv`
por corrida). `SUSTAINED_RATE` = último nivel sin violar §1.3 de `plan-pruebas.md`.

---

## FASE 2 — Resiliencia (12h por sistema)

Solo después de tener `SUSTAINED_RATE` de Fase 1. Carga sostenida + chaos, los
dos juntos con `&` + `wait` en el mismo shell (el chaos coordina el timing con la
ventana de carga: t+2h y t+6h).

### A  (`.env` bloque A activo)

```
grep -E "^SSH_HOST|^SSH_ORCHESTRATOR|^SYSTEM" load-tests/.env   # debe decir A / native

TARGET_HOST=204.168.203.32:5100 SUSTAINED_RATE=100 SYSTEM=A \
  ./load-tests/run-endurance.sh &
GATEWAY_URL=http://204.168.203.32/health/data-management \
  ./chaos/run-during-endurance.sh &
wait
```

A native → chaos inyecta solo `kill-rabbitmq` (t+2h) y `pause-data-management`
(t+6h). `netem-delay` se salta solo.

### B  (editar `.env`: comentar A, descomentar B)

```
grep -E "^SSH_HOST|^SSH_ORCHESTRATOR|^SYSTEM" load-tests/.env   # debe decir B / k8s

TARGET_HOST=178.105.104.95:5000 SUSTAINED_RATE=100 SYSTEM=B \
  ./load-tests/run-endurance.sh &
GATEWAY_URL=http://178.105.104.95/api/v1/data/health \
  ./chaos/run-during-endurance.sh &
wait
```

B k8s → chaos inyecta los 3: `kill-rabbitmq`, `pause-data-management`,
`netem-delay` (ew → data-analysis).

### Resultados

`load-tests/results/<SYS>/sustained-12h.json` + snapshots en `chaos/results/`.
Revisar contra §2.4 de `plan-pruebas.md`: consumidores reconectan, cola drena,
sin pérdida de alertas, memoria estable.

---

## Tener en cuenta

- **Un generador a la vez.** No correr A y B en paralelo desde esta máquina.
  Secuencial.
- **No usar la máquina para nada pesado durante una corrida.** Contamina la
  medición de CPU del cliente y el generador es frágil.
- **Fase 2 = 12h reales.** Laptop sin suspensión, red estable. Si cae el SSH, el
  chaos falla la inyección.
- **Techo del generador ~100-145 fps.** `SUSTAINED_RATE=100` está dentro de lo
  que el cliente aguanta limpio (control: 144.7 fps a 0% error). No subir.
- **`.env` nunca se commitea** (está en `.gitignore`). Las credenciales viven ahí.
- **`GATEWAY_URL` es opcional** (se autoderiva del `SSH_HOST`); se pasa explícito
  para ver contra qué endpoint chequea el chaos.

Contexto y por qué del alcance: `docs/plan-pruebas-estado.md`.
