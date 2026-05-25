#!/usr/bin/env bash
# -------------------------------------------
# Specialist: check-deps
# Summary: Versões de Docker, Compose, curl, jq, sudo, timeout, getent + NTP
# -------------------------------------------
# Verifica que todas as ferramentas locais necessárias estão instaladas e
# em versão compatível. Read-only — não modifica nada.
#
# Espelha a Fase 1 do siscan-server-setup.sh sem duplicar a lógica de
# correção (a setup faz exit com instruções de instalação; aqui só reporta).
# -------------------------------------------

set -uo pipefail

SPECIALIST_NAME="check-deps"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./_common.sh
source "$SCRIPT_DIR/_common.sh"

usage() {
    cat <<EOF
Uso: bash $(basename "$0") [--quiet | --json] [--help]

Verifica disponibilidade local de: docker, docker compose, curl, jq,
sudo, openssl, timeout, getent, e sincronização NTP do relógio.

Exit code: 0 = OK · 1 = pelo menos uma dependência ausente · 2 = uso inválido
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        *)
            if common_parse_arg "$@"; then shift "$shift_count"
            else echo "argumento desconhecido: $1" >&2; usage >&2; exit 2; fi
            ;;
    esac
done

CAT_RUNTIME="Container runtime (Docker)"
CAT_NETWORK="Network tools"
CAT_SYSTEM="Sistema"
CAT_TIME="Sincronização de tempo"

# _check_bin CATEGORY NAME VERSION_CMD
# Reporta presença e (se disponível) versão do binário.
_check_bin() {
    local category="$1" name="$2" version_cmd="${3:-}"
    if command -v "$name" >/dev/null 2>&1; then
        local ver=""
        if [ -n "$version_cmd" ]; then
            ver=$(eval "$version_cmd" 2>/dev/null | head -1)
        fi
        add_ok "$category" cmd 0 "$name" "${ver:-presente}"
    else
        add_fail "$category" cmd 0 "$name" "binário ausente — instale com: sudo apt install -y $name"
    fi
}

# Container runtime
print_category_header "$CAT_RUNTIME" "Docker Engine e plugin Compose v2 — pré-requisitos para subir qualquer stack do projeto."
if command -v docker >/dev/null 2>&1; then
    docker_ver=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "")
    if [ -n "$docker_ver" ]; then
        major=$(echo "$docker_ver" | cut -d. -f1)
        if [ "$major" -ge 24 ] 2>/dev/null; then
            add_ok "$CAT_RUNTIME" cmd 0 "docker" "$docker_ver"
        else
            add_ok "$CAT_RUNTIME" cmd 0 "docker" "$docker_ver (recomendado >= 24)"
        fi
    else
        add_fail "$CAT_RUNTIME" cmd 0 "docker" "daemon não acessível"
    fi
else
    add_fail "$CAT_RUNTIME" cmd 0 "docker" "binário ausente"
fi

if docker compose version >/dev/null 2>&1; then
    compose_ver=$(docker compose version --short 2>/dev/null || echo "presente")
    add_ok "$CAT_RUNTIME" cmd 0 "docker compose" "$compose_ver"
else
    add_fail "$CAT_RUNTIME" cmd 0 "docker compose" "plugin v2 ausente — sudo apt install docker-compose-plugin"
fi

# Network tools
print_category_header "$CAT_NETWORK" "Ferramentas usadas pelo check-network e por scripts de geração de chave/manipulação de JSON."
_check_bin "$CAT_NETWORK" curl    "curl --version | head -1 | awk '{print \$2}'"
_check_bin "$CAT_NETWORK" jq      "jq --version | head -1"
_check_bin "$CAT_NETWORK" openssl "openssl version | awk '{print \$2}'"

# Sistema
print_category_header "$CAT_SYSTEM" "Comandos básicos usados pelo siscan-server-setup.sh e pelos specialists."
_check_bin "$CAT_SYSTEM" sudo    "sudo --version | head -1 | awk '{print \$3}'"
_check_bin "$CAT_SYSTEM" timeout "timeout --version | head -1 | awk '{print \$NF}'"
_check_bin "$CAT_SYSTEM" getent  ""
_check_bin "$CAT_SYSTEM" git     "git --version | awk '{print \$3}'"

# Sistema operacional (DEPLOY_SERVER.md pré-req: Ubuntu 24.04 LTS)
CAT_OS="Sistema operacional"
print_category_header "$CAT_OS" "Ubuntu 24.04 LTS é o alvo testado no DEPLOY_SERVER.md — versões mais antigas podem ter Docker/Compose desatualizados."
os_id=""
os_ver=""
if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    os_id=$(grep -E '^ID=' /etc/os-release | head -1 | cut -d= -f2 | tr -d '"')
    os_ver=$(grep -E '^VERSION_ID=' /etc/os-release | head -1 | cut -d= -f2 | tr -d '"')
fi

if [ -z "$os_id" ]; then
    add_fail "$CAT_OS" os 0 "OS" "/etc/os-release ausente — não dá pra identificar a distro"
elif [ "$os_id" = "ubuntu" ]; then
    # Compara major version (24, 22, 20...)
    os_major="${os_ver%%.*}"
    if [ "$os_major" -ge 24 ] 2>/dev/null; then
        add_ok "$CAT_OS" os 0 "Ubuntu $os_ver" "alvo do DEPLOY_SERVER.md"
    elif [ "$os_major" -ge 22 ] 2>/dev/null; then
        add_ok "$CAT_OS" os 0 "Ubuntu $os_ver" "anterior ao alvo (24.04) mas suportado — pode ter Docker/Compose desatualizados"
    else
        add_fail "$CAT_OS" os 0 "Ubuntu $os_ver" "muito antiga — DEPLOY_SERVER.md exige 24.04 LTS"
    fi
else
    add_fail "$CAT_OS" os 0 "$os_id $os_ver" "distro não testada — DEPLOY_SERVER.md exige Ubuntu 24.04 LTS"
fi

# Sincronização de tempo
print_category_header "$CAT_TIME" "Clock dessincronizado causa SSL_ERROR_SYSCALL no TLS — sintoma típico relatado no chat do servidor parceiro em 06/05."
# Em ambientes sem systemd (WSL, containers), timedatectl falha — skip controlado
# (não conta como FAIL, mas avisa).
if command -v timedatectl >/dev/null 2>&1; then
    tdc_out=$(timedatectl status 2>&1)
    tdc_rc=$?
    if [ "$tdc_rc" -ne 0 ]; then
        warn "timedatectl indisponível ($(echo "$tdc_out" | head -1)) — pulando check de NTP"
    elif echo "$tdc_out" | grep -q 'System clock synchronized: yes'; then
        add_ok "$CAT_TIME" cmd 0 "timedatectl" "clock sincronizado"
    else
        # Coerente com a intenção declarada no comentário acima ('não conta como FAIL')
        # e com warn() das duas branches vizinhas. NTP fora de sync é forte indicador
        # de problemas de TLS, mas não impede o setup de prosseguir.
        add_ok "$CAT_TIME" cmd 0 "timedatectl" "clock NÃO sincronizado (warn) — pode causar SSL_ERROR_SYSCALL no TLS; sudo timedatectl set-ntp true"
    fi
else
    warn "timedatectl não instalado — pulando check de NTP"
fi

render_results
finalize_exit
