# local/ — Desarrollo local

Levanta toda la infraestructura y los microservicios del nuevo sistema de monitoreo de deslizamientos basado de Bai et al. 2020 en local, de forma desacoplada: la infraestructura es independiente de los servicios y puede levantarse o reiniciarse sin afectarlos.

## Estructura

```
local/
├── infra/
│   ├── docker-compose.yml              # Consul · RabbitMQ · Redis · MySQL x4 · Nginx
│   ├── Makefile                        # comandos de conveniencia de infra
│   ├── consul/
│   │   └── config.json
│   ├── rabbitmq/
│   │   ├── definitions.json            # exchanges, colas, DLX, usuarios, permisos
│   │   └── rabbitmq.conf
│   ├── mysql/
│   │   ├── data-management/init/       # 00_schema.sql: crea BD + usuarios + grants (sin tablas)
│   │   ├── user-management/init/       # 00_schema.sql: crea BD + usuarios + grants (sin tablas)
│   │   ├── project-management/init/    # 00_schema.sql: crea BD + usuarios + grants (sin tablas)
│   │   └── early-warning/init/         # 00_schema.sql: crea BD + usuarios + grants (sin tablas)
│   ├── nginx/
│   │   └── nginx.conf                  # API Gateway estático
│   └── envs/                           # credenciales de infraestructura (NO commitear)
│       ├── rabbitmq.env
│       ├── redis.env
│       ├── mysql-data-management.env
│       ├── mysql-user-management.env
│       ├── mysql-project-management.env
│       └── mysql-early-warning.env
└── services/
    ├── envs/                           # credenciales de microservicios (NO commitear)
    │   ├── data-receiving.env
    │   ├── data-management.env
    │   ├── data-analysis.env
    │   ├── early-warning.env
    │   ├── user-management.env
    │   └── project-management.env
    ├── data-receiving/
    │   └── docker-compose.yml          # 3 instancias (TCP 5000-5002, HTTP 8080-8082)
    ├── data-management/
    │   └── docker-compose.yml          # 2 instancias (HTTP 8083-8084)
    ├── data-analysis/
    │   └── docker-compose.yml          # 2 instancias (HTTP 8085-8086)
    ├── early-warning/
    │   └── docker-compose.yml          # 2 instancias (HTTP 8087-8088)
    ├── user-management/
    │   └── docker-compose.yml          # 1 instancia  (HTTP 8089)
    └── project-management/
        └── docker-compose.yml          # 1 instancia  (HTTP 8090)
```

## Prerequisitos

- Docker >= 24
- Docker Compose >= 2.20
- make

## Primer uso

```bash
# 1. Completar los archivos de entorno de infra
#    Editar contraseñas en cada archivo (nunca commitear valores reales)
cd local

cp infra/envs/rabbitmq.env.example            infra/envs/rabbitmq.env
cp infra/envs/redis.env.example               infra/envs/redis.env
cp infra/envs/mysql-data-management.env.example   infra/envs/mysql-data-management.env
cp infra/envs/mysql-user-management.env.example   infra/envs/mysql-user-management.env
cp infra/envs/mysql-project-management.env.example infra/envs/mysql-project-management.env
cp infra/envs/mysql-early-warning.env.example     infra/envs/mysql-early-warning.env

# 2. Completar los archivos de entorno de servicios
cp services/envs/data-receiving.env.example   services/envs/data-receiving.env
cp services/envs/data-management.env.example  services/envs/data-management.env
cp services/envs/data-analysis.env.example    services/envs/data-analysis.env
cp services/envs/early-warning.env.example    services/envs/early-warning.env
cp services/envs/user-management.env.example  services/envs/user-management.env
cp services/envs/project-management.env.example services/envs/project-management.env

cd ..

# 3. Levantar infraestructura (desde la raíz del monorepo)
make infra-up

# 4. Verificar conectividad
make ping

# 5. Levantar microservicios
make all-svc-up

# O todo en un solo comando
make all-up
```

## Comandos disponibles (desde la raíz del monorepo)

```bash
# Infraestructura
make infra-up                       # levanta Consul, RabbitMQ, Redis, MySQL x4, Nginx
make infra-down                     # baja sin borrar datos
make infra-reset                    # reset total (borra volúmenes)

# Un microservicio
make svc-up SVC=data-receiving      # levanta un servicio específico
make svc-down SVC=data-receiving    # baja un servicio
make svc-logs SVC=early-warning     # logs en tiempo real
make svc-build SVC=data-management  # reconstruye la imagen

# Todos los microservicios
make all-svc-up                     # levanta todos
make all-svc-down                   # baja todos

# Todo junto
make all-up                         # infra + todos los servicios
make all-down                       # baja todo

# Utilidades
make status                         # estado de todos los contenedores
make ping                           # verifica puertos activos
```

## UIs disponibles

| Servicio        | URL                     | Credenciales            |
|---|---|---|
| Consul          | http://localhost:8500   | sin auth (local)        |
| RabbitMQ        | http://localhost:15672  | ver `infra/envs/rabbitmq.env` |
| Nginx / API GW  | http://localhost:80     | —                       |

## Puertos de microservicios

| Servicio            | Puerto TCP | Puerto HTTP       |
|---|---|---|
| data-receiving      | 5000–5002  | 8080–8082         |
| data-management     | —          | 8083–8084         |
| data-analysis       | —          | 8085–8086         |
| early-warning       | —          | 8087–8088         |
| user-management     | —          | 8089              |
| project-management  | —          | 8090              |

## Bases de datos MySQL

Cada microservicio tiene su propio contenedor MySQL (database-per-service):

| Contenedor               | BD                  | Puerto externo |
|---|---|---|
| mysql-data-management    | data_management     | 3306           |
| mysql-user-management    | user_management     | 3307           |
| mysql-project-management | project_management  | 3308           |
| mysql-early-warning      | early_warning       | 3309           |

`data-analysis` no tiene BD propia — lee de `mysql-data-management` con usuario de solo lectura.
`data-receiving` no tiene BD propia — usa Redis como buffer temporal.

### Inicialización y migraciones

Los scripts en `mysql/<svc>/init/` solo crean la **base de datos**, los **usuarios** de servicio y sus **grants** (privilegios mínimos: DML). **No crean tablas.**

La creación y evolución del esquema (tablas, índices, particiones) es responsabilidad de cada microservicio vía sus **migraciones**. Como los usuarios de servicio `svc_*` solo tienen permisos DML (`SELECT/INSERT/UPDATE/DELETE`), las migraciones se ejecutan con **root** (`MYSQL_ROOT_PASSWORD`), no con el usuario de servicio.

## Red Docker

La red `landslide-net` es creada por `infra/docker-compose.yml` y debe existir antes de levantar cualquier microservicio. Todos los servicios se unen a ella declarando:

```yaml
networks:
  landslide-net:
    external: true
    name: landslide-net
```

## Topología RabbitMQ

| Elemento              | Valor                                         |
|---|---|
| Exchange principal    | `sensors.raw` (topic, durable)                |
| Exchange DLX          | `sensors.dlx` (topic, durable)                |
| Cola Data Management  | `data_management.persist`                     |
| Cola Early Warning    | `early_warning.evaluate`                      |
| Cola DLQ              | `sensors.dead_letter`                         |
| Routing key pattern   | `sensors.<project_id>.<sensor_type>`          |

## .gitignore recomendado

```gitignore
# Archivos de entorno con credenciales
local/infra/envs/*.env
local/services/envs/*.env

# Datos de MySQL en bind mounts
local/infra/mysql-data/
```

## Notas para producción (Kubernetes)

En producción esta infra se reemplaza por los manifiestos en `k8s/infra/`. El service discovery pasa de Consul a DNS nativo de Kubernetes y los secrets se gestionan vía Kubernetes Secrets en lugar de archivos `.env`.