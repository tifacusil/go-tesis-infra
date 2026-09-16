# Runbook — Fase 1 y Fase 2, A y B

Comandos listos para correr las dos fases en los dos sistemas, desde esta
máquina cliente. Correr en **Git Bash** (no PowerShell), desde la raíz del repo:

```
cd /c/Users/<usuario>/.../go-tesis-infra   # ruta del clon en tu maquina
```

Datos de los sistemas:

| sistema | TARGET_HOST | SSH_ORCHESTRATOR | gateway (chaos) |
|---|---|---|---|
| A (Java/Python, systemd) | `204.168.203.32:5100` | `native` | `http://204.168.203.32/health/data-management` |
| B (Go, k3s) | `178.105.104.95:5000` | `k8s` | `http://178.105.104.95/api/v1/data/health` |

### Versiones de infraestructura (Sistema B)

Downgrade aplicado el **2026-09-15** para acercar el Sistema B a las versiones
del baseline. Los manifests son la fuente de verdad
(`k8s/base/infra/*/statefulset.yaml`):

| componente | versión | antes del 2026-09-15 |
|---|---|---|
| RabbitMQ | `3.12.1-management-alpine` | 4.3.1 |
| Redis | `7.0.15-alpine` | 8.8.0 |
| MySQL (×4) | `8.0.46` | 9.7.0 |
| Prometheus | `v3.5.4` | v3.4.1 (upgrade) |

**Esto invalidó la línea base previa del Sistema B.** MySQL 8.0 vs 9.7 y
RabbitMQ 3.12 vs 4.3 tienen perfiles de throughput distintos, así que las
corridas anteriores al 2026-09-15 **no son comparables** con las nuevas. La
escalera de Fase 1 hay que rehacerla — ver `docs/ladder-b-2026-07-22.md` para lo
que queda archivado.

Verificar contra el servidor antes de una campaña, para no medir sobre algo
distinto de lo que se documenta:

```
sudo kubectl -n landslide exec rabbitmq-0 -- rabbitmqctl version
sudo kubectl -n landslide exec redis-0 -- sh -c 'redis-cli -a "$REDIS_PASSWORD" INFO server' | grep redis_version
sudo kubectl -n landslide exec mysql-data-management-0 -- sh -c 'mysql -u root -p"$MYSQL_ROOT_PASSWORD" -N -e "SELECT VERSION()"'
```

Las versiones del **Sistema A** no están registradas en este repo. Si la tesis
afirma paridad de versiones entre ambos sistemas, hay que relevarlas en
`204.168.203.32` y anotarlas acá — sin eso, la afirmación no es verificable.

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

## FASE 1 — Descubrimiento (~3h30 por sistema)

**4 niveles × 5 corridas = 20 corridas por sistema.** Cada corrida son 10 min
(3 warmup + 7 medición) más 30 s de pausa: ≈ 3 h 29 min por sistema, ~7 h para
los dos.

Se pasó de 3 a 5 repeticiones por nivel para que la mediana y el IC 95 %
(`aggregate-results.js`) descansen en algo más que tres observaciones: con n=3
un solo outlier mueve la mediana, y el intervalo sale tan ancho que no permite
afirmar diferencias entre A y B.

Solo niveles ≤100: arriba de eso el generador (no el servidor) es el techo en
esta máquina. No agregar 150+.

### A  (`.env` bloque A activo)

```
grep -E "^SSH_HOST|^SSH_ORCHESTRATOR|^SYSTEM" load-tests/.env   # debe decir A / native

VU_LEVELS="001 010 050 100" REPEATS=5 \
  TARGET_HOST=204.168.203.32:5100 SYSTEM=A \
  ./load-tests/run-all.sh
```

### B  (editar `.env`: comentar A, descomentar B)

```
grep -E "^SSH_HOST|^SSH_ORCHESTRATOR|^SYSTEM" load-tests/.env   # debe decir B / k8s

VU_LEVELS="001 010 050 100" REPEATS=5 \
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

Solo después de tener `SUSTAINED_RATE` de Fase 1. Carga sostenida + chaos.

**El chaos no carga el `.env` de forma confiable** (su loader interno lo
descarta en silencio en ese proceso → muere con "SSH_ORCHESTRATOR es
obligatorio", y sin credenciales SSH). El fix a prueba de balas: **sourcear el
`.env` a mano** en la shell del chaos antes de lanzarlo — el proceso hereda todo
(orchestrator, system, prometheus, credenciales SSH). El endurance sí levanta su
config solo.

Usar **dos terminales Git Bash** (más robusto que `& … & wait`: si matás una,
no arrastrás la otra). Terminal 1 = carga; terminal 2 = chaos, arrancado apenas
la carga entró en régimen (tras el ramp de 3 min). El chaos inyecta a t+2h y
t+6h **desde su propio arranque**, así que un offset de pocos minutos con la
carga no importa — la carga es plana las 12h.

El bloque activo del `.env` **debe ser el del sistema que estás corriendo** —
tanto la carga como el chaos dependen de eso.

### A  (`.env` bloque A activo)

Terminal 1 — carga:
```
grep -E "^SSH_HOST|^SSH_ORCHESTRATOR|^SYSTEM" load-tests/.env   # debe decir A / native
TARGET_HOST=204.168.203.32:5100 SUSTAINED_RATE=100 SYSTEM=A \
  ./load-tests/run-endurance.sh
```

Terminal 2 — chaos (arrancar tras el ramp):
```
set -a; . load-tests/.env; set +a
GATEWAY_URL=http://204.168.203.32/health/data-management \
  ./chaos/run-during-endurance.sh
```

A native → chaos inyecta solo `kill-rabbitmq` (t+2h) y `pause-data-management`
(t+6h). `netem-delay` se salta solo.

### B  (editar `.env`: comentar A, descomentar B)

Terminal 1 — carga:
```
grep -E "^SSH_HOST|^SSH_ORCHESTRATOR|^SYSTEM" load-tests/.env   # debe decir B / k8s
TARGET_HOST=178.105.104.95:5000 SUSTAINED_RATE=100 SYSTEM=B \
  ./load-tests/run-endurance.sh
```

Terminal 2 — chaos (arrancar tras el ramp):
```
set -a; . load-tests/.env; set +a
GATEWAY_URL=http://178.105.104.95/api/v1/data/health \
  ./chaos/run-during-endurance.sh
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
  Secuencial. Con 20 corridas por sistema, Fase 1 completa (A+B) son ~7 h: no
  entra en una tarde, planificar dos bloques o dejar uno corriendo de noche.
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
