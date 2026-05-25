#!/usr/bin/env bash
# -------------------------------------------
# Specialist: check-permissions
# -------------------------------------------
# Cobre 4 problemas reais do chat ICI relacionados a permissão:
#   - /app/siscan-rpa criado como root (19/03, 20/03) → bind mount falha
#   - git pull com "dubious ownership" (19/03) → COMPOSE_DIR sem safe.directory
#   - PermissionError em data/.artifacts/auth (01/04) → UID 1000 do appuser
#   - excel_columns_mapping.json ausente em config/ (27/03) → RPA quebra
# -------------------------------------------

set -uo pipefail

SPECIALIST_NAME="check-permissions"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./_common.sh
source "$SCRIPT_DIR/_common.sh"

COMPOSE_DIR="${COMPOSE_DIR:-$(pwd)}"
ENV_FILE="$COMPOSE_DIR/.env"

usage() {
    cat <<EOF
Uso: bash $(basename "$0") [--env-file FILE] [--compose-dir DIR] [--quiet | --json] [--help]

Valida ownership/permissões do COMPOSE_DIR, HOST_*_DIR, git safe.directory,
data/.artifacts (UID 1000) e config/excel_columns_mapping.json (RPA).

Exit code: 0 = OK · 1 = FAIL · 2 = uso inválido
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --env-file)     ENV_FILE="${2:-}"; shift 2 ;;
        --env-file=*)   ENV_FILE="${1#*=}"; shift ;;
        --compose-dir)   COMPOSE_DIR="${2:-}"; ENV_FILE="$COMPOSE_DIR/.env"; shift 2 ;;
        --compose-dir=*) COMPOSE_DIR="${1#*=}"; ENV_FILE="$COMPOSE_DIR/.env"; shift ;;
        -h|--help)      usage; exit 0 ;;
        *)
            if common_parse_arg "$@"; then shift "$shift_count"
            else echo "argumento desconhecido: $1" >&2; usage >&2; exit 2; fi
            ;;
    esac
done

_read_env() {
    grep -E "^${1}=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | sed 's/^["'\'']\(.*\)["'\'']$/\1/'
}

CURRENT_USER="$(whoami)"
CAT_COMPOSE="Stack dir ($COMPOSE_DIR)"
CAT_GIT="Git safe.directory"
CAT_HOST="Diretórios HOST_*"
CAT_ARTIFACTS="data/.artifacts (UID 1000 — RPA)"
CAT_CONFIG="config/excel_columns_mapping.json (RPA)"

SISCAN_PRODUCT=""
[ -f "$ENV_FILE" ] && SISCAN_PRODUCT=$(_read_env SISCAN_PRODUCT)

# ────────────────────────────────────────────────────────────────────────────
# 1. COMPOSE_DIR ownership
# ────────────────────────────────────────────────────────────────────────────
print_category_header "$CAT_COMPOSE" "O diretório do assistente precisa pertencer ao usuário corrente — caso contrário git pull e bind mounts falham (chat ICI 19/03)."

if [ ! -d "$COMPOSE_DIR" ]; then
    add_fail "$CAT_COMPOSE" fs 0 "$COMPOSE_DIR" "diretório não existe"
else
    owner=$(stat -c '%U' "$COMPOSE_DIR" 2>/dev/null || echo "?")
    if [ "$owner" = "$CURRENT_USER" ]; then
        add_ok "$CAT_COMPOSE" fs 0 "owner" "$CURRENT_USER"
    else
        add_fail "$CAT_COMPOSE" fs 0 "owner" "atual=$owner, esperado=$CURRENT_USER — sudo chown -R $CURRENT_USER:$CURRENT_USER $COMPOSE_DIR"
    fi
fi

# ────────────────────────────────────────────────────────────────────────────
# 2. Git safe.directory
# ────────────────────────────────────────────────────────────────────────────
print_category_header "$CAT_GIT" "Se o diretório foi clonado como outro usuário, git pull falha com 'dubious ownership' (chat ICI 19/03). Precisa de 'git config --global --add safe.directory'."

if command -v git >/dev/null 2>&1 && [ -d "$COMPOSE_DIR/.git" ]; then
    if git -C "$COMPOSE_DIR" rev-parse >/dev/null 2>&1; then
        add_ok "$CAT_GIT" git 0 "safe.directory" "git pull funciona neste diretório"
    else
        add_fail "$CAT_GIT" git 0 "safe.directory" "git recusa o diretório — git config --global --add safe.directory $COMPOSE_DIR"
    fi
else
    add_ok "$CAT_GIT" git 0 "safe.directory" "não aplicável (git ausente ou não é repo)"
fi

# ────────────────────────────────────────────────────────────────────────────
# 3. HOST_*_DIR — existência e escrita
# ────────────────────────────────────────────────────────────────────────────
print_category_header "$CAT_HOST" "Cada caminho declarado no .env como HOST_*_DIR precisa existir e ser escrevível pelo usuário corrente (caso contrário bind mount falha)."

HOST_VARS=()
case "$SISCAN_PRODUCT" in
    rpa)       HOST_VARS=(HOST_LOG_DIR HOST_SISCAN_REPORTS_INPUT_DIR HOST_REPORTS_OUTPUT_CONSOLIDATED_DIR HOST_REPORTS_OUTPUT_CONSOLIDATED_PDFS_DIR HOST_CONFIG_DIR) ;;
    dashboard) HOST_VARS=(HOST_LOG_DIR) ;;
    full)      HOST_VARS=(HOST_LOG_DIR HOST_SISCAN_REPORTS_INPUT_DIR HOST_REPORTS_OUTPUT_CONSOLIDATED_DIR HOST_REPORTS_OUTPUT_CONSOLIDATED_PDFS_DIR HOST_CONFIG_DIR) ;;
    *)         warn "SISCAN_PRODUCT não definido — pulando checks HOST_*"; HOST_VARS=() ;;
esac

for var in "${HOST_VARS[@]}"; do
    path=$(_read_env "$var")
    if [ -z "$path" ]; then
        add_fail "$CAT_HOST" fs 0 "$var" "vazio no .env"
    elif [ ! -d "$path" ]; then
        add_fail "$CAT_HOST" fs 0 "$var" "$path NÃO existe — mkdir -p '$path' && sudo chown $CURRENT_USER:$CURRENT_USER '$path'"
    else
        owner=$(stat -c '%U' "$path" 2>/dev/null || echo "?")
        if [ -w "$path" ]; then
            add_ok "$CAT_HOST" fs 0 "$var" "$path (owner=$owner, escrevível)"
        else
            add_fail "$CAT_HOST" fs 0 "$var" "$path existe mas $CURRENT_USER não consegue escrever (owner=$owner)"
        fi
    fi
done

# ────────────────────────────────────────────────────────────────────────────
# 4. data/.artifacts — UID 1000 do appuser dentro do container (RPA)
# ────────────────────────────────────────────────────────────────────────────
if [ "$SISCAN_PRODUCT" = "rpa" ] || [ "$SISCAN_PRODUCT" = "full" ]; then
    print_category_header "$CAT_ARTIFACTS" "O appuser dentro do container RPA é UID 1000. data/.artifacts precisa pertencer a UID 1000, senão dá PermissionError (chat ICI 01/04)."

    ARTIFACTS_DIR="$COMPOSE_DIR/data/.artifacts"
    if [ -d "$ARTIFACTS_DIR" ]; then
        uid=$(stat -c '%u' "$ARTIFACTS_DIR" 2>/dev/null || echo "?")
        if [ "$uid" = "1000" ]; then
            add_ok "$CAT_ARTIFACTS" fs 0 "$ARTIFACTS_DIR" "UID 1000"
        else
            add_fail "$CAT_ARTIFACTS" fs 0 "$ARTIFACTS_DIR" "UID=$uid, esperado=1000 — sudo chown -R 1000:1000 $ARTIFACTS_DIR && sudo chmod -R 755 $ARTIFACTS_DIR"
        fi
    else
        # Diretório ainda não existe — ok, será criado em runtime se permissões pais permitirem
        add_ok "$CAT_ARTIFACTS" fs 0 "$ARTIFACTS_DIR" "ainda não criado (será no primeiro run)"
    fi
fi

# ────────────────────────────────────────────────────────────────────────────
# 5. config/excel_columns_mapping.json (RPA)
# ────────────────────────────────────────────────────────────────────────────
if [ "$SISCAN_PRODUCT" = "rpa" ] || [ "$SISCAN_PRODUCT" = "full" ]; then
    print_category_header "$CAT_CONFIG" "Arquivo de mapeamento de colunas usado pelo RPA — sem ele, a coleta quebra (chat ICI 27/03 — Fase 4 do setup só avisa)."

    CFG_DIR_VAR=$(_read_env HOST_CONFIG_DIR)
    CFG_DIR="${CFG_DIR_VAR:-$COMPOSE_DIR/config}"

    if [ -f "$CFG_DIR/excel_columns_mapping.json" ]; then
        add_ok "$CAT_CONFIG" fs 0 "excel_columns_mapping.json" "presente em $CFG_DIR/"
    else
        add_fail "$CAT_CONFIG" fs 0 "excel_columns_mapping.json" "ausente em $CFG_DIR/ — RPA vai falhar ao iniciar coleta"
    fi
fi

render_results
finalize_exit
