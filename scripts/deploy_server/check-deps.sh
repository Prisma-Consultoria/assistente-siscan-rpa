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
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# PRODUCTS_FILE overridável por env (testabilidade); default = manifesto do repo.
PRODUCTS_FILE="${PRODUCTS_FILE:-${REPO_ROOT}/scripts/data/products.json}"

# shellcheck source=./_common.sh
source "$SCRIPT_DIR/_common.sh"

usage() {
    cat <<EOF
Uso: bash $(basename "$0") [--quiet | --json] [--help]

Verifica versão do Docker Engine e do plugin Docker Compose (comparada com o
piso do manifesto), a versão do Ubuntu, a sincronização NTP do relógio e a
disponibilidade dos binários genéricos exigidos. A lista de binários e os
limiares de versão vêm de scripts/data/products.json
(.defaults.host_requirements: required_binaries, min/recommended_docker_major,
min_compose_version, ubuntu_target/supported_major).

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

# ────────────────────────────────────────────────────────────────────────────
# Requisitos de host (GLOBAIS — iguais para todo produto). Fonte única da
# verdade: scripts/data/products.json (.defaults.host_requirements). NÃO há
# limiares hardcoded como configuração (issue #113).
#
# Bootstrap: check-deps é justamente o specialist que detecta jq ausente. Sem
# jq o manifesto é ilegível — então mantemos um fallback mínimo (idêntico aos
# valores do manifesto) só pra não travar o diagnóstico nesse cenário; o próprio
# jq ausente já é reportado como FAIL na seção Network tools abaixo.
# ────────────────────────────────────────────────────────────────────────────
# hostreq (lê .defaults.host_requirements.KEY) vem de _common.sh (#113) — evita
# duplicar a função idêntica em check-deps e check-db.
MIN_DOCKER_MAJOR=""
RECOMMENDED_DOCKER_MAJOR=""
MIN_COMPOSE_VERSION=""
UBUNTU_TARGET_MAJOR=""
UBUNTU_SUPPORTED_MAJOR=""
REQUIRED_BINARIES=()
if command -v jq >/dev/null 2>&1 && [ -f "$PRODUCTS_FILE" ]; then
    MIN_DOCKER_MAJOR=$(hostreq min_docker_major)
    RECOMMENDED_DOCKER_MAJOR=$(hostreq recommended_docker_major)
    MIN_COMPOSE_VERSION=$(hostreq min_compose_version)
    UBUNTU_TARGET_MAJOR=$(hostreq ubuntu_target_major)
    UBUNTU_SUPPORTED_MAJOR=$(hostreq ubuntu_supported_major)
    while IFS= read -r _bin; do
        [ -n "$_bin" ] && REQUIRED_BINARIES+=("$_bin")
    done < <(jq -r '.defaults.host_requirements.required_binaries[]? // empty' "$PRODUCTS_FILE" 2>/dev/null)
fi
# Fallback de bootstrap (jq ausente / manifesto ilegível) — modo degradado, não
# é a fonte da verdade; mantém os valores em paridade com o manifesto.
: "${MIN_DOCKER_MAJOR:=24}"
: "${RECOMMENDED_DOCKER_MAJOR:=28}"
: "${MIN_COMPOSE_VERSION:=2.37}"
: "${UBUNTU_TARGET_MAJOR:=24}"
: "${UBUNTU_SUPPORTED_MAJOR:=22}"
if [ "${#REQUIRED_BINARIES[@]}" -eq 0 ]; then
    REQUIRED_BINARIES=(curl jq openssl sudo timeout getent git)
fi

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
        # Camadas (manifesto): >= recomendado (alvo) ok; entre piso e alvo = aviso;
        # abaixo do piso = aviso mais forte (advisory — versão não bloqueia o deploy).
        major=$(echo "$docker_ver" | cut -d. -f1)
        if [ "$major" -ge "$RECOMMENDED_DOCKER_MAJOR" ] 2>/dev/null; then
            add_ok "$CAT_RUNTIME" cmd 0 "docker" "$docker_ver"
        elif [ "$major" -ge "$MIN_DOCKER_MAJOR" ] 2>/dev/null; then
            add_ok "$CAT_RUNTIME" cmd 0 "docker" "$docker_ver (warn) — atende o piso ${MIN_DOCKER_MAJOR}, recomendado >= ${RECOMMENDED_DOCKER_MAJOR}"
        else
            add_ok "$CAT_RUNTIME" cmd 0 "docker" "$docker_ver (warn) — abaixo do piso ${MIN_DOCKER_MAJOR}; recomendado >= ${RECOMMENDED_DOCKER_MAJOR}"
        fi
    else
        add_fail "$CAT_RUNTIME" cmd 0 "docker" "daemon não acessível"
    fi
else
    add_fail "$CAT_RUNTIME" cmd 0 "docker" "binário ausente"
fi

if docker compose version >/dev/null 2>&1; then
    compose_ver=$(docker compose version --short 2>/dev/null || echo "")
    if [ -z "$compose_ver" ]; then
        add_ok "$CAT_RUNTIME" cmd 0 "docker compose" "presente (versão não detectável)"
    else
        # Compara com o piso do manifesto via sort -V (lida com sufixos tipo
        # 2.38.1-desktop.1). Abaixo do piso = aviso não-bloqueante.
        compose_num="${compose_ver#v}"
        if [ "$(printf '%s\n%s\n' "$MIN_COMPOSE_VERSION" "$compose_num" | sort -V | head -1)" = "$MIN_COMPOSE_VERSION" ]; then
            add_ok "$CAT_RUNTIME" cmd 0 "docker compose" "$compose_ver (>= ${MIN_COMPOSE_VERSION})"
        else
            add_ok "$CAT_RUNTIME" cmd 0 "docker compose" "$compose_ver (warn) — abaixo do recomendado ${MIN_COMPOSE_VERSION}"
        fi
    fi
else
    add_fail "$CAT_RUNTIME" cmd 0 "docker compose" "plugin v2 ausente — sudo apt install docker-compose-plugin"
fi

# Binários genéricos: QUAIS verificar vem do manifesto
# (.defaults.host_requirements.required_binaries, #113). A categoria e o comando
# de versão de cada um são apresentação/lógica de shell — ficam no specialist,
# resolvidos por nome. Imprime o cabeçalho da categoria quando ela muda
# (a ordem do manifesto agrupa por categoria).
_bin_category() {
    case "$1" in
        curl|jq|openssl)         echo "$CAT_NETWORK" ;;
        sudo|timeout|getent|git) echo "$CAT_SYSTEM" ;;
        *)                       echo "" ;;
    esac
}
_bin_version_cmd() {
    case "$1" in
        curl)    echo "curl --version | head -1 | awk '{print \$2}'" ;;
        jq)      echo "jq --version | head -1" ;;
        openssl) echo "openssl version | awk '{print \$2}'" ;;
        sudo)    echo "sudo --version | head -1 | awk '{print \$3}'" ;;
        timeout) echo "timeout --version | head -1 | awk '{print \$NF}'" ;;
        git)     echo "git --version | awk '{print \$3}'" ;;
        getent)  echo "" ;;
        *)       echo "" ;;
    esac
}
_cat_desc() {
    case "$1" in
        "$CAT_NETWORK") echo "Ferramentas usadas pelo check-network e por scripts de geração de chave/manipulação de JSON." ;;
        "$CAT_SYSTEM")  echo "Comandos básicos usados pelo siscan-server-setup.sh e pelos specialists." ;;
        *)              echo "" ;;
    esac
}

_last_cat=""
for _bin in "${REQUIRED_BINARIES[@]}"; do
    _cat="$(_bin_category "$_bin")"
    if [ -z "$_cat" ]; then
        # Binário exigido no manifesto sem rotina de verificação aqui: drift
        # entre products.json e o specialist — reporta como FAIL na categoria Sistema.
        [ "$_last_cat" = "$CAT_SYSTEM" ] || { print_category_header "$CAT_SYSTEM" "$(_cat_desc "$CAT_SYSTEM")"; _last_cat="$CAT_SYSTEM"; }
        add_fail "$CAT_SYSTEM" cmd 0 "$_bin" "exigido em .defaults.host_requirements.required_binaries (products.json) mas sem rotina de verificação no check-deps — drift manifesto↔specialist (#113)"
        continue
    fi
    if [ "$_cat" != "$_last_cat" ]; then
        print_category_header "$_cat" "$(_cat_desc "$_cat")"
        _last_cat="$_cat"
    fi
    _check_bin "$_cat" "$_bin" "$(_bin_version_cmd "$_bin")"
done

# Sistema operacional — alvo lido do manifesto (.defaults.host_requirements, #113)
CAT_OS="Sistema operacional"
print_category_header "$CAT_OS" "Ubuntu ${UBUNTU_TARGET_MAJOR}.04 LTS é o alvo testado no DEPLOY_SERVER.md — versões mais antigas podem ter Docker/Compose desatualizados."
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
    # Compara major version (24, 22, 20...) contra os limiares do manifesto
    os_major="${os_ver%%.*}"
    if [ "$os_major" -ge "$UBUNTU_TARGET_MAJOR" ] 2>/dev/null; then
        add_ok "$CAT_OS" os 0 "Ubuntu $os_ver" "alvo do DEPLOY_SERVER.md"
    elif [ "$os_major" -ge "$UBUNTU_SUPPORTED_MAJOR" ] 2>/dev/null; then
        add_ok "$CAT_OS" os 0 "Ubuntu $os_ver" "anterior ao alvo (${UBUNTU_TARGET_MAJOR}.04) mas suportado — pode ter Docker/Compose desatualizados"
    else
        add_fail "$CAT_OS" os 0 "Ubuntu $os_ver" "muito antiga — DEPLOY_SERVER.md exige >= ${UBUNTU_TARGET_MAJOR}.04 LTS"
    fi
else
    add_fail "$CAT_OS" os 0 "$os_id $os_ver" "distro não testada — DEPLOY_SERVER.md exige Ubuntu ${UBUNTU_TARGET_MAJOR}.04 LTS"
fi

# Sincronização de tempo
print_category_header "$CAT_TIME" "Clock dessincronizado causa SSL_ERROR_SYSCALL no TLS — sintoma típico relatado no registro interno em 06/05."
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
