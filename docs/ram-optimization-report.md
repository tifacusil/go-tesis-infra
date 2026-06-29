# Reporte de Optimización RAM — Servidor go-tesis

**Fecha:** 2026-06-29  
**Servidor:** 178.105.104.95 (Ubuntu 24.04, 3.8 GB RAM, k3s)  
**Basado en:** server-ram-report.md

---

## Resumen de Soluciones Aplicadas

| # | Solución | Estado | Repos afectados | Ahorro estimado |
|---|----------|--------|-----------------|-----------------|
| 1 | Implement `Analyze` RPC en data-analysis | ✅ Aplicado | `go-data-analysis` | Elimina spike nocturno 600–1400 MB |
| 2 | Eliminar pod huérfano namespace `default` | ✅ Aplicado | servidor (kubectl) | Limpieza CPU/kubelet |
| 3 | Reducir data-analysis 2→1 réplica | ⏭ Skip | — | Requeridas 2 réplicas |
| 4 | Agregar CPU limit a data-analysis | ✅ Aplicado | `tesis-infra` | Estabilidad |
| 5 | Afinar parámetros MySQL (4 instancias) | ✅ Aplicado | `tesis-infra` | ~280 MB |
| 6 | Consolidar 4 MySQL → 1 instancia | ⏭ Skip | — | Database-per-service requerido |
| 7 | `vm.overcommit_memory=2` | ⏭ Pendiente | servidor | Seguridad OOM |

---

## Sol 1 — Implement `Analyze` RPC en data-analysis

**Problema:** Early-warning llama `dataanalysis.v1.AnalysisService.Analyze` cada noche a las 00:00 UTC. El servicio Python no tenía este RPC implementado → respondía `UNIMPLEMENTED` → circuit breaker abría a las 00:05 UTC tras 5 fallos → 2 réplicas de data-analysis escalaban a 400–700 MB cada una durante los reintentos en burst.

**Evidencia:**
```
2026-06-25T00:05:05 WARN data_analysis_circuit_open project=lingzhan
2026-06-26T00:05:05 WARN data_analysis_circuit_open project=lingzhan
...
```

**Causa raíz adicional:** Tablas de sensores tenían 0 filas. Sin validación de dataset vacío, cualquier cálculo estadístico lanzaría excepción → timeout gRPC.

**Cambios en `go-data-analysis`:**

| Archivo | Cambio |
|---------|--------|
| `proto/dataanalysis_v1.proto` | Nuevo contrato — `Analyze` RPC (alineado a `go-early-warning`) |
| `scripts/gen_proto.sh` | Genera stubs para `dataanalysis_v1.proto` |
| `app/config.py` | Config MySQL read-only (dual-key `ANALYSIS__MYSQL__*` / `MYSQL_*`) |
| `app/analyze_servicer.py` | Implementación: consulta 5 tablas de sensores en ventana; retorna `trend="no_data"` si vacías (no error) |
| `main.py` | Registra `AnalyzeServicer` en servidor gRPC |
| `requirements.txt` | Agrega `PyMySQL==1.1.1` |
| `.env.example` | Documenta vars MySQL |

**Lógica de `AnalyzeServicer.Analyze`:**
1. Conecta a MySQL data-management con usuario read-only `svc_data_analysis_ro`
2. Consulta tablas en orden de prioridad: `gnss_readings` → `deep_displacement_readings` → `rainfall_readings` → `strain_readings` → `soil_pressure_readings`
3. Primera tabla no vacía en la ventana temporal → regresión polinomial grado 1 → clasifica tendencia por signo de pendiente (`stable` / `accelerating` / `decelerating`)
4. Todas vacías → retorna `trend="no_data"` sin lanzar excepción → circuit breaker nunca se abre

**Commits:**
- `1dad588` — feat(grpc): implement Analyze RPC for early-warning enrichment
- `2ae086a` — fix(proto): rm invalid python_out option
- `611675d` — fix(scripts): correct protoc output filename (single underscore)
- `c8d80f5` — fix(lint): remove unused timezone import
- `cb69f5b` — fix(imports): correct protoc-generated module names (single underscore)

---

## Sol 2 — Eliminar pod huérfano namespace `default`

**Problema:** `default/mysql-data-management-0` estaba en `CreateContainerConfigError` porque el Secret `mysql-data-management` no existía en namespace `default` (solo en `landslide`). El pod consumía ciclos del kubelet en reintentos continuos. Durante la sesión se descubrió que namespace `default` tenía una copia completa del stack (4 MySQL StatefulSets + data-analysis Deployment) con 1536 Mi en memory requests, bloqueando el scheduler para pods en `landslide`.

**Comandos ejecutados en servidor:**
```bash
# Eliminación inicial (StatefulSet + PVC del pod original huérfano)
sudo kubectl delete statefulset mysql-data-management -n default
sudo kubectl delete pvc data-mysql-data-management-0 -n default

# Eliminación del stack completo huérfano descubierto posteriormente
sudo kubectl delete deployment data-analysis -n default
sudo kubectl delete statefulset mysql-data-management mysql-early-warning \
    mysql-project-management mysql-user-management -n default
sudo kubectl delete service data-analysis mysql-data-management \
    mysql-early-warning mysql-project-management mysql-user-management -n default
```

**Resultado:** Namespace `default` limpio. 1536 Mi de memory requests liberados → pods en `landslide` pudieron schedulear.

---

## Sol 4 — CPU limit en data-analysis

**Problema:** El Deployment de data-analysis tenía `limits.memory: 768Mi` pero sin `limits.cpu`. Durante análisis nocturno podía consumir 100% de CPU sin restricción, compitiendo con k3s, MySQL y demás pods, prolongando el estado de alto consumo de RAM.

**Cambio en `tesis-infra/k8s/base/services/data-analysis/deployment.yaml`:**
```yaml
resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: "500m"     # agregado
    memory: 768Mi
```

**Commit:** `3256dbf` — fix(data-analysis): add CPU limit 500m to prevent monopolization

---

## Sol 5 — Afinar parámetros MySQL (4 instancias)

**Problema:** Cada instancia MySQL consumía ~185 MB RSS a pesar de `--innodb-buffer-pool-size=64M`. Buffers secundarios (sort, read, join, tmp, thread-stack) no estaban acotados.

**Cambios en los 4 StatefulSets** (`mysql-data-management`, `mysql-early-warning`, `mysql-project-management`, `mysql-user-management`):

```yaml
args:
  - "--innodb-buffer-pool-size=32M"    # 64M → 32M
  - "--innodb-buffer-pool-instances=1"
  - "--performance-schema=OFF"
  - "--max-connections=25"             # 50 → 25
  - "--table-open-cache=64"
  - "--thread-cache-size=4"
  - "--key-buffer-size=8M"             # nuevo
  - "--sort-buffer-size=256K"          # nuevo
  - "--read-buffer-size=256K"          # nuevo
  - "--join-buffer-size=256K"          # nuevo
  - "--tmp-table-size=16M"             # nuevo
  - "--max-heap-table-size=16M"        # nuevo
  - "--thread-stack=196608"            # nuevo
```

```yaml
resources:
  requests:
    cpu: 100m
    memory: 96Mi     # 256Mi → 96Mi (ajustado para caber en nodo saturado)
  limits:
    memory: 320Mi    # 384Mi → 320Mi
```

**Ahorro estimado:** ~65–70 MB × 4 instancias = ~280 MB

**Commits:**
- `5f16a90` — perf(mysql): reduce buffer pool and secondary buffers across all instances
- `a64fa99` — fix(mysql): lower memory requests 192Mi → 96Mi to fit 3.4Gi allocated node

---

## Soluciones No Aplicadas

### Sol 3 — Reducir réplicas data-analysis 2→1
**Motivo:** Se requieren 2 réplicas por diseño del sistema.

### Sol 6 — Consolidar 4 MySQL → 1 instancia
**Motivo:** Viola el principio database-per-service (CLAUDE.md §1.2). Cada microservicio debe acceder únicamente a su propio esquema/base de datos.

### Sol 7 — `vm.overcommit_memory=2`
**Motivo:** Riesgo medio — Go GC y k3s prereservan virtual memory. Requiere validación en horario de bajo tráfico. Pendiente para futura ventana de mantenimiento.

**Comando para aplicar cuando se decida:**
```bash
# Probar en caliente (reversible)
sudo sysctl vm.overcommit_memory=2
sudo sysctl vm.overcommit_ratio=75
sudo kubectl get pods -n landslide  # verificar que todo sigue Running

# Persistir solo si todo ok
echo -e "vm.overcommit_memory = 2\nvm.overcommit_ratio = 75" | \
    sudo tee /etc/sysctl.d/99-overcommit.conf
```

---

## Estado Final del Cluster

Tras aplicar todas las soluciones, namespace `landslide` queda:

| Pod | Status esperado |
|-----|-----------------|
| data-analysis ×2 | Running (imagen nueva con Analyze RPC) |
| mysql-data-management | Running |
| mysql-early-warning | Running |
| mysql-project-management | Running |
| mysql-user-management | Running |
| data-management ×2 | Running |
| data-receiving ×3 | Running |
| early-warning ×2 | Running |
| project-management | Running |
| user-management | Running |
| rabbitmq | Running |
| redis | Running |

Namespace `default`: limpio (solo `service/kubernetes`).
