# Chaos / fault-injection — tolerancia a fallos cuantificada

Bai et al. (2020) afirma tolerancia a fallos sin medirla; El Fellah et al. (2026)
tampoco la prueba empíricamente. Esta carpeta inyecta fallos controlados sobre
la infra Docker Compose (`local/infra`, `local/services/*`) y captura:

- **MTTR** (mean time to recovery): timestamp del fallo inyectado → timestamp en
  que el circuit breaker vuelve a `closed` (`ew_circuit_breaker_state == 0`) o el
  servicio vuelve a responder su `/health`.
- **Mensajes perdidos**: delta entre `data_receiving_messages_published_total`
  (productor) y `ew_messages_consumed_total` (consumidor) antes/durante/después
  de la ventana de fallo.
- **Blast radius**: qué otros servicios degradan durante el fallo, visible en
  `ew_circuit_breaker_state{target}` por target y en el panel Grafana "estado
  de breakers" (pendiente de agregar cuando el experimento corra la primera vez
  y se sepa qué targets aparecen).

## Herramienta: Pumba

Se usa [Pumba](https://github.com/alexei-led/pumba) vía `docker run` (imagen
`gaiaadm/pumba`), sin instalación permanente — actúa directo sobre contenedores
Docker por nombre/label, montando el socket de Docker del host.

## Escenarios

| Script | Acción | Objetivo |
|---|---|---|
| `kill-rabbitmq.sh` | `pumba kill` sobre `rabbitmq-1` | Mide MTTR de reconexión de productores/consumidores AMQP y mensajes perdidos en el tramo sin broker |
| `pause-data-management.sh` | `pumba pause` sobre `data-management-1` | Mide blast radius: ¿el balanceador (nginx round-robin) desvía tráfico a `data-management-2` sin errores visibles al cliente? |
| `netem-delay-ew-da.sh` | `pumba netem delay` entre `early-warning-*` y `data-analysis-1` | Prueba el circuit breaker bajo latencia alta (no solo bajo down total) — CLAUDE.md §2.3: con el circuito abierto, Early Warning debe seguir alertando por umbral simple |

## Uso

Requiere la infra levantada (`make -C local/infra up` + los `docker-compose.yml`
de cada servicio) y Docker Desktop corriendo (para montar `/var/run/docker.sock`).

```bash
# Captura métricas 60s antes, durante el fallo, y 120s después de la recuperación
./chaos/kill-rabbitmq.sh
./chaos/pause-data-management.sh
./chaos/netem-delay-ew-da.sh 2000  # 2000ms de delay agregado
```

Cada script imprime un resumen (MTTR, mensajes publicados vs consumidos,
estado de breakers por target) y deja el JSON crudo de Prometheus en
`chaos/results/<escenario>-<timestamp epoch>.json` para análisis posterior.

## Nota sobre Sistema A (baseline)

Estos escenarios aplican igual al stack baseline (Sistema A, si corre en la
misma red `landslide-net` con nginx round-robin) — el propósito es comparar
MTTR/pérdida/blast-radius entre ambos sistemas bajo el mismo fallo inyectado,
no solo caracterizar el Sistema B en aislamiento.
