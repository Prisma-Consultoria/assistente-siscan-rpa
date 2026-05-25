#!/usr/bin/env bash
# -------------------------------------------
# Specialist: check-env
# -------------------------------------------
# Valida o .env do diretório atual (ou apontado por --env-file):
#   - Variáveis obrigatórias presentes e não-vazias
#   - DATABASE_HOST ≠ "db" (padrão dev), DATABASE_PASSWORD ≠ default
#   - RPA_DATABASE_URL com formato postgresql://user:pass@host:port/db
#   - APP_LOG_LEVEL ≠ DEBUG (warning, não FAIL — TROUBLESHOOTING Problema C)
#   - Conjunto de obrigatórias varia por SISCAN_PRODUCT (rpa | dashboard | full)
#
# Não usa eval/source — lê o .env como dados (segurança).
# -------------------------------------------

set -uo pipefail

SPECIALIST_NAME="check-env"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./_common.sh
source "$SCRIPT_DIR/_common.sh"

ENV_FILE="$(pwd)/.env"

usage() {
    cat <<EOF
Uso: bash $(basename "$0") [--env-file FILE] [--quiet | --json] [--help]

Valida o .env (default: \$CWD/.env) com base em SISCAN_PRODUCT.

Exit code: 0 = OK · 1 = FAIL em obrigatórias · 2 = uso inválido / .env ausente
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --env-file)   ENV_FILE="${2:-}"; shift 2 ;;
        --env-file=*) ENV_FILE="${1#*=}"; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)
            if common_parse_arg "$@"; then shift "$shift_count"
            else echo "argumento desconhecido: $1" >&2; usage >&2; exit 2; fi
            ;;
    esac
done

[ -f "$ENV_FILE" ] || fail "arquivo .env não encontrado: $ENV_FILE (use --env-file para apontar para outro caminho)"

# _read_env VAR -> imprime o valor (string vazia se não definido)
# Lê o .env como texto, sem source/eval; aceita variáveis com '=' no valor.
_read_env() {
    grep -E "^${1}=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | sed 's/^["'\'']\(.*\)["'\'']$/\1/'
}

# _check_required CATEGORY VAR_NAME [INVALID_VALUE_REGEX_OR_EMPTY] [FRIENDLY_MSG]
# Default: válido se não-vazio.
_check_required() {
    local category="$1" var="$2" forbidden="${3:-}" friendly="${4:-}"
    local value
    value=$(_read_env "$var")
    if [ -z "$value" ]; then
        add_fail "$category" env 0 "$var" "vazio${friendly:+ — $friendly}"
        return
    fi
    if [ -n "$forbidden" ] && [[ "$value" =~ $forbidden ]]; then
        add_fail "$category" env 0 "$var" "valor inválido ($value)${friendly:+ — $friendly}"
        return
    fi
    add_ok "$category" env 0 "$var" "definido"
}

CAT_PRODUCT="Produto e arquivo"
CAT_DB="Banco de dados"
CAT_APP="Aplicação"
CAT_PATHS="Diretórios HOST_*"
CAT_WARN="Avisos (não impedem o boot)"

# Detectar produto
print_category_header "$CAT_PRODUCT" "SISCAN_PRODUCT define quais variáveis são obrigatórias (rpa, dashboard, full)."
SISCAN_PRODUCT="$(_read_env SISCAN_PRODUCT)"
if [ -z "$SISCAN_PRODUCT" ]; then
    add_fail "$CAT_PRODUCT" env 0 "SISCAN_PRODUCT" "não definido — siscan-server-setup.sh persiste esse valor"
    SISCAN_PRODUCT="unknown"
else
    case "$SISCAN_PRODUCT" in
        rpa|dashboard|full) add_ok "$CAT_PRODUCT" env 0 "SISCAN_PRODUCT" "$SISCAN_PRODUCT" ;;
        *) add_fail "$CAT_PRODUCT" env 0 "SISCAN_PRODUCT" "valor inválido ($SISCAN_PRODUCT) — esperado: rpa, dashboard ou full" ;;
    esac
fi

# Variáveis comuns a todos os produtos
print_category_header "$CAT_DB" "Credenciais e endereço do PostgreSQL externo (RPA) e/ou banco do dashboard."
_check_required "$CAT_DB" DATABASE_HOST "^db$" "use IP/hostname real do PostgreSQL externo"
_check_required "$CAT_DB" DATABASE_USER ""
_check_required "$CAT_DB" DATABASE_NAME ""
_check_required "$CAT_DB" DATABASE_PASSWORD "^(siscan_rpa|siscan_dashboard|changeme|password)$" "ainda é o default — altere antes de produção"

# Variáveis por produto
print_category_header "$CAT_APP" "Chaves de sessão e senha do admin. Conjunto varia por produto."
case "$SISCAN_PRODUCT" in
    rpa|full)
        # SECRET_KEY: precisa ter >= 32 caracteres
        sk="$(_read_env SECRET_KEY)"
        if [ -z "$sk" ]; then
            add_fail "$CAT_APP" env 0 "SECRET_KEY" "vazio — siscan-server-setup gera automaticamente"
        elif [ "${#sk}" -lt 32 ]; then
            add_fail "$CAT_APP" env 0 "SECRET_KEY" "curto demais (${#sk} chars) — esperado ≥ 32"
        else
            add_ok "$CAT_APP" env 0 "SECRET_KEY" "${#sk} chars"
        fi
        ;;
esac

case "$SISCAN_PRODUCT" in
    dashboard|full)
        ss="$(_read_env SESSION_SECRET)"
        if [ -z "$ss" ]; then
            add_fail "$CAT_APP" env 0 "SESSION_SECRET" "vazio — siscan-server-setup gera automaticamente"
        elif [ "${#ss}" -lt 32 ]; then
            add_fail "$CAT_APP" env 0 "SESSION_SECRET" "curto demais (${#ss} chars) — esperado ≥ 32"
        else
            add_ok "$CAT_APP" env 0 "SESSION_SECRET" "${#ss} chars"
        fi

        _check_required "$CAT_APP" ADMIN_PASSWORD "" "sem isso, dashboard gera senha temporária nos logs"

        # RPA_DATABASE_URL: formato postgresql://user:pass@host:port/dbname
        # Chat ICI 27/03: foi setado como "siscandashboard" só (faltava prefixo).
        rdb="$(_read_env RPA_DATABASE_URL)"
        if [ -z "$rdb" ]; then
            add_fail "$CAT_DB" env 0 "RPA_DATABASE_URL" "vazio — sync_exames não funciona"
        elif [[ ! "$rdb" =~ ^postgresql://[^:]+:[^@]+@[^:]+:[0-9]+/[^?]+$ ]]; then
            add_fail "$CAT_DB" env 0 "RPA_DATABASE_URL" "formato inválido — esperado: postgresql://user:pass@host:port/db (observado: ${rdb:0:30}...)"
        else
            add_ok "$CAT_DB" env 0 "RPA_DATABASE_URL" "formato válido"
        fi
        ;;
esac

# Diretórios HOST_* — verificar definidos (existência fica para check-permissions)
print_category_header "$CAT_PATHS" "Caminhos absolutos Linux usados como bind mounts nos containers. Existência/permissão verificada por check-permissions."
HOST_VARS=()
case "$SISCAN_PRODUCT" in
    rpa) HOST_VARS=(HOST_LOG_DIR HOST_SISCAN_REPORTS_INPUT_DIR HOST_REPORTS_OUTPUT_CONSOLIDATED_DIR HOST_REPORTS_OUTPUT_CONSOLIDATED_PDFS_DIR HOST_CONFIG_DIR) ;;
    dashboard) HOST_VARS=(HOST_LOG_DIR) ;;
    full) HOST_VARS=(HOST_LOG_DIR HOST_SISCAN_REPORTS_INPUT_DIR HOST_REPORTS_OUTPUT_CONSOLIDATED_DIR HOST_REPORTS_OUTPUT_CONSOLIDATED_PDFS_DIR HOST_CONFIG_DIR) ;;
esac

for var in "${HOST_VARS[@]}"; do
    val=$(_read_env "$var")
    if [ -z "$val" ]; then
        add_fail "$CAT_PATHS" env 0 "$var" "vazio — bind mount vai falhar"
    elif [[ "$val" =~ \\ ]] || [[ "$val" =~ ^[A-Z]: ]]; then
        add_fail "$CAT_PATHS" env 0 "$var" "caminho parece Windows: $val — converta para Linux absoluto"
    else
        add_ok "$CAT_PATHS" env 0 "$var" "$val"
    fi
done

# Avisos
print_category_header "$CAT_WARN" "Configurações que não impedem o boot mas geram impacto operacional (volume de log, custo, etc.)."
log_level=$(_read_env APP_LOG_LEVEL)
case "$log_level" in
    DEBUG) add_fail "$CAT_WARN" env 0 "APP_LOG_LEVEL" "DEBUG em produção gera volume alto de log — TROUBLESHOOTING Problema C" ;;
    INFO|WARNING|ERROR|"") add_ok "$CAT_WARN" env 0 "APP_LOG_LEVEL" "${log_level:-padrão (INFO)}" ;;
    *) add_fail "$CAT_WARN" env 0 "APP_LOG_LEVEL" "valor inesperado: $log_level" ;;
esac

render_results
finalize_exit
