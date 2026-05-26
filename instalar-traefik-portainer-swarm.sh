#!/usr/bin/env bash
set -euo pipefail

# ===== AJUSTE AQUI =====
MANAGER_IP="192.168.0.53"
ACME_EMAIL="nayara.lino@gmail.com"
TRAEFIK_DOMAIN="tk.cicloia.shop"
PORTAINER_DOMAIN="pn.cicloia.shop"
TRAEFIK_USER="admin"
TRAEFIK_PASS="&2f4<:E4tc6s"
# =======================

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker nao encontrado."
  exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "openssl nao encontrado."
  exit 1
fi

SWARM_STATE="$(docker info --format '{{.Swarm.LocalNodeState}}')"

if [ "$SWARM_STATE" != "active" ]; then
  echo "Inicializando Swarm..."
  docker swarm init --advertise-addr "$MANAGER_IP"
else
  echo "Swarm ja esta ativo."
fi

echo "Criando redes overlay..."
docker network inspect public >/dev/null 2>&1 || docker network create --driver overlay public
docker network inspect agent_network >/dev/null 2>&1 || docker network create --driver overlay agent_network

echo "Criando volume do Portainer..."
docker volume inspect portainer_data >/dev/null 2>&1 || docker volume create portainer_data

echo "Preparando armazenamento do Let's Encrypt..."
mkdir -p /opt/swarm/traefik/letsencrypt
touch /opt/swarm/traefik/letsencrypt/acme.json
chmod 600 /opt/swarm/traefik/letsencrypt/acme.json

AUTH_HASH=$(openssl passwd -apr1 "$TRAEFIK_PASS" | sed 's/\$/$$/g')

echo "Gerando stack do Traefik..."
cat > /opt/swarm/traefik-stack.yml <<YAML
version: "3.8"

services:
  traefik:
    image: traefik:v3.4
    command:
      - --global.sendanonymoususage=false
      - --log.level=INFO
      - --accesslog=true
      - --api.dashboard=true
      - --providers.swarm.endpoint=unix:///var/run/docker.sock
      - --providers.swarm.exposedbydefault=false
      - --providers.swarm.network=public
      - --entrypoints.web.address=:80
      - --entrypoints.websecure.address=:443
      - --certificatesresolvers.le.acme.email=${ACME_EMAIL}
      - --certificatesresolvers.le.acme.storage=/letsencrypt/acme.json
      - --certificatesresolvers.le.acme.httpchallenge=true
      - --certificatesresolvers.le.acme.httpchallenge.entrypoint=web
    ports:
      - target: 80
        published: 80
        protocol: tcp
        mode: ingress
      - target: 443
        published: 443
        protocol: tcp
        mode: ingress
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /opt/swarm/traefik/letsencrypt:/letsencrypt
    networks:
      - public
    deploy:
      mode: replicated
      replicas: 1
      placement:
        constraints:
          - node.role == manager
      labels:
        - traefik.enable=true

        - traefik.http.routers.http-catchall.rule=HostRegexp(\`{host:.+}\`)
        - traefik.http.routers.http-catchall.entrypoints=web
        - traefik.http.routers.http-catchall.middlewares=redirect-to-https
        - traefik.http.middlewares.redirect-to-https.redirectscheme.scheme=https

        - traefik.http.routers.traefik.rule=Host(\`${TRAEFIK_DOMAIN}\`) && (PathPrefix(\`/api\`) || PathPrefix(\`/dashboard\`))
        - traefik.http.routers.traefik.entrypoints=websecure
        - traefik.http.routers.traefik.tls=true
        - traefik.http.routers.traefik.tls.certresolver=le
        - traefik.http.routers.traefik.service=api@internal
        - traefik.http.routers.traefik.middlewares=traefik-auth
        - traefik.http.middlewares.traefik-auth.basicauth.users=${TRAEFIK_USER}:${AUTH_HASH}

        # dummy service exigido no dashboard em swarm
        - traefik.http.services.traefik-dummy.loadbalancer.server.port=9999

networks:
  public:
    external: true
YAML

echo "Gerando stack do Portainer..."
cat > /opt/swarm/portainer-stack.yml <<YAML
version: "3.8"

services:
  agent:
    image: portainer/agent:lts
    environment:
      AGENT_CLUSTER_ADDR: tasks.agent
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /var/lib/docker/volumes:/var/lib/docker/volumes
    networks:
      - agent_network
    deploy:
      mode: global
      placement:
        constraints:
          - node.platform.os == linux

  portainer:
    image: portainer/portainer-ce:lts
    command: -H tcp://tasks.agent:9001 --tlsskipverify
    volumes:
      - portainer_data:/data
    networks:
      - public
      - agent_network
    deploy:
      mode: replicated
      replicas: 1
      placement:
        constraints:
          - node.role == manager
      labels:
        - traefik.enable=true
        - traefik.http.routers.portainer.rule=Host(\`${PORTAINER_DOMAIN}\`)
        - traefik.http.routers.portainer.entrypoints=websecure
        - traefik.http.routers.portainer.tls=true
        - traefik.http.routers.portainer.tls.certresolver=le
        - traefik.http.services.portainer.loadbalancer.server.port=9000

volumes:
  portainer_data:
    external: true

networks:
  public:
    external: true
  agent_network:
    external: true
YAML

echo "Deployando Traefik..."
docker stack deploy -c /opt/swarm/traefik-stack.yml traefik

echo "Aguardando Traefik subir..."
sleep 8

echo "Deployando Portainer..."
docker stack deploy -c /opt/swarm/portainer-stack.yml portainer

echo
echo "Concluido."
echo "Traefik dashboard: https://${TRAEFIK_DOMAIN}/dashboard/"
echo "Portainer:         https://${PORTAINER_DOMAIN}"
echo
echo "Verifique:"
echo "  docker service ls"
echo "  docker service logs -f traefik_traefik"
echo "  docker service logs -f portainer_portainer"
