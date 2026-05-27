#!/usr/bin/env bash
# -------------------------------------------
# SISCAN Runner Recover — Recuperação cirúrgica do self-hosted runner
# -------------------------------------------
# Arquivo: siscan-runner-recover.sh
# Propósito: Recuperar o GitHub Actions self-hosted runner em dois cenários
#            descobertos no registro interno (incidente 15/04 → 25/05):
#
#   Cenário A — Auto-removal após 14 dias offline
#     GitHub remove runners offline há > 14 dias. Diagnóstico: 'total_count: 0'
#     na API. Resolução: re-registrar (novo token).
#
#   Cenário B — Regra dos 30 dias de auto-update
#     Runner online + serviço ativo, mas GitHub não envia jobs porque o runner
#     ficou > 30 dias sem atualizar sua versão. Resolução: 'run.sh --check'.
#
# Não é uma reinstalação: assume que ~/actions-runner/ existe (rodar
# siscan-server-setup.sh em VM nova). Reusa nome + label do manifesto.
#
# Uso:
#   bash ./siscan-runner-recover.sh                       # detecta produto via .env
#   bash ./siscan-runner-recover.sh --product rpa         # explícito
#   bash ./siscan-runner-recover.sh --product dashboard
#   bash ./siscan-runner-recover.sh --skip-doctor         # pula pré-flight (debug)
#   bash ./siscan-runner-recover.sh --help
#
# Variáveis de ambiente opcionais:
#   GH_TOKEN  Token com scope 'repo' pra consulta da API (ou 'gh auth status').
#             Sem token, a diagnose remota é pulada (apenas cenário B
#             via idade local é detectado).
#
# Exit code:
#   0  runner saudável (nada a fazer) OU recovery bem-sucedido
#   1  reservado (atualmente não usado — ver nota)
#   2  qualquer falha — uso inválido, pré-condição não atendida, OU
#      falha em etapa do recovery. O helper fail() de _common.sh sempre
#      sai com 2; automações que precisam distinguir "erro de invocação"
#      de "falha de recovery" devem inspecionar stderr.
#
# Referência: docs/guides/siscan-runner-recover.md
# -------------------------------------------

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPECIALISTS_DIR="$SCRIPT_DIR/scripts/deploy_server"
PRODUCTS_FILE="$SCRIPT_DIR/scripts/data/products.json"
DOCTOR_SCRIPT="$SCRIPT_DIR/siscan-server-doctor.sh"

# Source da biblioteca comum (cores, product_*, helpers ok/warn/fail)
SPECIALIST_NAME="recover"
# shellcheck source=scripts/deploy_server/_common.sh
source "$SPECIALISTS_DIR/_common.sh"
# shellcheck source=scripts/deploy_server/_runner.sh
source "$SPECIALISTS_DIR/_runner.sh"

# Force human mode — script interativo, não json/quiet
OUTPUT_MODE="human"
_setup_colors

# ────────────────────────────────────────────────────────────────────────────
# Configuração
# ────────────────────────────────────────────────────────────────────────────
RUNNER_DIR="${RUNNER_DIR:-${HOME}/actions-runner}"
COMPOSE_DIR="${COMPOSE_DIR:-$(pwd)}"
ENV_FILE="${COMPOSE_DIR}/.env"
SISCAN_PRODUCT=""
SKIP_DOCTOR=false
TOKEN_ARG=""
PAT_ARG=""
CURRENT_USER="$(whoami)"

usage() {
    cat <<EOF
Uso: bash $(basename "$0") [opções]

Opções:
  --product rpa|dashboard|full   Produto-alvo (lê .env se omitido)
  --env-file FILE                Override do .env (default: \$COMPOSE_DIR/.env ou \$CWD/.env)
  --runner-dir DIR               Override do diretório do runner (default: ~/actions-runner)
  --skip-doctor                  Pula pré-flight via doctor (debugging)
  --token TOKEN                  Token de registro do runner (alternativa a gh/GH_TOKEN);
                                 quando fornecido, sobrescreve o prompt interativo
  --pat PAT                      Personal Access Token (scope 'repo') usado pelo
                                 'run.sh --check' nos ramos B/WARN. Se omitido,
                                 tenta resolver via 'gh auth token' ou prompt interativo.
  -h, --help                     Esta ajuda

Cenários detectados automaticamente:
  OK   ) Runner saudável                                   → exit 0, nada a fazer
  N/A  ) ~/actions-runner não existe                       → bootstrap completo (pede token)
  1    ) dir existe mas binários ausentes                  → bootstrap incremental (pede token)
  2    ) binários OK, .runner ausente                      → register + install + start (pede token)
  C    ) .runner OK + systemd unit ausente                 → svc.sh install + start (sem token)
  A    ) total_count=0 na API (auto-removal >14d)          → uninstall + register + install (pede token)
  A2   ) runner offline ou nome mismatch na API            → uninstall + register + install (pede token)
  B    ) idade >=30d                                       → run.sh --check (pede PAT)
  WARN ) idade 25-29d                                      → run.sh --check preventivo (pede PAT)
  UNKNOWN) sem gh/GH_TOKEN/--token + estado inconclusivo   → orienta passos manuais

Exit code: 0 = OK · 2 = qualquer falha (uso / pré-cond / recovery) · 1 = reservado
EOF
}

# _require_value FLAG VALUE — valida que flag --foo tem argumento de valor.
# Usado pelos flags que esperam VALUE (--product, --env-file, --runner-dir, --token).
# Sem essa validação, "--flag" no fim da linha (sem valor) causaria loop infinito
# no while, pois `shift 2` falha silenciosamente quando só resta 1 argumento.
_require_value() {
    if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
        printf "erro: %s requer um valor\n" "$1" >&2
        usage >&2
        exit 2
    fi
}

while [ $# -gt 0 ]; do
    case "$1" in
        --product)      _require_value "$@"; SISCAN_PRODUCT="$2"; shift 2 ;;
        --product=*)    SISCAN_PRODUCT="${1#*=}"; shift ;;
        --env-file)     _require_value "$@"; ENV_FILE="$2"; shift 2 ;;
        --env-file=*)   ENV_FILE="${1#*=}"; shift ;;
        --runner-dir)   _require_value "$@"; RUNNER_DIR="$2"; shift 2 ;;
        --runner-dir=*) RUNNER_DIR="${1#*=}"; shift ;;
        --skip-doctor)  SKIP_DOCTOR=true; shift ;;
        --token)        _require_value "$@"; TOKEN_ARG="$2"; shift 2 ;;
        --token=*)      TOKEN_ARG="${1#*=}"; shift ;;
        --pat)          _require_value "$@"; PAT_ARG="$2"; shift 2 ;;
        --pat=*)        PAT_ARG="${1#*=}"; shift ;;
        -h|--help)      usage; exit 0 ;;
        *) echo "argumento desconhecido: $1" >&2; usage >&2; exit 2 ;;
    esac
done

_read_env_var() {
    grep -E "^${1}=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | sed 's/^["'\'']\(.*\)["'\'']$/\1/'
}

step_print() {
    printf "\n${CYAN}══════════════════════════════════════════════════${NC}\n"
    printf "${WHITE}  %s${NC}\n" "$1"
    printf "${CYAN}══════════════════════════════════════════════════${NC}\n"
}

# ────────────────────────────────────────────────────────────────────────────
# 1. Detectar produto + validar manifesto
# ────────────────────────────────────────────────────────────────────────────
step_print "1/6 — Detecção do produto e validação do manifesto"

if [ -z "$SISCAN_PRODUCT" ] && [ -f "$ENV_FILE" ]; then
    SISCAN_PRODUCT=$(_read_env_var SISCAN_PRODUCT)
fi
[ -n "$SISCAN_PRODUCT" ] || fail "SISCAN_PRODUCT não definido. Use --product rpa|dashboard|full ou preencha .env."

product_validate
PRODUCT_LABEL=$(product_get label)
REPO_FULL=$(product_get repo)
REPO_OWNER="${REPO_FULL%%/*}"
REPO_NAME="${REPO_FULL##*/}"
RUNNER_SUFFIX=$(product_get runner_name_suffix)
RUNNER_LABEL=$(product_get runner_label)
EXPECTED_NAME="$(hostname)-${RUNNER_SUFFIX}"

ok "Produto: $SISCAN_PRODUCT ($PRODUCT_LABEL)"
info "Repo: $REPO_FULL"
info "Nome do runner esperado: $EXPECTED_NAME"
info "Label: $RUNNER_LABEL"

# ────────────────────────────────────────────────────────────────────────────
# 2. Inspeção do estado local — sem abortar; o cenário decide
# ────────────────────────────────────────────────────────────────────────────
step_print "2/6 — Inspeção da instalação local"

LOCAL_STATE=$(runner_get_state "$RUNNER_DIR")
case "$LOCAL_STATE" in
    N/A) info "Diretório do runner ausente — será criado pelo bootstrap (cenário N/A)" ;;
    1)   info "Diretório existe mas binários ausentes — bootstrap incremental" ;;
    2)   info ".runner ausente — registro necessário" ;;
    3)   ok "Binários + .runner OK; systemd unit ausente (cenário C provável)" ;;
    4)   ok "Instalação local completa em $RUNNER_DIR" ;;
esac

# ────────────────────────────────────────────────────────────────────────────
# 3. Pré-flight via doctor (não inclui check-runner — é o que vamos consertar)
# ────────────────────────────────────────────────────────────────────────────
step_print "3/6 — Pré-flight via doctor (rede, binários, daemon, permissões)"

if [ "$SKIP_DOCTOR" = "true" ]; then
    warn "Pré-flight pulado por --skip-doctor (não recomendado)"
elif [ ! -x "$DOCTOR_SCRIPT" ]; then
    warn "siscan-server-doctor.sh ausente — pulando pré-flight"
else
    info "Rodando doctor em modo quiet..."
    if bash "$DOCTOR_SCRIPT" --quiet \
        --only check-network,check-deps,check-docker,check-permissions; then
        ok "Doctor aprovou: rede, binários, daemon e permissões OK"
    else
        printf "\n${RED}ERRO: doctor reportou problemas além do runner.${NC}\n" >&2
        printf "${WHITE}Detalhes:${NC} ${CYAN}bash $DOCTOR_SCRIPT --only check-network,check-deps,check-docker,check-permissions${NC}\n" >&2
        printf "${WHITE}Skip:${NC}     ${CYAN}bash $(basename "$BASH_SOURCE") --skip-doctor${NC}\n\n" >&2
        exit 2
    fi
fi

# ────────────────────────────────────────────────────────────────────────────
# 4. Diagnóstico do cenário (delegado para _runner.sh)
# ────────────────────────────────────────────────────────────────────────────
step_print "4/6 — Diagnóstico do estado do runner"

age_days=$(runner_local_age_days "$RUNNER_DIR")
if [ "$age_days" -ne 999 ]; then
    info "Idade do runner: $age_days dia(s)"
fi

HAS_TOKEN_ARG="false"
[ -n "$TOKEN_ARG" ] && HAS_TOKEN_ARG="true"

scenario=$(runner_diagnose "$RUNNER_DIR" "$EXPECTED_NAME" "$REPO_OWNER" "$REPO_NAME" "$HAS_TOKEN_ARG")

case "$scenario" in
    OK)
        ok "Runner saudável (online, $age_days d desde último update) — nada a fazer."
        exit 0
        ;;
    N/A) info "→ Cenário N/A: $RUNNER_DIR não existe — bootstrap completo" ;;
    1)   info "→ Cenário 1: binários ausentes — bootstrap incremental (download + register + install + start)" ;;
    2)   info "→ Cenário 2: .runner ausente — register + install + start" ;;
    C)   info "→ Cenário C: systemd unit ausente, .runner válido — install + start (sem token)" ;;
    A)   info "→ Cenário A (auto-removal): total_count=0 na API — re-registro completo" ;;
    A2)
        if [ "$HAS_TOKEN_ARG" = "true" ] && ! command -v gh >/dev/null 2>&1 && [ -z "${GH_TOKEN:-}" ]; then
            info "→ Cenário A' (defensivo): --token fornecido sem API consultável — assume runner removido"
        else
            info "→ Cenário A' (offline/nome mismatch na API) — re-registro completo"
        fi
        ;;
    B)   info "→ Cenário B (regra dos 30 dias): $age_days d — run.sh --check" ;;
    WARN) info "→ AVISO ($age_days d): regra dos 30d em $((30 - age_days)) d — run.sh --check preventivo" ;;
    UNKNOWN)
        warn "API GitHub indisponível (sem gh/GH_TOKEN/--token) e idade local insuficiente pra disparar B/WARN."
        ;;
esac

# ────────────────────────────────────────────────────────────────────────────
# 5. Execução do recovery (delegada para _runner.sh)
# ────────────────────────────────────────────────────────────────────────────
step_print "5/6 — Execução do recovery"

REPO_URL="https://github.com/$REPO_OWNER/$REPO_NAME"

# prompt_token_if_needed — usa --token se fornecido; senão pergunta interativo.
# Mensagem de origem do token vira "args.fornecido" ou "prompt.interativo".
prompt_token_if_needed() {
    if [ -n "$TOKEN_ARG" ]; then
        TOKEN="$TOKEN_ARG"
        info "Token fornecido via --token"
    else
        printf "${YELLOW}Token de registro requerido — expira em poucos minutos; gere agora.${NC}\n"
        printf "${WHITE}URL:${NC} ${CYAN}%s/settings/actions/runners/new${NC}\n\n" "$REPO_URL"
        # shellcheck disable=SC2162
        read -srp "Token: " TOKEN
        echo ""
    fi
    [ -n "$TOKEN" ] || fail "Token vazio. Abortando."
}

# resolve_pat — define $PAT para uso em 'run.sh --check' (ramos B/WARN).
# Precedência: --pat > GH_TOKEN > 'gh auth token' > prompt interativo.
# PAT é diferente do token de registro: precisa scope 'repo' e dura mais.
# Fix #53/Bug 3: antes, run.sh --check era chamado sem --url/--pat e caía em
# prompt interativo bloqueando o fluxo automatizado.
resolve_pat() {
    if [ -n "$PAT_ARG" ]; then
        PAT="$PAT_ARG"
        info "PAT fornecido via --pat"
    elif [ -n "${GH_TOKEN:-}" ]; then
        PAT="$GH_TOKEN"
        info "PAT obtido de \$GH_TOKEN"
    elif command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
        PAT=$(gh auth token 2>/dev/null)
        [ -n "$PAT" ] && info "PAT obtido de 'gh auth token'"
    fi
    if [ -z "${PAT:-}" ]; then
        printf "${YELLOW}PAT (Personal Access Token) requerido para 'run.sh --check'.${NC}\n"
        printf "${WHITE}Gere em:${NC} ${CYAN}https://github.com/settings/tokens (scope 'repo')${NC}\n\n"
        # shellcheck disable=SC2162
        read -srp "PAT: " PAT
        echo ""
    fi
    [ -n "$PAT" ] || fail "PAT vazio. Abortando 'run.sh --check'."
}

case "$scenario" in
    N/A)
        # Bootstrap completo — recover instalando do zero
        runner_download_binaries "$RUNNER_DIR" \
            || fail "Falha no download do runner. Verifique conectividade com github.com."
        prompt_token_if_needed
        runner_register "$RUNNER_DIR" "$REPO_URL" "$TOKEN" "$EXPECTED_NAME" "$RUNNER_LABEL" \
            || fail "Falha ao registrar o runner."
        runner_install_service "$RUNNER_DIR" "$CURRENT_USER" \
            || fail "Falha ao instalar systemd unit."
        runner_start_service "$RUNNER_DIR" \
            || fail "Falha ao iniciar serviço do runner."
        ;;

    1)
        # Diretório existe mas binários ausentes (estado raro — limpeza parcial)
        runner_download_binaries "$RUNNER_DIR" \
            || fail "Falha no download do runner."
        prompt_token_if_needed
        runner_register "$RUNNER_DIR" "$REPO_URL" "$TOKEN" "$EXPECTED_NAME" "$RUNNER_LABEL" \
            || fail "Falha ao registrar o runner."
        runner_install_service "$RUNNER_DIR" "$CURRENT_USER" \
            || fail "Falha ao instalar systemd unit."
        runner_start_service "$RUNNER_DIR" \
            || fail "Falha ao iniciar serviço do runner."
        ;;

    2)
        # Binários presentes, .runner ausente
        prompt_token_if_needed
        runner_register "$RUNNER_DIR" "$REPO_URL" "$TOKEN" "$EXPECTED_NAME" "$RUNNER_LABEL" \
            || fail "Falha ao registrar o runner."
        runner_install_service "$RUNNER_DIR" "$CURRENT_USER" \
            || fail "Falha ao instalar systemd unit."
        runner_start_service "$RUNNER_DIR" \
            || fail "Falha ao iniciar serviço do runner."
        ;;

    C)
        # .runner válido, systemd unit ausente — caminho cirúrgico, sem token
        runner_install_service "$RUNNER_DIR" "$CURRENT_USER" \
            || fail "Falha ao instalar systemd unit."
        runner_start_service "$RUNNER_DIR" \
            || fail "Falha ao iniciar serviço do runner."
        ;;

    A|A2)
        prompt_token_if_needed
        runner_stop_service "$RUNNER_DIR"
        runner_uninstall_service "$RUNNER_DIR"
        # Issue #63: passar OWNER+REPO em vez do registration-token. A função
        # detecta estado remoto, obtém remove-token via API quando aplicável,
        # e sempre garante limpeza local de .runner+.credentials*.
        runner_remove_registration "$RUNNER_DIR" "$REPO_OWNER" "$REPO_NAME" \
            || fail "Não foi possível limpar o registro local do runner em $RUNNER_DIR. Verifique permissões em .runner / .credentials* e re-execute."
        runner_register "$RUNNER_DIR" "$REPO_URL" "$TOKEN" "$EXPECTED_NAME" "$RUNNER_LABEL" \
            || fail "Falha no config.sh — verifique o token (expira em poucos minutos) e a URL do repo."
        runner_install_service "$RUNNER_DIR" "$CURRENT_USER" \
            || fail "svc.sh install falhou."
        runner_start_service "$RUNNER_DIR" \
            || fail "svc.sh start falhou."
        ;;

    B|WARN)
        resolve_pat
        runner_stop_service "$RUNNER_DIR"
        info "Forçando auto-update via 'run.sh --check' (pode demorar ~30s)..."
        # Fix #53/Bug 3: passar --url e --pat para evitar prompt interativo.
        # Fix #53/Bug 2: 'run.sh --check' retorna exit 0 mesmo com FAILs
        # internos. Capturar output e fazer parse procurando 'F A I L'.
        check_output=$(sudo -u "$CURRENT_USER" "$RUNNER_DIR/run.sh" --check \
            --url "$REPO_URL" --pat "$PAT" 2>&1)
        check_exit=$?
        printf '%s\n' "$check_output"
        if [ "$check_exit" -ne 0 ] || printf '%s' "$check_output" | grep -q "F A I L"; then
            fail "run.sh --check reportou falha (exit=$check_exit). Verifique logs em $RUNNER_DIR/_diag/. Causas comuns: PAT sem scope 'repo', firewall bloqueando endpoints do GitHub Actions, runner removido do GitHub (cenário A — rode com --token <token-registro> em vez de --pat)."
        fi
        ok "run.sh --check OK (runner atualizado, sem FAILs internos)"
        runner_start_service "$RUNNER_DIR" \
            || fail "svc.sh start falhou."
        ;;

    *)
        fail "Cenário desconhecido — nada a fazer automaticamente.
       Rode 'bash $DOCTOR_SCRIPT --only check-runner' para diagnóstico detalhado,
       ou 'bash siscan-server-setup.sh --product $SISCAN_PRODUCT' para re-instalação completa.
       Alternativa: forneça --token <novo> para forçar fluxo A2 defensivo."
        ;;
esac

# ────────────────────────────────────────────────────────────────────────────
# 6. Validação pós-recovery via check-runner
# ────────────────────────────────────────────────────────────────────────────
step_print "6/6 — Validação pós-recovery"

cd "$SCRIPT_DIR" || true
info "Aguardando 5s pra runner estabelecer conexão..."
sleep 5

# Fix #53/Bug 4: exportar RUNNER_DIR pra propagação garantida pra subshell
# do check-runner.sh. Sem isso, o specialist podia cair no default
# ${HOME}/actions-runner em contextos onde HOME era inconsistente com o
# RUNNER_DIR usado pelo recover, gerando falso positivo 'config.sh: ausente'.
export RUNNER_DIR

if bash "$SPECIALISTS_DIR/check-runner.sh" --quiet; then
    ok "Runner recuperado com sucesso — pronto pra receber jobs."
    info "Acompanhe os logs: sudo journalctl -u 'actions.runner.*.service' -f"
    exit 0
else
    printf "\n${YELLOW}AVISO: check-runner ainda reporta problema(s) — pode ser timing.${NC}\n" >&2
    printf "${WHITE}Diagnostique:${NC} ${CYAN}bash $SPECIALISTS_DIR/check-runner.sh${NC}\n\n" >&2
    exit 1
fi
