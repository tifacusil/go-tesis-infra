# Plan de pruebas — estado y alcance real

Resumen del plan de pruebas como queda después de la tanda del 2026-07-22
(corpus de flota, compare-and-set del baseline, instrumentación por proceso, y
el hallazgo de que el generador de carga es el techo por encima de ~100 fps).

Para el detalle de los cambios ver
[`diagnostico-sustained-rate-a-vs-b.md`](diagnostico-sustained-rate-a-vs-b.md)
§10 y [`ladder-b-2026-07-22.md`](ladder-b-2026-07-22.md).

---

## Fase 1 — Descubrimiento de `SUSTAINED_RATE`

**Objetivo:** encontrar la tasa de entrada sostenida de cada sistema.

**Cómo:** escalones de VU × 3 repeticiones, mediana + IC 95%
(`load-tests/aggregate-results.js`).

**Alcance efectivo: ≤100 fps.** Por encima de 100, el generador de carga
(Artillery + emulador Python, un proceso por conexión, en la máquina cliente
Windows) es el cuello de botella, no el servidor. Los niveles 150-400 se
reportan como **caracterización del instrumento**, no como capacidad del
sistema. El techo real del servidor quedó **sin medir**: el instrumento se rompe
antes de alcanzarlo.

**Corpus:** flota de 100 sensores con series de desplazamiento físicas
(`dtu-emulator/src/sender/field.py`). Baseline con compare-and-set. Ambos fixes
desplegados en A y B.

**Estado:**

| sistema | escalera | resultado |
|---|---|---|
| B | ✅ hecho (2026-07-22) | `SUSTAINED_RATE = 100`, piso validado |
| A | ⬜ pendiente | la escalera del 18-jul usó el corpus viejo; hay que rehacer |

**Falta:** correr A en niveles 1/10/50/100 × 3 (~2h15). Requisitos previos:
1. Archivar los resultados viejos de A (`results/A/*.json` del 18-jul) →
   `results/A-corpus-viejo/`, igual que se hizo con B.
2. Activar el bloque de A en `load-tests/.env` (systemd nativo, `204.168.203.32`,
   `SSH_ORCHESTRATOR=native`) o pasar las variables por línea de comando.
   Con el bloque de B activo, `reset-state.sh` limpiaría el Redis de B mientras
   la carga va contra A.
3. **host:port de data-receiving de A** — sin confirmar.

---

## Fase 2 — Validación de resiliencia

**Objetivo:** que el sistema se recupere de fallos inyectados bajo carga
sostenida.

**Cómo:** 12h a `SUSTAINED_RATE = 100` + chaos:

| momento | fallo |
|---|---|
| t+2h | `chaos/kill-rabbitmq.sh` |
| t+6h | `chaos/pause-data-management.sh` |
| durante | `chaos/netem-delay-ew-da.sh` (latencia early-warning → data-analysis) |

**Se valida (§2.4 de `plan-pruebas.md`):** consumidores reconectan, la cola
drena, no hay pérdida de alertas, memoria estable.

**Estado:** no corrida. Depende de cerrar Fase 1.

**Viable con el generador actual:** 100 fps sostenidos está dentro de lo que el
cliente aguanta limpio (corrida de control: 144.7 fps a 0% de error). El techo
del generador solo bloquea *explorar por encima* de 100, no *sostener* 100.

---

## Framing honesto para la tesis

- `SUSTAINED_RATE = 100` es un **piso verificado**, no el techo del servidor. En
  la redacción: "100 fps es la tasa sostenida verificada; el techo real quedó
  sin medir por el límite del generador de carga". Nunca "el sistema aguanta
  como máximo 100 fps".
- La comparación A vs B es válida **≤100 fps**, donde el cliente no interfiere.
- Los niveles 150-400 de B **no son resultados del sistema**: son la evidencia de
  dónde se rompe el generador. Se reportan como límite del instrumento.
- Subir el techo del generador requiere un emulador asíncrono de un solo proceso
  (N conexiones en un event loop, no un proceso por conexión) o un cliente
  Linux. Fuera de alcance por ahora.

### Por qué el generador es el techo, no el servidor

- La cola `early_warning.evaluate` se mantuvo en **0** durante las 5h de la
  escalera de B: early-warning nunca fue el limitante en ningún escalón.
- Los fallos por encima de 100 son `pool_dispatch_failed`, `WinError 8/10055`,
  `emulator_error` — todos del lado que **genera** la carga, no rechazos del
  servidor.
- Son **intermitentes**: dependen del estado transitorio de la máquina cliente
  (sockets TIME_WAIT drenando, procesos huérfanos, presión de memoria), no de la
  carga nominal. En B, vu-150 r1 pasó con 0 fallos y r2/r3 fallaron con la config
  idéntica.
- Artillery v2 ya reparte los escenarios en worker threads entre cores
  (medido: `node_max` 432% en un solo proceso), así que agregar procesos no sube
  el techo — solo multiplica el pool de Python, que es el límite real.

---

## Orden de trabajo pendiente

1. Archivar `results/A/` viejo → `results/A-corpus-viejo/` con README.
2. `load-tests/.env` al bloque de A (o variables por CLI).
3. **Fase 1 en A: niveles 1/10/50/100 × 3.**
4. `aggregate-results.js A`; comparar con B ≤100.
5. Fase 2 en cada sistema a `SUSTAINED_RATE = 100`.

**Bloqueante para (3):** host:port de data-receiving de A.
