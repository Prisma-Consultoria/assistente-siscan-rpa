#!/usr/bin/env bash
# -------------------------------------------
# SISCAN Runner Recover — Recuperação cirúrgica do self-hosted runner
# -------------------------------------------
# Arquivo: siscan-runner-recover.sh
# Propósito: Recuperar o GitHub Actions self-hosted runner em dois cenários
#            descobertos no chat ICI (incidente 15/04 → 25/05):
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
#   1  falha em alguma etapa do recovery
#   2  uso inválido / pré-condição não atendida
#
# Referência: docs/siscan-server-doctor/scripts/siscan-runner-recover.md
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
CURRENT_USER="$(whoami)"

usage() {
    cat <<EOF
Uso: bash $(basename "$0") [opções]

Opções:
  --product rpa|dashboard|full   Produto-alvo (lê .env se omitido)
  --env-file FILE                Override do .env (default: \$COMPOSE_DIR/.env ou \$CWD/.env)
  --runner-dir DIR               Override do diretório do runner (default: ~/actions-runner)
  --skip-doctor                  Pula pré-flight via doctor (debugging)
  -h, --help                     Esta ajuda

Cenários detectados automaticamente via GitHub API:
  A) Auto-removal (>14d offline)  → re-registro (pede token novo)
  B) Regra dos 30 dias            → run.sh --check (sem token)
  OK) Runner saudável             → exit 0, nada a fazer
  N/A) Runner nunca instalado     → orienta siscan-server-setup.sh

Exit code: 0 = OK · 1 = falha no recovery · 2 = pré-condição/uso
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --product)      SISCAN_PRODUCT="${2:-}"; shift 2 ;;
        --product=*)    SISCAN_PRODUCT="${1#*=}"; shift ;;
        --env-file)     ENV_FILE="${2:-}"; shift 2 ;;
        --env-file=*)   ENV_FILE="${1#*=}"; shift ;;
        --runner-dir)   RUNNER_DIR="${2:-}"; shift 2 ;;
        --runner-dir=*) RUNNER_DIR="${1#*=}"; shift ;;
        --skip-doctor)  SKIP_DOCTOR=true; shift ;;
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
# 2. Pré-condição: ~/actions-runner/ deve existir
# ────────────────────────────────────────────────────────────────────────────
step_print "2/6 — Validação da instalação local"

if [ ! -d "$RUNNER_DIR" ]; then
    fail "Diretório do runner não existe: $RUNNER_DIR
       Esse script é pra recuperar runner JÁ INSTALADO. Para nova instalação:
       bash siscan-server-setup.sh --product $SISCAN_PRODUCT"
fi
if [ ! -x "$RUNNER_DIR/config.sh" ] || [ ! -x "$RUNNER_DIR/svc.sh" ]; then
    fail "Binários do runner ausentes em $RUNNER_DIR (config.sh ou svc.sh).
       Reinstale via: bash siscan-server-setup.sh --product $SISCAN_PRODUCT"
fi
ok "Binários do runner presentes em $RUNNER_DIR"

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
# 4. Diagnóstico do cenário
# ────────────────────────────────────────────────────────────────────────────
step_print "4/6 — Diagnóstico do estado do runner"

# 4a — Idade local
age_days=999
age_source=""
age_file=""
if [ -f "$RUNNER_DIR/.runner_migrated" ]; then
    age_file="$RUNNER_DIR/.runner_migrated"
    age_source="último upgrade (.runner_migrated)"
elif [ -d "$RUNNER_DIR/_diag" ]; then
    age_file=$(ls -t "$RUNNER_DIR/_diag"/Runner_*.log 2>/dev/null | head -1)
    [ -n "$age_file" ] && age_source="último log em _diag/"
elif [ -f "$RUNNER_DIR/.runner" ]; then
    age_file="$RUNNER_DIR/.runner"
    age_source="data de registro (.runner)"
fi

if [ -n "$age_source" ] && [ -e "$age_file" ]; then
    age_epoch=$(stat -c '%Y' "$age_file" 2>/dev/null || echo 0)
    now_epoch=$(date +%s)
    age_days=$(( (now_epoch - age_epoch) / 86400 ))
    info "Idade do runner: $age_days dia(s) ($age_source)"
else
    warn "Não foi possível determinar idade do runner — assumindo velho"
fi

# 4b — Estado remoto via GitHub API
runners_json=""
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    runners_json=$(gh api "repos/$REPO_OWNER/$REPO_NAME/actions/runners" 2>/dev/null || echo "")
elif [ -n "${GH_TOKEN:-}" ]; then
    runners_json=$(curl -s -H "Authorization: Bearer $GH_TOKEN" \
        "https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/actions/runners" 2>/dev/null || echo "")
fi

scenario="UNKNOWN"
if [ -z "$runners_json" ]; then
    warn "API GitHub indisponível (sem gh ou GH_TOKEN). Cenário A vs B detectável só via idade."
    if [ "$age_days" -ge 30 ]; then
        scenario="B"
        info "→ Cenário B (regra dos 30 dias) — runner com $age_days d"
    fi
else
    total=$(echo "$runners_json" | jq -r '.total_count // 0')
    if [ "$total" -eq 0 ]; then
        scenario="A"
        info "→ Cenário A (auto-removal): total_count=0 — runner removido pelo GitHub"
    else
        remote_status=$(echo "$runners_json" | jq -r ".runners[] | select(.name == \"$EXPECTED_NAME\") | .status" | head -1)
        if [ -z "$remote_status" ]; then
            scenario="A2"
            names=$(echo "$runners_json" | jq -r '.runners[].name' | paste -sd, -)
            info "→ Cenário A' (nome mismatch): esperado '$EXPECTED_NAME' não está na API"
            info "   Registrados: $names"
        elif [ "$remote_status" = "offline" ]; then
            scenario="A2"
            info "→ Cenário A' (offline na API): runner registrado mas reportando offline"
        elif [ "$age_days" -ge 30 ]; then
            scenario="B"
            info "→ Cenário B (regra dos 30 dias): runner online mas $age_days d sem update"
        elif [ "$age_days" -ge 25 ]; then
            scenario="WARN"
            info "→ AVISO: runner $age_days d sem update (regra dos 30d em $((30 - age_days))d)"
        else
            ok "Runner saudável (online, $age_days d desde último update) — nada a fazer."
            exit 0
        fi
    fi
fi

# ────────────────────────────────────────────────────────────────────────────
# 5. Execução do recovery
# ────────────────────────────────────────────────────────────────────────────
step_print "5/6 — Execução do recovery"

cd "$RUNNER_DIR" || fail "Não foi possível entrar em $RUNNER_DIR"

case "$scenario" in
    A|A2)
        printf "${YELLOW}Re-registro requer token novo (expira em ~5 min).${NC}\n"
        printf "${WHITE}Gere agora em:${NC} ${CYAN}https://github.com/$REPO_OWNER/$REPO_NAME/settings/actions/runners/new${NC}\n\n"
        # shellcheck disable=SC2162
        read -srp "Token: " TOKEN
        echo ""
        [ -n "$TOKEN" ] || fail "Token vazio. Abortando."

        info "Parando serviço..."
        sudo ./svc.sh stop 2>/dev/null && ok "svc.sh stop" || warn "svc.sh stop (já parado?)"

        info "Desinstalando serviço..."
        sudo ./svc.sh uninstall 2>/dev/null && ok "svc.sh uninstall" || warn "svc.sh uninstall (já desinstalado?)"

        info "Removendo registro local (config.sh remove)..."
        ./config.sh remove --token "$TOKEN" 2>/dev/null && ok "config remove" || warn "config remove (404 esperado se runner já foi auto-removido)"

        info "Re-registrando com novo token..."
        if ./config.sh \
            --url "https://github.com/$REPO_OWNER/$REPO_NAME" \
            --token "$TOKEN" \
            --name "$EXPECTED_NAME" \
            --labels "$RUNNER_LABEL" \
            --unattended --replace; then
            ok "config register OK (name=$EXPECTED_NAME, label=$RUNNER_LABEL)"
        else
            fail "Falha no config.sh — verifique o token (expira em ~5min) e a URL do repo"
        fi

        info "Instalando serviço systemd..."
        sudo ./svc.sh install "$CURRENT_USER" && ok "svc.sh install" || fail "svc.sh install falhou"

        info "Iniciando serviço..."
        sudo ./svc.sh start && ok "svc.sh start" || fail "svc.sh start falhou"
        ;;

    B|WARN)
        info "Parando serviço (sem desinstalar)..."
        sudo ./svc.sh stop && ok "svc.sh stop" || warn "svc.sh stop (já parado?)"

        info "Forçando auto-update via 'run.sh --check' (pode demorar ~30s)..."
        if sudo -u "$CURRENT_USER" ./run.sh --check; then
            ok "run.sh --check OK (runner atualizado)"
        else
            fail "run.sh --check retornou erro — runner pode estar com problema mais sério"
        fi

        info "Reiniciando serviço..."
        sudo ./svc.sh start && ok "svc.sh start" || fail "svc.sh start falhou"
        ;;

    *)
        fail "Cenário desconhecido — nada a fazer automaticamente.
       Rode 'bash $DOCTOR_SCRIPT --only check-runner' para diagnóstico detalhado,
       ou 'bash siscan-server-setup.sh --product $SISCAN_PRODUCT' para re-instalação completa."
        ;;
esac

# ────────────────────────────────────────────────────────────────────────────
# 6. Validação pós-recovery via check-runner
# ────────────────────────────────────────────────────────────────────────────
step_print "6/6 — Validação pós-recovery"

cd "$SCRIPT_DIR" || true
info "Aguardando 5s pra runner estabelecer conexão..."
sleep 5

if bash "$SPECIALISTS_DIR/check-runner.sh" --quiet; then
    ok "Runner recuperado com sucesso — pronto pra receber jobs."
    info "Acompanhe os logs: sudo journalctl -u 'actions.runner.*.service' -f"
    exit 0
else
    printf "\n${YELLOW}AVISO: check-runner ainda reporta problema(s) — pode ser timing.${NC}\n" >&2
    printf "${WHITE}Diagnostique:${NC} ${CYAN}bash $SPECIALISTS_DIR/check-runner.sh${NC}\n\n" >&2
    exit 1
fi
