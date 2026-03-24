#!/usr/bin/env bash
# -------------------------------------------
# Setup do Servidor — Opção 1.A Self-hosted Runner
# -------------------------------------------
# Arquivo: siscan-server-setup.sh
# Propósito: Preparar servidor Linux para receber deploys automáticos do
#            SISCAN (RPA e/ou Dashboard) via GitHub Actions self-hosted runner.
#
# Uso:
#   bash ./siscan-server-setup.sh --product rpa          # Setup da VM do RPA
#   bash ./siscan-server-setup.sh --product dashboard     # Setup da VM do Dashboard
#   bash ./siscan-server-setup.sh --product full          # Setup HOST (tudo junto)
#   bash ./siscan-server-setup.sh                         # pergunta interativamente
#
#   bash ./siscan-server-setup.sh --product rpa --check       # Verifica consistência do RPA
#   bash ./siscan-server-setup.sh --product dashboard --check # Verifica consistência do Dashboard
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
RUN_MODE="setup"
while [[ $# -gt 0 ]]; do
    case "${1}" in
        --product) SISCAN_PRODUCT="${2:-}"; shift 2 ;;
        --product=*) SISCAN_PRODUCT="${1#*=}"; shift ;;
        --check) RUN_MODE="check"; shift ;;
        *) shift ;;
    esac
done

# ────────────────────────────────────────────────────────────────────────────
# Configuração
# ────────────────────────────────────────────────────────────────────────────
RUNNER_DIR="${RUNNER_DIR:-${HOME}/actions-runner}"
CURRENT_USER="$(whoami)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ────────────────────────────────────────────────────────────────────────────
# Helpers de output
# ────────────────────────────────────────────────────────────────────────────
step() {
    printf "\n${CYAN}══════════════════════════════════════════════════${NC}\n"
    printf "${WHITE}  %s${NC}\n" "${1}"
    printf "${CYAN}══════════════════════════════════════════════════${NC}\n\n"
}

ok()   { printf "  ${GREEN}✔${NC}  %s\n" "${1}"; }
info() { printf "  ${GRAY}→${NC}  %s\n" "${1}"; }
warn() { printf "  ${YELLOW}⚠${NC}  %s\n" "${1}"; }
fail() { printf "\n${RED}ERRO: %s${NC}\n\n" "${1}" >&2; exit 1; }

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

# ════════════════════════════════════════════════════════════════════════════
# MAIN — só executa quando o script é chamado diretamente (não via source)
# ════════════════════════════════════════════════════════════════════════════
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then

# ── Seleção de produto ────────────────────────────────────────────────────
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

# ════════════════════════════════════════════════════════════════════════════
# MODO CHECK — verifica consistência da instalação existente
# ════════════════════════════════════════════════════════════════════════════
if [ "${RUN_MODE}" = "check" ]; then

printf "\n${WHITE}╔════════════════════════════════════════════════════╗${NC}\n"
printf "${WHITE}║  %s — Verificação de Consistência$(printf '%*s' $((18 - ${#PRODUCT_DISPLAY})) '')║${NC}\n" "${PRODUCT_DISPLAY}"
printf "${WHITE}╚════════════════════════════════════════════════════╝${NC}\n\n"

CHECK_ERRORS=0

# ── 1. Repositório do assistente ─────────────────────────────────────────
step "1. Repositório do assistente"
if [ -d "${COMPOSE_DIR}/.git" ]; then
    ok "Repositório git detectado em ${COMPOSE_DIR}"

    # Buscar atualizações do remoto sem alterar nada
    git -C "${COMPOSE_DIR}" fetch origin main --quiet 2>/dev/null || true

    LOCAL_HEAD=$(git -C "${COMPOSE_DIR}" rev-parse HEAD 2>/dev/null || echo "")
    REMOTE_HEAD=$(git -C "${COMPOSE_DIR}" rev-parse origin/main 2>/dev/null || echo "")

    if [ -z "${LOCAL_HEAD}" ] || [ -z "${REMOTE_HEAD}" ]; then
        warn "Não foi possível comparar versões local e remota"
    elif [ "${LOCAL_HEAD}" = "${REMOTE_HEAD}" ]; then
        ok "Repositório atualizado (branch local = origin/main)"
    else
        BEHIND_COUNT=$(git -C "${COMPOSE_DIR}" rev-list --count HEAD..origin/main 2>/dev/null || echo "?")
        warn "Repositório desatualizado — ${BEHIND_COUNT} commit(s) atrás de origin/main"
        printf "\n  ${WHITE}Deseja atualizar o repositório agora? (git pull origin main) (S/N) ${NC}"
        read -r do_pull
        if [[ "${do_pull:-}" =~ ^[Ss] ]]; then
            printf "\n"
            if git -C "${COMPOSE_DIR}" pull origin main; then
                ok "Repositório atualizado com sucesso"
            else
                warn "git pull falhou — pode haver alterações locais não commitadas"
                printf "  ${GRAY}Resolva manualmente com: cd %s && git status${NC}\n" "${COMPOSE_DIR}"
                CHECK_ERRORS=$((CHECK_ERRORS + 1))
            fi
        else
            info "Pulando atualização. Execute manualmente: cd ${COMPOSE_DIR} && git pull origin main"
        fi
    fi
else
    info "${COMPOSE_DIR} não é um repositório git — verificação de versão ignorada"
fi

# ── 2. Compose file ──────────────────────────────────────────────────────
step "2. Compose file"
COMPOSE_FILE_PATH="${COMPOSE_DIR}/${COMPOSE_FILE}"
if [ -f "${COMPOSE_FILE_PATH}" ]; then
    ok "${COMPOSE_FILE} presente"
else
    warn "${COMPOSE_FILE} NÃO encontrado em ${COMPOSE_DIR}"
    CHECK_ERRORS=$((CHECK_ERRORS + 1))
fi

# ── 3. .env sample ──────────────────────────────────────────────────────
step "3. Sample de referência"
ENV_SAMPLE_PATH="${COMPOSE_DIR}/${ENV_SAMPLE_NAME}"
if [ -f "${ENV_SAMPLE_PATH}" ]; then
    ok "${ENV_SAMPLE_NAME} presente"
else
    # Tentar localizar no diretório do script
    if [ -f "${SCRIPT_DIR}/${ENV_SAMPLE_NAME}" ]; then
        ENV_SAMPLE_PATH="${SCRIPT_DIR}/${ENV_SAMPLE_NAME}"
        ok "${ENV_SAMPLE_NAME} encontrado em ${SCRIPT_DIR}"
    else
        warn "${ENV_SAMPLE_NAME} NÃO encontrado"
        CHECK_ERRORS=$((CHECK_ERRORS + 1))
    fi
fi

# ── 4. Consistência .env vs sample ───────────────────────────────────────
step "4. Variáveis do .env"
if [ ! -f "${ENV_FILE}" ]; then
    warn ".env não encontrado em ${COMPOSE_DIR} — execute o setup primeiro"
    CHECK_ERRORS=$((CHECK_ERRORS + 1))
elif [ -f "${ENV_SAMPLE_PATH}" ]; then
    # Extrair chaves do sample (ignora comentários e linhas vazias)
    SAMPLE_KEYS=$(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "${ENV_SAMPLE_PATH}" | cut -d= -f1 | sort)
    ENV_KEYS=$(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "${ENV_FILE}" | cut -d= -f1 | sort)

    MISSING_KEYS=$(comm -23 <(echo "${SAMPLE_KEYS}") <(echo "${ENV_KEYS}"))

    if [ -z "${MISSING_KEYS}" ]; then
        ok "Todas as variáveis do sample estão presentes no .env"
    else
        MISSING_COUNT=$(echo "${MISSING_KEYS}" | wc -l)
        warn "${MISSING_COUNT} variável(is) do sample ausente(s) no .env:"
        printf "\n"

        while IFS= read -r key; do
            sample_val=$(grep -E "^${key}=" "${ENV_SAMPLE_PATH}" | head -1 | cut -d= -f2-)
            printf "  ${YELLOW}•${NC} ${CYAN}%s${NC}" "${key}"
            [ -n "${sample_val}" ] && printf " ${GRAY}(default: %s)${NC}" "${sample_val}"
            printf "\n"
        done <<< "${MISSING_KEYS}"

        printf "\n  ${WHITE}Deseja adicionar as variáveis faltantes ao .env com os valores default do sample? (S/N) ${NC}"
        read -r add_missing
        if [[ "${add_missing:-}" =~ ^[Ss] ]]; then
            printf "\n"
            while IFS= read -r key; do
                sample_line=$(grep -E "^${key}=" "${ENV_SAMPLE_PATH}" | head -1)
                echo "${sample_line}" >> "${ENV_FILE}"
                ok "Adicionado: ${sample_line}"
            done <<< "${MISSING_KEYS}"
        else
            info "Variáveis não adicionadas. Edite o .env manualmente se necessário."
            CHECK_ERRORS=$((CHECK_ERRORS + 1))
        fi
    fi

    # Verificar variáveis com valor vazio que são obrigatórias
    for key in DATABASE_HOST DATABASE_PASSWORD; do
        val="$(_read_env_value "${ENV_FILE}" "${key}")"
        if [ -z "${val}" ]; then
            warn "${key} está vazio no .env — preencha antes de subir a stack"
            CHECK_ERRORS=$((CHECK_ERRORS + 1))
        else
            ok "${key} configurado"
        fi
    done

    if [ "${SISCAN_PRODUCT}" = "dashboard" ]; then
        val="$(_read_env_value "${ENV_FILE}" "RPA_DATABASE_URL")"
        if [ -z "${val}" ]; then
            warn "RPA_DATABASE_URL está vazio no .env — o sync não funcionará"
            CHECK_ERRORS=$((CHECK_ERRORS + 1))
        else
            ok "RPA_DATABASE_URL configurado"
        fi
    fi
else
    info "Não foi possível comparar — sample não encontrado"
fi

# ── 5. COMPOSE_DIR no .env do runner ─────────────────────────────────────
step "5. Runner — COMPOSE_DIR"
RUNNER_ENV="${RUNNER_DIR}/.env"
if [ -f "${RUNNER_ENV}" ]; then
    RUNNER_COMPOSE_DIR=$(grep -E "^COMPOSE_DIR=" "${RUNNER_ENV}" 2>/dev/null | cut -d= -f2-)
    if [ -n "${RUNNER_COMPOSE_DIR}" ]; then
        ok "COMPOSE_DIR=${RUNNER_COMPOSE_DIR} em ${RUNNER_ENV}"
        if [ "${RUNNER_COMPOSE_DIR}" != "${COMPOSE_DIR}" ]; then
            warn "COMPOSE_DIR do runner (${RUNNER_COMPOSE_DIR}) difere do diretório atual (${COMPOSE_DIR})"
            CHECK_ERRORS=$((CHECK_ERRORS + 1))
        fi
    else
        warn "COMPOSE_DIR não encontrado em ${RUNNER_ENV}"
        printf "\n  ${WHITE}Deseja adicionar COMPOSE_DIR=${COMPOSE_DIR} ao ${RUNNER_ENV}? (S/N) ${NC}"
        read -r add_compose_dir
        if [[ "${add_compose_dir:-}" =~ ^[Ss] ]]; then
            echo "COMPOSE_DIR=${COMPOSE_DIR}" >> "${RUNNER_ENV}"
            ok "COMPOSE_DIR adicionado ao ${RUNNER_ENV}"
        else
            CHECK_ERRORS=$((CHECK_ERRORS + 1))
        fi
    fi
else
    warn "Arquivo ${RUNNER_ENV} não encontrado — runner pode não estar instalado"
    CHECK_ERRORS=$((CHECK_ERRORS + 1))
fi

# ── 6. Status do runner ──────────────────────────────────────────────────
step "6. Runner — status do serviço"
if [ -f "${RUNNER_DIR}/svc.sh" ]; then
    RUNNER_SVC_STATUS=$(sudo "${RUNNER_DIR}/svc.sh" status 2>/dev/null || true)
    if echo "${RUNNER_SVC_STATUS}" | grep -qi "active\|running"; then
        ok "Serviço do runner: ativo"
    else
        warn "Serviço do runner pode não estar ativo"
        printf "  ${GRAY}Verifique com: sudo %s/svc.sh status${NC}\n" "${RUNNER_DIR}"
        printf "\n  ${WHITE}Deseja reiniciar o runner? (S/N) ${NC}"
        read -r restart_runner
        if [[ "${restart_runner:-}" =~ ^[Ss] ]]; then
            sudo "${RUNNER_DIR}/svc.sh" stop 2>/dev/null || true
            sudo "${RUNNER_DIR}/svc.sh" start 2>/dev/null || true
            RUNNER_SVC_STATUS=$(sudo "${RUNNER_DIR}/svc.sh" status 2>/dev/null || true)
            if echo "${RUNNER_SVC_STATUS}" | grep -qi "active\|running"; then
                ok "Runner reiniciado com sucesso"
            else
                warn "Runner pode não ter reiniciado corretamente"
                CHECK_ERRORS=$((CHECK_ERRORS + 1))
            fi
        else
            CHECK_ERRORS=$((CHECK_ERRORS + 1))
        fi
    fi
else
    warn "Runner não instalado em ${RUNNER_DIR}"
    CHECK_ERRORS=$((CHECK_ERRORS + 1))
fi

# ── Resumo ───────────────────────────────────────────────────────────────
printf "\n${CYAN}══════════════════════════════════════════════════${NC}\n"
if [ ${CHECK_ERRORS} -eq 0 ]; then
    printf "  ${GREEN}Verificação concluída — tudo OK!${NC}\n"
else
    printf "  ${YELLOW}Verificação concluída — %d ponto(s) requer(em) atenção.${NC}\n" "${CHECK_ERRORS}"
fi
printf "${CYAN}══════════════════════════════════════════════════${NC}\n\n"

exit ${CHECK_ERRORS}

fi # fim do modo check

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

# ── RPA_DATABASE_URL (só para dashboard) ──────────────────────────────────
if [ "${SISCAN_PRODUCT}" = "dashboard" ]; then
    RPA_DB_URL_VAL="$(_read_env_value "${ENV_FILE}" "RPA_DATABASE_URL")"
    if [ -z "${RPA_DB_URL_VAL}" ]; then
        printf "\n  ${CYAN}RPA_DATABASE_URL${NC} — Conexão ao banco do siscan-rpa\n"
        printf "  ${GRAY}Formato: postgresql://usuario:senha@host:porta/banco${NC}\n"
        printf "  ${GRAY}Exemplo: postgresql://siscan_rpa:senha@192.168.1.10:5432/siscan_rpa${NC}\n"
        printf "  Valor: "
        read -r RPA_DB_URL_NEW
        if [ -n "${RPA_DB_URL_NEW}" ]; then
            _set_env_value "${ENV_FILE}" "RPA_DATABASE_URL" "${RPA_DB_URL_NEW}"
            ok "RPA_DATABASE_URL configurado"
        else
            warn "RPA_DATABASE_URL não definido — o sync não funcionará até ser configurado"
        fi
    else
        ok "RPA_DATABASE_URL já configurado"
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

# ════════════════════════════════════════════════════════════════════════════
step "FASE 6 — Criação dos diretórios HOST_*"
# ════════════════════════════════════════════════════════════════════════════

ensure_host_paths "${ENV_FILE}"

# ════════════════════════════════════════════════════════════════════════════
step "FASE 7 — GitHub Actions Runner"
# ════════════════════════════════════════════════════════════════════════════

RUNNER_ALREADY_INSTALLED=false
if [ -f "${RUNNER_DIR}/config.sh" ]; then
    RUNNER_ALREADY_INSTALLED=true
    ok "Runner já instalado em ${RUNNER_DIR}"
fi

if ${RUNNER_ALREADY_INSTALLED}; then
    # Verificar status do serviço
    RUNNER_SVC_STATUS=$(sudo "${RUNNER_DIR}/svc.sh" status 2>/dev/null || true)
    if echo "${RUNNER_SVC_STATUS}" | grep -qi "active\|running"; then
        ok "Serviço do runner: ativo"
    else
        warn "Serviço do runner pode não estar ativo. Verifique com:"
        printf "  ${GRAY}sudo %s/svc.sh status${NC}\n" "${RUNNER_DIR}"
        printf "  ${GRAY}sudo %s/svc.sh start${NC}\n" "${RUNNER_DIR}"
    fi
else
    printf "  ${WHITE}Download e registro do runner${NC}\n\n"

    # Detectar arquitetura
    ARCH=$(uname -m)
    case "${ARCH}" in
        x86_64)  RUNNER_ARCH="x64" ;;
        aarch64) RUNNER_ARCH="arm64" ;;
        *) fail "Arquitetura não suportada pelo runner: ${ARCH}" ;;
    esac
    info "Arquitetura: ${ARCH} → linux-${RUNNER_ARCH}"

    # Obter versão mais recente
    info "Consultando versão mais recente do runner..."
    RUNNER_VERSION=$(curl -fsSL \
        "https://api.github.com/repos/actions/runner/releases/latest" \
        | grep '"tag_name"' \
        | sed 's/.*"v\([^"]*\)".*/\1/' \
        | head -1)

    if [ -z "${RUNNER_VERSION}" ]; then
        fail "Não foi possível obter a versão do runner. Verifique a conectividade com github.com."
    fi
    info "Versão: ${RUNNER_VERSION}"

    RUNNER_TARBALL_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"

    # Baixar e extrair
    mkdir -p "${RUNNER_DIR}"
    TARBALL="${RUNNER_DIR}/actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"

    info "Baixando runner em ${TARBALL}..."
    if ! curl -fsSL --progress-bar -o "${TARBALL}" "${RUNNER_TARBALL_URL}"; then
        rm -f "${TARBALL}"
        fail "Falha ao baixar o runner. Verifique a conectividade."
    fi

    info "Extraindo em ${RUNNER_DIR}..."
    tar xzf "${TARBALL}" -C "${RUNNER_DIR}"
    rm -f "${TARBALL}"
    ok "Runner extraído"

    # Registro
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

    info "Registrando runner com label '${RUNNER_LABEL}'..."
    if ! (cd "${RUNNER_DIR}" && ./config.sh \
            --url "${REPO_URL}" \
            --token "${REG_TOKEN}" \
            --labels "${RUNNER_LABEL}" \
            --name "${RUNNER_NAME}" \
            --unattended \
            --replace); then
        fail "Falha ao registrar o runner. Verifique a URL e o token (tokens expiram após alguns minutos)."
    fi
    ok "Runner registrado: ${RUNNER_NAME} [${RUNNER_LABEL}]"

    # Instalar e iniciar como serviço systemd
    # sudo não preserva o diretório de trabalho — passar via bash -c para garantir
    info "Instalando runner como serviço systemd (usuário: ${CURRENT_USER})..."
    if ! sudo bash -c "cd '${RUNNER_DIR}' && ./svc.sh install '${CURRENT_USER}'"; then
        fail "Falha ao instalar o serviço systemd do runner."
    fi

    if ! sudo bash -c "cd '${RUNNER_DIR}' && ./svc.sh start"; then
        fail "Falha ao iniciar o serviço do runner."
    fi
    ok "Serviço do runner instalado e iniciado"
fi

# ════════════════════════════════════════════════════════════════════════════
step "FASE 8 — Persistir variáveis no ambiente do runner"
# ════════════════════════════════════════════════════════════════════════════

# O runner roda como serviço systemd e NÃO carrega ~/.bashrc nem
# /etc/environment. O único mecanismo para injetar variáveis nos
# jobs é o arquivo .env dentro do diretório do runner.
# O runner roda como serviço systemd e NÃO carrega ~/.bashrc nem
# /etc/environment. O único mecanismo para injetar variáveis nos
# jobs é o arquivo .env dentro do diretório do runner.
RUNNER_ENV="${RUNNER_DIR}/.env"
if [ -d "${RUNNER_DIR}" ]; then
    touch "${RUNNER_ENV}" 2>/dev/null || true
    _set_env_value "${RUNNER_ENV}" "COMPOSE_DIR" "${COMPOSE_DIR}"
    ok "COMPOSE_DIR=${COMPOSE_DIR} → ${RUNNER_ENV}"
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
