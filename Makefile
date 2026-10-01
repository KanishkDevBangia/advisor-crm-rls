.PHONY: up wait load test down clean

DB_EXEC = docker compose exec -T db psql -U postgres -d advisor_crm_demo -v ON_ERROR_STOP=1

up:
	docker compose up -d

wait:
	@echo "Waiting for Postgres to accept connections..."
	@until docker compose exec -T db pg_isready -U postgres > /dev/null 2>&1; do sleep 1; done

load: wait
	$(DB_EXEC) -f - < schema.sql
	$(DB_EXEC) -f - < seed.sql

test: up load
	$(DB_EXEC) -f - < tests/isolation_test.sql

down:
	docker compose down -v

clean: down
