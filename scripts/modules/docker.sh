#!/usr/bin/env bash
# docker.sh - validate docker & compose, login to registry (non-echoing)

set -euo pipefail

module_main() {
  echo "Validando Docker e Docker Compose..."
  if ! command -v docker >/dev/null 2>&1; then
    echo "Docker não encontrado. Instale Docker antes." >&2
    return 1
  fi

  if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
    echo "Docker Compose não encontrado. Instale Docker Compose." >&2
    return 1
  fi

  if [ -n "${TOKEN:-}" ] && [ -n "${REGISTRY:-}" ]; then
    echo "Efetuando login no registro privado (token não será exibido)..."
    # GHCR (GitHub Container Registry)
    if [[ "$REGISTRY" == *ghcr.io* ]]; then
      if [ -z "${REGISTRY_USER:-}" ]; then
        echo "Aviso: GHCR geralmente requer REGISTRY_USER (GitHub username)" >&2
      fi
      printf '%s' "$TOKEN" | docker login ghcr.io --username "${REGISTRY_USER:-}" --password-stdin

    # Azure ACR (try az acr login if available)
    elif [[ "$REGISTRY" == *.azurecr.io* ]]; then
      if command -v az >/dev/null 2>&1; then
        ACR_NAME=$(echo "$REGISTRY" | cut -d'.' -f1)
        if ! az acr login --name "$ACR_NAME" >/dev/null 2>&1; then
          echo "az acr login falhou; tentando docker login com credenciais" >&2
          if [ -n "${REGISTRY_USER:-}" ]; then
            printf '%s' "$TOKEN" | docker login "$REGISTRY" --username "${REGISTRY_USER}" --password-stdin
          fi
        fi
      else
        if [ -n "${REGISTRY_USER:-}" ]; then
          printf '%s' "$TOKEN" | docker login "$REGISTRY" --username "${REGISTRY_USER}" --password-stdin
        fi
      fi

    # AWS ECR
    elif [[ "$REGISTRY" =~ \.dkr\.ecr\. ]]; then
      if command -v aws >/dev/null 2>&1; then
        aws ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY"
      else
        echo "AWS CLI não encontrado; não foi possível autenticar no ECR" >&2
      fi

    else
      if [ -n "${REGISTRY_USER:-}" ]; then
        printf '%s' "$TOKEN" | docker login "$REGISTRY" --username "${REGISTRY_USER}" --password-stdin
      else
        if ! printf '%s' "$TOKEN" | docker login "$REGISTRY" --username oauth2 --password-stdin 2>/dev/null; then
          echo "Aviso: login com 'oauth2' falhou. Forneça REGISTRY_USER se necessário." >&2
        fi
      fi
    fi
  fi

  return 0
}
