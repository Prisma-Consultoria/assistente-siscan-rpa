#!/usr/bin/env bash
# install.sh - Remote installer bootstrap for Assistente SISCan RPA
#
# Usage:
# curl -sSL https://raw.githubusercontent.com/Prisma-Consultoria/assistente-siscan-rpa/main/install.sh | bash
#
set -euo pipefail
IFS=$'\n\t'

REPO_BASE="https://raw.githubusercontent.com/Prisma-Consultoria/assistente-siscan-rpa/main"
CACHE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/assistente-siscan/installer-cache"

ensure_dir() { mkdir -p "$1"; }
ensure_dir "$CACHE_DIR"

download_module() {
  local module_path="$1" dest="$2" url
  url="$REPO_BASE/$module_path"
  if curl -fsSL "$url" -o "$dest"; then
    return 0
  else
    return 1
  fi
}

download_checksums() {
  local dest="$CACHE_DIR/checksums.txt" url
  url="$REPO_BASE/scripts/checksums.txt"
  if curl -fsSL "$url" -o "$dest"; then
    echo "$dest"
  else
    echo "" 
  fi
}

verify_file_checksum() {
  local file="$1" checksums="$2" fname expected actual
  if [ -z "$checksums" ] || [ ! -f "$checksums" ]; then
    return 0
  fi
  fname=$(basename "$file")
  expected=$(grep -E "[a-fA-F0-9]{64}\s+${fname}$" "$checksums" | awk '{print $1}' || true)
  if [ -z "$expected" ]; then
    return 0
  fi
  actual=$(sha256sum "$file" | awk '{print $1}')
  if [ "$actual" != "$expected" ]; then
    echo "Checksum mismatch for $fname (expected $expected, got $actual)" >&2
    return 1
  fi
  return 0
}

read_secret() {
  local prompt="$1"
  read -r -s -p "$prompt: " val
  echo
  printf '%s' "$val"
}

load_and_run_module() {
  local relpath="$1" dest
  dest="$CACHE_DIR/$(basename "$relpath")"
  checksums=$(download_checksums)

  if ! download_module "$relpath" "$dest"; then
    if [ ! -f "$dest" ]; then
      echo "Failed to download $relpath and no cache present." >&2
      return 1
    else
      echo "Using cached module $(basename "$relpath")" >&2
    fi
  fi

  if ! verify_file_checksum "$dest" "$checksums"; then
    echo "Checksum verification failed for $dest" >&2
    return 1
  fi

  # shellcheck source=/dev/null
  . "$dest"
  if declare -f module_main >/dev/null 2>&1; then
    module_main
    return 0
  else
    echo "Module $relpath does not implement module_main" >&2
    return 1
  fi
}

main() {
  echo "Assistente SISCan RPA - Instalador"

  read -r -p "Registry URL (ex: ghcr.io or registry.example.com): " registry
  read -r -p "Registry usuário (deixe em branco para token-only): " registry_user
  token=$(read_secret "Token para imagem privada (entrada oculta)")

  read -r -p "SISCan usuário: " siscan_user
  siscan_pass=$(read_secret "SISCan senha (entrada oculta)")

  export REGISTRY="$registry"
  export REGISTRY_USER="$registry_user"
  export TOKEN="$token"
  export SISCAN_USER="$siscan_user"
  export SISCAN_PASS="$siscan_pass"

  if ! load_and_run_module "scripts/modules/docker.sh"; then
    echo "Docker module failed. Aborting." >&2
    exit 1
  fi

  if ! load_and_run_module "scripts/modules/siscan.sh"; then
    echo "SISCan module failed. Aborting." >&2
    exit 1
  fi

  echo "Instalação concluída."
}

main "$@"
