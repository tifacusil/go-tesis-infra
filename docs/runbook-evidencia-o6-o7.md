# Runbook — Evidencia de O6 y O7 (AP5, AP6, AP7)

Pruebas cortas para cerrar dos observaciones del revisor:

- **O6** — el circuit breaker de la ruta de alertas abre cuando user-management
  falla, el sistema **sigue emitiendo alertas** y se recupera.
- **O7** — tres prácticas verificadas con evidencia:
  - **AP5**: bytes y llamadas por evento, en A y en B.
  - **AP6**: reinyectar un mensaje ya procesado no duplica nada.
  - **AP7**: un mensaje que falla siempre se reintenta 3 veces y va a la DLQ.

Cada script hace todo solo (inyecta, mide, evalúa y limpia) y deja la
evidencia en `chaos/results/`. Solo hay que lanzarlos y mirar el veredicto.

---

## Duración total: ~1 h

| Paso | Qué | Duración aprox. |
|---|---|---|
| 0 | Preparar y verificar | ~5 min |
| 1 | AP5 en Sistema B (×3) | ~7 min |
| 2 | AP6 (×3) | ~6 min |
| 3 | AP7 (×3) | ~6 min |
| 4 | O6 (×3) | ~25–27 min |
| 5 | AP5 en Sistema A (×3) | ~8 min |
| 6 | Revisar y subir resultados | ~5 min |

Si algo falla y hay que repetir, sumar el tiempo de esa prueba.

---

## Reglas antes de empezar

- **Sin carga:** no puede haber ningún generador de carga (Artillery / Fase 1 /
  Fase 2) corriendo contra el sistema. Las pruebas necesitan el sistema en
  reposo; AP5 y AP7 lo verifican y abortan si no.
- **Git Bash:** todo se corre en **Git Bash**, no en PowerShell, desde la raíz
  del repo.
- **No cortar O6 ni AP7:** no interrumpir O6 ni AP7 a la mitad con Ctrl+C
  salvo emergencia: dejan un fallo inyectado que el script quita al terminar.
  Si pasa, ver [Si algo se cortó](#si-algo-se-cortó).
- **Orden:** respetar el orden de los pasos. AP5 va primero porque necesita el
  sistema totalmente quieto; O6 va al final porque genera bastante tráfico.

---

## Paso 0 — Preparar (~5 min)

**0.1 Actualizar el repo**

```bash
cd /c/Users/adria/Escritorio/TESIS/go-tesis-infra
git checkout main && git pull
```

**0.2 Activar el bloque del Sistema B en `load-tests/.env`**

Comentar el bloque A y descomentar el B. Verificar:

```bash
grep -E "^SSH_HOST|^SSH_ORCHESTRATOR|^SYSTEM" load-tests/.env
```

Debe decir `SSH_HOST=178.105.104.95` y `SSH_ORCHESTRATOR=k8s`. Luego cargarlo
en la terminal (**repetir esto si se abre otra terminal**):

```bash
set -a; . load-tests/.env; set +a
```

**0.3 Verificar que B tiene la versión nueva de early-warning**

O6 necesita una métrica nueva de early-warning. Se comprueba publicando un
evento y preguntándole a Prometheus:

```bash
./chaos/publish-event.sh
sleep 20
curl -s "http://178.105.104.95:31083/api/v1/query?query=count(ew_alert_dispatch_duration_seconds_count)"
```

- Si la respuesta tiene `"value":[…,"1"]` (o cualquier número > 0), está bien.
- Si dice `"result":[]`, falta desplegar. Avisar antes de seguir; se arregla
  con:

  ```bash
  # en el servidor B
  sudo kubectl -n landslide rollout restart deployment/early-warning deployment/data-management
  sudo kubectl -n landslide rollout status deployment/early-warning
  ```

  y repetir 0.3.

---

## Paso 1 — AP5 en Sistema B (~7 min)

```bash
for i in 1 2 3; do ./chaos/ap5-capture.sh; sleep 30; done
```

**Qué se ve si salió bien:** cada corrida termina con una tabla
"Tráfico por servidor" y la línea `NETO atribuible al evento: … B`.

**Si falla con "el sistema no está en reposo":** hay carga corriendo o colas
con mensajes. Esperar 1–2 min y relanzar.

---

## Paso 2 — AP6 (~6 min)

```bash
for i in 1 2 3; do ./chaos/ap6-idempotency.sh; sleep 10; done
```

**Qué se ve si salió bien:** `Veredicto AP6: CUMPLE` en las tres corridas, con
todos los criterios en `PASS`.

**Si sale `NO CUMPLE`:** anotar qué criterio dice `FAIL` y avisar; no hace
falta repetir antes de consultar.

---

## Paso 3 — AP7 (~6 min)

```bash
for i in 1 2 3; do ./chaos/ap7-dead-letter.sh; sleep 10; done
```

**Qué se ve si salió bien:** `Veredicto AP7: CUMPLE` en las tres, y al final
`Trigger … eliminado` y `Cola sonda … eliminada`.

**Si sale `NO CUMPLE`:** anotar el criterio en `FAIL` y avisar.

---

## Paso 4 — O6 (~25–27 min)

```bash
for i in 1 2 3; do ./chaos/netem-delay-ew-um.sh 9000 240; sleep 120; done
```

Cada corrida dura ~6–7 min más 2 min de pausa. Durante la ventana de fallo se
imprime una línea cada 5 s con el estado del breaker; es normal.

**Qué se ve si salió bien:**

- Al comienzo, `Driver: … enrutados=N errores=0` con N creciendo, y
  `Alertas emitidas en 45s de verificacion:` con un número ≥ 5.
- `-> circuito ABIERTO a los …s`
- `Continuidad operativa:        verificada`
- `Verificado: no quedó netem en ningún netns de user-management.`

**Si aborta al comienzo con "ew_alert_dispatch_duration_seconds no tiene
series":** falta el despliegue del paso 0.3.

**Si aborta con "el sistema emitio N alertas en la ventana de verificacion":**
mirar la línea `Driver:` justo arriba. Si `enrutados` es 0 o hay `errores`, el
driver no está publicando: mandar el archivo
`chaos/results/netem-delay-ew-um-driver-<epoch>.log`. Si el driver publica bien
pero hay pocas alertas, avisar (EW no está procesando).

**Si dice "el breaker nunca abrio":** el script imprime un `DIAGNOSTICO`.
Copiarlo y avisar.

---

## Paso 5 — AP5 en Sistema A (~8 min)

**5.1 Cambiar a Sistema A en `load-tests/.env`**

Comentar el bloque B y descomentar el A. Además, el bloque A necesita dos
variables nuevas con las credenciales de la Management API del RabbitMQ de A:

```
RABBITMQ_MGMT_USER=...
RABBITMQ_MGMT_PASS=...
```

Verificar y cargar:

```bash
grep -E "^SSH_HOST|^SSH_ORCHESTRATOR|^SYSTEM" load-tests/.env   # 204.168.203.32 / native
set -a; . load-tests/.env; set +a
```

**5.2 Correr**

```bash
for i in 1 2 3; do ./chaos/ap5-capture.sh; sleep 30; done
```

Mismo resultado esperado que en el paso 1.

**Si falla con "requiere RABBITMQ_MGMT_USER y RABBITMQ_MGMT_PASS":** faltan
las dos variables de 5.1.

---

## Paso 6 — Revisar y subir resultados (~5 min)

**6.1 Resumen rápido** (copiar la salida y mandarla)

```bash
echo "== O6"; grep -hE '^(fail_start_utc|breaker_opened_after_s|recovery_s|dispatch_mean_before_open_s|dispatch_mean_while_open_s|continuity)=' chaos/results/netem-delay-ew-um-summary-*.env
echo "== AP6 / AP7"; grep -H '^verdict=' chaos/results/ap6-*-summary.env chaos/results/ap7-*-summary.env
echo "== AP5"; grep -HE '^(system|net_bytes|net_packets|hops)=' chaos/results/ap5-*-summary.env
```

Se esperan: 3 bloques de O6 con `continuity=verificada`, 6 líneas
`verdict=CUMPLE` (3 de AP6 y 3 de AP7) y 6 corridas de AP5 (3 con
`system=B`, 3 con `system=A`).

**6.2 Subir la evidencia**

```bash
git add chaos/results/
git commit -m "chore(evidencia): corridas de O6, AP5, AP6 y AP7"
git push
```

**6.3 Dejar el `.env` como estaba**

Si la siguiente tarea es con el Sistema B, volver a activar el bloque B en
`load-tests/.env`.

---

## Si algo se cortó

Si se cerró la terminal o se cayó la conexión **en medio de O6 o AP7**,
verificar en el servidor B que no quedó el fallo inyectado.

**AP7 — trigger en MySQL.** La lista debe salir vacía:

```bash
sudo kubectl -n landslide exec mysql-early-warning-0 -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW TRIGGERS FROM early_warning"'
```

Si aparece un `ap7_block_…`, borrarlo:

```bash
sudo kubectl -n landslide exec mysql-early-warning-0 -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "DROP TRIGGER early_warning.ap7_block_NNNN"'
```

**O6 — latencia de red en user-management.** Quitarla en todos los pods:

```bash
sudo sh -c 'for id in $(crictl ps --name user-management -q); do
  pid=$(crictl inspect -o go-template --template "{{.info.pid}}" $id)
  nsenter -t $pid -n tc qdisc del dev eth0 root 2>/dev/null
done; echo listo'
```

Después de limpiar, relanzar solo la corrida que se cortó.

---

## Problemas frecuentes

| Mensaje | Causa | Qué hacer |
|---|---|---|
| `Falta SSH_HOST` | No se cargó el `.env` en esta terminal | `set -a; . load-tests/.env; set +a` |
| `el sistema no está en reposo` | Hay carga o mensajes en cola | Esperar 1–2 min y relanzar |
| `no se pudo consultar Prometheus` | Prometheus de B no responde | Verificar que el pod de Prometheus esté arriba |
| `el broker no enrutó la lectura` | RabbitMQ sin el binding `sensors.#` | Avisar: es un problema de la infra, no de la prueba |
| `hace falta python/py local` (AP7) | No hay Python en la máquina | Instalar Python 3 (no el de Microsoft Store) |
