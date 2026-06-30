.PHONY: up down reset rebuild status logs ps wait-healthy obs-up obs-down local-up local-down

# ─────────────────────────────────────────────────────────────────
# Makefile — Infraestructura local del sistema de monitoreo
# ─────────────────────────────────────────────────────────────────

COMPOSE       = docker compose -f docker-compose.yml
COMPOSE_OBS   = docker compose -f docker-compose.observability.yml --env-file envs/observability.env
COMPOSE_LOCAL = docker compose -f docker-compose.local.yml --env-file envs/observability.env

# Levantar toda la infraestructura en background
up:
	@echo "-> Levantando infraestructura..."
	$(COMPOSE) up -d
	@$(MAKE) wait-healthy

# Bajar sin borrar datos (los volúmenes persisten)
down:
	$(COMPOSE) down

# Reset total: baja + borra volúmenes + vuelve a levantar
reset:
	@echo "[!] Esto borrara TODOS los datos (MySQL, RabbitMQ, Redis, Consul)."
	@read -p "Continuar? [y/N] " confirm && [ "$$confirm" = "y" ]
	$(COMPOSE) down -v
	$(MAKE) up

# Rebuild total: baja + borra volúmenes + reconstruye imágenes locales + levanta.
# Igual que reset pero con --build (reconstruye lo que tiene `build:`, p.ej. el
# gateway nginx+consul-template). Nota: los datos en bind mounts (mysql-data/)
# NO los borra `down -v`; bórralos a mano si necesitas un MySQL realmente virgen.
rebuild:
	@echo "[!] Esto borrara los volúmenes y reconstruira las imágenes locales."
	@read -p "Continuar? [y/N] " confirm && [ "$$confirm" = "y" ]
	$(COMPOSE) down -v
	$(COMPOSE) up -d --build
	@$(MAKE) wait-healthy

# Ver estado de todos los contenedores
status:
	$(COMPOSE) ps

# Logs en tiempo real de un servicio específico: make logs SVC=rabbitmq-1
logs:
	$(COMPOSE) logs -f $(SVC)

# Logs de todos
logs-all:
	$(COMPOSE) logs -f

# Esperar a que los healthchecks pasen
wait-healthy:
	@echo "-> Esperando healthchecks..."
	@until docker inspect consul-1 --format '{{.State.Health.Status}}' 2>/dev/null | grep -q healthy; do \
		echo "  consul-1 no esta healthy aun..."; sleep 3; done
	@echo "  [OK] consul-1 healthy"
	@until docker inspect rabbitmq-1 --format '{{.State.Health.Status}}' 2>/dev/null | grep -q healthy; do \
		echo "  rabbitmq-1 no esta healthy aun..."; sleep 3; done
	@echo "  [OK] rabbitmq-1 healthy"
	@for db in mysql-data-management mysql-user-management mysql-project-management mysql-early-warning; do \
		until docker inspect $$db --format '{{.State.Health.Status}}' 2>/dev/null | grep -q healthy; do \
			echo "  $$db no esta healthy aun..."; sleep 3; done; \
		echo "  [OK] $$db healthy"; \
	done
	@echo ""
	@echo "[OK] Infraestructura lista."
	@echo "   Consul UI:      http://localhost:8500"
	@echo "   RabbitMQ UI:    http://localhost:15672"
	@echo "   MySQL:          localhost:3306-3309"
	@echo "   Redis:          localhost:6379"
	@echo "   Nginx (gateway):http://localhost:80"

# Levantar stack de observabilidad (Prometheus + exporters + Grafana)
# Requiere: infra base ya corriendo (make up) + envs/observability.env creado
obs-up:
	@echo "-> Levantando observabilidad..."
	$(COMPOSE_OBS) up -d
	@echo ""
	@echo "[OK] Observabilidad lista."
	@echo "   Prometheus: http://localhost:9090"
	@echo "   Grafana:    http://localhost:3000"

# Bajar stack de observabilidad sin borrar datos de Grafana/Prometheus
obs-down:
	$(COMPOSE_OBS) down

# Levantar Grafana en laptop (requiere túnel SSH activo: ssh -L 9090:localhost:9090 usuario@servidor)
local-up:
	@echo "-> Levantando Grafana local..."
	$(COMPOSE_LOCAL) up -d
	@echo ""
	@echo "[OK] Grafana lista."
	@echo "   Grafana: http://localhost:3000"
	@echo "   (Asegúrate de tener el túnel SSH activo)"

local-down:
	$(COMPOSE_LOCAL) down

# Verificar conectividad rápida sin Docker
ping:
	@nc -z -w3 localhost 5672  && echo "[OK] RabbitMQ AMQP OK"  || echo "[FAIL] RabbitMQ AMQP FAIL"
	@nc -z -w3 localhost 6379  && echo "[OK] Redis OK"          || echo "[FAIL] Redis FAIL"
	@nc -z -w3 localhost 3306  && echo "[OK] MySQL OK"          || echo "[FAIL] MySQL FAIL"
	@nc -z -w3 localhost 8500  && echo "[OK] Consul OK"         || echo "[FAIL] Consul FAIL"
	@nc -z -w3 localhost 80    && echo "[OK] Nginx OK"          || echo "[FAIL] Nginx FAIL"