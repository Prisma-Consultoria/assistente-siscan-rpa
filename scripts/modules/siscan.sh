#!/usr/bin/env bash
# siscan.sh - pull image, configure volumes and deploy Assistente SISCan RPA

set -euo pipefail

module_main() {
  IMAGE="${REGISTRY:-} /prisma-consultoria/assistente-siscan-rpa:latest"
  # sanitize whitespace if REGISTRY empty
  IMAGE=$(echo "$IMAGE" | sed -E 's@ +@/@g; s@/+@/@g; s@^/@')

  DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/assistente-siscan/data"
  COMPOSE_FILE="${XDG_DATA_HOME:-$HOME/.local/share}/assistente-siscan/docker-compose.yml"

  mkdir -p "$DATA_DIR"

  echo "Baixando imagem $IMAGE (pode demorar)..."
  if ! docker pull "$IMAGE"; then
    echo "Falha ao puxar imagem $IMAGE" >&2
  fi

  cat > "$COMPOSE_FILE" <<EOF
version: '3.8'
services:
  assistente-siscan-rpa:
    image: $IMAGE
    restart: unless-stopped
    environment:
      - SISCAN_USER=${SISCAN_USER:-}
      - SISCAN_PASS=${SISCAN_PASS:-}
    volumes:
      - $DATA_DIR:/app/data
    ports:
      - "8080:8080"
EOF

  echo "Iniciando serviço via docker compose..."
  if ! docker compose -f "$COMPOSE_FILE" up -d --remove-orphans; then
    echo "docker compose up falhou" >&2
  fi

  return 0
}
