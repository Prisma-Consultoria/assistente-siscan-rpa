#!/usr/bin/env bash
# -------------------------------------------
# Specialist: check-permissions
# Summary: Ownership de diretórios, git safe.directory, UID 1000, chaves RSA persistidas
# -------------------------------------------
# Cobre 5 problemas reais do registro interno relacionados a permissão + RSA keys:
#   - /app/siscan-rpa criado como root (19/03, 20/03) → bind mount falha
#   - git pull com "dubious ownership" (19/03) → COMPOSE_DIR sem safe.directory
#   - PermissionError em data/.artifacts/auth (01/04) → UID 1000 do appuser
#   - excel_columns_mapping.json ausente em config/ (27/03) → RPA quebra
#   - chaves RSA não persistidas (01/04) → credenciais SISCAN expirando a cada deploy
#
# Todos os checks específicos-de-produto vêm do manifesto products.json:
# host_dir_vars, extras.rsa_keys_required, extras.host_secrets_dir_optional,
# extras.host_backups_dir_optional, extras.excel_columns_mapping_required.
# -------------------------------------------

set -uo pipefail

SPECIALIST_NAME="check-permissions"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=./_common.sh
source "$SCRIPT_DIR/_common.sh"

COMPOSE_DIR="${COMPOSE_DIR:-$(pwd)}"
ENV_FILE="$COMPOSE_DIR/.env"
PRODUCTS_FILE="${REPO_ROOT}/scripts/data/products.json"

usage() {
    cat <<EOF
Uso: bash $(basename "$0") [--env-file FILE] [--compose-dir DIR] [--quiet | --json] [--help]

Valida ownership/permissões do COMPOSE_DIR, HOST_*_DIR (do manifesto),
git safe.directory, data/.artifacts (UID 1000), chaves RSA em
HOST_SECRETS_DIR e excel_columns_mapping.json (conforme o produto).

Exit code: 0 = OK · 1 = FAIL · 2 = uso inválido
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --env-file)      ENV_FILE="${2:-}"; shift 2 ;;
        --env-file=*)    ENV_FILE="${1#*=}"; shift ;;
        --compose-dir)   COMPOSE_DIR="${2:-}"; ENV_FILE="$COMPOSE_DIR/.env"; shift 2 ;;
        --compose-dir=*) COMPOSE_DIR="${1#*=}"; ENV_FILE="$COMPOSE_DIR/.env"; shift ;;
        -h|--help)       usage; exit 0 ;;
        *)
            if common_parse_arg "$@"; then shift "$shift_count"
            else echo "argumento desconhecido: $1" >&2; usage >&2; exit 2; fi
            ;;
    esac
done

# jq via product_validate (_common.sh); getent pra resolver UID/GID dos owners
require_commands jq getent

_read_env() {
    grep -E "^${1}=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | sed 's/^["'\'']\(.*\)["'\'']$/\1/'
}

CURRENT_USER="$(whoami)"
SISCAN_PRODUCT=""
[ -f "$ENV_FILE" ] && SISCAN_PRODUCT=$(_read_env SISCAN_PRODUCT)

# Manifesto opcional aqui — se SISCAN_PRODUCT não definido, faz só os checks gerais
HAS_PRODUCT=false
if [ -n "$SISCAN_PRODUCT" ]; then
    product_validate
    HAS_PRODUCT=true
fi

CAT_COMPOSE="Stack dir ($COMPOSE_DIR)"
CAT_GIT="Git safe.directory"
CAT_HOST="Diretórios HOST_*"
CAT_SECRETS="Secrets dir + chaves RSA"
CAT_BACKUPS="Backups dir"
CAT_ARTIFACTS="data/.artifacts (UID 1000)"
CAT_CONFIG="config/excel_columns_mapping.json"

# ────────────────────────────────────────────────────────────────────────────
# 1. COMPOSE_DIR ownership
# ────────────────────────────────────────────────────────────────────────────
print_category_header "$CAT_COMPOSE" "O diretório do assistente precisa pertencer ao usuário corrente — caso contrário git pull e bind mounts falham (registro interno 19/03)."

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
print_category_header "$CAT_GIT" "Se o diretório foi clonado como outro usuário, git pull falha com 'dubious ownership' (registro interno 19/03). Precisa de 'git config --global --add safe.directory'."

if command -v git >/dev/null 2>&1 && [ -d "$COMPOSE_DIR/.git" ]; then
    if git -C "$COMPOSE_DIR" rev-parse >/dev/null 2>&1; then
        add_ok "$CAT_GIT" git 0 "safe.directory" "git pull funciona neste diretório"
    else
        add_fail "$CAT_GIT" git 0 "safe.directory" "git recusa o diretório — git config --global --add safe.directory $COMPOSE_DIR"
    fi
else
    add_ok "$CAT_GIT" git 0 "safe.directory" "não aplicável (git ausente ou não é repo)"
fi

# Se não tem produto definido, paramos aqui (resto depende do manifesto)
if ! $HAS_PRODUCT; then
    warn "SISCAN_PRODUCT não definido — pulando checks HOST_*, secrets, artifacts, config"
    render_results
    finalize_exit
fi

# ────────────────────────────────────────────────────────────────────────────
# 3. HOST_*_DIR — do manifesto
# ────────────────────────────────────────────────────────────────────────────
print_category_header "$CAT_HOST" "Cada caminho declarado no .env como HOST_*_DIR (host_dir_vars no manifesto) precisa existir e ser escrevível."

while IFS= read -r var; do
    [ -z "$var" ] && continue
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
done < <(product_get_array host_dir_vars)

# ────────────────────────────────────────────────────────────────────────────
# 4. HOST_SECRETS_DIR + chaves RSA (P1 — só se extras pedir)
# ────────────────────────────────────────────────────────────────────────────
if product_has_extra host_secrets_dir_optional || product_has_extra rsa_keys_required; then
    # Derivar fallback do parent do HOST_LOG_DIR (lógica idêntica ao workflow CD)
    secrets_dir=$(_read_env HOST_SECRETS_DIR)
    if [ -z "$secrets_dir" ]; then
        log_dir=$(_read_env HOST_LOG_DIR)
        if [ -n "$log_dir" ]; then
            secrets_dir="$(dirname "$log_dir")/secrets"
            secrets_source="derivado (HOST_LOG_DIR parent)"
        fi
    else
        secrets_source="HOST_SECRETS_DIR do .env"
    fi

    print_category_header "$CAT_SECRETS" "Diretório de chaves RSA do RPA — sem persistência, credenciais SISCAN expiram a cada deploy (registro interno 01/04). $secrets_source."

    if [ -z "$secrets_dir" ]; then
        add_fail "$CAT_SECRETS" fs 0 "HOST_SECRETS_DIR" "não dá pra derivar (HOST_LOG_DIR também ausente)"
    elif [ ! -d "$secrets_dir" ]; then
        add_fail "$CAT_SECRETS" fs 0 "$secrets_dir" "diretório NÃO existe — mkdir -p '$secrets_dir' && chmod 700 '$secrets_dir'"
    else
        perms=$(stat -c '%a' "$secrets_dir" 2>/dev/null || echo "?")
        if [ "$perms" = "700" ]; then
            add_ok "$CAT_SECRETS" fs 0 "$secrets_dir" "perms 700 (apropriado pra secrets)"
        else
            add_fail "$CAT_SECRETS" fs 0 "$secrets_dir" "perms $perms (esperado 700) — chmod 700 '$secrets_dir'"
        fi

        if product_has_extra rsa_keys_required; then
            for key in rsa_private_key.pem rsa_public_key.pem; do
                if [ -f "$secrets_dir/$key" ]; then
                    add_ok "$CAT_SECRETS" fs 0 "$key" "presente em $secrets_dir"
                else
                    add_fail "$CAT_SECRETS" fs 0 "$key" "ausente — credenciais SISCAN serão invalidadas a cada deploy"
                fi
            done
        fi
    fi
fi

# ────────────────────────────────────────────────────────────────────────────
# 5. HOST_BACKUPS_DIR (P1)
# ────────────────────────────────────────────────────────────────────────────
if product_has_extra host_backups_dir_optional; then
    backups_dir=$(_read_env HOST_BACKUPS_DIR)
    if [ -z "$backups_dir" ]; then
        log_dir=$(_read_env HOST_LOG_DIR)
        [ -n "$log_dir" ] && backups_dir="$(dirname "$log_dir")/backups"
    fi

    print_category_header "$CAT_BACKUPS" "Diretório de backups (dumps do banco). Workflow CD deriva de HOST_LOG_DIR parent se não setado."

    if [ -z "$backups_dir" ]; then
        add_fail "$CAT_BACKUPS" fs 0 "HOST_BACKUPS_DIR" "não dá pra derivar"
    elif [ ! -d "$backups_dir" ]; then
        add_fail "$CAT_BACKUPS" fs 0 "$backups_dir" "diretório NÃO existe — mkdir -p '$backups_dir'"
    else
        add_ok "$CAT_BACKUPS" fs 0 "$backups_dir" "existe"
    fi
fi

# ────────────────────────────────────────────────────────────────────────────
# 6. data/.artifacts (UID 1000 do appuser — RPA)
# ────────────────────────────────────────────────────────────────────────────
ARTIFACTS_DIR="$COMPOSE_DIR/data/.artifacts"
if product_has_extra rsa_keys_required; then  # extras-flag implícita: produto RPA-like
    print_category_header "$CAT_ARTIFACTS" "O appuser dentro do container RPA é UID 1000. data/.artifacts precisa pertencer a UID 1000 (registro interno 01/04)."

    if [ -d "$ARTIFACTS_DIR" ]; then
        uid=$(stat -c '%u' "$ARTIFACTS_DIR" 2>/dev/null || echo "?")
        if [ "$uid" = "1000" ]; then
            add_ok "$CAT_ARTIFACTS" fs 0 "$ARTIFACTS_DIR" "UID 1000"
        else
            add_fail "$CAT_ARTIFACTS" fs 0 "$ARTIFACTS_DIR" "UID=$uid, esperado=1000 — sudo chown -R 1000:1000 $ARTIFACTS_DIR && sudo chmod -R 755 $ARTIFACTS_DIR"
        fi
    else
        add_ok "$CAT_ARTIFACTS" fs 0 "$ARTIFACTS_DIR" "ainda não criado (será no primeiro run)"
    fi
fi

# ────────────────────────────────────────────────────────────────────────────
# 7. config/excel_columns_mapping.json (RPA)
# ────────────────────────────────────────────────────────────────────────────
if product_has_extra excel_columns_mapping_required; then
    print_category_header "$CAT_CONFIG" "Arquivo de mapeamento de colunas usado pelo RPA — sem ele, a coleta quebra (registro interno 27/03)."

    cfg_dir=$(_read_env HOST_CONFIG_DIR)
    cfg_dir="${cfg_dir:-$COMPOSE_DIR/config}"

    # Fase 4 do setup: verifica que o diretório config/ existe (não só o arquivo dentro)
    if [ ! -d "$cfg_dir" ]; then
        add_fail "$CAT_CONFIG" fs 0 "$cfg_dir/" "diretório NÃO existe — mkdir -p '$cfg_dir' (Fase 4 do setup)"
    elif [ -f "$cfg_dir/excel_columns_mapping.json" ]; then
        add_ok "$CAT_CONFIG" fs 0 "excel_columns_mapping.json" "presente em $cfg_dir/"
    else
        add_fail "$CAT_CONFIG" fs 0 "excel_columns_mapping.json" "ausente em $cfg_dir/ — RPA vai falhar ao iniciar coleta"
    fi
fi

render_results
finalize_exit
