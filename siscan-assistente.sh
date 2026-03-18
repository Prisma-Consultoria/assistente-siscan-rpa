#!/usr/bin/env bash
# -------------------------------------------
# CLI do Assistente SIScan RPA
# -------------------------------------------
# Arquivo: siscan-assistente.sh
# Propósito: Auxiliar no deploy, atualização e gerenciamento do ambiente do SIScan RPA.
#
# Uso:
#   bash ./siscan-assistente.sh
#   ./siscan-assistente.sh   (requer chmod +x)
#
# Pré-requisitos:
#   - Docker e docker compose instalados e disponíveis no PATH.
#   - bash 4+ (para arrays associativos)
#   - jq (opcional, para leitura de .env.help.json)
#   - curl ou wget (para atualização do assistente)
#
# Mantenedores:
#   - Prisma-Consultoria / Time: Infra / DevOps
#
# Registro de alterações:
#   2025-11-30  v0.1  Versão inicial para Linux/bash (port do siscan-assistente.ps1)
# -------------------------------------------

# Note: We intentionally do NOT use 'set -e' (errexit) because this is an
# interactive menu-driven script where many functions return non-zero codes
# as normal control flow (e.g., check_service returning 1 when no container
# is found). Each call site handles errors explicitly.
set -uo pipefail

# ---------------------------------------------------------------------------
# Diretório do script (equivalente a $PSScriptRoot)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Cores ANSI
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
WHITE='\033[1;37m'
DARK_GRAY='\033[2;37m'
DARK_CYAN='\033[0;36m'
NC='\033[0m'   # No Color / Reset

# ---------------------------------------------------------------------------
# Variáveis globais
# ---------------------------------------------------------------------------
CRED_FILE="credenciais.txt"
IMAGE_PATH="ghcr.io/prisma-consultoria/siscan-rpa-rpa:main"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.prd.host.yml"

# Credenciais em memória (não persistidas por padrão)
CRED_USER=""
CRED_TOKEN=""

# ---------------------------------------------------------------------------
# Textos de ajuda para variáveis do .env
# Estes são os padrões embutidos; podem ser sobrescritos por .env.help.json
# ---------------------------------------------------------------------------
declare -A ENV_HELP_TEXTS=(
    [SECRET_KEY]="Chave de assinatura de sessão web. Gerada automaticamente se estiver vazia. Não compartilhe este valor."
)

# Entradas completas do help (preenchido via .env.help.json se disponível)
# Chaves: KEY__help, KEY__secret, KEY__required, KEY__example
declare -A ENV_HELP_ENTRIES=()

# ---------------------------------------------------------------------------
# Carrega .env.help.json se disponível (requer jq)
# ---------------------------------------------------------------------------
_load_env_help_json() {
    local help_path="${SCRIPT_DIR}/.env.help.json"
    if [ ! -f "${help_path}" ]; then
        return
    fi
    if ! command -v jq &>/dev/null; then
        return
    fi

    # Limpa arrays para repopular a partir do JSON
    unset ENV_HELP_TEXTS ENV_HELP_ENTRIES
    declare -gA ENV_HELP_TEXTS=()
    declare -gA ENV_HELP_ENTRIES=()

    # Itera sobre as chaves dentro de .keys
    local keys
    keys="$(jq -r '.keys | keys[]' "${help_path}" 2>/dev/null)" || return

    while IFS= read -r k; do
        [ -z "${k}" ] && continue

        local help secret required example type_val
        help="$(jq -r --arg k "${k}" '.keys[$k].help // ""' "${help_path}" 2>/dev/null)"
        secret="$(jq -r --arg k "${k}" '.keys[$k].secret // "false"' "${help_path}" 2>/dev/null)"
        required="$(jq -r --arg k "${k}" '.keys[$k].required // "false"' "${help_path}" 2>/dev/null)"
        example="$(jq -r --arg k "${k}" '.keys[$k].example // ""' "${help_path}" 2>/dev/null)"
        type_val="$(jq -r --arg k "${k}" '.keys[$k].type // ""' "${help_path}" 2>/dev/null)"

        [ -n "${help}" ] && ENV_HELP_TEXTS["${k}"]="${help}"
        ENV_HELP_ENTRIES["${k}__help"]="${help}"
        ENV_HELP_ENTRIES["${k}__secret"]="${secret}"
        ENV_HELP_ENTRIES["${k}__required"]="${required}"
        ENV_HELP_ENTRIES["${k}__example"]="${example}"
        ENV_HELP_ENTRIES["${k}__type"]="${type_val}"
    done <<< "${keys}"
}

_load_env_help_json

# ---------------------------------------------------------------------------
# Utilitários gerais
# ---------------------------------------------------------------------------

# Equivalente a Pause / Read-Host "Pressione Enter..."
pause() {
    echo ""
    read -rp "Pressione Enter para continuar..." _PAUSE_DUMMY
}

# ---------------------------------------------------------------------------
# is_docker_available
# Verifica se o Docker está disponível.
# Retorna 0 (ok) ou 1 (indisponível).
# ---------------------------------------------------------------------------
is_docker_available() {
    local ver
    ver="$(docker --version 2>&1)"
    local rc=$?
    if [ ${rc} -ne 0 ]; then
        printf "${RED}Docker não disponível: %s${NC}\n" "${ver}"
        return 1
    fi
    printf "${GREEN}%s${NC}\n" "${ver}"
    return 0
}

# ---------------------------------------------------------------------------
# get_expected_service_names
# Analisa o compose file e retorna os nomes dos serviços (um por linha).
# ---------------------------------------------------------------------------
get_expected_service_names() {
    local compose_path="${1:-${COMPOSE_FILE}}"
    if [ ! -f "${compose_path}" ]; then
        return
    fi

    local in_services=false
    while IFS= read -r line; do
        # Detecta a seção services:
        if [[ "${line}" =~ ^[[:space:]]*services[[:space:]]*: ]]; then
            in_services=true
            continue
        fi

        if ${in_services}; then
            # Serviços têm exatamente 2 espaços de indentação
            if [[ "${line}" =~ ^[[:space:]]{2}([a-zA-Z0-9_-]+)[[:space:]]*: ]]; then
                local svc_name="${BASH_REMATCH[1]}"
                # Ignora seções de nível raiz que podem aparecer após services:
                if [[ ! "${svc_name}" =~ ^(version|volumes|networks|configs|secrets)$ ]]; then
                    echo "${svc_name}"
                fi
            fi
            # Para quando encontrar outra seção de nível raiz (sem indentação)
            if [[ "${line}" =~ ^[a-zA-Z] ]]; then
                break
            fi
        fi
    done < "${compose_path}"
}

# ---------------------------------------------------------------------------
# docker_pull_with_progress
# Executa docker pull em background com spinner animado.
# Uso: docker_pull_with_progress "<imagem>"
# Retorna o exit code do docker pull.
# ---------------------------------------------------------------------------
docker_pull_with_progress() {
    local image="${1:-${IMAGE_PATH}}"
    local tmp_output
    tmp_output="$(mktemp)"

    # Inicia o pull em background
    docker pull "${image}" > "${tmp_output}" 2>&1 &
    local pull_pid=$!

    local stages=(
        "Conectando ao registro..."
        "Verificando camadas..."
        "Baixando camadas..."
        "Extraindo camadas..."
        "Finalizando..."
    )
    local spinner_chars=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local stage_idx=0
    local spin_idx=0
    local bar_len=40
    local progress=0
    local direction=1

    printf "\n"

    while kill -0 "${pull_pid}" 2>/dev/null; do
        # Atualiza progresso
        progress=$(( progress + direction * 3 ))
        if [ ${progress} -ge ${bar_len} ]; then
            progress=${bar_len}
            direction=-1
            stage_idx=$(( (stage_idx + 1) % ${#stages[@]} ))
        elif [ ${progress} -le 0 ]; then
            progress=0
            direction=1
        fi

        local spinner="${spinner_chars[$(( spin_idx % ${#spinner_chars[@]} ))]}"
        spin_idx=$(( spin_idx + 1 ))

        # Constrói barra de progresso
        local filled=$(( progress ))
        local empty=$(( bar_len - filled ))
        local bar=""
        local i
        for (( i=0; i<filled; i++ )); do bar+="#"; done
        for (( i=0; i<empty; i++ )); do bar+="-"; done

        local status="${stages[${stage_idx}]}"
        printf "\r${CYAN}%s${NC} [${GREEN}%s${NC}] ${WHITE}%s${NC}    " \
            "${spinner}" "${bar}" "${status}"

        sleep 0.12
    done

    # Aguarda o processo terminar e captura o exit code
    wait "${pull_pid}" 2>/dev/null
    local exit_code=$?

    # Limpa a linha do spinner
    printf "\r%-80s\r" ""

    if [ ${exit_code} -eq 0 ]; then
        printf "${GREEN}Download concluído com sucesso.${NC}\n"
    else
        printf "${RED}Falha no download (exit code: %d)${NC}\n" "${exit_code}"
        if [ -s "${tmp_output}" ]; then
            printf "${GRAY}--- Saída do docker pull ---${NC}\n"
            cat "${tmp_output}"
            printf "${GRAY}----------------------------${NC}\n"
        fi
    fi

    rm -f "${tmp_output}"
    return ${exit_code}
}

# ---------------------------------------------------------------------------
# get_credentials_file
# Lê credenciais do arquivo credenciais.txt e preenche CRED_USER / CRED_TOKEN.
# Retorna 0 se encontrou ambos, 1 caso contrário.
# ---------------------------------------------------------------------------
get_credentials_file() {
    if [ ! -f "${CRED_FILE}" ]; then
        return 1
    fi

    local found_user="" found_token=""

    while IFS= read -r line || [ -n "${line}" ]; do
        local lkey="${line%%=*}"
        local lval="${line#*=}"
        if [ "${lkey}" = "usuario" ]; then
            found_user="${lval}"
        elif [ "${lkey}" = "token" ]; then
            found_token="${lval}"
        fi
    done < "${CRED_FILE}"

    if [ -n "${found_user}" ] && [ -n "${found_token}" ]; then
        CRED_USER="${found_user}"
        CRED_TOKEN="${found_token}"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# ask_credentials
# Solicita ao usuário o username do GitHub e o token PAT.
# Preenche CRED_USER e CRED_TOKEN.
# ---------------------------------------------------------------------------
ask_credentials() {
    printf "\n${CYAN}========================================${NC}\n"
    printf "${CYAN}  Autenticação GitHub Container Registry${NC}\n"
    printf "${CYAN}========================================${NC}\n\n"

    printf "${YELLOW}Para acessar imagens privadas no GHCR, você precisa:${NC}\n"
    printf "${GRAY}  1. Usuário: Seu username do GitHub (não o email)${NC}\n"
    printf "${GRAY}  2. Token: Personal Access Token (PAT) com permissão 'read:packages'${NC}\n"
    printf "${GRAY}\nGerar token em: https://github.com/settings/tokens/new${NC}\n\n"

    # Lê o nome de usuário
    local user=""
    read -rp "Usuário: " user

    # Sanitiza e valida usuário
    user="${user#"${user%%[![:space:]]*}"}"  # ltrim
    user="${user%"${user##*[![:space:]]}"}"  # rtrim

    if [ -z "${user}" ]; then
        printf "${YELLOW}Aviso: Usuário vazio. Isso provavelmente causará falha de autenticação.${NC}\n"
    elif [[ "${user}" == *" "* ]]; then
        printf "${YELLOW}Aviso: Usuário contém espaços. Isso pode causar problemas.${NC}\n"
    fi

    # Lê o token (entrada oculta)
    local tok=""
    printf "Token: "
    read -rs tok
    printf "\n"

    # Sanitiza e valida token
    tok="${tok#"${tok%%[![:space:]]*}"}"  # ltrim
    tok="${tok%"${tok##*[![:space:]]}"}"  # rtrim

    if [ -z "${tok}" ]; then
        printf "${YELLOW}Aviso: Token vazio. Isso provavelmente causará falha de autenticação.${NC}\n"
    else
        if [ ${#tok} -lt 20 ]; then
            printf "${YELLOW}Aviso: Token muito curto. Tokens GitHub PAT têm geralmente 40+ caracteres.${NC}\n"
        fi
        # Remove espaços internos (se houver)
        local tok_nospace
        tok_nospace="$(printf '%s' "${tok}" | tr -d '[:space:]')"
        if [ "${tok_nospace}" != "${tok}" ]; then
            printf "${YELLOW}Aviso: Token contém espaços. Removendo automaticamente...${NC}\n"
            tok="${tok_nospace}"
            printf "${GREEN}Token ajustado (sem espaços).${NC}\n"
        fi
    fi

    printf "\n${WHITE}Credenciais recebidas (não serão salvas em disco).${NC}\n\n"

    CRED_USER="${user}"
    CRED_TOKEN="${tok}"
}

# ---------------------------------------------------------------------------
# ensure_credentials
# Remove o arquivo de credenciais salvo (se existir) e solicita novas credenciais.
# ---------------------------------------------------------------------------
ensure_credentials() {
    if [ -f "${CRED_FILE}" ]; then
        rm -f "${CRED_FILE}" 2>/dev/null || true
    fi
    ask_credentials
}

# ---------------------------------------------------------------------------
# test_github_token
# Valida formato básico das credenciais em memória (CRED_USER / CRED_TOKEN).
# Retorna 0 (válido) ou 1 (inválido).
# ---------------------------------------------------------------------------
test_github_token() {
    printf "\n${CYAN}Validando credenciais...${NC}\n"

    if [ -z "${CRED_USER}" ] || [ -z "${CRED_TOKEN}" ]; then
        printf "${RED}  Usuário ou token vazio.${NC}\n"
        return 1
    fi

    if [ ${#CRED_TOKEN} -lt 20 ]; then
        printf "${YELLOW}  Token muito curto (deve ter 40+ caracteres).${NC}\n"
        return 1
    fi

    printf "${GREEN}  Formato das credenciais OK.${NC}\n"
    return 0
}

# ---------------------------------------------------------------------------
# docker_login
# Autentica no ghcr.io com CRED_USER / CRED_TOKEN.
# Retorna 0 em caso de sucesso ou 1 em caso de falha.
# ---------------------------------------------------------------------------
docker_login() {
    printf "\n${CYAN}Tentando acessar ao serviço SISCAN RPA (ghcr.io)...${NC}\n"

    # Valida credenciais
    if [ -z "${CRED_USER}" ] || [ -z "${CRED_TOKEN}" ]; then
        printf "${RED}Erro: Credenciais inválidas ou vazias.${NC}\n"
        return 1
    fi

    # Verifica se o Docker está respondendo
    printf "${GRAY}Verificando se Docker está acessível...${NC}\n"
    local docker_check_output
    docker_check_output="$(docker info 2>&1)"
    local docker_check_rc=$?

    if [ ${docker_check_rc} -ne 0 ]; then
        printf "${RED}\n============================================${NC}\n"
        printf "${RED}  DOCKER NÃO ESTÁ FUNCIONANDO${NC}\n"
        printf "${RED}============================================${NC}\n"
        printf "${YELLOW}\nO Docker não está respondendo corretamente.${NC}\n"
        printf "${GRAY}Saída do Docker:${NC}\n"
        printf "${DARK_GRAY}%s${NC}\n" "${docker_check_output}"
        printf "${CYAN}\nVerifique:${NC}\n"
        printf "${WHITE}  1. O daemon do Docker está iniciado e rodando?${NC}\n"
        printf "${WHITE}  2. Você pode executar 'docker ps' em outro terminal?${NC}\n"
        printf "${WHITE}  3. Há erros no serviço Docker?${NC}\n"
        printf "${RED}\n============================================${NC}\n\n"
        return 1
    fi
    printf "${GREEN}Docker está acessível: OK${NC}\n"

    # Validação básica do token
    if ! test_github_token; then
        printf "${YELLOW}\nDeseja continuar mesmo assim? (S/N) ${NC}"
        local continuar=""
        read -rp "" continuar
        if [[ ! "${continuar}" =~ ^[Ss] ]]; then
            printf "${YELLOW}Operação cancelada pelo usuário.${NC}\n"
            return 1
        fi
    fi

    # Tentativa de login via pipe do token para docker login
    printf "${GRAY}Tentando autenticação no ghcr.io...${NC}\n"
    printf "${DARK_GRAY}  Usuario: %s${NC}\n" "${CRED_USER}"
    local token_preview="${CRED_TOKEN:0:8}"
    printf "${DARK_GRAY}  Token: %s...${NC}\n" "${token_preview}"

    local login_output
    login_output="$(printf '%s' "${CRED_TOKEN}" | docker login ghcr.io -u "${CRED_USER}" --password-stdin 2>&1)"
    local login_rc=$?

    if [ ${login_rc} -eq 0 ]; then
        printf "${GREEN}Login realizado com sucesso!${NC}\n"
        return 0
    fi

    # Login falhou — mostra diagnóstico detalhado
    printf "${RED}\n============================================${NC}\n"
    printf "${RED}  FALHA NO LOGIN${NC}\n"
    printf "${RED}============================================${NC}\n"
    printf "${YELLOW}\nDetalhes do erro:${NC}\n"
    printf "${GRAY}%s${NC}\n" "${login_output}"

    printf "${CYAN}\n========================================${NC}\n"
    printf "${CYAN}  DIAGNÓSTICO${NC}\n"
    printf "${CYAN}========================================${NC}\n"

    # Versão do Docker
    local docker_ver
    docker_ver="$(docker --version 2>&1)"
    if [ $? -eq 0 ]; then
        printf "${GREEN}Docker encontrado: %s${NC}\n" "${docker_ver}"
    else
        printf "${RED}PROBLEMA: Docker não está respondendo!${NC}\n"
        printf "${YELLOW}Verifique se o daemon Docker está rodando.${NC}\n"
    fi

    # Testar conectividade com ghcr.io
    printf "${GRAY}\nTestando conectividade com ghcr.io...${NC}\n"
    if command -v nc &>/dev/null; then
        if nc -z -w 5 ghcr.io 443 2>/dev/null; then
            printf "${GREEN}Conectividade com ghcr.io:443: OK${NC}\n"
        else
            printf "${RED}PROBLEMA: Não foi possível conectar a ghcr.io porta 443${NC}\n"
            printf "${YELLOW}Verifique firewall/proxy corporativo.${NC}\n"
        fi
    elif command -v curl &>/dev/null; then
        if curl -s --max-time 5 --connect-timeout 5 -o /dev/null -w "%{http_code}" "https://ghcr.io" 2>/dev/null | grep -q "[23][0-9][0-9]"; then
            printf "${GREEN}Conectividade com ghcr.io: OK${NC}\n"
        else
            printf "${YELLOW}Não foi possível confirmar conectividade com ghcr.io.${NC}\n"
        fi
    else
        printf "${GRAY}Não foi possível testar conectividade (nc e curl não encontrados).${NC}\n"
    fi

    printf "${CYAN}\n========================================${NC}\n"
    printf "${CYAN}  O QUE FAZER AGORA${NC}\n"
    printf "${CYAN}========================================${NC}\n"

    printf "\n${GREEN}OPÇÃO A - Fazer login manualmente (RECOMENDADO):${NC}\n\n"
    printf "${WHITE}  PASSO 1: Abra um NOVO terminal${NC}\n"
    printf "${GRAY}  ----------------------------------------${NC}\n"
    printf "\n"
    printf "${WHITE}  PASSO 2: Execute o comando abaixo:${NC}\n"
    printf "${GRAY}  ------------------------------------------------------------------${NC}\n\n"
    printf "${CYAN}  MÉTODO (echo):${NC}\n"
    printf "${YELLOW}  echo '%s' | docker login ghcr.io -u %s --password-stdin${NC}\n\n" "${CRED_TOKEN}" "${CRED_USER}"
    printf "${WHITE}  IMPORTANTE: Pare quando aparecer 'Login Succeeded'${NC}\n\n"
    printf "${WHITE}  PASSO 3: Volte para ESTE terminal e responda abaixo:${NC}\n"
    printf "${GRAY}  ----------------------------------------------------${NC}\n"
    printf "${GREEN}  - Pressione S (SIM) se o login funcionou${NC}\n"
    printf "${YELLOW}  - Pressione N (NAO) se apareceu erro${NC}\n"

    printf "\n${YELLOW}OPÇÃO B - Entrar em contato com suporte técnico:${NC}\n\n"
    printf "${GRAY}  Se o login manual também falhar, entre em contato com:${NC}\n\n"
    printf "${WHITE}  Consultor Técnico - Prisma Consultoria${NC}\n\n"
    printf "${GRAY}  Informe a mensagem de erro exibida acima.${NC}\n"

    printf "${CYAN}\n============================================${NC}\n\n"
    printf "${WHITE}Você conseguiu fazer o login manualmente?${NC}\n"
    printf "${GREEN}(S = Sim, apareceu 'Login Succeeded')${NC}\n"
    printf "${YELLOW}(N = Não, apareceu erro ou preciso de ajuda)${NC}\n"
    local resposta=""
    read -rp $'\nResposta (S/N): ' resposta

    if [[ "${resposta}" =~ ^[Ss] ]]; then
        printf "${GREEN}\nÓtimo! O login foi realizado com sucesso.${NC}\n"
        printf "${CYAN}Continuando o processo de download...${NC}\n"
        return 0
    else
        printf "${YELLOW}\n============================================${NC}\n"
        printf "${YELLOW}  ENTRE EM CONTATO COM SUPORTE${NC}\n"
        printf "${YELLOW}============================================${NC}\n\n"
        printf "${WHITE}Por favor, entre em contato com:${NC}\n"
        printf "${CYAN}Consultor Técnico - Prisma Consultoria${NC}\n\n"
        printf "${WHITE}Tenha em mãos:${NC}\n"
        printf "${GRAY}- A mensagem de erro exibida acima${NC}\n"
        printf "${GRAY}- O usuário informado: %s${NC}\n\n" "${CRED_USER}"
        printf "${YELLOW}Operação cancelada.${NC}\n"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# check_env_configured
# Verifica se o .env existe e possui SECRET_KEY e variáveis HOST_* obrigatórias.
# Parâmetro: show_message (true|false) — se deve exibir mensagens de orientação.
# Retorna 0 se OK, 1 se não configurado.
# ---------------------------------------------------------------------------
check_env_configured() {
    local show_message="${1:-true}"
    local env_file="${SCRIPT_DIR}/.env"

    if [ ! -f "${env_file}" ]; then
        if [ "${show_message}" = "true" ]; then
            printf "\n${YELLOW}============================================${NC}\n"
            printf "${YELLOW}  CONFIGURAÇÃO NECESSÁRIA${NC}\n"
            printf "${YELLOW}============================================${NC}\n"
            printf "${RED}\nO arquivo .env não foi encontrado.${NC}\n"
            printf "${YELLOW}Antes de iniciar o serviço, é necessário configurar as variáveis.${NC}\n"
            printf "${CYAN}\nPor favor:${NC}\n"
            printf "${WHITE}  1. Escolha a opção 3 no menu principal${NC}\n"
            printf "${WHITE}  2. Configure as variáveis obrigatórias (caminhos HOST_* e SECRET_KEY)${NC}\n"
            printf "${CYAN}\nDepois volte e escolha a opção 1 para iniciar o serviço.${NC}\n"
            printf "${YELLOW}============================================${NC}\n\n"
        fi
        return 1
    fi

    local has_secret_key=false
    local -A host_vars=(
        [HOST_LOG_DIR]=""
        [HOST_SISCAN_REPORTS_INPUT_DIR]=""
        [HOST_REPORTS_OUTPUT_CONSOLIDATED_DIR]=""
        [HOST_REPORTS_OUTPUT_CONSOLIDATED_PDFS_DIR]=""
        [HOST_CONFIG_DIR]=""
    )

    while IFS= read -r line || [ -n "${line}" ]; do
        # Ignora comentários e linhas vazias
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue

        local lkey="${line%%=*}"
        local lval="${line#*=}"
        lkey="${lkey#"${lkey%%[![:space:]]*}"}"
        lkey="${lkey%"${lkey##*[![:space:]]}"}"
        lval="${lval#"${lval%%[![:space:]]*}"}"
        lval="${lval%"${lval##*[![:space:]]}"}"

        if [ "${lkey}" = "SECRET_KEY" ] && [ -n "${lval}" ]; then
            has_secret_key=true
        fi
        if [[ -v host_vars["${lkey}"] ]] && [ -n "${lval}" ]; then
            host_vars["${lkey}"]="${lval}"
        fi
    done < "${env_file}"

    local missing=()
    if ! ${has_secret_key}; then
        missing+=("SECRET_KEY (chave de sessão web — gerada automaticamente pelo assistente)")
    fi
    for k in "${!host_vars[@]}"; do
        if [ -z "${host_vars[${k}]}" ]; then
            missing+=("${k}")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        if [ "${show_message}" = "true" ]; then
            printf "\n${YELLOW}============================================${NC}\n"
            printf "${YELLOW}  CONFIGURAÇÃO INCOMPLETA${NC}\n"
            printf "${YELLOW}============================================${NC}\n"
            printf "${RED}\nO arquivo .env existe, mas variáveis obrigatórias estão faltando ou vazias:${NC}\n"
            for m in "${missing[@]}"; do
                printf "${YELLOW}  - %s${NC}\n" "${m}"
            done
            printf "${CYAN}\nPor favor:${NC}\n"
            printf "${WHITE}  1. Escolha a opção 3 no menu principal${NC}\n"
            printf "${WHITE}  2. Preencha as variáveis que estão faltando${NC}\n"
            printf "${CYAN}\nDepois volte e escolha a opção 1 para iniciar o serviço.${NC}\n"
            printf "${YELLOW}============================================${NC}\n\n"
        fi
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# ensure_host_paths
# Cria no host os diretórios de bind mount definidos no .env.
# Deve ser chamado antes de `docker compose up` para garantir que os
# diretórios existam antes da montagem.
# Retorna 0 se tudo OK, 1 se algum caminho não pôde ser criado.
# ---------------------------------------------------------------------------
ensure_host_paths() {
    local env_file="${SCRIPT_DIR}/.env"
    [ ! -f "${env_file}" ] && return 1

    local -A dir_vars=(
        [HOST_LOG_DIR]=""
        [HOST_SISCAN_REPORTS_INPUT_DIR]=""
        [HOST_REPORTS_OUTPUT_CONSOLIDATED_DIR]=""
        [HOST_REPORTS_OUTPUT_CONSOLIDATED_PDFS_DIR]=""
        [HOST_CONFIG_DIR]=""
        [HOST_SCRIPTS_CLIENTS]=""
        [HOST_BACKUPS_DIR]=""
    )

    while IFS= read -r line || [ -n "${line}" ]; do
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        local lkey="${line%%=*}"
        local lval="${line#*=}"
        lkey="${lkey#"${lkey%%[![:space:]]*}"}"
        lkey="${lkey%"${lkey##*[![:space:]]}"}"
        lval="${lval#"${lval%%[![:space:]]*}"}"
        lval="${lval%"${lval##*[![:space:]]}"}"
        if [[ -v dir_vars["${lkey}"] ]]; then
            dir_vars["${lkey}"]="${lval}"
        fi
    done < "${env_file}"

    local failed=0

    for k in "${!dir_vars[@]}"; do
        local p="${dir_vars[${k}]}"
        [ -z "${p}" ] && continue
        if [ ! -d "${p}" ]; then
            if mkdir -p "${p}" 2>/dev/null; then
                printf "${GREEN}Diretório criado: %s${NC}\n" "${p}"
            else
                printf "${RED}Erro ao criar diretório: %s${NC}\n" "${p}"
                failed=1
            fi
        fi
    done

    return ${failed}
}

# ---------------------------------------------------------------------------
# update_and_restart
# Faz pull da imagem, verifica .env e recria o compose.
# ---------------------------------------------------------------------------
update_and_restart() {
    printf "\n${YELLOW}Atualizando o SISCAN RPA e reiniciando (pode demorar)...${NC}\n"

    if [ ! -f "${COMPOSE_FILE}" ]; then
        printf "${RED}Arquivo de configuração 'docker-compose.prd.host.yml' não encontrado em: %s${NC}\n" "${COMPOSE_FILE}"
        return 1
    fi

    # Tenta o pull direto com progresso
    printf "\n${CYAN}Baixando a versão mais recente...${NC}\n"
    printf "${GRAY}Imagem: %s${NC}\n\n" "${IMAGE_PATH}"

    local pull_exit_code=0
    if ! docker_pull_with_progress "${IMAGE_PATH}"; then
        pull_exit_code=1
    fi

    if [ ${pull_exit_code} -ne 0 ]; then
        printf "${YELLOW}Não foi possível baixar diretamente. Verificando Docker e credenciais...${NC}\n"

        # Verifica autenticação no docker info
        local docker_info
        docker_info="$(docker info 2>&1)"
        if echo "${docker_info}" | grep -qi "Username"; then
            printf "${CYAN}Parece que já está autenticado no Docker.${NC}\n"
        else
            printf "${YELLOW}Não há autenticação ativa no Docker.${NC}\n"
        fi

        # Tenta credenciais salvas
        local cred_rc=0
        get_credentials_file || cred_rc=$?
        if [ ${cred_rc} -eq 0 ] && [ -n "${CRED_USER}" ] && [ -n "${CRED_TOKEN}" ]; then
            printf "${CYAN}Credenciais salvas encontradas; testando acesso com elas...${NC}\n"
            if docker_login; then
                printf "${CYAN}Acesso com credenciais salvas OK. Tentando baixar novamente...${NC}\n\n"
                if docker_pull_with_progress "${IMAGE_PATH}"; then
                    pull_exit_code=0
                fi
            else
                printf "${YELLOW}Acesso com credenciais salvas falhou.${NC}\n"
            fi
        fi

        # Se ainda falhou, pede novas credenciais
        if [ ${pull_exit_code} -ne 0 ]; then
            printf "${CYAN}Por favor, informe usuário e token novamente...${NC}\n"
            ask_credentials
            if docker_login; then
                printf "${CYAN}Acesso com novas credenciais OK. Tentando baixar novamente...${NC}\n\n"
                if docker_pull_with_progress "${IMAGE_PATH}"; then
                    pull_exit_code=0
                fi
            else
                printf "${YELLOW}Acesso com novas credenciais falhou.${NC}\n"
            fi
        fi

        # Último recurso: docker compose pull
        if [ ${pull_exit_code} -ne 0 ]; then
            printf "${YELLOW}Ainda não foi possível baixar. Tentando 'docker compose pull' como último recurso...${NC}\n"
            if (cd "${SCRIPT_DIR}" && docker compose pull 2>&1); then
                printf "${GREEN}Atualização via compose concluída com sucesso.${NC}\n"
                pull_exit_code=0
            else
                printf "${RED}Erro ao baixar a atualização via compose.${NC}\n"
                printf "${YELLOW}\nAções recomendadas:${NC}\n"
                printf "${YELLOW}- Verifique sua conexão de rede e resolução DNS para 'ghcr.io'.${NC}\n"
                printf "${YELLOW}- Confirme que o token tem permissão de leitura de pacotes no GitHub.${NC}\n"
                printf "${YELLOW}- Execute 'docker logout ghcr.io' e tente login manualmente se precisar.${NC}\n"
                printf "${YELLOW}- Se estiver atrás de proxy/firewall, confirme regras para https (porta 443).${NC}\n"
                return 1
            fi
        fi
    fi

    printf "\n${GREEN}============================================${NC}\n"
    printf "${GREEN}  DOWNLOAD CONCLUÍDO COM SUCESSO!${NC}\n"
    printf "${GREEN}============================================${NC}\n\n"

    # Verifica .env antes de iniciar
    if ! check_env_configured "false"; then
        printf "${YELLOW}Agora é necessário configurar as variáveis do sistema.${NC}\n"
        printf "${CYAN}\nDeseja configurar agora? (S/N) ${NC}"
        local resposta=""
        read -rp "" resposta

        if [[ "${resposta}" =~ ^[Ss] ]]; then
            printf "\n${CYAN}Abrindo editor de configurações...${NC}\n\n"
            sleep 1
            manage_env "skip_restart"

            printf "\n\n${CYAN}Verificando configuração...${NC}\n"
            if check_env_configured "false"; then
                printf "${GREEN}Configuração OK! Iniciando serviços...${NC}\n\n"
            else
                printf "\n${YELLOW}Configuração ainda incompleta.${NC}\n"
                printf "${RED}O serviço NÃO será iniciado.${NC}\n"
                printf "${CYAN}Por favor, volte ao menu e escolha a opção 3 para completar a configuração.${NC}\n"
                return 1
            fi
        else
            printf "\n${YELLOW}Imagem atualizada, mas serviço NÃO foi iniciado.${NC}\n"
            printf "${CYAN}Para iniciar o serviço:${NC}\n"
            printf "${WHITE}  1. Escolha a opção 3 no menu para configurar as variáveis${NC}\n"
            printf "${WHITE}  2. Depois escolha a opção 1 para iniciar o serviço${NC}\n"
            return 0
        fi
    else
        printf "${GREEN}Configuração do .env encontrada e validada.${NC}\n"
    fi

    # Garante que os caminhos do host existem antes de subir os containers
    ensure_host_paths

    # Recria os serviços
    printf "\n${CYAN}Recriando o SISCAN RPA...${NC}\n"
    (cd "${SCRIPT_DIR}" && docker compose down && docker compose up -d)
    local compose_rc=$?

    if [ ${compose_rc} -eq 0 ]; then
        printf "\n${GREEN}============================================${NC}\n"
        printf "${GREEN}  SISCAN RPA PRONTO PARA USO!${NC}\n"
        printf "${GREEN}============================================${NC}\n"
        printf "${GREEN}\nO serviço foi atualizado e iniciado com sucesso!${NC}\n"
        printf "${CYAN}Você pode acessar o sistema em: http://localhost:5001${NC}\n"
    else
        printf "${RED}\nErro ao reiniciar o SISCAN RPA.${NC}\n"
    fi

    return ${compose_rc}
}

# ---------------------------------------------------------------------------
# restart_service
# Para e reinicia o docker compose.
# ---------------------------------------------------------------------------
restart_service() {
    if [ ! -f "${COMPOSE_FILE}" ]; then
        printf "\n${RED}Arquivo de configuração 'docker-compose.prd.host.yml' não foi encontrado.${NC}\n"
        return 1
    fi

    if ! check_env_configured "true"; then
        return 1
    fi

    ensure_host_paths

    printf "\n${CYAN}Reiniciando o SISCAN RPA...${NC}\n"
    (cd "${SCRIPT_DIR}" && docker compose down && docker compose up -d)
    local rc=$?

    if [ ${rc} -eq 0 ]; then
        printf "${GREEN}SISCAN RPA reiniciado com sucesso.${NC}\n"
    else
        printf "${RED}Erro ao reiniciar o SISCAN RPA.${NC}\n"
    fi
    return ${rc}
}

# ---------------------------------------------------------------------------
# check_service
# Verifica se há containers do SISCAN RPA rodando.
# Retorna 0 se encontrar algum, 1 caso contrário.
# ---------------------------------------------------------------------------
check_service() {
    local containers
    containers="$(docker ps --format "{{.Names}}" 2>&1)"
    local rc=$?

    if [ ${rc} -ne 0 ]; then
        printf "${YELLOW}Aviso: Não foi possível consultar containers Docker.${NC}\n"
        return 1
    fi

    # Procura por padrões: extrator-siscan-rpa, siscan-rpa-*, ou siscan
    if echo "${containers}" | grep -qE '(extrator-siscan-rpa|siscan-rpa-|siscan)'; then
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# show_system_history
# Exibe histórico de boots, desligamentos e eventos críticos do kernel via
# journalctl / last / utmpdump (equivalente Linux do Get-WinEvent).
# ---------------------------------------------------------------------------
show_system_history() {
    printf "\n${CYAN}============================================${NC}\n"
    printf "${CYAN}  HISTÓRICO DO SISTEMA (Últimos 30 dias)${NC}\n"
    printf "${CYAN}============================================${NC}\n\n"

    printf "${GRAY}Coletando eventos do sistema...${NC}\n"
    printf "${GRAY}Isso pode demorar alguns segundos...${NC}\n\n"

    # ---- Estatísticas básicas ----
    local reboot_count=0
    local shutdown_count=0
    local crash_count=0
    local oom_count=0

    # Conta reboots com 'last reboot' (filtra últimos 30 dias)
    if command -v last &>/dev/null; then
        reboot_count="$(last reboot 2>/dev/null | grep -v "^$\|^wtmp" | awk -v d="$(date -d '-30 days' '+%b %e' 2>/dev/null || date -v -30d '+%b %e' 2>/dev/null || echo '')" 'NF > 0 {print}' | wc -l | tr -d ' ')"
        shutdown_count="$(last -x shutdown 2>/dev/null | grep -v "^$\|^wtmp" | wc -l | tr -d ' ')"
    fi

    # Conta kernel panics e OOM com journalctl
    if command -v journalctl &>/dev/null; then
        crash_count="$(journalctl -k --since "30 days ago" 2>/dev/null | grep -ic 'kernel panic\|oops\|BUG:' || true)"
        oom_count="$(journalctl -k --since "30 days ago" 2>/dev/null | grep -ic 'oom\|out of memory\|killed process' || true)"
    fi

    printf "${WHITE}RESUMO:${NC}\n"
    printf "${WHITE}========${NC}\n"
    printf "  ${CYAN}Inicializações detectadas (last reboot):${NC} %s\n" "${reboot_count}"
    printf "  ${CYAN}Desligamentos detectados (last shutdown): ${NC}%s\n" "${shutdown_count}"

    if [ "${crash_count}" -gt 0 ] 2>/dev/null; then
        printf "  ${RED}Kernel panics / BUGs detectados:${NC} %s\n" "${crash_count}"
    else
        printf "  ${GREEN}Kernel panics / BUGs:${NC} nenhum detectado\n"
    fi
    if [ "${oom_count}" -gt 0 ] 2>/dev/null; then
        printf "  ${YELLOW}Eventos OOM (Out of Memory):${NC} %s\n" "${oom_count}"
    else
        printf "  ${GREEN}Eventos OOM:${NC} nenhum detectado\n"
    fi

    # ---- Alertas ----
    if [ "${crash_count}" -gt 0 ] 2>/dev/null || [ "${oom_count}" -gt 0 ] 2>/dev/null; then
        printf "\n${YELLOW}ATENÇÃO:${NC}\n"
        [ "${crash_count}" -gt 0 ] 2>/dev/null && \
            printf "${RED}  - Foram detectados %s kernel panic(s)/BUG(s)! Verifique a estabilidade do hardware.${NC}\n" "${crash_count}"
        [ "${oom_count}" -gt 0 ] 2>/dev/null && \
            printf "${YELLOW}  - Foram detectados %s evento(s) OOM. Considere aumentar a memória disponível.${NC}\n" "${oom_count}"
    else
        printf "\n${GREEN}Sistema estável - Nenhum problema crítico detectado.${NC}\n"
    fi

    # ---- Lista de boots (journalctl --list-boots) ----
    if command -v journalctl &>/dev/null; then
        printf "\n${CYAN}============================================${NC}\n"
        printf "${CYAN}  LISTA DE BOOTS (journalctl --list-boots)${NC}\n"
        printf "${CYAN}============================================${NC}\n\n"

        local boots_output
        boots_output="$(journalctl --list-boots 2>/dev/null | tail -20 || echo '(não disponível)')"
        printf "${GRAY}%s${NC}\n" "${boots_output}"
    fi

    # ---- Eventos recentes de kernel ----
    if command -v journalctl &>/dev/null; then
        printf "\n${CYAN}============================================${NC}\n"
        printf "${CYAN}  EVENTOS RECENTES DO KERNEL (últimos 20)${NC}\n"
        printf "${CYAN}============================================${NC}\n\n"

        local kernel_events
        kernel_events="$(journalctl -k --since "30 days ago" --no-pager -n 20 2>/dev/null || echo '(não disponível)')"
        printf "${GRAY}%s${NC}\n" "${kernel_events}"
    fi

    # ---- Histórico de reboots (last) ----
    if command -v last &>/dev/null; then
        printf "\n${CYAN}============================================${NC}\n"
        printf "${CYAN}  HISTÓRICO DE REBOOTS (last reboot)${NC}\n"
        printf "${CYAN}============================================${NC}\n\n"

        local reboot_list
        reboot_list="$(last reboot 2>/dev/null | head -20 || echo '(não disponível)')"
        printf "${GRAY}%s${NC}\n" "${reboot_list}"
    fi

    # ---- Opção de exportar relatório ----
    printf "\n${CYAN}============================================${NC}\n"
    printf "${YELLOW}Deseja exportar o relatório completo? (S/N) ${NC}"
    local export_resp=""
    read -rp "" export_resp

    if [[ "${export_resp}" =~ ^[Ss] ]]; then
        local report_date
        report_date="$(date '+%Y%m%d-%H%M%S')"
        local report_path="${SCRIPT_DIR}/relatorio-sistema-${report_date}.txt"

        {
            echo "============================================"
            echo "  RELATÓRIO DE HISTÓRICO DO SISTEMA"
            echo "  Gerado em: $(date '+%d/%m/%Y %H:%M:%S')"
            echo "  Host: $(hostname 2>/dev/null || echo 'desconhecido')"
            echo "============================================"
            echo ""
            echo "RESUMO:"
            echo "========"
            echo "  Inicializações (last reboot): ${reboot_count}"
            echo "  Desligamentos (last shutdown): ${shutdown_count}"
            echo "  Kernel panics / BUGs: ${crash_count}"
            echo "  Eventos OOM: ${oom_count}"
            echo ""
            if command -v journalctl &>/dev/null; then
                echo "LISTA DE BOOTS:"
                echo "==============="
                journalctl --list-boots 2>/dev/null || echo "(não disponível)"
                echo ""
                echo "EVENTOS RECENTES DO KERNEL:"
                echo "==========================="
                journalctl -k --since "30 days ago" --no-pager 2>/dev/null || echo "(não disponível)"
                echo ""
            fi
            if command -v last &>/dev/null; then
                echo "HISTÓRICO DE REBOOTS:"
                echo "====================="
                last reboot 2>/dev/null || echo "(não disponível)"
                echo ""
                echo "HISTÓRICO DE DESLIGAMENTOS:"
                echo "============================"
                last -x shutdown 2>/dev/null || echo "(não disponível)"
                echo ""
            fi
            echo "============================================"
            echo "Fim do relatório"
            echo "============================================"
        } > "${report_path}" 2>&1

        printf "\n${GREEN}Relatório exportado para:${NC}\n"
        printf "${CYAN}  %s${NC}\n" "${report_path}"
    fi
}

# ---------------------------------------------------------------------------
# run_nightly_script
# Executa manualmente o script nightly_rpa_runner.sh dentro do container.
# ---------------------------------------------------------------------------
run_nightly_script() {
    printf "\n${CYAN}============================================${NC}\n"
    printf "${CYAN}  EXECUÇÃO MANUAL - TAREFAS RPA${NC}\n"
    printf "${CYAN}============================================${NC}\n"

    # Verifica se o serviço está rodando
    if ! check_service; then
        printf "\n${RED}ERRO: O serviço SISCAN RPA não está em execução.${NC}\n"
        printf "${YELLOW}Inicie o serviço primeiro (opção 1 do menu).${NC}\n"
        return 1
    fi

    # Obtém nome do container
    local container_name
    container_name="$(docker ps --filter "name=extrator-siscan-rpa" --format "{{.Names}}" 2>/dev/null | head -1)"
    if [ -z "${container_name}" ]; then
        container_name="$(docker ps --filter "name=siscan" --format "{{.Names}}" 2>/dev/null | head -1)"
    fi

    if [ -z "${container_name}" ]; then
        printf "\n${RED}ERRO: Não foi possível encontrar o container do SISCAN RPA.${NC}\n"
        printf "${YELLOW}Verifique se o serviço está rodando com 'docker ps'.${NC}\n"
        return 1
    fi

    printf "\n${GREEN}Container encontrado: %s${NC}\n" "${container_name}"
    printf "\n${YELLOW}Este script executará as seguintes tarefas:${NC}\n"
    printf "${GRAY}  1. Baixar exames requisitados (status R)${NC}\n"
    printf "${GRAY}  2. Baixar exames com laudos (status C)${NC}\n"
    printf "${GRAY}  3. Baixar exames com laudo requisitado (status L)${NC}\n"
    printf "${GRAY}  4. Processar laudos de mamografia (exportar XLSX/CSV)${NC}\n"
    printf "${CYAN}\nData de referência: DIA ANTERIOR${NC}\n"
    printf "\n${YELLOW}Esta operação pode demorar vários minutos dependendo da quantidade de dados.${NC}\n"
    printf "\n${WHITE}Deseja continuar? (S/N) ${NC}"
    local confirm=""
    read -rp "" confirm

    if [[ ! "${confirm}" =~ ^[Ss] ]]; then
        printf "${YELLOW}Operação cancelada.${NC}\n"
        return 0
    fi

    printf "\n${CYAN}============================================${NC}\n"
    printf "${CYAN}  EXECUTANDO TAREFAS RPA...${NC}\n"
    printf "${CYAN}============================================${NC}\n\n"

    local script_path="/app/scripts/nightly_rpa_runner.sh"
    printf "${GRAY}Executando: docker exec %s sh %s${NC}\n\n" "${container_name}" "${script_path}"
    printf "${YELLOW}Aguarde... Este processo pode demorar vários minutos.${NC}\n"
    printf "${GRAY}(A saída será exibida em tempo real)${NC}\n\n"

    docker exec "${container_name}" sh "${script_path}"
    local exit_code=$?

    printf "\n"
    if [ ${exit_code} -eq 0 ]; then
        printf "${GREEN}============================================${NC}\n"
        printf "${GREEN}  TAREFAS CONCLUÍDAS COM SUCESSO!${NC}\n"
        printf "${GREEN}============================================${NC}\n"
        printf "${CYAN}\nOs arquivos processados devem estar disponíveis nos diretórios configurados.${NC}\n"
    else
        printf "${RED}============================================${NC}\n"
        printf "${RED}  ERRO NA EXECUÇÃO (Exit Code: %d)${NC}\n" "${exit_code}"
        printf "${RED}============================================${NC}\n"
        printf "${YELLOW}\nPara mais detalhes, verifique os logs do container:${NC}\n"
        printf "${GRAY}  docker logs %s${NC}\n" "${container_name}"
        printf "${YELLOW}\nOu acompanhe em tempo real:${NC}\n"
        printf "${GRAY}  docker logs -f %s${NC}\n" "${container_name}"
    fi
    return ${exit_code}
}

# ---------------------------------------------------------------------------
# update_env_file
# Lê o arquivo .env linha a linha e para cada KEY=VALUE solicita novo valor.
# Usa read -s para variáveis secretas.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# _generate_secret
# Gera uma chave hexadecimal de 64 caracteres (256 bits) usando a melhor
# fonte disponível no ambiente.
# ---------------------------------------------------------------------------
_generate_secret() {
    if command -v openssl &>/dev/null; then
        openssl rand -hex 32
    elif command -v python3 &>/dev/null; then
        python3 -c "import secrets; print(secrets.token_hex(32))"
    else
        tr -dc 'a-f0-9' < /dev/urandom | head -c 64
    fi
}

# ---------------------------------------------------------------------------
# _validate_linux_path VARNAME VALUE
# Detecta caminhos no formato Windows (drive letter, UNC, backslash) e avisa
# o usuário. Retorna 0 se o caminho parece compatível com Linux, 1 se suspeito.
# ---------------------------------------------------------------------------
_validate_linux_path() {
    local var_name="${1}"
    local path_val="${2}"

    [ -z "${path_val}" ] && return 0

    local is_unc=false
    local is_drive=false
    local has_backslash=false
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

    printf "\n${YELLOW}============================================${NC}\n"
    printf "${YELLOW}  AVISO: Caminho com formato Windows${NC}\n"
    printf "${YELLOW}============================================${NC}\n"
    printf "${CYAN}Variável: %s${NC}\n" "${var_name}"
    printf "${GRAY}Caminho informado: %s${NC}\n" "${path_val}"
    printf "\n${RED}Problemas encontrados:${NC}\n"
    for p in "${problems[@]}"; do
        printf "  - %s\n" "${p}"
    done
    printf "\n${CYAN}Soluções:${NC}\n"
    if ${is_unc}; then
        printf "  - Monte o compartilhamento de rede no Linux e use o ponto de montagem\n"
        printf "    ${GRAY}Exemplo: /mnt/siscan-dados${NC}\n"
    fi
    if ${is_drive}; then
        printf "  - Use um caminho Linux absoluto\n"
        printf "    ${GRAY}Exemplo: /home/usuario/siscan/dados${NC}\n"
    fi
    if ${has_backslash}; then
        printf "  - Substitua '\\\\' por '/'\n"
    fi
    printf "${YELLOW}============================================${NC}\n\n"
    return 1
}

update_env_file() {
    local env_path="${1}"
    if [ ! -f "${env_path}" ]; then
        touch "${env_path}"
    fi

    local tmp_file
    tmp_file="$(mktemp)"

    while IFS= read -r line || [ -n "${line}" ]; do
        # Preserva comentários e linhas vazias
        if [[ "${line}" =~ ^[[:space:]]*# ]] || [[ -z "${line// }" ]]; then
            printf '%s\n' "${line}" >> "${tmp_file}"
            continue
        fi

        # Detecta KEY=VALUE (split no primeiro '=')
        if [[ "${line}" =~ ^[[:space:]]*([A-Za-z0-9_]+)[[:space:]]*= ]]; then
            local key="${line%%=*}"
            local val="${line#*=}"
            # Limpa espaços do key
            key="${key#"${key%%[![:space:]]*}"}"
            key="${key%"${key##*[![:space:]]}"}"

            # Determina se é secreta (por entrada do JSON ou por nome)
            local is_secret=false
            local secret_entry="${ENV_HELP_ENTRIES["${key}__secret"]:-}"
            if [ "${secret_entry}" = "true" ]; then
                is_secret=true
            elif [[ "${key}" =~ (PASSWORD|TOKEN|SECRET|KEY) ]]; then
                is_secret=true
            fi

            # Texto de ajuda
            local help_text="${ENV_HELP_TEXTS["${key}"]:-}"
            local example_text="${ENV_HELP_ENTRIES["${key}__example"]:-}"
            local required_text="${ENV_HELP_ENTRIES["${key}__required"]:-}"
            local key_type="${ENV_HELP_ENTRIES["${key}__type"]:-}"

            # Chave gerada automaticamente (ex.: SECRET_KEY)
            if [ "${key_type}" = "generated_secret" ]; then
                printf "\n${CYAN}Variável: %s${NC}\n" "${key}"
                [ -n "${help_text}" ] && printf "${DARK_CYAN}Ajuda: %s${NC}\n" "${help_text}"
                if [ -n "${val}" ]; then
                    printf "${DARK_GRAY}Valor atual: (configurado)${NC}\n"
                    printf "${YELLOW}Deseja regenerar a chave? Isso invalidará sessões ativas. (S/N) ${NC}"
                    local regen=""
                    read -rp "" regen
                    if [[ "${regen}" =~ ^[Ss] ]]; then
                        local new_secret
                        new_secret="$(_generate_secret)"
                        printf "${GREEN}Nova chave gerada com sucesso.${NC}\n"
                        printf '%s=%s\n' "${key}" "${new_secret}" >> "${tmp_file}"
                    else
                        printf '%s\n' "${line}" >> "${tmp_file}"
                    fi
                else
                    printf "${DARK_GRAY}Valor atual: (vazio — gerando automaticamente)${NC}\n"
                    local new_secret
                    new_secret="$(_generate_secret)"
                    printf "${GREEN}Chave gerada automaticamente.${NC}\n"
                    printf '%s=%s\n' "${key}" "${new_secret}" >> "${tmp_file}"
                fi
                continue
            fi

            printf "\n${CYAN}Variável: %s${NC}\n" "${key}"

            if ${is_secret}; then
                if [ -n "${val}" ]; then
                    printf "${DARK_GRAY}Valor atual: (oculto)${NC}\n"
                else
                    printf "${DARK_GRAY}Valor atual: (vazio)${NC}\n"
                fi
            else
                printf "${DARK_GRAY}Valor atual: %s${NC}\n" "${val}"
            fi

            [ -n "${example_text}" ] && printf "${DARK_GRAY}Exemplo: %s${NC}\n" "${example_text}"
            [ "${required_text}" = "true" ] && printf "${YELLOW}Obrigatório${NC}\n"
            [ -n "${help_text}" ] && printf "${DARK_CYAN}Ajuda: %s${NC}\n" "${help_text}"

            if ${is_secret}; then
                local new_val=""
                printf "Novo valor (Enter para manter): "
                read -rs new_val
                printf "\n"
                if [ -n "${new_val}" ]; then
                    printf '%s=%s\n' "${key}" "${new_val}" >> "${tmp_file}"
                else
                    printf '%s\n' "${line}" >> "${tmp_file}"
                fi
            else
                local new_val=""
                read -rp "Novo valor (Enter para manter): " new_val
                if [ -n "${new_val}" ]; then
                    if [[ "${key}" =~ _PATH$|_DIR$|_ROOT$|MEDIA|CONFIG ]]; then
                        if ! _validate_linux_path "${key}" "${new_val}"; then
                            printf "${YELLOW}Deseja usar este caminho mesmo assim? (S/N) ${NC}"
                            local confirm=""
                            read -rp "" confirm
                            if [[ ! "${confirm}" =~ ^[Ss] ]]; then
                                printf "${GRAY}Mantendo valor anterior.${NC}\n"
                                printf '%s\n' "${line}" >> "${tmp_file}"
                                continue
                            fi
                        fi
                    fi
                    printf '%s=%s\n' "${key}" "${new_val}" >> "${tmp_file}"
                else
                    printf '%s\n' "${line}" >> "${tmp_file}"
                fi
            fi
        else
            # Linha não é KEY=VALUE — preserva como está
            printf '%s\n' "${line}" >> "${tmp_file}"
        fi
    done < "${env_path}"

    # Substitui o arquivo original pelo temporário
    cp "${tmp_file}" "${env_path}"
    rm -f "${tmp_file}"

    printf "\n${GREEN}Arquivo .env atualizado e salvo em %s${NC}\n" "${env_path}"
}

# ---------------------------------------------------------------------------
# manage_env
# Garante que o .env existe (copia de template ou cria vazio), edita e
# oferece reiniciar os serviços.
# Parâmetro opcional: "skip_restart"
# ---------------------------------------------------------------------------
manage_env() {
    local skip_restart="${1:-}"
    local env_file="${SCRIPT_DIR}/.env"
    local template_files=('.env.host.sample' '.env.example' '.env.template' '.env.dist')

    if [ ! -f "${env_file}" ]; then
        local found_template=""
        for t in "${template_files[@]}"; do
            local tp="${SCRIPT_DIR}/${t}"
            if [ -f "${tp}" ]; then
                found_template="${tp}"
                break
            fi
        done

        if [ -n "${found_template}" ]; then
            cp "${found_template}" "${env_file}"
            printf "${YELLOW}.env não encontrado. Copiado de: %s${NC}\n" "${found_template}"
        else
            touch "${env_file}"
            printf "${YELLOW}.env não encontrado. Criado arquivo vazio: %s${NC}\n" "${env_file}"
        fi
    else
        printf "${YELLOW}.env encontrado: %s${NC}\n" "${env_file}"
    fi

    update_env_file "${env_file}"

    # Oferece reiniciar os serviços (exceto quando chamado com skip_restart)
    if [ "${skip_restart}" = "skip_restart" ]; then
        return 0
    fi

    printf "\n${CYAN}============================================${NC}\n"
    printf "${CYAN}  APLICAR CONFIGURAÇÕES${NC}\n"
    printf "${CYAN}============================================${NC}\n"

    if check_service; then
        printf "\n${YELLOW}O serviço SISCAN RPA está em execução.${NC}\n"
        printf "${YELLOW}Para aplicar as mudanças no .env, é necessário reiniciar o serviço.${NC}\n"
        printf "${CYAN}\nDeseja reiniciar o serviço agora? (S/N) ${NC}"
        local resposta=""
        read -rp "" resposta

        if [[ "${resposta}" =~ ^[Ss] ]]; then
            printf "\n${CYAN}Reiniciando serviço para aplicar as configurações...${NC}\n\n"
            sleep 1

            if check_env_configured "false"; then
                ensure_host_paths
                (cd "${SCRIPT_DIR}" && docker compose down && docker compose up -d)
                local rc=$?
                if [ ${rc} -eq 0 ]; then
                    printf "\n${GREEN}============================================${NC}\n"
                    printf "${GREEN}  CONFIGURAÇÕES APLICADAS!${NC}\n"
                    printf "${GREEN}============================================${NC}\n"
                    printf "${GREEN}\nO serviço foi reiniciado com sucesso.${NC}\n"
                    printf "${CYAN}As novas configurações estão ativas.${NC}\n"
                else
                    printf "${RED}\nErro ao reiniciar o serviço.${NC}\n"
                    printf "${YELLOW}Verifique os logs para mais detalhes.${NC}\n"
                fi
            else
                printf "${YELLOW}\nConfiguração incompleta. Serviço não foi reiniciado.${NC}\n"
                printf "${CYAN}Complete as variáveis obrigatórias e tente novamente.${NC}\n"
            fi
        else
            printf "\n${YELLOW}Serviço NÃO foi reiniciado.${NC}\n"
            printf "${CYAN}As mudanças no .env serão aplicadas quando o serviço for reiniciado.${NC}\n"
            printf "${GRAY}Você pode reiniciar manualmente escolhendo a opção 1 no menu.${NC}\n"
        fi
    else
        printf "\n${GRAY}Nenhum serviço em execução detectado.${NC}\n"
        printf "${CYAN}As configurações serão aplicadas quando o serviço for iniciado.${NC}\n"
        printf "${GRAY}Use a opção 1 no menu para iniciar o serviço.${NC}\n"
    fi
}

# ---------------------------------------------------------------------------
# update_assistant_script
# Atualiza o próprio script siscan-assistente.sh com rollback automático.
# Retorna 0 em caso de sucesso, 1 em caso de falha.
# ---------------------------------------------------------------------------
update_assistant_script() {
    printf "\n${CYAN}========================================${NC}\n"
    printf "${CYAN}  Atualização do Assistente SISCAN RPA${NC}\n"
    printf "${CYAN}========================================${NC}\n\n"

    local script_path="${BASH_SOURCE[0]}"
    # Resolve para caminho absoluto
    if [[ "${script_path}" != /* ]]; then
        script_path="${SCRIPT_DIR}/siscan-assistente.sh"
    fi

    if [ ! -f "${script_path}" ]; then
        printf "${RED}Erro: Não foi possível localizar o script atual em: %s${NC}\n" "${script_path}"
        return 1
    fi

    local timestamp
    timestamp="$(date '+%Y%m%d_%H%M%S')"
    local backup_path="${script_path}.backup.${timestamp}"
    local temp_path="${script_path}.temp"

    local repo_owner="Prisma-Consultoria"
    local repo_name="assistente-siscan-rpa"
    local branch="main"
    local script_filename="siscan-assistente.sh"
    local download_url="https://raw.githubusercontent.com/${repo_owner}/${repo_name}/${branch}/${script_filename}"

    printf "${GRAY}Script atual: %s${NC}\n" "${script_path}"
    printf "${GRAY}Backup será salvo em: %s${NC}\n" "${backup_path}"
    printf "${GRAY}URL de download: %s${NC}\n\n" "${download_url}"

    # ---- PASSO 1: Backup ----
    printf "${CYAN}[1/5] Criando backup do script atual...${NC}\n"
    if cp "${script_path}" "${backup_path}"; then
        printf "${GREEN}Backup criado com sucesso.${NC}\n"
    else
        printf "${RED}Erro ao criar backup.${NC}\n"
        return 1
    fi

    # ---- PASSO 2: Download ----
    printf "\n${CYAN}[2/5] Baixando nova versão do GitHub...${NC}\n"
    local download_ok=false

    if command -v curl &>/dev/null; then
        if curl -fsSL --max-time 60 -o "${temp_path}" "${download_url}" 2>&1; then
            download_ok=true
            printf "${GREEN}Download via curl concluído.${NC}\n"
        else
            printf "${YELLOW}curl falhou. Tentando wget...${NC}\n"
        fi
    fi

    if ! ${download_ok} && command -v wget &>/dev/null; then
        if wget -q --timeout=60 -O "${temp_path}" "${download_url}" 2>&1; then
            download_ok=true
            printf "${GREEN}Download via wget concluído.${NC}\n"
        else
            printf "${RED}wget também falhou.${NC}\n"
        fi
    fi

    if ! ${download_ok}; then
        printf "${RED}Erro: Não foi possível baixar a atualização (curl e wget falharam ou não encontrados).${NC}\n"
        printf "${YELLOW}Restaurando backup...${NC}\n"
        cp "${backup_path}" "${script_path}" && printf "${GREEN}Script original restaurado.${NC}\n"
        rm -f "${temp_path}"
        return 1
    fi

    # ---- PASSO 3: Validação ----
    printf "\n${CYAN}[3/5] Validando arquivo baixado...${NC}\n"

    if [ ! -f "${temp_path}" ]; then
        printf "${RED}Arquivo temporário não encontrado após download.${NC}\n"
        printf "${YELLOW}Restaurando backup...${NC}\n"
        cp "${backup_path}" "${script_path}"
        return 1
    fi

    local temp_size
    temp_size="$(wc -c < "${temp_path}" 2>/dev/null || echo 0)"
    temp_size="${temp_size// /}"

    if [ "${temp_size}" -lt 1000 ] 2>/dev/null; then
        printf "${RED}Arquivo baixado muito pequeno (%s bytes). Possível erro.${NC}\n" "${temp_size}"
        printf "${YELLOW}Restaurando backup...${NC}\n"
        cp "${backup_path}" "${script_path}"
        rm -f "${temp_path}"
        return 1
    fi

    # Verifica se contém o shebang esperado
    if ! grep -q '#!/usr/bin/env bash' "${temp_path}" 2>/dev/null; then
        printf "${RED}Arquivo baixado não parece ser um script bash válido (shebang ausente).${NC}\n"
        printf "${YELLOW}Restaurando backup...${NC}\n"
        cp "${backup_path}" "${script_path}"
        rm -f "${temp_path}"
        return 1
    fi

    printf "${GREEN}Validação básica OK (%s bytes).${NC}\n" "${temp_size}"

    # ---- PASSO 4: Aplicação ----
    printf "\n${CYAN}[4/5] Aplicando atualização...${NC}\n"
    if cp "${temp_path}" "${script_path}" && chmod +x "${script_path}"; then
        rm -f "${temp_path}"
        printf "${GREEN}Script atualizado com sucesso.${NC}\n"
    else
        printf "${RED}Erro ao aplicar atualização.${NC}\n"
        printf "${YELLOW}Restaurando backup...${NC}\n"
        cp "${backup_path}" "${script_path}"
        rm -f "${temp_path}"
        return 1
    fi

    # ---- PASSO 5: Verificação de sintaxe ----
    printf "\n${CYAN}[5/5] Verificando sintaxe do novo script...${NC}\n"
    local syntax_output
    syntax_output="$(bash -n "${script_path}" 2>&1)"
    local syntax_rc=$?

    if [ ${syntax_rc} -eq 0 ]; then
        printf "${GREEN}Sintaxe OK.${NC}\n"
    else
        printf "${YELLOW}Aviso: Problema de sintaxe detectado:${NC}\n"
        printf "${GRAY}%s${NC}\n" "${syntax_output}"
        printf "${YELLOW}Deseja restaurar o backup? (S/N) ${NC}"
        local resp=""
        read -rp "" resp
        if [[ "${resp}" =~ ^[Ss] ]]; then
            cp "${backup_path}" "${script_path}"
            printf "${GREEN}Backup restaurado.${NC}\n"
            return 1
        fi
    fi

    printf "\n${GREEN}========================================${NC}\n"
    printf "${GREEN}  Atualização concluída com sucesso!${NC}\n"
    printf "${GREEN}========================================${NC}\n"
    printf "${GRAY}\nBackup mantido em: %s${NC}\n" "${backup_path}"
    printf "${CYAN}Para usar a nova versão, reinicie o assistente.${NC}\n"
    printf "\n${YELLOW}Pressione Enter para sair e reiniciar o assistente...${NC}\n"
    read -r _UPDATE_DUMMY

    return 0
}

# ---------------------------------------------------------------------------
# show_menu
# Exibe o menu principal.
# ---------------------------------------------------------------------------
show_menu() {
    clear

    printf "${CYAN}========================================${NC}\n"
    printf "${WHITE}   Assistente SISCAN RPA - Fácil e seguro${NC}\n"
    printf "${CYAN}========================================${NC}\n\n"
    printf "${WHITE} 1) Reiniciar o SISCAN RPA${NC}\n"
    printf "${GRAY}    - Fecha e inicia o serviço (útil para problemas simples)${NC}\n"
    printf "${WHITE} 2) Atualizar / Instalar o SISCAN RPA${NC}\n"
    printf "${GRAY}    - Baixa a versão mais recente do serviço SISCAN RPA${NC}\n"
    printf "${WHITE} 3) Editar configurações básicas${NC}\n"
    printf "${GRAY}    - Ajuste caminhos e opções essenciais (.env)${NC}\n"
    printf "${WHITE} 4) Executar tarefas RPA manualmente${NC}\n"
    printf "${GRAY}    - Força execução do script de download/processamento (dia anterior)${NC}\n"
    printf "${WHITE} 5) Histórico do Sistema${NC}\n"
    printf "${GRAY}    - Visualiza desligamentos, crashes e reinicializações${NC}\n"
    printf "${WHITE} 6) Atualizar o Assistente${NC}\n"
    printf "${GRAY}    - Baixa a versão mais recente do assistente com rollback automático${NC}\n"
    printf "${WHITE} 7) Sair${NC}\n"
    printf "\n${CYAN}----------------------------------------${NC}\n"
}

# ---------------------------------------------------------------------------
# MAIN LOOP — só executa quando o script é chamado diretamente (não via source)
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then

CRED_USER=""
CRED_TOKEN=""

running=true

while ${running}; do
    show_menu
    printf ""
    read -rp "Escolha uma opção (1-7): " op

    case "${op}" in
        1)
            if check_service; then
                restart_service
            else
                printf "${YELLOW}Nenhum serviço do SISCAN RPA em execução encontrado.${NC}\n"
                printf "${CYAN}Tentando iniciar o serviço...${NC}\n"

                if [ ! -f "${COMPOSE_FILE}" ]; then
                    printf "${RED}Erro: Arquivo docker-compose.prd.host.yml não encontrado em: %s${NC}\n" "${COMPOSE_FILE}"
                elif ! check_env_configured "true"; then
                    : # Mensagem já exibida por check_env_configured
                else
                    # Lista serviços esperados
                    local_services="$(get_expected_service_names "${COMPOSE_FILE}")"
                    if [ -n "${local_services}" ]; then
                        printf "${CYAN}Serviços encontrados no docker-compose.prd.host.yml:${NC}\n"
                        while IFS= read -r svc; do
                            printf "${GRAY} - %s${NC}\n" "${svc}"
                        done <<< "${local_services}"
                        printf "\n${CYAN}Iniciando serviços...${NC}\n"
                    else
                        printf "${YELLOW}Aviso: Nenhum serviço detectado no arquivo docker-compose.prd.host.yml${NC}\n"
                        printf "${CYAN}Tentando iniciar mesmo assim...${NC}\n"
                    fi

                    ensure_host_paths
                    (cd "${SCRIPT_DIR}" && docker compose up -d)
                    if [ $? -eq 0 ]; then
                        printf "${GREEN}Serviços iniciados com sucesso!${NC}\n"
                    else
                        printf "${RED}Erro ao iniciar os serviços.${NC}\n"
                    fi
                fi
            fi
            pause
            ;;

        2)
            ask_credentials
            if docker_login; then
                update_and_restart
            else
                printf "${YELLOW}Aviso: não foi possível autenticar. Tentarei atualizar mesmo assim...${NC}\n"
                update_and_restart
            fi
            pause
            ;;

        3)
            manage_env
            pause
            ;;

        4)
            run_nightly_script
            pause
            ;;

        5)
            show_system_history
            pause
            ;;

        6)
            if update_assistant_script; then
                # Saiu do loop — usuário foi instruído a reiniciar
                running=false
            else
                # Falha ou cancelamento — volta ao menu
                pause
            fi
            ;;

        7)
            printf "\n${WHITE}Saindo...${NC}\n"
            running=false
            ;;

        *)
            printf "\n${YELLOW}Opção inválida.${NC}\n"
            pause
            ;;
    esac
done

fi # fim do guard BASH_SOURCE
