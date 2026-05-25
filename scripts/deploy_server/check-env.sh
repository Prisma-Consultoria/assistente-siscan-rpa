#!/usr/bin/env bash
# -------------------------------------------
# Specialist: check-env
# -------------------------------------------
# Valida o .env do COMPOSE_DIR/CWD:
#   - SISCAN_PRODUCT definido e conhecido no products.json
#   - Variáveis obrigatórias (do manifesto) preenchidas e não-vazias
#   - DATABASE_HOST ≠ "db" (padrão dev) — sempre
#   - DATABASE_PASSWORD não é um dos defaults do produto (siscan_rpa, siscan_dashboard)
#   - SESSION_SECRET / SECRET_KEY (depende do produto) ≥ 32 caracteres
#   - RPA_DATABASE_URL formato postgresql:// quando exigido (dashboard)
#   - REDIS_PORT, HOST_APP_EXTERNAL_PORT numéricos em range válido
#   - APP_LOG_LEVEL ≠ DEBUG (warning, não FAIL)
#
# Não usa eval/source — lê o .env como dados.
# -------------------------------------------

set -uo pipefail

SPECIALIST_NAME="check-env"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=./_common.sh
source "$SCRIPT_DIR/_common.sh"

ENV_FILE="${COMPOSE_DIR:-$(pwd)}/.env"
PRODUCTS_FILE="${REPO_ROOT}/scripts/data/products.json"

usage() {
    cat <<EOF
Uso: bash $(basename "$0") [--env-file FILE] [--quiet | --json] [--help]

Valida o .env (default: \$COMPOSE_DIR/.env ou \$CWD/.env) com base em
SISCAN_PRODUCT, consultando o manifesto scripts/data/products.json.

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

# _read_env VAR — lê valor do .env como dados, sem source/eval.
_read_env() {
    grep -E "^${1}=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | sed 's/^["'\'']\(.*\)["'\'']$/\1/'
}

CAT_PRODUCT="Produto e arquivo"
CAT_REQ="Variáveis obrigatórias"
CAT_PATHS="Diretórios HOST_*"
CAT_FORMAT="Formato e domínio"
CAT_WARN="Avisos (não impedem o boot)"

# ────────────────────────────────────────────────────────────────────────────
# 1. SISCAN_PRODUCT + validação do manifesto
# ────────────────────────────────────────────────────────────────────────────
print_category_header "$CAT_PRODUCT" "SISCAN_PRODUCT define quais variáveis são obrigatórias. Lido do manifesto products.json."

SISCAN_PRODUCT="$(_read_env SISCAN_PRODUCT)"
if [ -z "$SISCAN_PRODUCT" ]; then
    add_fail "$CAT_PRODUCT" env 0 "SISCAN_PRODUCT" "não definido — siscan-server-setup.sh persiste esse valor"
    render_results
    finalize_exit
fi

product_validate  # falha (exit 2) se SISCAN_PRODUCT não está em products.json
PRODUCT_LABEL=$(product_get label "$SISCAN_PRODUCT")
add_ok "$CAT_PRODUCT" env 0 "SISCAN_PRODUCT" "$SISCAN_PRODUCT ($PRODUCT_LABEL)"

# ────────────────────────────────────────────────────────────────────────────
# 2. Variáveis obrigatórias — do manifesto
# ────────────────────────────────────────────────────────────────────────────
print_category_header "$CAT_REQ" "Cada variável listada em products.json.required_env_vars precisa estar preenchida no .env."

# Coleta defaults perigosos pra DATABASE_PASSWORD do manifesto
mapfile -t DEFAULT_PWDS < <(product_get_array default_passwords_to_detect)

while IFS= read -r var; do
    [ -z "$var" ] && continue
    val=$(_read_env "$var")

    if [ -z "$val" ]; then
        add_fail "$CAT_REQ" env 0 "$var" "vazio"
        continue
    fi

    # Regras especiais por variável
    case "$var" in
        DATABASE_HOST)
            if [ "$val" = "db" ]; then
                add_fail "$CAT_REQ" env 0 "$var" "valor 'db' (padrão dev) — use IP/hostname real do PostgreSQL externo"
            else
                add_ok "$CAT_REQ" env 0 "$var" "$val"
            fi
            ;;
        DATABASE_PASSWORD)
            is_default=false
            for def in "${DEFAULT_PWDS[@]}"; do
                [ "$val" = "$def" ] && is_default=true && break
            done
            if $is_default; then
                add_fail "$CAT_REQ" env 0 "$var" "valor default ('$val') — altere antes de produção"
            else
                add_ok "$CAT_REQ" env 0 "$var" "definido (${#val} chars)"
            fi
            ;;
        *)
            add_ok "$CAT_REQ" env 0 "$var" "definido"
            ;;
    esac
done < <(product_get_array required_env_vars)

# ────────────────────────────────────────────────────────────────────────────
# 3. Validações de formato / domínio (lógica não-trivial em código)
# ────────────────────────────────────────────────────────────────────────────
print_category_header "$CAT_FORMAT" "Variáveis com regras específicas (tamanho mínimo, regex, range numérico) que vão além de 'não-vazio'."

# Session secret — nome da variável vem do manifesto (SECRET_KEY rpa, SESSION_SECRET dashboard)
sess_var=$(product_get session_secret_var)
if [ -n "$sess_var" ]; then
    sess_val=$(_read_env "$sess_var")
    if [ -n "$sess_val" ]; then
        if [ "${#sess_val}" -lt 32 ]; then
            add_fail "$CAT_FORMAT" env 0 "$sess_var" "curto demais (${#sess_val} chars) — esperado ≥ 32; gere com 'openssl rand -hex 32'"
        else
            add_ok "$CAT_FORMAT" env 0 "$sess_var" "${#sess_val} chars (>= 32 OK)"
        fi
    fi
fi

# RPA_DATABASE_URL — só valida formato se o produto exige (extras.rpa_database_url_required)
if product_has_extra rpa_database_url_required; then
    rdb=$(_read_env RPA_DATABASE_URL)
    if [ -n "$rdb" ]; then
        if [[ "$rdb" =~ ^postgresql://[^:]+:[^@]+@[^:]+:[0-9]+/[^?]+$ ]]; then
            add_ok "$CAT_FORMAT" env 0 "RPA_DATABASE_URL" "formato postgresql:// válido"
        else
            add_fail "$CAT_FORMAT" env 0 "RPA_DATABASE_URL" "formato inválido — esperado: postgresql://user:pass@host:port/db (observado: ${rdb:0:30}...)"
        fi
    fi
fi

# Portas numéricas em range 1-65535
_validate_port() {
    local var="$1" val="$2"
    if [[ "$val" =~ ^[0-9]+$ ]] && [ "$val" -ge 1 ] && [ "$val" -le 65535 ]; then
        add_ok "$CAT_FORMAT" env 0 "$var" "$val (porta válida)"
    else
        add_fail "$CAT_FORMAT" env 0 "$var" "valor '$val' não é uma porta válida (1-65535)"
    fi
}

for port_var in HOST_APP_EXTERNAL_PORT REDIS_PORT DATABASE_PORT; do
    pv=$(_read_env "$port_var")
    [ -n "$pv" ] && _validate_port "$port_var" "$pv"
done

# ────────────────────────────────────────────────────────────────────────────
# 4. Diretórios HOST_* — variáveis vêm do manifesto
# Aqui só validamos que estão DEFINIDAS no .env e não têm cara de caminho
# Windows. Existência/permissão dos diretórios fica para check-permissions.
# ────────────────────────────────────────────────────────────────────────────
print_category_header "$CAT_PATHS" "HOST_*_DIR do manifesto precisam estar declarados no .env (existência verificada por check-permissions)."

while IFS= read -r var; do
    [ -z "$var" ] && continue
    val=$(_read_env "$var")
    if [ -z "$val" ]; then
        add_fail "$CAT_PATHS" env 0 "$var" "vazio — bind mount vai falhar"
    elif [[ "$val" =~ \\ ]] || [[ "$val" =~ ^[A-Z]: ]]; then
        add_fail "$CAT_PATHS" env 0 "$var" "caminho parece Windows: $val — converta para Linux absoluto"
    else
        add_ok "$CAT_PATHS" env 0 "$var" "$val"
    fi
done < <(product_get_array host_dir_vars)

# ────────────────────────────────────────────────────────────────────────────
# 5. Avisos — não impedem boot, mas vale flagar
# ────────────────────────────────────────────────────────────────────────────
print_category_header "$CAT_WARN" "Configurações que não impedem o boot mas geram impacto operacional."

log_level=$(_read_env APP_LOG_LEVEL)
case "$log_level" in
    DEBUG) add_fail "$CAT_WARN" env 0 "APP_LOG_LEVEL" "DEBUG em produção gera volume alto de log — TROUBLESHOOTING Problema C" ;;
    INFO|WARNING|ERROR|"") add_ok "$CAT_WARN" env 0 "APP_LOG_LEVEL" "${log_level:-padrão (INFO)}" ;;
    *) add_fail "$CAT_WARN" env 0 "APP_LOG_LEVEL" "valor inesperado: $log_level" ;;
esac

# SYNC_INTERVAL_SECONDS — dashboard tem default no compose; warn se ausente
sync_default=$(product_extra sync_interval_default_seconds)
if [ -n "$sync_default" ]; then
    sync_val=$(_read_env SYNC_INTERVAL_SECONDS)
    if [ -z "$sync_val" ]; then
        add_ok "$CAT_WARN" env 0 "SYNC_INTERVAL_SECONDS" "não setado — usando default do compose ($sync_default s)"
    else
        add_ok "$CAT_WARN" env 0 "SYNC_INTERVAL_SECONDS" "$sync_val s"
    fi
fi

# SISCAN_URL — RPA tem default; só avisa se ausente
siscan_default=$(product_extra siscan_portal_url_default)
if [ -n "$siscan_default" ]; then
    siscan_val=$(_read_env SISCAN_URL)
    if [ -z "$siscan_val" ]; then
        add_ok "$CAT_WARN" env 0 "SISCAN_URL" "não setado — usando default: $siscan_default"
    else
        add_ok "$CAT_WARN" env 0 "SISCAN_URL" "$siscan_val"
    fi
fi

render_results
finalize_exit
