#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

STACK_NAME="n8n"
DOMAIN="n8n.cicloia.shop"
TIMEZONE="America/Sao_Paulo"
N8N_VERSION="2.19.4"

TRAEFIK_NETWORK="public"
TRAEFIK_ENTRYPOINT="web"

BASE_DIR="/opt/swarm/${STACK_NAME}"
SECRETS_DIR="${BASE_DIR}/secrets"
STACK_FILE="${BASE_DIR}/${STACK_NAME}-stack.yml"
ENV_FILE="${BASE_DIR}/.env.generated"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Erro: comando '$1' não encontrado." >&2
    exit 1
  }
}

require_cmd docker
require_cmd openssl

if [[ "${EUID}" -ne 0 ]]; then
  echo "Erro: execute como root ou com sudo." >&2
  exit 1
fi

if [[ "$(docker info --format '{{.Swarm.LocalNodeState}}')" != "active" ]]; then
  echo "Erro: Docker Swarm não está ativo neste servidor."
  echo "Execute antes:"
  echo "docker swarm init"
  exit 1
fi

if [[ "$(docker info --format '{{.Swarm.ControlAvailable}}')" != "true" ]]; then
  echo "Erro: execute este script em um nó manager do Swarm."
  exit 1
fi

mkdir -p "${SECRETS_DIR}"

if ! docker network inspect "${TRAEFIK_NETWORK}" >/dev/null 2>&1; then
  echo "Rede ${TRAEFIK_NETWORK} não encontrada. Criando..."
  docker network create --driver overlay "${TRAEFIK_NETWORK}"
fi

if [[ ! -f "${SECRETS_DIR}/postgres_password.txt" ]]; then
  openssl rand -hex 24 > "${SECRETS_DIR}/postgres_password.txt"
fi

if [[ ! -f "${SECRETS_DIR}/n8n_encryption_key.txt" ]]; then
  openssl rand -hex 32 > "${SECRETS_DIR}/n8n_encryption_key.txt"
fi

chmod 600 "${SECRETS_DIR}/postgres_password.txt"
chmod 600 "${SECRETS_DIR}/n8n_encryption_key.txt"

POSTGRES_PASSWORD_FILE="${SECRETS_DIR}/postgres_password.txt"
N8N_ENCRYPTION_KEY_FILE="${SECRETS_DIR}/n8n_encryption_key.txt"

cat > "${ENV_FILE}" <<ENV
STACK_NAME=${STACK_NAME}
DOMAIN=${DOMAIN}
TIMEZONE=${TIMEZONE}
N8N_VERSION=${N8N_VERSION}
TRAEFIK_NETWORK=${TRAEFIK_NETWORK}
TRAEFIK_ENTRYPOINT=${TRAEFIK_ENTRYPOINT}
POSTGRES_PASSWORD_FILE=${POSTGRES_PASSWORD_FILE}
N8N_ENCRYPTION_KEY_FILE=${N8N_ENCRYPTION_KEY_FILE}
ENV

chmod 600 "${ENV_FILE}"

cat > "${STACK_FILE}" <<YAML
version: "3.8"

services:
  postgres:
    image: postgres:16
    environment:
      POSTGRES_USER: postgres
      POSTGRES_DB: n8n
      POSTGRES_PASSWORD_FILE: /run/secrets/postgres_password
    secrets:
      - source: postgres_password
        target: postgres_password
    volumes:
      - n8n_postgres_data:/var/lib/postgresql/data
    networks:
      - n8n_internal
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -d n8n"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 30s
    deploy:
      mode: replicated
      replicas: 1
      placement:
        constraints:
          - node.role == manager
      restart_policy:
        condition: any
        delay: 5s
        max_attempts: 0

  n8n:
    image: docker.n8n.io/n8nio/n8n:${N8N_VERSION}
    environment:
      TZ: "${TIMEZONE}"
      GENERIC_TIMEZONE: "${TIMEZONE}"

      N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS: "true"
      N8N_RUNNERS_ENABLED: "true"

      N8N_HOST: "${DOMAIN}"
      N8N_PORT: "5678"
      N8N_PROTOCOL: "https"

      N8N_EDITOR_BASE_URL: "https://${DOMAIN}/"
      WEBHOOK_URL: "https://${DOMAIN}/"

      N8N_PROXY_HOPS: "1"
      N8N_SECURE_COOKIE: "true"

      N8N_ENCRYPTION_KEY_FILE: /run/secrets/n8n_encryption_key

      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: postgres
      DB_POSTGRESDB_PORT: "5432"
      DB_POSTGRESDB_DATABASE: n8n
      DB_POSTGRESDB_USER: postgres
      DB_POSTGRESDB_PASSWORD_FILE: /run/secrets/postgres_password
      DB_POSTGRESDB_SCHEMA: public
    secrets:
      - source: postgres_password
        target: postgres_password
      - source: n8n_encryption_key
        target: n8n_encryption_key
    volumes:
      - n8n_data:/home/node/.n8n
    networks:
      - public
      - n8n_internal
    deploy:
      mode: replicated
      replicas: 1
      placement:
        constraints:
          - node.role == manager
      restart_policy:
        condition: any
        delay: 5s
        max_attempts: 0
      labels:
        - traefik.enable=true
        - traefik.docker.network=public

        - traefik.http.routers.n8n.rule=Host(\`${DOMAIN}\`)
        - traefik.http.routers.n8n.entrypoints=web
        - traefik.http.routers.n8n.service=n8n

        - traefik.http.services.n8n.loadbalancer.server.port=5678

volumes:
  n8n_postgres_data:
    name: n8n_postgres_data
  n8n_data:
    name: n8n_data

secrets:
  postgres_password:
    file: ${POSTGRES_PASSWORD_FILE}
  n8n_encryption_key:
    file: ${N8N_ENCRYPTION_KEY_FILE}

networks:
  public:
    external: true
  n8n_internal:
    driver: overlay
YAML

docker stack deploy --prune -c "${STACK_FILE}" "${STACK_NAME}"

echo
echo "n8n enviado para o Swarm."
echo
echo "URL pública esperada:"
echo "https://${DOMAIN}"
echo
echo "Arquivos criados:"
echo "Stack: ${STACK_FILE}"
echo "Ambiente: ${ENV_FILE}"
echo "Segredos: ${SECRETS_DIR}"
echo
echo "IMPORTANTE:"
echo "No Cloudflare Tunnel, crie o Public Hostname:"
echo "${DOMAIN} -> http://traefik_traefik:80"
echo
echo "Depois acompanhe com:"
echo "docker service ls | grep n8n"
echo "docker service logs -f n8n_n8n"
