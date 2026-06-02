#!/usr/bin/env bash
# -------------------------------------------
# Setup do Servidor — Opção 1.A Self-hosted Runner
# -------------------------------------------
# Arquivo: siscan-server-setup.sh
# Propósito: Preparar servidor Linux para receber deploys automáticos do
#            SISCAN (RPA e/ou Dashboard) via GitHub Actions self-hosted runner.
#
# Uso:
#   bash ./siscan-server-setup.sh --product rpa        # VM do RPA
#   bash ./siscan-server-setup.sh --product dashboard   # VM do Dashboard
#   bash ./siscan-server-setup.sh --product full        # Host (tudo junto)
#   bash ./siscan-server-setup.sh --skip-doctor [...]   # pula a Fase 0 (gate doctor)
#   bash ./siscan-server-setup.sh                       # pergunta interativamente
#
# Pré-flight automático:
#   A Fase 0 invoca siscan-server-doctor.sh (subconjunto sem check-runner,
#   check-stack, check-db) e aborta se algum problema for detectado.
#   Use --skip-doctor pra pular esse gate em cenários de debugging.
#
# Variáveis de ambiente opcionais:
#   RUNNER_DIR     Diretório de instalação do runner (padrão: ~/actions-runner)
#
# Pré-requisitos:
#   - Linux (Ubuntu 22.04+ recomendado)
#   - Docker Engine >= 24 e Docker Compose >= 2 (plugin)
#   - curl
#   - sudo disponível (para instalar o runner como serviço)
#
# Referência: docs/DEPLOY_AUTOMATICO.md — Opção 1.A Self-hosted Runner
# -------------------------------------------

# Note: We intentionally do NOT use 'set -e' (errexit) because read/grep
# return non-zero in normal control flow. Errors are handled explicitly via fail().
set -uo pipefail

# ────────────────────────────────────────────────────────────────────────────
# Cores ANSI
# ────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
WHITE='\033[1;37m'
NC='\033[0m'

# ────────────────────────────────────────────────────────────────────────────
# Parse de argumentos
# ────────────────────────────────────────────────────────────────────────────
SISCAN_PRODUCT=""
SKIP_DOCTOR=false
FORCE_DOWNLOAD_BINARIES=false
while [[ $# -gt 0 ]]; do
    case "${1}" in
        --product) SISCAN_PRODUCT="${2:-}"; shift 2 ;;
        --product=*) SISCAN_PRODUCT="${1#*=}"; shift ;;
        --skip-doctor) SKIP_DOCTOR=true; shift ;;
        --force-download-binaries) FORCE_DOWNLOAD_BINARIES=true; shift ;;
        *) shift ;;
    esac
done

# ────────────────────────────────────────────────────────────────────────────
# Configuração
# ────────────────────────────────────────────────────────────────────────────
RUNNER_DIR="${RUNNER_DIR:-${HOME}/actions-runner}"
CURRENT_USER="$(whoami)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPECIALISTS_DIR="${SCRIPT_DIR}/scripts/deploy_server"
# Manifesto declarativo de produtos — usado por ensure_host_paths_derived
# (TSK00.05.01) para iterar variáveis com derivação automática (HOST_SECRETS_DIR,
# HOST_BACKUPS_DIR). Consumidores em scripts/deploy_server/check-*.sh já usam
# o mesmo PRODUCTS_FILE — manter consistente.
PRODUCTS_FILE="${PRODUCTS_FILE:-${SCRIPT_DIR}/scripts/data/products.json}"

# ────────────────────────────────────────────────────────────────────────────
# Helpers de output — sourcing _common.sh (TSK00.04.13 #92)
# ────────────────────────────────────────────────────────────────────────────
# Setup é human-only por design (interativo). Força OUTPUT_MODE=human
# de forma INCONDICIONAL antes do source — caso contrário, um
# OUTPUT_MODE=quiet/json herdado do ambiente (ex.: setup invocado de dentro
# de um doctor --json) deixaria os helpers ok/info/warn silenciosos no
# meio de um prompt interativo (revisão Copilot PR #93).
OUTPUT_MODE="human"
# shellcheck source=scripts/deploy_server/_common.sh
source "${SPECIALISTS_DIR}/_common.sh"

# Override pontual: _common.sh:fail() faz exit 2 (uso inválido para
# specialists). O setup usa fail() para qualquer erro fatal e o
# contrato histórico é exit 1 — preservamos esse contrato.
fail() { printf "\n${RED}ERRO: %s${NC}\n\n" "${1}" >&2; exit 1; }

step() {
    printf "\n${CYAN}══════════════════════════════════════════════════${NC}\n"
    printf "${WHITE}  %s${NC}\n" "${1}"
    printf "${CYAN}══════════════════════════════════════════════════${NC}\n\n"
}

# ────────────────────────────────────────────────────────────────────────────
# _generate_secret
# Gera uma chave hexadecimal de 64 caracteres (256 bits).
# ────────────────────────────────────────────────────────────────────────────
_generate_secret() {
    if command -v openssl &>/dev/null; then
        openssl rand -hex 32
    elif command -v python3 &>/dev/null; then
        python3 -c "import secrets; print(secrets.token_hex(32))"
    else
        tr -dc 'a-f0-9' < /dev/urandom | head -c 64
    fi
}

# ────────────────────────────────────────────────────────────────────────────
# _validate_linux_path VARNAME VALUE
# Detecta caminhos no formato Windows (drive letter, UNC, backslash) e avisa.
# Retorna 0 se o caminho parece compatível com Linux, 1 se suspeito.
# ────────────────────────────────────────────────────────────────────────────
_validate_linux_path() {
    local var_name="${1}" path_val="${2}"
    [ -z "${path_val}" ] && return 0

    local is_unc=false is_drive=false has_backslash=false
    local -a problems=()

    # Caminho UNC: \\servidor\share
    if [[ "${path_val}" =~ ^\\\\[^\\]+ ]]; then
        is_unc=true
        problems+=("caminho UNC (\\\\servidor\\share) não é suportado diretamente no Linux")
    fi

    # Letra de drive Windows: C:\ ou C:/
    if [[ "${path_val}" =~ ^[A-Za-z]:[/\\] ]]; then
        is_drive=true
        problems+=("caminho com letra de drive Windows (ex: C:\\...)")
    fi

    # Backslash como separador (exceto se já detectado como UNC)
    if [[ "${path_val}" == *\\* ]] && ! ${is_unc}; then
        has_backslash=true
        problems+=("usa '\\' como separador — Linux requer '/'")
    fi

    [ ${#problems[@]} -eq 0 ] && return 0

    printf "\n${YELLOW}  AVISO — Caminho com formato Windows: ${CYAN}%s${NC}\n" "${var_name}"
    printf "  ${GRAY}Valor: %s${NC}\n" "${path_val}"
    for p in "${problems[@]}"; do printf "  ${RED}•${NC} %s\n" "${p}"; done
    if ${is_drive} || ${has_backslash}; then
        printf "  ${CYAN}Sugestão:${NC} use um caminho Linux, ex: ${GRAY}/opt/siscan-rpa/dados${NC}\n"
    fi
    if ${is_unc}; then
        printf "  ${CYAN}Sugestão:${NC} monte o compartilhamento e use o ponto de montagem, ex: ${GRAY}/mnt/siscan-dados${NC}\n"
    fi
    printf "\n"
    return 1
}

# ────────────────────────────────────────────────────────────────────────────
# _read_env_value FILE KEY
# Retorna o valor de KEY no arquivo .env (sem aspas, sem espaços).
# ────────────────────────────────────────────────────────────────────────────
_read_env_value() {
    local file="${1}" key="${2}"
    grep -E "^[[:space:]]*${key}[[:space:]]*=" "${file}" 2>/dev/null \
        | tail -1 \
        | sed "s/^[^=]*=//;s/^['\"]//;s/['\"]$//" \
        | xargs 2>/dev/null || true
}

# ────────────────────────────────────────────────────────────────────────────
# _set_env_value FILE KEY VALUE
# Atualiza KEY=VALUE se a chave existe, ou acrescenta ao final.
# ────────────────────────────────────────────────────────────────────────────
_set_env_value() {
    local file="${1}" key="${2}" value="${3}"
    if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "${file}" 2>/dev/null; then
        sed -i "s|^[[:space:]]*${key}[[:space:]]*=.*|${key}=${value}|" "${file}"
    else
        printf '%s=%s\n' "${key}" "${value}" >> "${file}"
    fi
}

# ────────────────────────────────────────────────────────────────────────────
# ensure_host_paths ENV_FILE
# Cria os diretórios definidos nas variáveis HOST_*_DIR do .env.
# ────────────────────────────────────────────────────────────────────────────
ensure_host_paths() {
    local env_file="${1}"
    local -a dir_vars=(
        HOST_LOG_DIR
        HOST_SISCAN_REPORTS_INPUT_DIR
        HOST_REPORTS_OUTPUT_CONSOLIDATED_DIR
        HOST_REPORTS_OUTPUT_CONSOLIDATED_PDFS_DIR
        HOST_CONFIG_DIR
    )
    local failed=0

    for v in "${dir_vars[@]}"; do
        local p
        p="$(_read_env_value "${env_file}" "${v}")"
        [ -z "${p}" ] && { warn "${v} não definido — pulando criação do diretório"; continue; }
        if mkdir -p "${p}" 2>/dev/null; then
            ok "Diretório: ${p}"
        else
            warn "Não foi possível criar: ${p}"
            failed=$((failed + 1))
        fi
    done

    return ${failed}
}

# ────────────────────────────────────────────────────────────────────────────
# env_apply_derivation DERIVATION PARENT_VAL → stdout
# Aplica uma expressão de derivação declarada no manifesto products.json
# (campo host_dir_vars[].derivation) a um valor pai.
#
# Suporta atualmente a única expressão usada em produção (TSK00.05.01):
#   "dirname + /<subdir>"   →  $(dirname PARENT_VAL)/<subdir>
#
# Retorno:
#   - status 0 + valor em stdout: expressão reconhecida e aplicada
#   - status 1, stdout vazio:     expressão desconhecida (caller deve checar
#                                 status OU valor vazio — env_set_or_derive
#                                 hoje usa o segundo via `[ -z "${val}" ]`)
#   - status 0, stdout vazio:     PARENT_VAL vazio (early return — sem
#                                 expressão pra aplicar)
#
# Adicionar novas formas exige só estender este switch — o consumidor não muda.
# ────────────────────────────────────────────────────────────────────────────
env_apply_derivation() {
    local derivation="${1}" parent_val="${2}"
    [ -z "${parent_val}" ] && return 0

    case "${derivation}" in
        "dirname + "/*)
            # "dirname + /secrets" → /<dirname parent>/secrets
            local subdir="${derivation#dirname + }"
            printf '%s%s' "$(dirname "${parent_val}")" "${subdir}"
            ;;
        *)
            return 1
            ;;
    esac
}

# ────────────────────────────────────────────────────────────────────────────
# env_set_or_derive ENV_FILE VAR_NAME PARENT_VAR DERIVATION [DEFAULT_MODE] [AUTO_CREATE]
#
# Idempotente. Garante que VAR_NAME esteja presente no ENV_FILE e que o
# diretório correspondente exista com as permissões corretas.
#
#   - Se VAR_NAME já tem valor no .env: PRESERVA o valor (operador no
#     comando). Apenas cria o diretório (se AUTO_CREATE=true) e aplica
#     DEFAULT_MODE (se especificado) — preservando customizações.
#   - Se VAR_NAME está ausente/vazio: deriva via DERIVATION a partir do
#     valor de PARENT_VAR (também lido do .env). Grava o valor derivado
#     no .env, cria o diretório, aplica DEFAULT_MODE.
#   - Se PARENT_VAR também está vazio: pula (warn) — operador precisa
#     preencher PARENT_VAR antes.
#
# Retorna 0 em sucesso, 1 em falha de criação/chmod, 2 em erro de uso.
#
# Esta função é parte do contrato consolidado da TSK00.05.01 (#95) —
# Workflows CD downstream (siscan-rpa #694, siscan-dashboard #525)
# REMOVEM o step inline "Garantir HOST_SECRETS_DIR e HOST_BACKUPS_DIR"
# e confiam que o setup já entregou essas variáveis no .env.
# ────────────────────────────────────────────────────────────────────────────
env_set_or_derive() {
    local env_file="${1}" var_name="${2}" parent_var="${3}" derivation="${4}"
    local default_mode="${5:-}" auto_create="${6:-true}"

    [ -z "${env_file}" ] || [ -z "${var_name}" ] || [ -z "${parent_var}" ] || [ -z "${derivation}" ] && return 2

    local current parent val
    current="$(_read_env_value "${env_file}" "${var_name}")"

    if [ -n "${current}" ]; then
        # Preservar valor existente — operador já configurou.
        val="${current}"
        ok "${var_name}=${val} (preservado do .env)"
    else
        # Derivar a partir do parent.
        parent="$(_read_env_value "${env_file}" "${parent_var}")"
        if [ -z "${parent}" ]; then
            warn "${var_name} não pode ser derivado: ${parent_var} também está vazio no .env"
            return 1
        fi
        val="$(env_apply_derivation "${derivation}" "${parent}")"
        if [ -z "${val}" ]; then
            warn "${var_name} não pode ser derivado: expressão '${derivation}' não reconhecida"
            return 1
        fi
        _set_env_value "${env_file}" "${var_name}" "${val}"
        ok "${var_name}=${val} (derivado de ${parent_var})"
    fi

    if [ "${auto_create}" = "true" ]; then
        if ! mkdir -p "${val}" 2>/dev/null; then
            warn "Não foi possível criar ${val} — verifique permissões em $(dirname "${val}")"
            return 1
        fi
        if [ -n "${default_mode}" ]; then
            if ! chmod "${default_mode}" "${val}" 2>/dev/null; then
                warn "Não foi possível aplicar chmod ${default_mode} em ${val}"
                return 1
            fi
            info "Modo ${default_mode} aplicado em ${val}"
        fi
    fi

    return 0
}

# ────────────────────────────────────────────────────────────────────────────
# ensure_host_paths_derived ENV_FILE
# Itera os elementos OBJETO de host_dir_vars (schema v2.0) e aplica
# env_set_or_derive para cada um. Strings da forma legada são ignoradas —
# elas são tratadas pela coleta interativa anterior + ensure_host_paths.
#
# Pré-requisito: PRODUCTS_FILE e SISCAN_PRODUCT já definidos.
# ────────────────────────────────────────────────────────────────────────────
ensure_host_paths_derived() {
    local env_file="${1}"
    local total=0 failed=0

    # Sem manifesto, não há nada a derivar (compat retroativa).
    if [ -z "${PRODUCTS_FILE:-}" ] || [ ! -f "${PRODUCTS_FILE:-}" ]; then
        return 0
    fi
    command -v jq >/dev/null 2>&1 || return 0

    while IFS=$'\t' read -r name derived_from derivation default_mode auto_create _description; do
        [ -z "${name}" ] && continue
        # Sentinela "-" emitido por product_get_host_dir_vars_derived para
        # preservar campos vazios em IFS=tab. Reverter pra valor real.
        [ "${default_mode}" = "-" ] && default_mode=""
        total=$((total + 1))
        if ! env_set_or_derive "${env_file}" "${name}" "${derived_from}" "${derivation}" "${default_mode}" "${auto_create}"; then
            failed=$((failed + 1))
        fi
    done < <(product_get_host_dir_vars_derived)

    [ "${total}" -eq 0 ] && return 0
    return "${failed}"
}

# ════════════════════════════════════════════════════════════════════════════
# MAIN — só executa quando o script é chamado diretamente (não via source)
# ════════════════════════════════════════════════════════════════════════════
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then

# ── Seleção de produto ────────────────────────────────────────────────────
# Política de prioridade (alinhada com resolve_product em _common.sh — TSK00.05.05):
#   1. --product NAME na CLI (parseado acima → ${SISCAN_PRODUCT})
#   2. $SISCAN_PRODUCT herdado do ambiente (mantido se já não-vazio)
#   3. SISCAN_PRODUCT lido do .env existente em $COMPOSE_DIR ou $SCRIPT_DIR
#      (idempotência: re-rodar setup numa VM provisionada não exige re-digitar)
#   4. Prompt interativo (fluxo histórico — primeira instalação)
if [ -z "${SISCAN_PRODUCT}" ]; then
    # Fallback ao .env: tenta detectar produto de uma instalação anterior antes
    # de entrar no prompt interativo. ${COMPOSE_DIR:-${SCRIPT_DIR}} reproduz a
    # mesma derivação usada na linha 401 (sem antecipar o assignment global).
    _setup_env_file_candidate="${COMPOSE_DIR:-${SCRIPT_DIR}}/.env"
    if [ -f "${_setup_env_file_candidate}" ]; then
        _setup_env_product="$(_read_env_value "${_setup_env_file_candidate}" "SISCAN_PRODUCT")"
        if [ -n "${_setup_env_product}" ]; then
            case "${_setup_env_product}" in
                rpa|dashboard|full)
                    SISCAN_PRODUCT="${_setup_env_product}"
                    info "SISCAN_PRODUCT=${SISCAN_PRODUCT} herdado de ${_setup_env_file_candidate} (re-execução em VM já provisionada)"
                    ;;
                *)
                    warn "SISCAN_PRODUCT='${_setup_env_product}' em ${_setup_env_file_candidate} é inválido — ignorado, caindo no prompt interativo"
                    ;;
            esac
        fi
    fi
    unset _setup_env_file_candidate _setup_env_product
fi

if [ -z "${SISCAN_PRODUCT}" ]; then
    printf "\n${WHITE}╔════════════════════════════════════════════════════╗${NC}\n"
    printf "${WHITE}║  SISCAN — Setup do Servidor                        ║${NC}\n"
    printf "${WHITE}╚════════════════════════════════════════════════════╝${NC}\n\n"
    printf "  Selecione o produto a instalar nesta máquina:\n\n"
    printf "  ${CYAN}1${NC}) ${WHITE}rpa${NC}        — SISCAN RPA (coleta e extração de laudos)\n"
    printf "  ${CYAN}2${NC}) ${WHITE}dashboard${NC}  — SISCAN Dashboard (painel analítico)\n"
    printf "  ${CYAN}3${NC}) ${WHITE}full${NC}       — Ambos (HOST / PC local com banco em container)\n\n"
    printf "  Opção: "
    read -r product_choice
    case "${product_choice}" in
        1|rpa)       SISCAN_PRODUCT="rpa" ;;
        2|dashboard) SISCAN_PRODUCT="dashboard" ;;
        3|full)      SISCAN_PRODUCT="full" ;;
        *) fail "Opção inválida. Use: --product rpa | dashboard | full" ;;
    esac
fi

# Validar produto
case "${SISCAN_PRODUCT}" in
    rpa|dashboard|full) ;;
    *) fail "Produto inválido: '${SISCAN_PRODUCT}'. Valores aceitos: rpa, dashboard, full" ;;
esac

# ── Configuração derivada do produto ──────────────────────────────────────
case "${SISCAN_PRODUCT}" in
    rpa)
        COMPOSE_FILE="docker-compose.prd.rpa.yml"
        ENV_SAMPLE_NAME=".env.server-rpa.sample"
        RUNNER_LABEL="producao-rpa"
        RUNNER_NAME="$(hostname)-siscan-rpa"
        PRODUCT_DISPLAY="SISCAN RPA"
        REPO_URL_DEFAULT="https://github.com/Prisma-Consultoria/siscan-rpa"
        ;;
    dashboard)
        COMPOSE_FILE="docker-compose.prd.dashboard.yml"
        ENV_SAMPLE_NAME=".env.server-dashboard.sample"
        RUNNER_LABEL="producao-dashboard"
        RUNNER_NAME="$(hostname)-siscan-dashboard"
        PRODUCT_DISPLAY="SISCAN Dashboard"
        REPO_URL_DEFAULT="https://github.com/Prisma-Consultoria/siscan-dashboard"
        ;;
    full)
        COMPOSE_FILE="docker-compose.prd.host.yml"
        ENV_SAMPLE_NAME=".env.host.sample"
        RUNNER_LABEL="producao-cliente"
        RUNNER_NAME="$(hostname)-siscan-full"
        PRODUCT_DISPLAY="SISCAN RPA + Dashboard"
        REPO_URL_DEFAULT="https://github.com/Prisma-Consultoria/siscan-rpa"
        ;;
esac

COMPOSE_DIR="${COMPOSE_DIR:-${SCRIPT_DIR}}"
ENV_FILE="${COMPOSE_DIR}/.env"

# ── Banner ────────────────────────────────────────────────────────────────
printf "\n${WHITE}╔════════════════════════════════════════════════════╗${NC}\n"
printf "${WHITE}║  %s — Setup do Servidor$(printf '%*s' $((28 - ${#PRODUCT_DISPLAY})) '')║${NC}\n" "${PRODUCT_DISPLAY}"
printf "${WHITE}║  Opção 1.A — Self-hosted Runner + Docker Compose   ║${NC}\n"
printf "${WHITE}╚════════════════════════════════════════════════════╝${NC}\n"
printf "\n"
printf "  ${GRAY}Produto            : %s${NC}\n" "${SISCAN_PRODUCT}"
printf "  ${GRAY}Compose            : %s${NC}\n" "${COMPOSE_FILE}"
printf "  ${GRAY}Diretório da stack : %s${NC}\n" "${COMPOSE_DIR}"
printf "  ${GRAY}Diretório do runner: %s${NC}\n" "${RUNNER_DIR}"
printf "  ${GRAY}Usuário atual      : %s${NC}\n" "${CURRENT_USER}"
printf "  ${GRAY}Label do runner    : %s${NC}\n" "${RUNNER_LABEL}"

# ════════════════════════════════════════════════════════════════════════════
step "FASE 0 — Pré-flight via siscan-server-doctor"
# ════════════════════════════════════════════════════════════════════════════
# Gate diagnóstico ANTES de qualquer ação destrutiva. Aproveita os specialists
# em scripts/deploy_server/ pra detectar Docker/Compose/curl/jq ausentes, OS
# incompatível, recursos sub-dimensionados, firewall fechado, etc.
#
# Excluímos 3 specialists que só fazem sentido APÓS o setup completar:
#   - check-runner  (runner ainda será instalado nesta execução)
#   - check-stack   (stack ainda não foi subida)
#   - check-db      (.env final com DATABASE_HOST só sai depois da Fase 5)
#
# Use --skip-doctor pra pular este gate (debugging em ambientes anômalos).

DOCTOR_SCRIPT="${SCRIPT_DIR}/siscan-server-doctor.sh"
if [ "${SKIP_DOCTOR}" = "true" ]; then
    warn "Fase 0 pulada por --skip-doctor (não recomendado em produção)"
elif [ ! -f "${DOCTOR_SCRIPT}" ]; then
    warn "siscan-server-doctor.sh ausente — pulando Fase 0"
else
    info "Rodando doctor em modo quiet (só FAIL apareceria abaixo)..."
    if bash "${DOCTOR_SCRIPT}" --quiet --pre-setup; then
        ok "Doctor aprovou: VM atende aos pré-requisitos pré-setup"
    else
        printf "\n${RED}ERRO: o doctor reportou problemas nos pré-requisitos.${NC}\n\n" >&2
        printf "${WHITE}Detalhes:${NC} rode ${CYAN}bash ${DOCTOR_SCRIPT}${NC} (modo legível)\n" >&2
        printf "${WHITE}Skip:${NC}     rode ${CYAN}bash ${BASH_SOURCE[0]} --skip-doctor [...]${NC} (não recomendado)\n\n" >&2
        exit 2
    fi
fi

# ════════════════════════════════════════════════════════════════════════════
step "FASE 1 — Verificação de pré-requisitos"
# ════════════════════════════════════════════════════════════════════════════

# Docker
if ! command -v docker &>/dev/null; then
    fail "Docker não encontrado. Instale com: https://docs.docker.com/engine/install/"
fi
if ! docker info &>/dev/null; then
    # Diagnosticar a causa específica
    printf "\n${RED}ERRO: Não foi possível conectar ao daemon Docker.${NC}\n\n"
    # Serviço ativo?
    if command -v systemctl &>/dev/null && ! systemctl is-active --quiet docker 2>/dev/null; then
        printf "  ${YELLOW}•${NC} O serviço Docker não está ativo.\n"
        printf "    Inicie com: ${CYAN}sudo systemctl start docker${NC}\n"
        printf "    Habilite no boot: ${CYAN}sudo systemctl enable docker${NC}\n"
    fi
    # Usuário no grupo docker?
    if ! id -nG "${CURRENT_USER}" 2>/dev/null | grep -qw docker; then
        printf "  ${YELLOW}•${NC} O usuário '${CURRENT_USER}' não está no grupo 'docker'.\n"
        printf "    Adicione com: ${CYAN}sudo usermod -aG docker %s${NC}\n" "${CURRENT_USER}"
        printf "    Depois faça logout/login e execute o script novamente.\n"
    fi
    # Socket existe?
    if [ ! -S /var/run/docker.sock ]; then
        printf "  ${YELLOW}•${NC} O socket ${GRAY}/var/run/docker.sock${NC} não existe.\n"
        printf "    O daemon Docker pode não ter sido iniciado ainda.\n"
    fi
    printf "\n"
    exit 1
fi
DOCKER_VERSION=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "desconhecida")
DOCKER_MAJOR=$(echo "${DOCKER_VERSION}" | cut -d. -f1)
if [ -n "${DOCKER_MAJOR}" ] && [ "${DOCKER_MAJOR}" -lt 24 ] 2>/dev/null; then
    warn "Docker ${DOCKER_VERSION} — versão >= 24.x é recomendada para produção"
else
    ok "Docker ${DOCKER_VERSION}"
fi

# Docker Compose v2 (plugin)
if ! docker compose version &>/dev/null; then
    fail "Docker Compose v2 (plugin) não encontrado. Instale com: sudo apt install docker-compose-plugin"
fi
COMPOSE_VERSION=$(docker compose version --short 2>/dev/null || echo "desconhecida")
ok "Docker Compose ${COMPOSE_VERSION}"

# curl
command -v curl &>/dev/null || fail "curl não encontrado. Instale com: sudo apt install curl"
ok "curl $(curl --version 2>/dev/null | head -1 | awk '{print $2}')"

# sudo
command -v sudo &>/dev/null || fail "sudo não encontrado. Este script precisa de sudo para criar ${COMPOSE_DIR} e instalar o runner como serviço systemd."
ok "sudo disponível"

# ════════════════════════════════════════════════════════════════════════════
step "FASE 2 — Usuário dedicado para o runner"
# ════════════════════════════════════════════════════════════════════════════

if [ "$(id -u)" -eq 0 ]; then
    printf "  ${GRAY}O GitHub Actions runner recusa execução como root.${NC}\n"
    printf "  ${GRAY}Criando usuário dedicado 'siscan' e re-executando o script como ele.${NC}\n\n"

    if id siscan &>/dev/null; then
        ok "Usuário 'siscan' já existe"
    else
        useradd -m -s /bin/bash siscan || fail "Não foi possível criar o usuário 'siscan'"
        ok "Usuário 'siscan' criado"
        printf "\n  ${CYAN}Defina a senha do usuário 'siscan':${NC}\n"
        passwd siscan || fail "Não foi possível definir a senha do usuário 'siscan'"
    fi

    if id -nG siscan | grep -qw docker; then
        ok "Usuário 'siscan' já está no grupo 'docker'"
    else
        usermod -aG docker siscan || fail "Não foi possível adicionar 'siscan' ao grupo 'docker'"
        ok "Usuário 'siscan' adicionado ao grupo 'docker'"
    fi

    # Transferir propriedade do diretório do script para siscan
    # (caso tenha sido clonado como root, evita "Permission denied" no .git)
    chown -R siscan:siscan "${SCRIPT_DIR}"
    ok "Permissões de ${SCRIPT_DIR} transferidas para 'siscan'"

    info "Re-executando o script como usuário 'siscan'..."
    SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    exec sudo -u siscan SISCAN_PRODUCT="${SISCAN_PRODUCT}" COMPOSE_DIR="${COMPOSE_DIR}" RUNNER_DIR="${RUNNER_DIR}" bash "${SCRIPT_PATH}" --product "${SISCAN_PRODUCT}"
else
    ok "Usuário não-root: ${CURRENT_USER}"
fi

# ════════════════════════════════════════════════════════════════════════════
step "FASE 3 — Estrutura de diretórios da stack"
# ════════════════════════════════════════════════════════════════════════════

if [ -d "${COMPOSE_DIR}" ]; then
    ok "${COMPOSE_DIR} já existe"
else
    info "Criando ${COMPOSE_DIR}..."
    sudo mkdir -p "${COMPOSE_DIR}" || fail "Não foi possível criar ${COMPOSE_DIR}. Verifique permissões sudo."
    ok "${COMPOSE_DIR} criado"
fi

COMPOSE_DIR_OWNER=$(stat -c '%U' "${COMPOSE_DIR}" 2>/dev/null || echo "")
if [ "${COMPOSE_DIR_OWNER}" != "${CURRENT_USER}" ]; then
    info "Ajustando dono de ${COMPOSE_DIR} para ${CURRENT_USER}..."
    sudo chown "${CURRENT_USER}:${CURRENT_USER}" "${COMPOSE_DIR}" \
        || warn "Não foi possível alterar o dono de ${COMPOSE_DIR}"
    ok "Permissões ajustadas"
else
    ok "Permissões de ${COMPOSE_DIR} corretas (dono: ${CURRENT_USER})"
fi

# ════════════════════════════════════════════════════════════════════════════
step "FASE 4 — Arquivos da stack"
# ════════════════════════════════════════════════════════════════════════════

# docker-compose.prd.rpa.yml
COMPOSE_FILE_PATH="${COMPOSE_DIR}/${COMPOSE_FILE}"
if [ -f "${COMPOSE_FILE_PATH}" ]; then
    ok "${COMPOSE_FILE} presente"
else
    # Tentar copiar do diretório do script (se distribuídos juntos)
    if [ -f "${SCRIPT_DIR}/${COMPOSE_FILE}" ]; then
        cp "${SCRIPT_DIR}/${COMPOSE_FILE}" "${COMPOSE_FILE_PATH}"
        ok "${COMPOSE_FILE} copiado de ${SCRIPT_DIR}"
    else
        printf "\n${RED}  ARQUIVO OBRIGATÓRIO AUSENTE: %s${NC}\n\n" "${COMPOSE_FILE}"
        printf "  Coloque o arquivo fornecido pela equipe Prisma Educação em:\n"
        printf "  ${CYAN}%s${NC}\n\n" "${COMPOSE_FILE_PATH}"
        fail "Execute o script novamente após colocar ${COMPOSE_FILE} em ${COMPOSE_DIR}"
    fi
fi

# config/
CONFIG_DIR="${COMPOSE_DIR}/config"
if [ -d "${CONFIG_DIR}" ]; then
    ok "config/ presente"
    MAPPING_FILE="${CONFIG_DIR}/excel_columns_mapping.json"
    if [ ! -f "${MAPPING_FILE}" ]; then
        warn "excel_columns_mapping.json não encontrado em config/ — coloque-o antes de iniciar a stack"
    else
        ok "excel_columns_mapping.json presente"
    fi
else
    # Tentar copiar do diretório do script
    if [ -d "${SCRIPT_DIR}/config" ]; then
        cp -r "${SCRIPT_DIR}/config" "${CONFIG_DIR}"
        ok "config/ copiado de ${SCRIPT_DIR}"
    else
        mkdir -p "${CONFIG_DIR}"
        warn "config/ criado vazio — coloque excel_columns_mapping.json antes de iniciar a stack"
    fi
fi

# ════════════════════════════════════════════════════════════════════════════
step "FASE 5 — Configuração do .env"
# ════════════════════════════════════════════════════════════════════════════

# Criar .env a partir do sample correspondente ao produto
if [ ! -f "${ENV_FILE}" ]; then
    ENV_SAMPLE=""
    for candidate in \
        "${COMPOSE_DIR}/${ENV_SAMPLE_NAME}" \
        "${SCRIPT_DIR}/${ENV_SAMPLE_NAME}"; do
        if [ -f "${candidate}" ]; then
            ENV_SAMPLE="${candidate}"
            break
        fi
    done

    if [ -n "${ENV_SAMPLE}" ]; then
        cp "${ENV_SAMPLE}" "${ENV_FILE}"
        info ".env criado a partir de ${ENV_SAMPLE}"
    else
        touch "${ENV_FILE}"
        info ".env criado em branco (${ENV_SAMPLE_NAME} não encontrado)"
    fi
else
    ok ".env já existe"
fi

# Persistir o produto selecionado no .env
_set_env_value "${ENV_FILE}" "SISCAN_PRODUCT" "${SISCAN_PRODUCT}"

# ── Chave de sessão ────────────────────────────────────────────────────────
printf "\n${WHITE}  Variáveis obrigatórias${NC}\n\n"

if [ "${SISCAN_PRODUCT}" = "dashboard" ]; then
    SESSION_SECRET_VAL="$(_read_env_value "${ENV_FILE}" "SESSION_SECRET")"
    if [ -z "${SESSION_SECRET_VAL}" ]; then
        SESSION_SECRET_VAL="$(_generate_secret)"
        _set_env_value "${ENV_FILE}" "SESSION_SECRET" "${SESSION_SECRET_VAL}"
        ok "SESSION_SECRET gerada automaticamente"
    else
        ok "SESSION_SECRET já configurada"
    fi
else
    SECRET_KEY_VAL="$(_read_env_value "${ENV_FILE}" "SECRET_KEY")"
    if [ -z "${SECRET_KEY_VAL}" ]; then
        SECRET_KEY_VAL="$(_generate_secret)"
        _set_env_value "${ENV_FILE}" "SECRET_KEY" "${SECRET_KEY_VAL}"
        ok "SECRET_KEY gerada automaticamente"
    else
        ok "SECRET_KEY já configurada"
    fi
fi

# ── DATABASE_HOST ────────────────────────────────────────────────────────────
DB_HOST_VAL="$(_read_env_value "${ENV_FILE}" "DATABASE_HOST")"
if [ -z "${DB_HOST_VAL}" ] || [ "${DB_HOST_VAL}" = "db" ]; then
    printf "\n  ${CYAN}DATABASE_HOST${NC} — IP ou hostname do servidor PostgreSQL\n"
    printf "  ${GRAY}(banco externo — não use 'db'; não há container de banco nesta stack)${NC}\n"
    if [ "${DB_HOST_VAL:-}" = "db" ]; then
        printf "  ${YELLOW}Valor atual 'db' é inválido para banco externo.${NC}\n"
    fi
    printf "  Valor: "
    read -r DB_HOST_NEW
    if [ -n "${DB_HOST_NEW}" ]; then
        _set_env_value "${ENV_FILE}" "DATABASE_HOST" "${DB_HOST_NEW}"
        ok "DATABASE_HOST=${DB_HOST_NEW}"
    else
        warn "DATABASE_HOST não definido — edite ${ENV_FILE} antes de iniciar a stack"
    fi
else
    ok "DATABASE_HOST=${DB_HOST_VAL}"
fi

# ── DATABASE_PASSWORD ────────────────────────────────────────────────────────
DB_PASS_VAL="$(_read_env_value "${ENV_FILE}" "DATABASE_PASSWORD")"
IS_DEFAULT_PASS=false
[ "${DB_PASS_VAL:-}" = "siscan_rpa" ] && IS_DEFAULT_PASS=true

printf "\n  ${CYAN}DATABASE_PASSWORD${NC} — Senha do banco PostgreSQL\n"
if ${IS_DEFAULT_PASS}; then
    printf "  ${YELLOW}Senha padrão 'siscan_rpa' detectada — altere para produção.${NC}\n"
fi
if [ -n "${DB_PASS_VAL}" ]; then
    printf "  Valor atual: (configurado)${NC} — pressione Enter para manter\n"
fi
printf "  Novo valor: "
read -rs DB_PASS_NEW
printf "\n"
if [ -n "${DB_PASS_NEW}" ]; then
    _set_env_value "${ENV_FILE}" "DATABASE_PASSWORD" "${DB_PASS_NEW}"
    ok "DATABASE_PASSWORD atualizado"
else
    if [ -z "${DB_PASS_VAL}" ]; then
        warn "DATABASE_PASSWORD vazio — edite ${ENV_FILE} antes de iniciar a stack"
    else
        ok "DATABASE_PASSWORD mantido"
    fi
fi

# ── ADMIN_PASSWORD (só para dashboard) ────────────────────────────────────
if [ "${SISCAN_PRODUCT}" = "dashboard" ]; then
    ADMIN_PASS_VAL="$(_read_env_value "${ENV_FILE}" "ADMIN_PASSWORD")"
    if [ -z "${ADMIN_PASS_VAL}" ]; then
        printf "\n  ${CYAN}ADMIN_PASSWORD${NC} — Senha do usuário administrador do dashboard\n"
        printf "  ${GRAY}Obrigatória na primeira execução. Se vazia, uma senha temporária é gerada nos logs.${NC}\n"
        printf "  Valor: "
        read -rs ADMIN_PASS_NEW
        printf "\n"
        if [ -n "${ADMIN_PASS_NEW}" ]; then
            _set_env_value "${ENV_FILE}" "ADMIN_PASSWORD" "${ADMIN_PASS_NEW}"
            ok "ADMIN_PASSWORD configurado"
        else
            warn "ADMIN_PASSWORD vazio — o dashboard gerará uma senha temporária nos logs na primeira execução"
        fi
    else
        ok "ADMIN_PASSWORD já configurado"
    fi
fi

# ── RPA_DATABASE_URL (só para dashboard) ──────────────────────────────────
if [ "${SISCAN_PRODUCT}" = "dashboard" ]; then
    RPA_DB_URL_VAL="$(_read_env_value "${ENV_FILE}" "RPA_DATABASE_URL")"

    # Validar formato: deve começar com postgresql:// e ter pelo menos user@host/db
    RPA_URL_VALID=false
    if [[ "${RPA_DB_URL_VAL}" =~ ^postgresql://[^@]+@[^/]+/.+ ]]; then
        RPA_URL_VALID=true
    fi

    if [ -z "${RPA_DB_URL_VAL}" ] || ! ${RPA_URL_VALID}; then
        printf "\n  ${CYAN}RPA_DATABASE_URL${NC} — Conexão ao banco do siscan-rpa\n"
        printf "  ${GRAY}Formato: postgresql://usuario:senha@host:porta/banco${NC}\n"
        printf "  ${GRAY}Exemplo: postgresql://siscan_rpa:senha@192.168.1.10:5432/siscan_rpa${NC}\n"
        if [ -n "${RPA_DB_URL_VAL}" ] && ! ${RPA_URL_VALID}; then
            printf "  ${YELLOW}Valor atual '${RPA_DB_URL_VAL}' não parece uma URL PostgreSQL válida.${NC}\n"
        fi
        printf "  Valor: "
        read -r RPA_DB_URL_NEW
        if [ -n "${RPA_DB_URL_NEW}" ]; then
            if [[ "${RPA_DB_URL_NEW}" =~ ^postgresql://[^@]+@[^/]+/.+ ]]; then
                _set_env_value "${ENV_FILE}" "RPA_DATABASE_URL" "${RPA_DB_URL_NEW}"
                ok "RPA_DATABASE_URL configurado"
            else
                warn "Valor informado não parece uma URL PostgreSQL válida"
                printf "  ${GRAY}Formato esperado: postgresql://usuario:senha@host:porta/banco${NC}\n"
                _set_env_value "${ENV_FILE}" "RPA_DATABASE_URL" "${RPA_DB_URL_NEW}"
                warn "RPA_DATABASE_URL salvo mesmo assim — revise no .env"
            fi
        else
            warn "RPA_DATABASE_URL não definido — o sync não funcionará até ser configurado"
        fi
    else
        ok "RPA_DATABASE_URL já configurado (formato válido)"
    fi
fi

# ── HOST_* paths ─────────────────────────────────────────────────────────────
printf "\n${WHITE}  Variáveis HOST_* — caminhos de dados no servidor${NC}\n"
printf "  ${GRAY}(diretórios que serão montados como bind mounts nos containers)${NC}\n\n"

# Descrições e lista de paths variam por produto
declare -A HOST_VAR_HELP=(
    [HOST_LOG_DIR]="Logs da aplicação e do scheduler"
    [HOST_SISCAN_REPORTS_INPUT_DIR]="PDFs-fonte baixados do SISCAN"
    [HOST_REPORTS_OUTPUT_CONSOLIDATED_DIR]="Artefatos consolidados (Excel, Parquet)"
    [HOST_REPORTS_OUTPUT_CONSOLIDATED_PDFS_DIR]="PDFs individuais por laudo"
    [HOST_CONFIG_DIR]="Arquivos de configuração (ex: excel_columns_mapping.json)"
    [HOST_DASHBOARD_LOG_DIR]="Logs do dashboard"
)

case "${SISCAN_PRODUCT}" in
    rpa)
        HOST_PATH_VARS=(
            HOST_LOG_DIR
            HOST_SISCAN_REPORTS_INPUT_DIR
            HOST_REPORTS_OUTPUT_CONSOLIDATED_DIR
            HOST_REPORTS_OUTPUT_CONSOLIDATED_PDFS_DIR
            HOST_CONFIG_DIR
        ) ;;
    dashboard)
        HOST_PATH_VARS=(
            HOST_LOG_DIR
        ) ;;
    full)
        HOST_PATH_VARS=(
            HOST_LOG_DIR
            HOST_SISCAN_REPORTS_INPUT_DIR
            HOST_REPORTS_OUTPUT_CONSOLIDATED_DIR
            HOST_REPORTS_OUTPUT_CONSOLIDATED_PDFS_DIR
            HOST_CONFIG_DIR
            HOST_DASHBOARD_LOG_DIR
        ) ;;
esac

for var in "${HOST_PATH_VARS[@]}"; do
    current="$(_read_env_value "${ENV_FILE}" "${var}")"
    help_text="${HOST_VAR_HELP[${var}]:-}"

    printf "  ${CYAN}%s${NC}\n" "${var}"
    [ -n "${help_text}" ] && printf "  ${GRAY}%s${NC}\n" "${help_text}"
    printf "  ${GRAY}Valor atual: %s${NC}\n" "${current:-<vazio>}"

    # Avisar se o valor atual parece caminho Windows
    if [ -n "${current}" ] && ! _validate_linux_path "${var}" "${current}"; then
        printf "  ${YELLOW}Informe um caminho Linux para substituir.${NC}\n"
    fi

    printf "  Novo valor (Enter para manter): "
    read -r new_val
    if [ -n "${new_val}" ]; then
        if _validate_linux_path "${var}" "${new_val}"; then
            _set_env_value "${ENV_FILE}" "${var}" "${new_val}"
            ok "${var}=${new_val}"
        else
            printf "  ${YELLOW}Deseja usar este caminho mesmo assim? (S/N) ${NC}"
            read -r confirm
            if [[ "${confirm:-}" =~ ^[Ss] ]]; then
                _set_env_value "${ENV_FILE}" "${var}" "${new_val}"
                ok "${var}=${new_val} (mantido com aviso)"
            else
                warn "${var} mantido: ${current:-<vazio>}"
            fi
        fi
    else
        ok "${var} mantido: ${current:-<vazio>}"
    fi
    printf "\n"
done

# ── HOST_* derivados (TSK00.05.01 #95) ──────────────────────────────────────
# Variáveis declaradas como OBJETO em products.json.host_dir_vars[] — derivam
# automaticamente do parent de uma variável-fonte (tipicamente HOST_LOG_DIR).
# Hoje: HOST_SECRETS_DIR (mode 700) + HOST_BACKUPS_DIR para rpa/full.
# Anteriormente: workflow CD do siscan-rpa fazia essa derivação inline
# (linhas 311-352 do cd_imagem_certificada_selfhosted.yml) — movido pra cá
# para que workflows passem a confiar no .env já configurado.
printf "\n${WHITE}  Variáveis HOST_* derivadas automaticamente${NC}\n"
printf "  ${GRAY}(declaradas em scripts/data/products.json — não requerem input)${NC}\n\n"
ensure_host_paths_derived "${ENV_FILE}" || warn "Uma ou mais variáveis derivadas não puderam ser configuradas — revise ${ENV_FILE}"

# ════════════════════════════════════════════════════════════════════════════
step "FASE 6 — Criação dos diretórios HOST_*"
# ════════════════════════════════════════════════════════════════════════════

ensure_host_paths "${ENV_FILE}"

# ════════════════════════════════════════════════════════════════════════════
step "FASE 7 — GitHub Actions Runner"
# ════════════════════════════════════════════════════════════════════════════

# Lógica idempotente delegada para o módulo _runner.sh (issue #51).
# Estados detectados:
#   N/A  - $RUNNER_DIR não existe        → cria, baixa, registra, instala, start
#   1    - dir existe, binários ausentes → baixa, registra, instala, start
#   2    - binários OK, .runner ausente  → registra, instala, start
#   3    - .runner OK, systemd ausente   → instala, start
#   4    - tudo presente                 → garante start (idempotente)

# shellcheck source=scripts/deploy_server/_runner.sh
source "${SPECIALISTS_DIR}/_runner.sh"

RUNNER_STATE=$(runner_get_state "${RUNNER_DIR}")

# Override do classificador via --force-download-binaries (TSK00.04.01).
# Reinstalação em VM com volume reaproveitado pode ter binários velhos no
# disco; operador opta explicitamente por refresh. Estados N/A e 1 já
# baixam, não precisam override.
if [ "${FORCE_DOWNLOAD_BINARIES}" = "true" ] && [ "${RUNNER_STATE}" != "N/A" ] && [ "${RUNNER_STATE}" != "1" ]; then
    warn "--force-download-binaries ativo: state ${RUNNER_STATE} → 1 (forçando re-download)"
    RUNNER_STATE=1
fi

# Auto-detecção de obsolescência via mtime (TSK00.04.02). Reinstalação em
# volume com binários antigos no disco — pega o mesmo caso da flag manual,
# mas sem precisar o operador decidir explicitamente. Default 30d.
if [ "${RUNNER_STATE}" != "N/A" ] && [ "${RUNNER_STATE}" != "1" ]; then
    if runner_binaries_likely_obsolete "${RUNNER_DIR}"; then
        warn "Binários do runner aparentam obsoletos (mtime > ${RUNNER_OBSOLETE_DAYS:-30}d) — forçando re-download"
        RUNNER_STATE=1
    fi
fi

# Pre-flight defensivo de deps de SO (TSK00.04.04). Se state ≥ 2 nesse
# ponto, vamos pular runner_download_binaries — e com ele installdependen-
# cies.sh. Deps de SO podem ter mudado entre instalação inicial e re-run
# do setup (apt upgrade, distro upgrade). installdependencies é idempo-
# tente — apt skip pacotes presentes (~2-3s caminho feliz). Garante
# baseline correto antes de qualquer register.
if [ "${RUNNER_STATE}" != "N/A" ] && [ "${RUNNER_STATE}" != "1" ]; then
    runner_install_runtime_deps "${RUNNER_DIR}" || true
fi

# Bootstrap incremental: N/A e 1 precisam de download.
case "${RUNNER_STATE}" in
    N/A|1)
        printf "  ${WHITE}Download do runner${NC}\n\n"
        runner_download_binaries "${RUNNER_DIR}" \
            || fail "Falha no download do runner. Verifique conectividade com github.com."
        RUNNER_STATE=2
        ;;
    *)
        ok "Binários do runner presentes em ${RUNNER_DIR}"
        ;;
esac

# Estado 2 → 3: registro com URL + token interativo.
if [ "${RUNNER_STATE}" = "2" ]; then
    # Pré-purge defensiva: runner_get_state olha só .runner, mas auto-update
    # cria .runner_migrated (cópia 1:1 do .runner). Se .runner_migrated
    # persistir, config.sh --unattended --replace falha com "already
    # configured". Cenário possível em reinstalação (volume reaproveitado).
    # Idempotente — seguro mesmo numa instalação greenfield.
    runner_purge_local_config "${RUNNER_DIR}" \
        || fail "Falha ao limpar artefatos residuais (.runner_migrated/.path) — verifique permissões em ${RUNNER_DIR}."

    printf "\n${WHITE}  Registro do runner no repositório GitHub${NC}\n\n"
    printf "  O token de registro é gerado em:\n"
    printf "  ${CYAN}Settings → Actions → Runners → New self-hosted runner${NC}\n\n"

    printf "  URL do repositório\n"
    printf "  ${GRAY}(padrão: %s)${NC}\n" "${REPO_URL_DEFAULT}"
    printf "  URL (Enter para usar o padrão): "
    read -r REPO_URL
    REPO_URL="${REPO_URL:-${REPO_URL_DEFAULT}}"
    [ -z "${REPO_URL}" ] && fail "URL do repositório é obrigatória"

    printf "\n  Token de registro: "
    read -rs REG_TOKEN
    printf "\n"
    [ -z "${REG_TOKEN}" ] && fail "Token de registro é obrigatório"

    runner_register "${RUNNER_DIR}" "${REPO_URL}" "${REG_TOKEN}" "${RUNNER_NAME}" "${RUNNER_LABEL}" \
        || fail "Falha ao registrar o runner. Verifique URL e token (tokens expiram em ~5min)."
    RUNNER_STATE=3
else
    ok "Runner já registrado em ${RUNNER_DIR}"
fi

# Estado 3 → 4: instala systemd unit.
if [ "${RUNNER_STATE}" = "3" ]; then
    runner_install_service "${RUNNER_DIR}" "${CURRENT_USER}" \
        || fail "Falha ao instalar serviço systemd do runner."
    RUNNER_STATE=4
fi

# Estado 4: garantir que o serviço está rodando.
if runner_service_status_active "${RUNNER_DIR}"; then
    ok "Serviço do runner: ativo"
else
    runner_start_service "${RUNNER_DIR}" \
        || fail "Falha ao iniciar o serviço do runner."
fi

# ════════════════════════════════════════════════════════════════════════════
step "FASE 8 — Persistir variáveis no ambiente do runner"
# ════════════════════════════════════════════════════════════════════════════

# O runner roda como serviço systemd e NÃO carrega ~/.bashrc nem
# /etc/environment. O único mecanismo para injetar variáveis nos
# jobs é o arquivo .env dentro do diretório do runner.
RUNNER_ENV="${RUNNER_DIR}/.env"
if [ -d "${RUNNER_DIR}" ]; then
    touch "${RUNNER_ENV}" 2>/dev/null || true
    _set_env_value "${RUNNER_ENV}" "COMPOSE_DIR" "${COMPOSE_DIR}"
    ok "COMPOSE_DIR=${COMPOSE_DIR} → ${RUNNER_ENV}"

    # O runner foi iniciado na fase 7 antes do COMPOSE_DIR ser gravado.
    # Reiniciar para que ele carregue o .env atualizado.
    if [ -f "${RUNNER_DIR}/svc.sh" ]; then
        info "Reiniciando o runner para carregar COMPOSE_DIR..."
        sudo "${RUNNER_DIR}/svc.sh" stop 2>/dev/null || true
        sudo "${RUNNER_DIR}/svc.sh" start 2>/dev/null || true
        RUNNER_SVC_STATUS=$(sudo "${RUNNER_DIR}/svc.sh" status 2>/dev/null || true)
        if echo "${RUNNER_SVC_STATUS}" | grep -qi "active\|running"; then
            ok "Runner reiniciado — COMPOSE_DIR carregado"
        else
            warn "Runner pode não ter reiniciado — verifique com: sudo ${RUNNER_DIR}/svc.sh status"
        fi
    fi
else
    warn "Runner não instalado — variável não persistida"
    warn "Se instalar o runner depois, adicione ao ${RUNNER_ENV}:"
    printf "  ${GRAY}COMPOSE_DIR=%s${NC}\n" "${COMPOSE_DIR}"
fi

# Persistir em /etc/environment (para sessões interativas)
ETC_ENV="/etc/environment"
if [ -w "${ETC_ENV}" ] 2>/dev/null || command -v sudo &>/dev/null; then
    if grep -q "^COMPOSE_DIR=" "${ETC_ENV}" 2>/dev/null; then
        sudo sed -i "s|^COMPOSE_DIR=.*|COMPOSE_DIR=\"${COMPOSE_DIR}\"|" "${ETC_ENV}" 2>/dev/null || true
    else
        echo "COMPOSE_DIR=\"${COMPOSE_DIR}\"" | sudo tee -a "${ETC_ENV}" >/dev/null 2>/dev/null || true
    fi
    ok "COMPOSE_DIR persistido em /etc/environment"
fi

# ════════════════════════════════════════════════════════════════════════════
step "FASE 9 — Permissões Docker"
# ════════════════════════════════════════════════════════════════════════════

if id -nG "${CURRENT_USER}" 2>/dev/null | grep -qw docker; then
    ok "Usuário '${CURRENT_USER}' já está no grupo 'docker'"
else
    info "Adicionando '${CURRENT_USER}' ao grupo 'docker'..."
    sudo usermod -aG docker "${CURRENT_USER}" \
        || fail "Não foi possível adicionar '${CURRENT_USER}' ao grupo 'docker'. Execute manualmente: sudo usermod -aG docker ${CURRENT_USER}"
    ok "Usuário '${CURRENT_USER}' adicionado ao grupo 'docker'"
    printf "\n  ${YELLOW}ATENÇÃO: é necessário logout/login para que a mudança de grupo${NC}\n"
    printf "  ${YELLOW}tenha efeito na sessão atual do terminal.${NC}\n"
    printf "  ${GRAY}O serviço do runner, por reiniciar via systemd, já terá o grupo.${NC}\n"
fi

# ════════════════════════════════════════════════════════════════════════════
step "FASE 10 — Resumo e próximos passos"
# ════════════════════════════════════════════════════════════════════════════

printf "  ${GREEN}Setup concluído!${NC}\n\n"

printf "  ${WHITE}O que foi configurado:${NC}\n"
ok "Produto: ${PRODUCT_DISPLAY} (${SISCAN_PRODUCT})"
ok "Stack:   ${COMPOSE_DIR}"
ok "Compose: ${COMPOSE_DIR}/${COMPOSE_FILE}"
ok "Env:     ${ENV_FILE}"
ok "Runner:  ${RUNNER_DIR}"
ok "Label:   ${RUNNER_LABEL}"

printf "\n  ${WHITE}Próximos passos:${NC}\n\n"

printf "  1. Revise o arquivo .env:\n"
printf "     ${CYAN}cat %s${NC}\n\n" "${ENV_FILE}"

printf "  2. Confirme que o runner está visível no GitHub:\n"
printf "     ${CYAN}Settings → Actions → Runners${NC} (status esperado: Idle)\n\n"

printf "  3. Confirme o status do serviço:\n"
printf "     ${CYAN}sudo %s/svc.sh status${NC}\n\n" "${RUNNER_DIR}"

printf "  4. O próximo merge para 'main' acionará o deploy automaticamente.\n"
printf "     Para acionar manualmente:\n"
printf "     ${CYAN}Actions → CD — Deploy Produção → Run workflow${NC}\n\n"

printf "  5. Para acompanhar os logs do runner:\n"
printf "     ${CYAN}journalctl -u actions.runner.*.service -f${NC}\n\n"

printf "  6. Para acompanhar os logs da stack após o primeiro deploy:\n"
printf "     ${CYAN}docker compose -f %s/%s logs -f${NC}\n\n" "${COMPOSE_DIR}" "${COMPOSE_FILE}"

printf "  ${GRAY}Referência completa: docs/DEPLOY_AUTOMATICO.md — Opção 1.A${NC}\n\n"

printf "${CYAN}══════════════════════════════════════════════════${NC}\n"
printf "  ${WHITE}Você está em:${NC} $(pwd)\n"
printf "  ${WHITE}Diretório da stack:${NC} ${COMPOSE_DIR}\n"
printf "${CYAN}══════════════════════════════════════════════════${NC}\n\n"
printf "  Para ir ao diretório da stack:\n"
printf "  ${CYAN}cd %s${NC}\n\n" "${COMPOSE_DIR}"

fi # fim do guard BASH_SOURCE
