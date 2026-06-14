# go-tesis-infra — Infraestructura del sistema de monitoreo de deslizamientos

Repositorio contenedor de la **infraestructura** y los **docker-compose de los microservicios** del sistema de monitoreo de deslizamientos basado en Bai et al. (2020).

El repositorio agrupa, en un solo lugar, todo lo necesario para levantar el sistema completo (infra base + microservicios) en un entorno de desarrollo local, manteniendo la infraestructura desacoplada de los servicios: la infra puede levantarse, bajarse o reiniciarse sin afectar a los microservicios, y viceversa.

> Este repo **no contiene el código fuente** de los microservicios — solo su orquestación (docker-compose, env de ejemplo y configuración de infraestructura). El código de cada servicio vive en su propio repositorio.

## Estructura del repositorio

```
tesis-infra/
├── README.md              # este archivo — visión general del repositorio
├── Makefile               # orquestador raíz: comandos para infra y microservicios
├── .gitignore             # excluye .env reales y datos de volúmenes
└── local/                 # entorno de desarrollo local
    ├── README.local.md    # documentación detallada del entorno local
    ├── infra/             # infraestructura base
    │   ├── docker-compose.yml   # Consul · RabbitMQ · Redis · MySQL x4 · Nginx
    │   ├── consul/              # config de service discovery
    │   ├── rabbitmq/           # definitions.json (topología) + rabbitmq.conf
    │   ├── mysql/              # init SQL por BD (database-per-service)
    │   ├── nginx/             # config del API Gateway
    │   └── envs/             # *.env.example de infra (los .env reales NO se versionan)
    └── services/          # orquestación de microservicios
        ├── data-receiving/      # docker-compose.yml
        ├── data-management/     # docker-compose.yml
        ├── data-analysis/       # docker-compose.yml
        ├── early-warning/       # docker-compose.yml
        ├── user-management/     # docker-compose.yml
        ├── project-management/  # docker-compose.yml
        └── envs/               # *.env.example de servicios
```

### Por qué esta separación

| Carpeta            | Responsabilidad                                                                 |
|--------------------|---------------------------------------------------------------------------------|
| `local/infra/`     | Servicios de plataforma compartidos: discovery, mensajería, cache, BD, gateway. |
| `local/services/`  | Un `docker-compose.yml` por microservicio, cada uno con sus instancias.         |

La infra crea la red Docker externa `landslide-net`. Cada microservicio se une a esa red, de modo que infra y servicios se levantan de forma independiente pero se comunican entre sí.

## Componentes de infraestructura

| Componente | Rol                                                        |
|------------|------------------------------------------------------------|
| Consul     | Service discovery + health checking                        |
| RabbitMQ   | Mensajería asíncrona (ingesta de sensores, DLX)           |
| Redis      | Cache / buffer temporal de lecturas                       |
| MySQL ×4   | Una BD por servicio (database-per-service)                 |
| Nginx      | API Gateway / load balancer (enrutado HTTP por prefijo)   |

## Microservicios orquestados

| Servicio            | Instancias | Tiene BD propia                           |
|---------------------|-----------:|-------------------------------------------|
| data-receiving      | 3          | No (usa Redis como buffer)                |
| data-management     | 2          | `mysql-data-management`                   |
| data-analysis       | 2          | No (lee de data-management, solo lectura) |
| early-warning       | 2          | `mysql-early-warning`                     |
| user-management     | 1          | `mysql-user-management`                   |
| project-management  | 1          | `mysql-project-management`                |

## Uso rápido

Todos los comandos se ejecutan **desde la raíz del repositorio**, vía `make`:

```bash
make all-up        # levanta infra + todos los microservicios
make all-down      # baja todo
make status        # estado de todos los contenedores
make help          # lista completa de comandos
```

Comandos por servicio:

```bash
make infra-up                       # solo infraestructura
make svc-up   SVC=data-receiving    # un microservicio
make svc-logs SVC=early-warning     # logs en tiempo real
```

> La documentación detallada (primer uso, copia de `.env`, puertos, topología de RabbitMQ, UIs disponibles) está en [local/README.local.md](local/README.local.md).

## Prerequisitos

- Docker >= 24
- Docker Compose >= 2.20
- make

## Configuración de entorno

Los archivos `.env` con credenciales reales **no se versionan**. Cada carpeta `envs/` incluye plantillas `*.env.example`; cópialas y completa los valores antes de levantar:

```bash
cp local/infra/envs/redis.env.example local/infra/envs/redis.env
# ... repetir para cada .env.example (ver local/README.local.md)
```

El `.gitignore` excluye todos los `.env` reales y los datos de los volúmenes (bind mounts) que Docker genera al levantar la infra.

## Producción

En producción este entorno local se reemplaza por manifiestos de Kubernetes: el service discovery pasa de Consul a DNS nativo de Kubernetes y los secrets se gestionan vía Kubernetes Secrets en lugar de archivos `.env`.
