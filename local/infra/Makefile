.PHONY: up down reset status logs ps wait-healthy

# ─────────────────────────────────────────────────────────────────
# Makefile — Infraestructura local del sistema de monitoreo
# ─────────────────────────────────────────────────────────────────

COMPOSE = docker compose -f docker-compose.yml

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

# Verificar conectividad rápida sin Docker
ping:
	@nc -z -w3 localhost 5672  && echo "[OK] RabbitMQ AMQP OK"  || echo "[FAIL] RabbitMQ AMQP FAIL"
	@nc -z -w3 localhost 6379  && echo "[OK] Redis OK"          || echo "[FAIL] Redis FAIL"
	@nc -z -w3 localhost 3306  && echo "[OK] MySQL OK"          || echo "[FAIL] MySQL FAIL"
	@nc -z -w3 localhost 8500  && echo "[OK] Consul OK"         || echo "[FAIL] Consul FAIL"
	@nc -z -w3 localhost 80    && echo "[OK] Nginx OK"          || echo "[FAIL] Nginx FAIL"