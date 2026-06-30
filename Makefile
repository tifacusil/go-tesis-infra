.PHONY: infra-up infra-down infra-reset infra-rebuild \
        svc-up svc-down svc-logs svc-build \
        all-svc-up all-svc-down \
        all-up all-down \
        obs-up obs-down local-up local-down \
        load-test \
        status ping help

# ─────────────────────────────────────────────────────────────────────────────
# Makefile raíz — Sistema de monitoreo de deslizamientos
# Orquesta infraestructura y microservicios en local/
#
# Uso rápido:
#   make all-up                     # levanta infra + todos los servicios
#   make svc-up SVC=data-receiving  # levanta un servicio específico
#   make svc-logs SVC=early-warning # logs de un servicio
#   make all-down                   # baja todo
# ─────────────────────────────────────────────────────────────────────────────

INFRA_DIR    = local/infra
SERVICES_DIR = local/services

SERVICES = data-receiving \
           data-management \
           data-analysis \
           early-warning \
           user-management \
           project-management

# ── Infraestructura ───────────────────────────────────────────────────────────

infra-up:
	@echo "-> Levantando infraestructura..."
	$(MAKE) -C $(INFRA_DIR) up

infra-down:
	@echo "-> Bajando infraestructura..."
	$(MAKE) -C $(INFRA_DIR) down

infra-reset:
	$(MAKE) -C $(INFRA_DIR) reset

infra-rebuild:
	$(MAKE) -C $(INFRA_DIR) rebuild

# ── Un microservicio ──────────────────────────────────────────────────────────
# Uso: make svc-up SVC=data-receiving

svc-up:
	@test -n "$(SVC)" || (echo "❌ Falta SVC. Ejemplo: make svc-up SVC=data-receiving" && exit 1)
	@echo "-> Levantando $(SVC)..."
	docker compose -f $(SERVICES_DIR)/$(SVC)/docker-compose.yml up -d --build

svc-down:
	@test -n "$(SVC)" || (echo "❌ Falta SVC. Ejemplo: make svc-down SVC=data-receiving" && exit 1)
	docker compose -f $(SERVICES_DIR)/$(SVC)/docker-compose.yml down

svc-logs:
	@test -n "$(SVC)" || (echo "❌ Falta SVC. Ejemplo: make svc-logs SVC=data-receiving" && exit 1)
	docker compose -f $(SERVICES_DIR)/$(SVC)/docker-compose.yml logs -f

svc-build:
	@test -n "$(SVC)" || (echo "❌ Falta SVC. Ejemplo: make svc-build SVC=data-receiving" && exit 1)
	docker compose -f $(SERVICES_DIR)/$(SVC)/docker-compose.yml build

# ── Todos los microservicios ──────────────────────────────────────────────────

all-svc-up:
	@echo "-> Levantando todos los microservicios..."
	@for svc in $(SERVICES); do \
		echo "  -> $$svc"; \
		docker compose -f $(SERVICES_DIR)/$$svc/docker-compose.yml up -d --build; \
	done
	@echo "[OK] Todos los microservicios levantados."

all-svc-down:
	@echo "-> Bajando todos los microservicios..."
	@for svc in $(SERVICES); do \
		docker compose -f $(SERVICES_DIR)/$$svc/docker-compose.yml down; \
	done

# ── Todo junto ────────────────────────────────────────────────────────────────

all-up: infra-up all-svc-up
	@echo ""
	@echo "[OK] Sistema completo levantado."
	@echo "   Consul UI:       http://localhost:8500"
	@echo "   RabbitMQ UI:     http://localhost:15672"
	@echo "   Nginx/API GW:    http://localhost:80"
	@echo ""
	@echo "   Puertos de microservicios:"
	@echo "   data-receiving   TCP: 5000-5002  HTTP: 8080-8082"
	@echo "   data-management  HTTP: 8083-8084"
	@echo "   data-analysis    HTTP: 8085-8086"
	@echo "   early-warning    HTTP: 8087-8088"
	@echo "   user-management  HTTP: 8089"
	@echo "   project-mgmt     HTTP: 8090"

all-down: all-svc-down infra-down
	@echo "[OK] Sistema completo bajado."

# ── Observabilidad ───────────────────────────────────────────────────────────
# obs-up/obs-down: Prometheus + exporters en el SERVIDOR
# local-up/local-down: Grafana en la LAPTOP

obs-up:
	$(MAKE) -C $(INFRA_DIR) obs-up

obs-down:
	$(MAKE) -C $(INFRA_DIR) obs-down

local-up:
	$(MAKE) -C $(INFRA_DIR) local-up

local-down:
	$(MAKE) -C $(INFRA_DIR) local-down

# ── Load tests ────────────────────────────────────────────────────────────────
# Uso: make load-test TARGET_HOST=http://IP_SERVIDOR SYSTEM=A
# Requiere Artillery instalado: npm install -g artillery

load-test:
	@test -n "$(TARGET_HOST)" || (echo "Falta TARGET_HOST. Ej: make load-test TARGET_HOST=http://IP SYSTEM=A" && exit 1)
	TARGET_HOST=$(TARGET_HOST) SYSTEM=$(SYSTEM) bash load-tests/run-all.sh

# ── Utilidades ────────────────────────────────────────────────────────────────

status:
	@echo "=== Infraestructura ==="
	@docker ps --filter "name=consul-1|rabbitmq-1|redis|mysql-|nginx" \
		--format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || true
	@echo ""
	@echo "=== Microservicios ==="
	@docker ps --filter "name=data-receiving|data-management|data-analysis|early-warning|user-management|project-management" \
		--format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || true

ping:
	$(MAKE) -C $(INFRA_DIR) ping
	@echo ""
	@echo "=== Microservicios ==="
	@for port in 8080 8081 8082 8083 8084 8085 8086 8087 8088 8089 8090; do \
		nc -z -w1 localhost $$port 2>/dev/null \
			&& echo "[OK] localhost:$$port OK" \
			|| echo "[FAIL] localhost:$$port no responde"; \
	done

help:
	@echo "Comandos disponibles:"
	@echo ""
	@echo "  make infra-up                     Levanta Consul, RabbitMQ, Redis, MySQL x4, Nginx"
	@echo "  make infra-down                   Baja la infraestructura"
	@echo "  make infra-reset                  Reset total (borra volúmenes)"
	@echo "  make infra-rebuild                Reset + reconstruye imágenes locales (--build)"
	@echo ""
	@echo "  make svc-up SVC=<nombre>          Levanta un microservicio"
	@echo "  make svc-down SVC=<nombre>        Baja un microservicio"
	@echo "  make svc-logs SVC=<nombre>        Logs en tiempo real de un microservicio"
	@echo "  make svc-build SVC=<nombre>       Reconstruye la imagen de un microservicio"
	@echo ""
	@echo "  make all-svc-up                   Levanta todos los microservicios"
	@echo "  make all-svc-down                 Baja todos los microservicios"
	@echo ""
	@echo "  make all-up                       Levanta infra + todos los microservicios"
	@echo "  make all-down                     Baja todo"
	@echo ""
	@echo "  make status                       Estado de todos los contenedores"
	@echo "  make ping                         Verifica conectividad de puertos"
	@echo ""
	@echo "  make obs-up                       Levanta Prometheus + exporters (SERVIDOR)"
	@echo "  make obs-down                     Baja Prometheus + exporters"
	@echo "  make local-up                     Levanta Grafana (LAPTOP, requiere túnel SSH)"
	@echo "  make local-down                   Baja Grafana local"
	@echo ""
	@echo "  make load-test TARGET_HOST=http://IP SYSTEM=A"
	@echo "                                    Corre las 5 corridas de Artillery"
	@echo ""
	@echo "Servicios disponibles: $(SERVICES)"