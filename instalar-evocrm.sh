#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# =========================================================
# CONFIGURAÇÃO
# =========================================================
STACK_NAME="evocrm"
IMAGE_TAG="1.0.0-rc3"

FRONTEND_DOMAIN="crm.cicloia.shop"
API_DOMAIN="api.cicloia.shop"

# Mesmo padrão da stack que já funciona no seu ambiente
TRAEFIK_NETWORK="public"
TRAEFIK_ENTRYPOINT="web"

POSTGRES_DATABASE="evo_community"
POSTGRES_USERNAME="postgres"
POSTGRES_PORT="5432"
POSTGRES_SSLMODE="disable"

REDIS_PORT="6379"
REDIS_DB="0"

MAILER_TYPE="smtp"
MAILER_SENDER_EMAIL="nayara.lino@cicloia.shop"
SMTP_ADDRESS="smtppro.zoho.com"
SMTP_PORT="587"
SMTP_DOMAIN="cicloia.shop"
SMTP_AUTHENTICATION="login"
SMTP_ENABLE_STARTTLS_AUTO="true"
SMTP_OPENSSL_VERIFY_MODE="peer"
SMTP_USERNAME="nayara.lino@cicloia.shop"
SMTP_PASSWORD="${SMTP_PASSWORD:-}"

MFA_ISSUER="EvoCRM"
EVOLUTION_OPERATOR_EMAIL="nayara.lino@cicloia.shop"

OLD_STACKS_TO_WARN=()

BASE_DIR="/opt/swarm/${STACK_NAME}"
ENV_FILE="${BASE_DIR}/.env.generated"
STACK_FILE="${BASE_DIR}/${STACK_NAME}-stack.yml"

mkdir -p "${BASE_DIR}"

CFG_STACK_NAME="$STACK_NAME"
CFG_IMAGE_TAG="$IMAGE_TAG"
CFG_FRONTEND_DOMAIN="$FRONTEND_DOMAIN"
CFG_API_DOMAIN="$API_DOMAIN"
CFG_TRAEFIK_NETWORK="$TRAEFIK_NETWORK"
CFG_TRAEFIK_ENTRYPOINT="$TRAEFIK_ENTRYPOINT"
CFG_POSTGRES_DATABASE="$POSTGRES_DATABASE"
CFG_POSTGRES_USERNAME="$POSTGRES_USERNAME"
CFG_POSTGRES_PORT="$POSTGRES_PORT"
CFG_POSTGRES_SSLMODE="$POSTGRES_SSLMODE"
CFG_REDIS_PORT="$REDIS_PORT"
CFG_REDIS_DB="$REDIS_DB"
CFG_MAILER_TYPE="$MAILER_TYPE"
CFG_MAILER_SENDER_EMAIL="$MAILER_SENDER_EMAIL"
CFG_SMTP_ADDRESS="$SMTP_ADDRESS"
CFG_SMTP_PORT="$SMTP_PORT"
CFG_SMTP_DOMAIN="$SMTP_DOMAIN"
CFG_SMTP_AUTHENTICATION="$SMTP_AUTHENTICATION"
CFG_SMTP_ENABLE_STARTTLS_AUTO="$SMTP_ENABLE_STARTTLS_AUTO"
CFG_SMTP_OPENSSL_VERIFY_MODE="$SMTP_OPENSSL_VERIFY_MODE"
CFG_SMTP_USERNAME="$SMTP_USERNAME"
CFG_MFA_ISSUER="$MFA_ISSUER"
CFG_EVOLUTION_OPERATOR_EMAIL="$EVOLUTION_OPERATOR_EMAIL"
INPUT_SMTP_PASSWORD="$SMTP_PASSWORD"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Erro: comando obrigatório não encontrado: $1" >&2
    exit 1
  }
}

gen_fernet_key() {
  python3 - <<'PY'
import os, base64
print(base64.urlsafe_b64encode(os.urandom(32)).decode())
PY
}

write_env_kv() {
  local key="$1"
  local value="$2"
  printf '%s=%q\n' "$key" "$value" >> "$ENV_FILE"
}

prompt_secret_if_empty() {
  local var_name="$1"
  local prompt_label="$2"
  local current="${!var_name:-}"

  if [[ -n "$current" ]]; then
    return 0
  fi

  if [[ -t 0 ]]; then
    local value
    read -r -s -p "${prompt_label}: " value
    echo
    if [[ -z "$value" ]]; then
      echo "Erro: valor não informado para ${var_name}." >&2
      exit 1
    fi
    printf -v "$var_name" '%s' "$value"
  else
    echo "Erro: variável obrigatória ausente: ${var_name}" >&2
    echo "Defina ${var_name} no ambiente antes de executar este script." >&2
    exit 1
  fi
}

restore_static_config() {
  STACK_NAME="$CFG_STACK_NAME"
  IMAGE_TAG="$CFG_IMAGE_TAG"
  FRONTEND_DOMAIN="$CFG_FRONTEND_DOMAIN"
  API_DOMAIN="$CFG_API_DOMAIN"
  TRAEFIK_NETWORK="$CFG_TRAEFIK_NETWORK"
  TRAEFIK_ENTRYPOINT="$CFG_TRAEFIK_ENTRYPOINT"
  POSTGRES_DATABASE="$CFG_POSTGRES_DATABASE"
  POSTGRES_USERNAME="$CFG_POSTGRES_USERNAME"
  POSTGRES_PORT="$CFG_POSTGRES_PORT"
  POSTGRES_SSLMODE="$CFG_POSTGRES_SSLMODE"
  REDIS_PORT="$CFG_REDIS_PORT"
  REDIS_DB="$CFG_REDIS_DB"
  MAILER_TYPE="$CFG_MAILER_TYPE"
  MAILER_SENDER_EMAIL="$CFG_MAILER_SENDER_EMAIL"
  SMTP_ADDRESS="$CFG_SMTP_ADDRESS"
  SMTP_PORT="$CFG_SMTP_PORT"
  SMTP_DOMAIN="$CFG_SMTP_DOMAIN"
  SMTP_AUTHENTICATION="$CFG_SMTP_AUTHENTICATION"
  SMTP_ENABLE_STARTTLS_AUTO="$CFG_SMTP_ENABLE_STARTTLS_AUTO"
  SMTP_OPENSSL_VERIFY_MODE="$CFG_SMTP_OPENSSL_VERIFY_MODE"
  SMTP_USERNAME="$CFG_SMTP_USERNAME"
  MFA_ISSUER="$CFG_MFA_ISSUER"
  EVOLUTION_OPERATOR_EMAIL="$CFG_EVOLUTION_OPERATOR_EMAIL"

  if [[ -n "$INPUT_SMTP_PASSWORD" ]]; then
    SMTP_PASSWORD="$INPUT_SMTP_PASSWORD"
  fi
}

write_env_file() {
  : > "${ENV_FILE}"

  write_env_kv STACK_NAME "${STACK_NAME}"
  write_env_kv IMAGE_TAG "${IMAGE_TAG}"
  write_env_kv FRONTEND_DOMAIN "${FRONTEND_DOMAIN}"
  write_env_kv API_DOMAIN "${API_DOMAIN}"
  write_env_kv TRAEFIK_NETWORK "${TRAEFIK_NETWORK}"
  write_env_kv TRAEFIK_ENTRYPOINT "${TRAEFIK_ENTRYPOINT}"

  write_env_kv POSTGRES_DATABASE "${POSTGRES_DATABASE}"
  write_env_kv POSTGRES_USERNAME "${POSTGRES_USERNAME}"
  write_env_kv POSTGRES_PASSWORD "${POSTGRES_PASSWORD}"
  write_env_kv POSTGRES_PORT "${POSTGRES_PORT}"
  write_env_kv POSTGRES_SSLMODE "${POSTGRES_SSLMODE}"

  write_env_kv REDIS_PORT "${REDIS_PORT}"
  write_env_kv REDIS_DB "${REDIS_DB}"
  write_env_kv REDIS_PASSWORD "${REDIS_PASSWORD}"

  write_env_kv SECRET_KEY_BASE "${SECRET_KEY_BASE}"
  write_env_kv JWT_SECRET_KEY "${JWT_SECRET_KEY}"
  write_env_kv DOORKEEPER_JWT_SECRET_KEY "${DOORKEEPER_JWT_SECRET_KEY}"
  write_env_kv EVOAI_CRM_API_TOKEN "${EVOAI_CRM_API_TOKEN}"
  write_env_kv BOT_RUNTIME_SECRET "${BOT_RUNTIME_SECRET}"
  write_env_kv ENCRYPTION_KEY "${ENCRYPTION_KEY}"

  write_env_kv MAILER_TYPE "${MAILER_TYPE}"
  write_env_kv MAILER_SENDER_EMAIL "${MAILER_SENDER_EMAIL}"
  write_env_kv SMTP_ADDRESS "${SMTP_ADDRESS}"
  write_env_kv SMTP_PORT "${SMTP_PORT}"
  write_env_kv SMTP_DOMAIN "${SMTP_DOMAIN}"
  write_env_kv SMTP_AUTHENTICATION "${SMTP_AUTHENTICATION}"
  write_env_kv SMTP_ENABLE_STARTTLS_AUTO "${SMTP_ENABLE_STARTTLS_AUTO}"
  write_env_kv SMTP_OPENSSL_VERIFY_MODE "${SMTP_OPENSSL_VERIFY_MODE}"
  write_env_kv SMTP_USERNAME "${SMTP_USERNAME}"
  write_env_kv SMTP_PASSWORD "${SMTP_PASSWORD}"
  write_env_kv MFA_ISSUER "${MFA_ISSUER}"
  write_env_kv EVOLUTION_OPERATOR_EMAIL "${EVOLUTION_OPERATOR_EMAIL}"
}

validate_required_env() {
  local key
  local required_keys=(
    STACK_NAME
    IMAGE_TAG
    FRONTEND_DOMAIN
    API_DOMAIN
    TRAEFIK_NETWORK
    TRAEFIK_ENTRYPOINT
    POSTGRES_DATABASE
    POSTGRES_USERNAME
    POSTGRES_PASSWORD
    POSTGRES_PORT
    POSTGRES_SSLMODE
    REDIS_PORT
    REDIS_DB
    REDIS_PASSWORD
    SECRET_KEY_BASE
    JWT_SECRET_KEY
    DOORKEEPER_JWT_SECRET_KEY
    EVOAI_CRM_API_TOKEN
    BOT_RUNTIME_SECRET
    ENCRYPTION_KEY
    MAILER_TYPE
    MAILER_SENDER_EMAIL
    SMTP_ADDRESS
    SMTP_PORT
    SMTP_DOMAIN
    SMTP_AUTHENTICATION
    SMTP_ENABLE_STARTTLS_AUTO
    SMTP_OPENSSL_VERIFY_MODE
    SMTP_USERNAME
    SMTP_PASSWORD
    MFA_ISSUER
    EVOLUTION_OPERATOR_EMAIL
  )

  for key in "${required_keys[@]}"; do
    if [[ -z "${!key:-}" ]]; then
      echo "Erro: variável obrigatória ausente ou vazia: ${key}" >&2
      exit 1
    fi
  done
}

require_cmd docker
require_cmd openssl
require_cmd python3

if [[ "$(docker info --format '{{.Swarm.LocalNodeState}}')" != "active" ]]; then
  echo "Erro: Docker Swarm não está ativo neste host." >&2
  exit 1
fi

for old_stack in "${OLD_STACKS_TO_WARN[@]}"; do
  if docker stack ls --format '{{.Name}}' | grep -qx "${old_stack}"; then
    echo "Aviso: stack antiga detectada: ${old_stack}"
    echo "Se ela estiver usando os mesmos domínios, remova antes:"
    echo "  docker stack rm ${old_stack}"
    echo
  fi
done

if docker network inspect "${TRAEFIK_NETWORK}" >/dev/null 2>&1; then
  NET_SCOPE="$(docker network inspect "${TRAEFIK_NETWORK}" --format '{{.Scope}}')"
  NET_DRIVER="$(docker network inspect "${TRAEFIK_NETWORK}" --format '{{.Driver}}')"

  if [[ "${NET_SCOPE}" != "swarm" || "${NET_DRIVER}" != "overlay" ]]; then
    echo "Erro: a rede ${TRAEFIK_NETWORK} existe, mas não é overlay/swarm." >&2
    echo "Driver atual: ${NET_DRIVER}" >&2
    echo "Scope atual:  ${NET_SCOPE}" >&2
    exit 1
  fi
else
  echo "Criando rede overlay externa: ${TRAEFIK_NETWORK}"
  docker network create --driver overlay --attachable "${TRAEFIK_NETWORK}"
fi

if [[ -f "${ENV_FILE}" ]]; then
  echo "Reutilizando segredos existentes em ${ENV_FILE}"

  set -a
  source "${ENV_FILE}"
  set +a

  restore_static_config

  SECRET_KEY_BASE="${SECRET_KEY_BASE:-$(openssl rand -hex 64)}"
  JWT_SECRET_KEY="${JWT_SECRET_KEY:-$(openssl rand -hex 64)}"
  DOORKEEPER_JWT_SECRET_KEY="${DOORKEEPER_JWT_SECRET_KEY:-$(openssl rand -hex 64)}"
  EVOAI_CRM_API_TOKEN="${EVOAI_CRM_API_TOKEN:-$(openssl rand -hex 32)}"
  BOT_RUNTIME_SECRET="${BOT_RUNTIME_SECRET:-$(openssl rand -hex 32)}"
  ENCRYPTION_KEY="${ENCRYPTION_KEY:-$(gen_fernet_key)}"
  POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(openssl rand -hex 16)}"
  REDIS_PASSWORD="${REDIS_PASSWORD:-$(openssl rand -hex 16)}"

  prompt_secret_if_empty SMTP_PASSWORD "Informe a senha SMTP"

  write_env_file
else
  echo "Gerando segredos iniciais em ${ENV_FILE}"

  prompt_secret_if_empty SMTP_PASSWORD "Informe a senha SMTP"

  SECRET_KEY_BASE="$(openssl rand -hex 64)"
  JWT_SECRET_KEY="$(openssl rand -hex 64)"
  DOORKEEPER_JWT_SECRET_KEY="$(openssl rand -hex 64)"
  EVOAI_CRM_API_TOKEN="$(openssl rand -hex 32)"
  BOT_RUNTIME_SECRET="$(openssl rand -hex 32)"
  ENCRYPTION_KEY="$(gen_fernet_key)"
  POSTGRES_PASSWORD="$(openssl rand -hex 16)"
  REDIS_PASSWORD="$(openssl rand -hex 16)"

  write_env_file
fi

set -a
source "${ENV_FILE}"
set +a

validate_required_env

cat > "${STACK_FILE}" <<'YAML'
version: "3.8"

services:
  evo_postgres:
    image: pgvector/pgvector:pg16
    environment:
      POSTGRES_DB: "${POSTGRES_DATABASE}"
      POSTGRES_USER: "${POSTGRES_USERNAME}"
      POSTGRES_PASSWORD: "${POSTGRES_PASSWORD}"
    volumes:
      - evocrm_pg_data:/var/lib/postgresql/data
    networks:
      evocrm_internal:
        aliases:
          - evo_postgres
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.role == manager
      restart_policy:
        condition: any

  evo_redis:
    image: redis:7-alpine
    command: sh -c "redis-server --appendonly yes --requirepass ${REDIS_PASSWORD}"
    volumes:
      - evocrm_redis_data:/data
    networks:
      evocrm_internal:
        aliases:
          - evo_redis
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.role == manager
      restart_policy:
        condition: any

  evo_gateway:
    image: evoapicloud/evo-crm-gateway:${IMAGE_TAG}
    environment:
      AUTH_UPSTREAM: "evo_auth:3001"
      CRM_UPSTREAM: "evo_crm:3000"
      CORE_UPSTREAM: "evo_core:5555"
      PROCESSOR_UPSTREAM: "evo_processor:8000"
      BOT_RUNTIME_UPSTREAM: "evo_bot_runtime:8080"
    networks:
      - public
      - evocrm_internal
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.role == manager
      restart_policy:
        condition: any
      labels:
        - traefik.enable=true
        - traefik.docker.network=${TRAEFIK_NETWORK}
        - traefik.http.routers.evocrm-api.rule=Host(`${API_DOMAIN}`)
        - traefik.http.routers.evocrm-api.entrypoints=${TRAEFIK_ENTRYPOINT}
        - traefik.http.routers.evocrm-api.middlewares=evocrm-api-fix
        - traefik.http.middlewares.evocrm-api-fix.replacepathregex.regex=^/api/v1/api/v1/(.*)
        - traefik.http.middlewares.evocrm-api-fix.replacepathregex.replacement=/api/v1/$$1
        - traefik.http.services.evocrm-api.loadbalancer.server.port=3030

  evo_auth:
    image: evoapicloud/evo-auth-service-community:${IMAGE_TAG}
    command: >
      sh -c "bundle exec rails db:migrate 2>&1 || true; bundle exec rails s -p 3001 -b 0.0.0.0"
    environment:
      RAILS_ENV: "production"
      RAILS_MAX_THREADS: "5"
      SECRET_KEY_BASE: "${SECRET_KEY_BASE}"
      JWT_SECRET_KEY: "${JWT_SECRET_KEY}"
      EVOAI_CRM_API_TOKEN: "${EVOAI_CRM_API_TOKEN}"
      POSTGRES_HOST: "evo_postgres"
      POSTGRES_PORT: "${POSTGRES_PORT}"
      POSTGRES_USERNAME: "${POSTGRES_USERNAME}"
      POSTGRES_PASSWORD: "${POSTGRES_PASSWORD}"
      POSTGRES_DATABASE: "${POSTGRES_DATABASE}"
      POSTGRES_SSLMODE: "${POSTGRES_SSLMODE}"
      REDIS_URL: "redis://:${REDIS_PASSWORD}@evo_redis:${REDIS_PORT}/0"
      FRONTEND_URL: "https://${FRONTEND_DOMAIN}"
      BACKEND_URL: "https://${API_DOMAIN}"
      CORS_ORIGINS: "https://${FRONTEND_DOMAIN},https://${API_DOMAIN}"
      MAILER_SENDER_EMAIL: "${MAILER_SENDER_EMAIL}"
      SMTP_ADDRESS: "${SMTP_ADDRESS}"
      SMTP_PORT: "${SMTP_PORT}"
      SMTP_DOMAIN: "${SMTP_DOMAIN}"
      SMTP_AUTHENTICATION: "${SMTP_AUTHENTICATION}"
      SMTP_ENABLE_STARTTLS_AUTO: "${SMTP_ENABLE_STARTTLS_AUTO}"
      SMTP_USERNAME: "${SMTP_USERNAME}"
      SMTP_PASSWORD: "${SMTP_PASSWORD}"
      SMTP_OPENSSL_VERIFY_MODE: "${SMTP_OPENSSL_VERIFY_MODE}"
      DOORKEEPER_JWT_SECRET_KEY: "${DOORKEEPER_JWT_SECRET_KEY}"
      DOORKEEPER_JWT_ALGORITHM: "hs256"
      DOORKEEPER_JWT_ISS: "evo-auth-service"
      MFA_ISSUER: "${MFA_ISSUER}"
      SIDEKIQ_CONCURRENCY: "10"
      ACTIVE_STORAGE_SERVICE: "local"
      ENCRYPTION_KEY: "${ENCRYPTION_KEY}"
      EVOLUTION_OPERATOR_EMAIL: "${EVOLUTION_OPERATOR_EMAIL}"
    networks:
      evocrm_internal:
        aliases:
          - evo_auth
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.role == manager
      restart_policy:
        condition: any

  evo_auth_sidekiq:
    image: evoapicloud/evo-auth-service-community:${IMAGE_TAG}
    command: ["bundle", "exec", "sidekiq", "-C", "config/sidekiq.yml"]
    healthcheck:
      disable: true
    environment:
      RAILS_ENV: "production"
      SERVICE_ROLE: "sidekiq"
      DISABLE_HEALTHCHECK: "true"
      SECRET_KEY_BASE: "${SECRET_KEY_BASE}"
      JWT_SECRET_KEY: "${JWT_SECRET_KEY}"
      EVOAI_CRM_API_TOKEN: "${EVOAI_CRM_API_TOKEN}"
      POSTGRES_HOST: "evo_postgres"
      POSTGRES_PORT: "${POSTGRES_PORT}"
      POSTGRES_USERNAME: "${POSTGRES_USERNAME}"
      POSTGRES_PASSWORD: "${POSTGRES_PASSWORD}"
      POSTGRES_DATABASE: "${POSTGRES_DATABASE}"
      POSTGRES_SSLMODE: "${POSTGRES_SSLMODE}"
      REDIS_URL: "redis://:${REDIS_PASSWORD}@evo_redis:${REDIS_PORT}/0"
      CORS_ORIGINS: "https://${FRONTEND_DOMAIN},https://${API_DOMAIN}"
      MAILER_SENDER_EMAIL: "${MAILER_SENDER_EMAIL}"
      SMTP_ADDRESS: "${SMTP_ADDRESS}"
      SMTP_PORT: "${SMTP_PORT}"
      SMTP_DOMAIN: "${SMTP_DOMAIN}"
      SMTP_AUTHENTICATION: "${SMTP_AUTHENTICATION}"
      SMTP_ENABLE_STARTTLS_AUTO: "${SMTP_ENABLE_STARTTLS_AUTO}"
      SMTP_USERNAME: "${SMTP_USERNAME}"
      SMTP_PASSWORD: "${SMTP_PASSWORD}"
      SMTP_OPENSSL_VERIFY_MODE: "${SMTP_OPENSSL_VERIFY_MODE}"
      DOORKEEPER_JWT_SECRET_KEY: "${DOORKEEPER_JWT_SECRET_KEY}"
      DOORKEEPER_JWT_ALGORITHM: "hs256"
      DOORKEEPER_JWT_ISS: "evo-auth-service"
      MFA_ISSUER: "${MFA_ISSUER}"
      SIDEKIQ_CONCURRENCY: "10"
      ACTIVE_STORAGE_SERVICE: "local"
      ENCRYPTION_KEY: "${ENCRYPTION_KEY}"
      EVOLUTION_OPERATOR_EMAIL: "${EVOLUTION_OPERATOR_EMAIL}"
    networks:
      evocrm_internal:
        aliases:
          - evo_auth_sidekiq
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.role == manager
      restart_policy:
        condition: any

  evo_crm:
    image: evoapicloud/evo-ai-crm-community:${IMAGE_TAG}
    command: >
      sh -c "until wget -qO- http://evo_auth:3001/health >/dev/null 2>&1; do sleep 5; done; bundle exec rails db:migrate 2>&1 || true; bundle exec rails s -p 3000 -b 0.0.0.0"
    environment:
      RAILS_ENV: "production"
      RAILS_SERVE_STATIC_FILES: "true"
      RAILS_LOG_TO_STDOUT: "true"
      SECRET_KEY_BASE: "${SECRET_KEY_BASE}"
      JWT_SECRET_KEY: "${JWT_SECRET_KEY}"
      EVOAI_CRM_API_TOKEN: "${EVOAI_CRM_API_TOKEN}"
      POSTGRES_HOST: "evo_postgres"
      POSTGRES_PORT: "${POSTGRES_PORT}"
      POSTGRES_USERNAME: "${POSTGRES_USERNAME}"
      POSTGRES_PASSWORD: "${POSTGRES_PASSWORD}"
      POSTGRES_DATABASE: "${POSTGRES_DATABASE}"
      POSTGRES_SSLMODE: "${POSTGRES_SSLMODE}"
      REDIS_URL: "redis://:${REDIS_PASSWORD}@evo_redis:${REDIS_PORT}/0"
      EVO_AUTH_SERVICE_URL: "http://evo_auth:3001"
      EVO_AI_CORE_SERVICE_URL: "http://evo_core:5555"
      BACKEND_URL: "https://${API_DOMAIN}"
      FRONTEND_URL: "https://${FRONTEND_DOMAIN}"
      CORS_ORIGINS: "https://${FRONTEND_DOMAIN},https://${API_DOMAIN}"
      DISABLE_TELEMETRY: "true"
      ENABLE_ACCOUNT_SIGNUP: "true"
      ENABLE_PUSH_RELAY_SERVER: "true"
      ENABLE_INBOX_EVENTS: "true"
      BOT_RUNTIME_URL: "http://evo_bot_runtime:8080"
      BOT_RUNTIME_SECRET: "${BOT_RUNTIME_SECRET}"
      BOT_RUNTIME_POSTBACK_BASE_URL: "http://evo_crm:3000"
      MAILER_TYPE: "${MAILER_TYPE}"
      MAILER_SENDER_EMAIL: "${MAILER_SENDER_EMAIL}"
      SMTP_ADDRESS: "${SMTP_ADDRESS}"
      SMTP_PORT: "${SMTP_PORT}"
      SMTP_DOMAIN: "${SMTP_DOMAIN}"
      SMTP_AUTHENTICATION: "${SMTP_AUTHENTICATION}"
      SMTP_ENABLE_STARTTLS_AUTO: "${SMTP_ENABLE_STARTTLS_AUTO}"
      SMTP_USERNAME: "${SMTP_USERNAME}"
      SMTP_PASSWORD: "${SMTP_PASSWORD}"
      SMTP_OPENSSL_VERIFY_MODE: "${SMTP_OPENSSL_VERIFY_MODE}"
    networks:
      evocrm_internal:
        aliases:
          - evo_crm
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.role == manager
      restart_policy:
        condition: any

  evo_crm_sidekiq:
    image: evoapicloud/evo-ai-crm-community:${IMAGE_TAG}
    command: ["bundle", "exec", "sidekiq", "-C", "config/sidekiq.yml"]
    healthcheck:
      disable: true
    environment:
      RAILS_ENV: "production"
      SECRET_KEY_BASE: "${SECRET_KEY_BASE}"
      JWT_SECRET_KEY: "${JWT_SECRET_KEY}"
      EVOAI_CRM_API_TOKEN: "${EVOAI_CRM_API_TOKEN}"
      POSTGRES_HOST: "evo_postgres"
      POSTGRES_PORT: "${POSTGRES_PORT}"
      POSTGRES_USERNAME: "${POSTGRES_USERNAME}"
      POSTGRES_PASSWORD: "${POSTGRES_PASSWORD}"
      POSTGRES_DATABASE: "${POSTGRES_DATABASE}"
      POSTGRES_SSLMODE: "${POSTGRES_SSLMODE}"
      REDIS_URL: "redis://:${REDIS_PASSWORD}@evo_redis:${REDIS_PORT}/0"
      EVO_AUTH_SERVICE_URL: "http://evo_auth:3001"
      EVO_AI_CORE_SERVICE_URL: "http://evo_core:5555"
      FRONTEND_URL: "https://${FRONTEND_DOMAIN}"
      BACKEND_URL: "https://${API_DOMAIN}"
      CORS_ORIGINS: "https://${FRONTEND_DOMAIN},https://${API_DOMAIN}"
      BOT_RUNTIME_URL: "http://evo_bot_runtime:8080"
      BOT_RUNTIME_SECRET: "${BOT_RUNTIME_SECRET}"
      BOT_RUNTIME_POSTBACK_BASE_URL: "http://evo_crm:3000"
      MAILER_TYPE: "${MAILER_TYPE}"
      MAILER_SENDER_EMAIL: "${MAILER_SENDER_EMAIL}"
      SMTP_ADDRESS: "${SMTP_ADDRESS}"
      SMTP_PORT: "${SMTP_PORT}"
      SMTP_DOMAIN: "${SMTP_DOMAIN}"
      SMTP_AUTHENTICATION: "${SMTP_AUTHENTICATION}"
      SMTP_ENABLE_STARTTLS_AUTO: "${SMTP_ENABLE_STARTTLS_AUTO}"
      SMTP_USERNAME: "${SMTP_USERNAME}"
      SMTP_PASSWORD: "${SMTP_PASSWORD}"
      SMTP_OPENSSL_VERIFY_MODE: "${SMTP_OPENSSL_VERIFY_MODE}"
    networks:
      evocrm_internal:
        aliases:
          - evo_crm_sidekiq
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.role == manager
      restart_policy:
        condition: any

  evo_core:
    image: evoapicloud/evo-ai-core-service-community:${IMAGE_TAG}
    environment:
      DB_HOST: "evo_postgres"
      DB_PORT: "${POSTGRES_PORT}"
      DB_USER: "${POSTGRES_USERNAME}"
      DB_PASSWORD: "${POSTGRES_PASSWORD}"
      DB_NAME: "${POSTGRES_DATABASE}"
      DB_SSLMODE: "${POSTGRES_SSLMODE}"
      PORT: "5555"
      SECRET_KEY_BASE: "${SECRET_KEY_BASE}"
      JWT_SECRET_KEY: "${JWT_SECRET_KEY}"
      JWT_ALGORITHM: "HS256"
      ENCRYPTION_KEY: "${ENCRYPTION_KEY}"
      EVOLUTION_BASE_URL: "http://evo_crm:3000"
      EVO_AUTH_BASE_URL: "http://evo_auth:3001"
      AI_PROCESSOR_URL: "http://evo_processor:8000"
      AI_PROCESSOR_VERSION: "v1"
    networks:
      evocrm_internal:
        aliases:
          - evo_core
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.role == manager
      restart_policy:
        condition: any

  evo_processor:
    image: evoapicloud/evo-ai-processor-community:${IMAGE_TAG}
    command: >
      sh -c "alembic upgrade head 2>&1 || true; python -m scripts.run_seeders; uvicorn src.main:app --host \$$HOST --port \$$PORT"
    environment:
      POSTGRES_CONNECTION_STRING: "postgresql://${POSTGRES_USERNAME}:${POSTGRES_PASSWORD}@evo_postgres:${POSTGRES_PORT}/${POSTGRES_DATABASE}?sslmode=${POSTGRES_SSLMODE}"
      REDIS_HOST: "evo_redis"
      REDIS_PORT: "${REDIS_PORT}"
      REDIS_PASSWORD: "${REDIS_PASSWORD}"
      REDIS_SSL: "false"
      REDIS_DB: "${REDIS_DB}"
      REDIS_KEY_PREFIX: "a2a:"
      REDIS_TTL: "3600"
      HOST: "0.0.0.0"
      PORT: "8000"
      DEBUG: "false"
      SECRET_KEY_BASE: "${SECRET_KEY_BASE}"
      ENCRYPTION_KEY: "${ENCRYPTION_KEY}"
      EVOAI_CRM_API_TOKEN: "${EVOAI_CRM_API_TOKEN}"
      EVO_AI_CRM_URL: "http://evo_crm:3000"
      CORE_SERVICE_URL: "http://evo_core:5555/api/v1"
      APP_URL: "https://${API_DOMAIN}"
      API_URL: "https://${API_DOMAIN}"
      API_TITLE: "Agent Processor Community"
      API_DESCRIPTION: "Agent Processor Community for Evo AI"
      API_VERSION: "1.0.0"
      ORGANIZATION_NAME: "Evo CRM"
    volumes:
      - evocrm_processor_logs:/app/logs
    networks:
      evocrm_internal:
        aliases:
          - evo_processor
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.role == manager
      restart_policy:
        condition: any

  evo_bot_runtime:
    image: evoapicloud/evo-bot-runtime:${IMAGE_TAG}
    environment:
      LISTEN_ADDR: "0.0.0.0:8080"
      REDIS_URL: "redis://:${REDIS_PASSWORD}@evo_redis:${REDIS_PORT}/0"
      AI_PROCESSOR_URL: "http://evo_processor:8000"
      BOT_RUNTIME_SECRET: "${BOT_RUNTIME_SECRET}"
      AI_CALL_TIMEOUT_SECONDS: "30"
    networks:
      evocrm_internal:
        aliases:
          - evo_bot_runtime
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.role == manager
      restart_policy:
        condition: any

  evo_frontend:
    image: evoapicloud/evo-ai-frontend-community:${IMAGE_TAG}
    environment:
      VITE_APP_ENV: "production"
      VITE_API_URL: "https://${API_DOMAIN}"
      VITE_AUTH_API_URL: "https://${API_DOMAIN}"
      VITE_EVOAI_API_URL: "https://${API_DOMAIN}"
      VITE_AGENT_PROCESSOR_URL: "https://${API_DOMAIN}"
      VITE_WS_URL: "https://${API_DOMAIN}"
    networks:
      - public
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.role == manager
      restart_policy:
        condition: any
      labels:
        - traefik.enable=true
        - traefik.docker.network=${TRAEFIK_NETWORK}
        - traefik.http.routers.evocrm-frontend.rule=Host(`${FRONTEND_DOMAIN}`)
        - traefik.http.routers.evocrm-frontend.entrypoints=${TRAEFIK_ENTRYPOINT}
        - traefik.http.services.evocrm-frontend.loadbalancer.server.port=80

networks:
  public:
    external: true
  evocrm_internal:
    driver: overlay

volumes:
  evocrm_pg_data:
    name: evocrm_pg_data
  evocrm_redis_data:
    name: evocrm_redis_data
  evocrm_processor_logs:
    name: evocrm_processor_logs
YAML

echo "Validando stack..."
docker stack config -c "${STACK_FILE}" >/dev/null

echo "Subindo stack..."
docker stack deploy -c "${STACK_FILE}" "${STACK_NAME}"

cat <<EOF

Stack enviada com sucesso.

Arquivos:
  Stack:    ${STACK_FILE}
  Segredos: ${ENV_FILE}

URLs públicas:
  Frontend: https://${FRONTEND_DOMAIN}
  API:      https://${API_DOMAIN}

Próximos passos:
  1) acompanhe a subida:
     docker stack services ${STACK_NAME}
     docker stack ps ${STACK_NAME}

  2) seed inicial do auth:
     AUTH_CONTAINER=\$(docker ps --filter label=com.docker.swarm.service.name=${STACK_NAME}_evo_auth -q | head -n1)
     docker exec -it "\$AUTH_CONTAINER" sh -lc 'bundle exec rails db:prepare && bundle exec rails db:seed'

  3) force restart após o seed:
     docker service update --force ${STACK_NAME}_evo_auth
     docker service update --force ${STACK_NAME}_evo_auth_sidekiq
     docker service update --force ${STACK_NAME}_evo_crm
     docker service update --force ${STACK_NAME}_evo_crm_sidekiq
     docker service update --force ${STACK_NAME}_evo_core
     docker service update --force ${STACK_NAME}_evo_processor
     docker service update --force ${STACK_NAME}_evo_bot_runtime
     docker service update --force ${STACK_NAME}_evo_gateway
     docker service update --force ${STACK_NAME}_evo_frontend

Logs úteis:
  docker service logs -f ${STACK_NAME}_evo_gateway
  docker service logs -f ${STACK_NAME}_evo_frontend
  docker service logs -f ${STACK_NAME}_evo_auth
  docker service logs -f ${STACK_NAME}_evo_crm
EOF

