# Ajuste de memoria de MySQL en Kubernetes (sustento para el paper)

> Documento de respaldo para la sección de despliegue/operación de la
> investigación. Justifica la configuración de bajo consumo de memoria aplicada a
> los contenedores MySQL del sistema de monitoreo de deslizamientos desplegado en
> Kubernetes (k3s) sobre un único servidor VPS.
> Cambio asociado: commit `73aba68` (`perf(k8s): MySQL en bajo consumo de RAM`).

---

## 1. Contexto

El sistema sigue el patrón **database-per-service** (Bai et al., 2020): cada
microservicio con estado posee su propia base de datos, materializada como **cuatro
instancias MySQL independientes** (`data-management`, `user-management`,
`project-management`, `early-warning`), cada una como un `StatefulSet` con su
volumen persistente.

El despliegue objetivo es un **VPS único con 3.7 GiB de RAM** que aloja, en el mismo
nodo Kubernetes: las 4 instancias MySQL, RabbitMQ, Redis, las réplicas de los 6
microservicios (18 contenedores de aplicación según la topología del paper), el
plano de control de k3s y el runtime de contenedores (containerd).

## 2. Problema observado

Con la configuración por defecto de MySQL, el nodo operaba al **~92 % de uso de RAM
(3.4 GiB / 3.7 GiB), con 0 B de swap y ~383 MiB disponibles**. Las cuatro
instancias MySQL eran el mayor consumidor agregado de memoria.

La causa principal es el **InnoDB Buffer Pool**: la caché en memoria que MySQL
reserva para páginas de datos e índices. Por defecto, MySQL dimensiona el buffer
pool en **128 MiB por instancia** (más estructuras auxiliares). Con cuatro
instancias, esto reserva de forma estática una fracción significativa de la RAM del
nodo **independientemente de la carga real**, que en un sistema de monitoreo de
sensores con escritura moderada y volumen de datos acotado no requiere semejante
caché.

El riesgo concreto de operar sin margen y sin swap es la activación del
**OOM-Killer** del kernel, que terminaría contenedores (incluidas instancias MySQL
o microservicios) ante cualquier pico de memoria, degradando la disponibilidad.

## 3. Cambio aplicado

A cada uno de los cuatro `StatefulSet` de MySQL se añadieron los siguientes
argumentos de arranque del servidor (`mysqld`):

```yaml
args:
  - "--innodb-buffer-pool-size=64M"      # caché InnoDB: 128 MiB (default) -> 64 MiB
  - "--innodb-buffer-pool-instances=1"   # una sola partición del buffer pool
  - "--performance-schema=OFF"           # desactiva la instrumentación de perf
  - "--max-connections=50"               # techo de conexiones acorde a la carga
```

Adicionalmente, el límite de memoria del contenedor se redujo de **512 MiB a
384 MiB** por instancia (`resources.limits.memory`).

### Justificación por argumento

| Argumento | Efecto | Razón |
|---|---|---|
| `--innodb-buffer-pool-size=64M` | Reduce a la mitad la caché de páginas InnoDB reservada por instancia (128→64 MiB). | Es el principal driver de RAM en MySQL. El volumen de datos del sistema (lecturas/escrituras de sensores acotadas) no justifica 128 MiB de caché por base; 64 MiB mantiene un *working set* suficiente para las consultas operativas. |
| `--innodb-buffer-pool-instances=1` | Usa una única partición del buffer pool en vez de varias. | Las múltiples particiones reducen contención de bloqueos bajo alta concurrencia; con un buffer pool pequeño (64 MiB) y baja concurrencia son innecesarias y añaden overhead de memoria. |
| `--performance-schema=OFF` | Desactiva el `performance_schema` de MySQL. | Esta instrumentación consume del orden de ~100 MiB por instancia y solo es útil para *profiling* fino. No se requiere en operación normal; puede reactivarse puntualmente si se mide rendimiento. |
| `--max-connections=50` | Limita las conexiones concurrentes a 50. | Cada conexión reserva buffers por sesión. El default (151) sobredimensiona para un microservicio con *connection pooling* acotado; 50 cubre holgadamente la demanda real y acota el consumo por sesión. |

## 4. Resultado

Tras aplicar la configuración, se libera del orden de **~150–200 MiB por instancia
MySQL** (principalmente por la reducción del buffer pool y el apagado de
`performance_schema`), reduciendo la presión de RAM del nodo y restableciendo un
margen operativo seguro frente al OOM-Killer, **sin alterar la topología de
réplicas del paper** ni el patrón database-per-service.

## 5. Trade-off y reproducibilidad para mediciones

Esta configuración optimiza para **operación en recursos limitados**, no para
rendimiento máximo. Un buffer pool menor implica más fallos de caché (más lecturas
a disco) bajo cargas con *working set* grande, y `performance_schema=OFF` impide la
instrumentación detallada.

**Implicación metodológica:** si la investigación realiza mediciones de rendimiento
de las bases de datos (throughput, latencia de consultas), estos valores deben
revertirse o elevarse para no sesgar los resultados a la baja, y debe reportarse
explícitamente la configuración del buffer pool usada durante la medición. Para la
**validación funcional** del despliegue (objeto de esta fase) la configuración de
bajo consumo es adecuada y no afecta la correctitud del sistema.

## 6. Referencias técnicas

- MySQL Reference Manual — *InnoDB Buffer Pool* y dimensionamiento de
  `innodb_buffer_pool_size` / `innodb_buffer_pool_instances`.
- MySQL Reference Manual — *The Performance Schema* (coste de memoria de la
  instrumentación).
- Bai et al. (2020) — arquitectura base del sistema y patrón database-per-service.
  DOI: 10.1080/19475705.2020.1766580
