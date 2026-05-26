#!/usr/bin/env bash
set -euo pipefail

# =========================
# AJUSTE AQUI
# =========================
STACK_NAME="evogo"
DOMAIN="go.cicloia.shop"
API_KEY="2f4E4tc6s2f4E4tc6s"
POSTGRES_PASSWORD="EvogoPg2026A9"
CLIENT_NAME="evolution"
SERVER_PORT="4000"
# =========================

BASE_DIR="/opt/swarm/${STACK_NAME}"
mkdir -p "${BASE_DIR}/init"

cat > "${BASE_DIR}/init/01-create-dbs.sql" <<SQL
CREATE DATABASE evogo_auth;
CREATE DATABASE evogo_users;
SQL

cat > "${BASE_DIR}/${STACK_NAME}-stack.yml" <<YAML
version: "3.8"

services:
  postgres:
    image: postgres:16
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: postgres
      POSTGRES_INITDB_ARGS: --auth-host=scram-sha-256
    volumes:
      - ${STACK_NAME}_postgres_data:/var/lib/postgresql/data
      - ${BASE_DIR}/init:/docker-entrypoint-initdb.d
    networks:
      evogo_internal:
        aliases:
          - postgres
    deploy:
      mode: replicated
      replicas: 1
      placement:
        constraints:
          - node.role == manager
      restart_policy:
        condition: any

  redis:
    image: redis:7-alpine
    command:
      - redis-server
      - --appendonly
      - "yes"
      - --save
      - "900"
      - "1"
      - --save
      - "300"
      - "10"
      - --save
      - "60"
      - "10000"
    volumes:
      - ${STACK_NAME}_redis_data:/data
    networks:
      evogo_internal:
        aliases:
          - redis
    deploy:
      mode: replicated
      replicas: 1
      placement:
        constraints:
          - node.role == manager
      restart_policy:
        condition: any

  evolution_go:
    image: evoapicloud/evolution-go:0.7.0
    environment:
      SERVER_PORT: "${SERVER_PORT}"
      CLIENT_NAME: "${CLIENT_NAME}"
      GLOBAL_API_KEY: "${API_KEY}"
      POSTGRES_AUTH_DB: "postgresql://postgres:${POSTGRES_PASSWORD}@postgres:5432/evogo_auth?sslmode=disable"
      POSTGRES_USERS_DB: "postgresql://postgres:${POSTGRES_PASSWORD}@postgres:5432/evogo_users?sslmode=disable"
      DATABASE_SAVE_MESSAGES: "false"
      REDIS_URL: "redis://redis:6379"
      WADEBUG: "INFO"
      LOGTYPE: "console"
      LOG_DIRECTORY: "/app/logs"
      CONNECT_ON_STARTUP: "true"
      WEBHOOKFILES: "true"
    volumes:
      - ${STACK_NAME}_app_data:/app/dbdata
      - ${STACK_NAME}_logs:/app/logs
    networks:
      - public
      - evogo_internal
    deploy:
      mode: replicated
      replicas: 1
      placement:
        constraints:
          - node.role == manager
      restart_policy:
        condition: any
      labels:
        - traefik.enable=true
        - traefik.docker.network=public
        - traefik.http.routers.${STACK_NAME}.rule=Host(\`${DOMAIN}\`)
        - traefik.http.routers.${STACK_NAME}.entrypoints=web
        - traefik.http.services.${STACK_NAME}.loadbalancer.server.port=${SERVER_PORT}

volumes:
  ${STACK_NAME}_postgres_data:
  ${STACK_NAME}_redis_data:
  ${STACK_NAME}_app_data:
  ${STACK_NAME}_logs:

networks:
  public:
    external: true
  evogo_internal:
    driver: overlay
YAML

echo "Validando stack..."
docker stack config -c "${BASE_DIR}/${STACK_NAME}-stack.yml" >/dev/null

echo "Subindo stack..."
docker stack deploy -c "${BASE_DIR}/${STACK_NAME}-stack.yml" "${STACK_NAME}"

echo
echo "Stack enviada."
echo "Arquivo: ${BASE_DIR}/${STACK_NAME}-stack.yml"
echo
echo "Comandos úteis:"
echo "  docker service ls"
echo "  docker service ps ${STACK_NAME}_evolution_go"
echo "  docker service logs -f ${STACK_NAME}_evolution_go"
echo
echo "Dominio previsto:"
echo "  https://${DOMAIN}"
echo
echo "Manager inicial:"
echo "  https://${DOMAIN}/manager/login"
echo
echo "API key:"
echo "  ${API_KEY}"
