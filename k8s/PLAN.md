# Plan de despliegue en Kubernetes (k3s, VPS único)

> Plan de migración del sistema de monitoreo de deslizamientos desde el
> `docker-compose` local a un cluster Kubernetes corriendo en un solo servidor
> VPS. Distribución elegida: **k3s**. Empaquetado: **Kustomize**. Discovery:
> **nativo de K8s** (se elimina Consul). Stateful deps **dentro del cluster**
> como StatefulSets.

---

## 0. Decisiones de diseño

| Aspecto | Decisión | Motivo |
|---|---|---|
| Distribución | **k3s** | Ligero, single-binary, ideal para 1 VPS. Trae Traefik ingress + local-path storage. Bajo overhead RAM/CPU. |
| Stateful deps (4× MySQL, Redis, RabbitMQ) | **En el cluster (StatefulSets + PVC local-path)** | Self-contained, reproduce el compose actual, preserva database-per-service. |
| Service discovery | **K8s nativo (se elimina Consul)** | Services + DNS de K8s reemplazan Consul. nginx + consul-template → Ingress. Menos piezas, idiomático. |
| Empaquetado | **YAML plano + Kustomize** | Nativo `kubectl`, sin deps extra, legible y versionable (base + overlay prod). |

---

## 1. Hallazgo que simplifica la migración (config-only, sin tocar código)

Las apps **NO resuelven gRPC vía Consul**. Usan env vars con hostname directo:

- `USER_MANAGEMENT_GRPC = user-management-1:9090`
- `DATA_ANALYSIS_GRPC = data-analysis-1:50051`
- gRPC `grpc.NewClient(host)` directo, sin discovery dinámico.

Consul solo se usa para que cada instancia **se registre** y nginx/consul-template
arme los upstreams. En Kubernetes eso lo hace un **Service** (ClusterIP + DNS
estable + balanceo nativo). Por tanto:

- **No se toca código** Go/Python de los microservicios.
- Solo cambian env vars en los manifests:
  - `CONSUL_ENABLED=false` (flag ya existente en early-warning / user / project).
  - Endpoints gRPC apuntan a nombres de Service K8s (`user-management:9090`,
    `data-analysis:50051`).
  - El registro Consul de data-receiving / data-analysis queda sin efecto; el
    Service cubre el descubrimiento.

Los hostnames de los Services K8s coinciden casi 1:1 con los del compose actual
(`mysql-data-management`, `rabbitmq`, `redis`, ...), así que la traducción es casi
directa.

---

## 2. Arquitectura destino

```
Internet → Traefik Ingress (incluido en k3s)
              ↓  host landslide.tudominio  o  IP:80
         ┌────────────────────────────────────────┐
         │  Services (ClusterIP, DNS estable)      │
         │  /api/v1/receiving → data-receiving     │
         │  /api/v1/data      → data-management    │
         │  /api/v1/analysis  → data-analysis      │
         │  /api/v1/warnings  → early-warning      │
         │  /api/v1/users     → user-management    │
         │  /api/v1/projects  → project-management │
         └────────────────────────────────────────┘
              ↓ gRPC/AMQP por DNS interno (svc.landslide.svc.cluster.local)
  StatefulSets: 4× MySQL · Redis · RabbitMQ   (PVC local-path)
```

**Qué desaparece respecto al compose:** Consul, nginx, consul-template
(reemplazados por Ingress + Service DNS).

**Qué se mantiene:** database-per-service (4 MySQL), Redis, RabbitMQ, las réplicas
de cada microservicio, los contratos (gRPC/AMQP/OpenAPI), la ingesta TCP de sensores.

---

## 2.1 Load balancing (función obligatoria) — cubierto por K8s nativo

En el sistema actual **nginx hace dos trabajos distintos**:

1. **API Gateway**: entrada externa + ruteo por path (`/api/v1/...`).
2. **Load balancer**: reparte requests entre las réplicas (data-receiving-1/2/3,
   data-management-1/2, etc.), usando los upstreams que `consul-template` regenera
   desde el catálogo de salud de Consul.

En Kubernetes esos dos trabajos se separan en dos piezas **nativas**, y el load
balancing **viene de cajón** (no se instala nada extra):

| Trabajo de nginx hoy | Pieza nativa en K8s | ¿Built-in? |
|---|---|---|
| Ruteo por path (gateway) | **Ingress** (Traefik, incluido en k3s) | Sí |
| **Load balancing entre réplicas** | **Service** (ClusterIP) | **Sí — nativo y obligatorio** |

### Cómo lo hace el Service

Un `Service` de K8s **es** un balanceador de carga. Al declararlo:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: data-receiving
spec:
  selector:
    app: data-receiving      # agarra TODOS los pods con este label (las 3 réplicas)
  ports:
    - port: 8080
```

K8s automáticamente:

- Descubre los pods de `data-receiving` por el `selector`.
- Les expone **una sola IP virtual + nombre DNS** (`data-receiving`).
- **Reparte las conexiones** entre los pods sanos (vía kube-proxy / iptables/IPVS).
- **Saca del balanceo** cualquier pod que muera o no pase su `readinessProbe`,
  y lo reincorpora al recuperarse — automático.

Esto es **equivalente** a lo que hoy hacen nginx + consul-template + Consul, pero
sin esas tres piezas: el `selector` + el `readinessProbe` reemplazan al
`range service` de la plantilla de nginx.

### Equivalencia directa

```
HOY (compose):
  request → nginx → upstream {data-receiving-1, -2, -3}   (round-robin)
            ↑ consul-template regenera el upstream cuando un pod cae

K8S:
  request → Ingress → Service data-receiving → {pod-1, pod-2, pod-3}
                       ↑ K8s saca pods no-ready del balanceo, automático
```

### Nivel de balanceo (matiz importante)

- **Service = balanceo L4** (por conexión, no por request HTTP individual). Con
  HTTP keep-alive, varios requests pueden reusar la misma conexión y caer en el
  mismo pod.
- **Ingress (Traefik) = balanceo L7** (por request HTTP) en la entrada externa.
- Para **gRPC** (multiplexa muchas llamadas sobre una sola conexión HTTP/2), el
  balanceo L4 del Service mandaría todo a un pod. Si se requiere balanceo por
  llamada gRPC entre réplicas, se usa Traefik (L7/gRPC) o un service mesh
  (linkerd/istio). Para el alcance de la tesis, el balanceo del Service (L4) para
  tráfico interno + Ingress (L7) en la entrada cubre la función de nginx.

**Conclusión:** el load balancing no se pierde al quitar nginx; lo provee el
`Service` nativo de K8s (obligatorio y automático), reforzado por el Ingress en la
capa de entrada.

---

## 3. Estructura de archivos (`k8s/`)

```
k8s/
├── PLAN.md                            # este documento
├── base/
│   ├── namespace.yaml                 # ns: landslide
│   ├── infra/
│   │   ├── mysql-data-management/     # StatefulSet + Service + PVC + SealedSecret
│   │   ├── mysql-user-management/
│   │   ├── mysql-project-management/
│   │   ├── mysql-early-warning/
│   │   ├── redis/                     # StatefulSet + Service + SealedSecret
│   │   └── rabbitmq/                  # StatefulSet + Service + ConfigMap(definitions) + SealedSecret
│   ├── services/
│   │   ├── data-receiving/            # Deployment(3) + Service(HTTP 8080 + TCP 5000)
│   │   ├── data-management/           # Deployment(2) + Service(HTTP)
│   │   ├── data-analysis/             # Deployment(2) + Service(HTTP + gRPC 50051)
│   │   ├── early-warning/             # Deployment(2) + Service(HTTP)
│   │   ├── user-management/           # Deployment(1) + Service(HTTP + gRPC 9090)
│   │   └── project-management/        # Deployment(1) + Service(HTTP + gRPC 9090)
│   ├── ingress.yaml                   # Traefik, rutas /api/v1/*
│   └── kustomization.yaml
├── overlays/
│   └── prod/
│       ├── kustomization.yaml         # replicas, image tags, resources, namespace
│       └── sealed-secrets/            # SealedSecret cifrados (SÍ versionados, seguros)
│           ├── mysql-data-management.yaml
│           ├── mysql-user-management.yaml
│           ├── mysql-project-management.yaml
│           ├── mysql-early-warning.yaml
│           ├── redis.yaml
│           ├── rabbitmq.yaml
│           └── jwt.yaml
└── bootstrap/
    ├── README.md                      # instalar controller + kubeseal + sellar secrets
    └── seal-secrets.sh                # helper: lee valores locales → genera SealedSecrets
```

> Los `SealedSecret` (cifrados) viven en git de forma segura. Los **valores en
> claro** se mantienen fuera del repo (un `.env` local o gestor de contraseñas) y
> solo se usan al momento de sellar con `kubeseal`. El `imagePullSecret` de GHCR
> se crea aparte en el VPS (6.1), no se sella.

---

## 4. Detalles de diseño por componente

1. **Microservicios → Deployment** (no StatefulSet): son stateless. Réplicas
   iguales al compose: data-receiving 3, data-management/analysis/early-warning 2,
   user/project 1.
2. **Service DNS reemplaza el alias compartido de Docker:** un Service
   `data-receiving` balancea (round-robin nativo) sobre sus 3 pods, igual que el
   alias `data-receiving` del compose.
3. **Ingesta TCP de sensores (data-receiving:5000):** Service tipo `LoadBalancer`
   (en k3s lo resuelve Klipper/ServiceLB → puerto en la IP del VPS) o `NodePort`.
   No pasa por el Ingress HTTP.
4. **MySQL database-per-service:** 4 StatefulSets independientes, cada uno con su
   PVC (`local-path`, storage class default de k3s). Preserva el aislamiento actual.
5. **Secrets:** passwords (MySQL root ×4, Redis, RabbitMQ, JWT) gestionados con
   **sealed-secrets** (decisión del proyecto). Cada Secret se cifra con la clave
   pública del controller → se versiona en git como `SealedSecret` (YAML cifrado);
   el controller del cluster lo descifra y crea el `Secret` real al aplicar. Ver 6.2.
6. **Probes:** `livenessProbe` + `readinessProbe` HTTP a `/health` (reemplazan el
   check de Consul). data-receiving es distroless (sin shell) → `httpGet` directo
   al puerto 8080.
7. **Config:** `ConfigMap` por servicio (vars no secretas) + `Secret` (passwords).
   Se reutilizan los nombres de env actuales; solo cambian los hosts a Service names.
8. **Migraciones DB:** las apps Go corren goose al arranque (ya lo hacen). No se
   necesita Job aparte; opcionalmente un `initContainer` que espere a MySQL listo.
9. **imagePullSecret:** los pods hacen `pull` de `ghcr.io/tifacusil/*` (registry
   privado). Se incluye un Secret tipo `docker-registry` para GHCR.

---

## 5. Cambios fuera de Kubernetes (mínimos)

- **Ningún repo de aplicación cambia su código.**
- Env vars en los manifests apuntan a Service names; coinciden casi 1:1 con los
  hostnames del compose actual.
- `CONSUL_ENABLED=false` en early-warning / user-management / project-management;
  el registro Consul de data-receiving / data-analysis queda sin efecto (el
  Service cubre el discovery).

---

## 6. Decisiones confirmadas

| Aspecto | Decisión |
|---|---|
| **Ingress host** | **IP del VPS + ruteo por path** (sin dominio). El Ingress se declara sin `host:`; las rutas `/api/v1/*` aplican a cualquier Host → `http://<IP-VPS>/api/v1/...`. |
| **TLS** | **HTTP plano** (contexto tesis). Sin cert-manager. Se deja un `TODO` para Let's Encrypt si más adelante hay dominio. |
| **Registry pull** | **`imagePullSecret` para GHCR privado.** Los manifests solo referencian el secret (`imagePullSecrets: [name: ghcr]`); el valor se crea en el VPS, nunca va al repo. |
| **Estrategia de secrets** | **sealed-secrets desde el inicio** (decisión del proyecto). `SealedSecret` cifrados versionados en git; el controller los descifra en el cluster. Ver 6.2. |

### 6.1 imagePullSecret (GHCR) — ninguna credencial va al repo

El secret se crea **en el VPS**, leyendo un PAT de GitHub con scope `read:packages`
(el mismo tipo usado para `docker login ghcr.io`). Los manifests solo lo
referencian por nombre.

```bash
# Se ejecuta en el VPS (no en git). Usa tu PAT read:packages:
kubectl -n landslide create secret docker-registry ghcr \
  --docker-server=ghcr.io \
  --docker-username=<TU_USUARIO> \
  --docker-password=<PAT_read:packages>
```

El secret vive solo en el cluster (etcd del VPS). El plan **no** contiene
credenciales y nadie necesita compartir un PAT por fuera del VPS.

### 6.2 Secrets de aplicación — sealed-secrets

Estrategia elegida: **sealed-secrets** (Bitnami). Maneja los passwords (MySQL root
×4, Redis, RabbitMQ, JWT) cifrándolos para poder versionarlos en git de forma
segura. Solo el controller del cluster puede descifrarlos.

**Cómo funciona:**

1. Se instala una vez el **controller** `sealed-secrets` en el cluster. Genera un
   par de claves (pública/privada); la privada nunca sale del cluster.
2. Con la CLI `kubeseal` y la clave **pública**, cada `Secret` se cifra → produce
   un `SealedSecret` (YAML cifrado).
3. El `SealedSecret` **se commitea a git** — es seguro: sin la clave privada del
   controller no se puede descifrar.
4. Al hacer `kubectl apply -k`, el controller descifra el `SealedSecret` y crea el
   `Secret` real en el namespace automáticamente. Los pods lo consumen como
   cualquier Secret.

**Flujo de uso (resumen; detalle en `bootstrap/README.md`):**

```bash
# 1. Instalar el controller (una vez por cluster)
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/latest/download/controller.yaml

# 2. Instalar la CLI kubeseal en tu máquina (o en el VPS)
#    (descarga del release de bitnami-labs/sealed-secrets)

# 3. Sellar un secreto: Secret en claro (local, NO va a git) → SealedSecret (cifrado, SÍ va a git)
kubectl -n landslide create secret generic mysql-data-management \
  --from-literal=MYSQL_ROOT_PASSWORD='...' --dry-run=client -o yaml \
  | kubeseal --format yaml \
  > k8s/overlays/prod/sealed-secrets/mysql-data-management.yaml

# 4. Versionar el SealedSecret y aplicar todo
git add k8s/overlays/prod/sealed-secrets/
kubectl apply -k k8s/overlays/prod
```

**Consideraciones:**

- **Los valores en claro nunca van a git.** Se mantienen en un `.env` local o
  gestor de contraseñas, y solo se usan al sellar. El repo solo contiene los
  `SealedSecret` cifrados.
- **Respaldar la clave privada del controller.** Si se reinstala el cluster sin
  restaurar esa clave, los `SealedSecret` existentes ya no se pueden descifrar y
  hay que re-sellarlos. Backup recomendado:

  ```bash
  kubectl -n kube-system get secret \
    -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > sealed-secrets-key.backup.yaml
  # guardar este archivo fuera de git, en lugar seguro.
  ```

- El `imagePullSecret` de GHCR (6.1) **no** se sella: se crea directo en el VPS
  con `kubectl create secret docker-registry`.

---

## 7. Entregable

~30–40 manifests YAML + 2 `kustomization.yaml` + README con comandos:
instalación de k3s, creación de secrets, `kubectl apply -k overlays/prod`.
Todo bajo `tesis-infra/k8s/`. Nada se aplica a un cluster real desde el repo: se
generan los archivos; el despliegue se ejecuta en el VPS.

### Comandos previstos (resumen)

```bash
# 1. Instalar k3s en el VPS
curl -sfL https://get.k3s.io | sh -

# 2. Crear secrets (ejemplo MySQL; repetir por servicio)
kubectl create namespace landslide
kubectl -n landslide create secret generic mysql-data-management \
  --from-literal=MYSQL_ROOT_PASSWORD=...

# 3. imagePullSecret para GHCR
kubectl -n landslide create secret docker-registry ghcr \
  --docker-server=ghcr.io --docker-username=<user> --docker-password=<PAT>

# 4. Desplegar todo
kubectl apply -k k8s/overlays/prod

# 5. Verificar
kubectl -n landslide get pods,svc,ingress
```
