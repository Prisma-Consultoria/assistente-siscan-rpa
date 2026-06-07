#!/usr/bin/env bash
# -------------------------------------------
# Specialist: check-db
# Summary: Conectividade TCP + pg_isready com PostgreSQL externo (VLAN interna do servidor parceiro)
# -------------------------------------------
# Valida conectividade da VM da aplicação com o(s) PostgreSQL externo(s):
#   - RPA / Full: DATABASE_HOST:DATABASE_PORT (TCP + pg_isready)
#   - Dashboard / Full: idem para o host parseado de RPA_DATABASE_URL
#
# Seção 9 do PDF de whitelist é VLAN interna do servidor parceiro, não internet —
# por isso check-network não cobre. Esse é o specialist dedicado.
# -------------------------------------------

set -uo pipefail

SPECIALIST_NAME="check-db"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=./_common.sh
source "$SCRIPT_DIR/_common.sh"

ENV_FILE="${COMPOSE_DIR:-$(pwd)}/.env"
PRODUCTS_FILE="${REPO_ROOT}/scripts/data/products.json"
# Defaults de conveniência — avaliados na issue #113 e MANTIDOS no specialist
# (não migrados ao products.json) por já serem configuráveis e não variarem por
# produto: TIMEOUT_SEC é sobrescrevível por --timeout; a porta do Postgres é
# lida do .env (DATABASE_PORT, default 5432 logo abaixo) — todos os bancos do
# projeto usam a porta padrão 5432/TCP, então externalizar não agregaria.
TIMEOUT_SEC=5

usage() {
    cat <<EOF
Uso: bash $(basename "$0") [--env-file FILE] [--product NAME] [--timeout SEC] [--quiet | --json] [--help]

Verifica conectividade TCP/5432 + pg_isready (se disponível) com o(s)
PostgreSQL externo(s) configurado(s) no .env do produto.

Opções específicas:
  --product NAME   Define SISCAN_PRODUCT explicitamente (rpa | dashboard | full).
                   Prioridade: --product > \$SISCAN_PRODUCT (env) > .env.
                   Útil quando o consumer (workflow CD) quer declarar o
                   contexto independente do que está no .env da VM.

Exit code: 0 = OK · 1 = FAIL · 2 = uso inválido
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

# timeout (coreutils) é usado pra TCP check com bind do file descriptor
require_commands timeout

_read_env() {
    grep -E "^${1}=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | sed 's/^["'\'']\(.*\)["'\'']$/\1/'
}

[ -f "$ENV_FILE" ] || fail ".env não encontrado: $ENV_FILE"

# TSK00.05.05: resolve SISCAN_PRODUCT por prioridade --product > $SISCAN_PRODUCT > .env
resolve_product
HAS_PG_ISREADY=false
command -v pg_isready >/dev/null 2>&1 && HAS_PG_ISREADY=true

# _check_db_target CATEGORY HOST PORT [USER] [DB_NAME]
#   Faz TCP/5432 e, se pg_isready disponível, valida o protocolo Postgres.
_check_db_target() {
    local category="$1" host="$2" port="${3:-5432}" user="${4:-}" db="${5:-}" password="${6:-}"

    # TCP
    if timeout "$TIMEOUT_SEC" bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null; then
        add_ok "$category" tcp "$port" "$host" "TCP/$port aberto"
    else
        add_fail "$category" tcp "$port" "$host" "TCP/$port refused/timeout — postgres não acessível desta VM"
        return
    fi

    # pg_isready (se disponível e user/db informados)
    if $HAS_PG_ISREADY && [ -n "$user" ] && [ -n "$db" ]; then
        if pg_isready -h "$host" -p "$port" -U "$user" -d "$db" -t "$TIMEOUT_SEC" >/dev/null 2>&1; then
            add_ok "$category" pg "$port" "${host}/${db}" "pg_isready: accepting connections"
        else
            add_fail "$category" pg "$port" "${host}/${db}" "pg_isready: postgres não está aceitando conexões para $user@$db"
        fi
    elif ! $HAS_PG_ISREADY; then
        info "pg_isready ausente (apt install postgresql-client) — validação restrita a TCP/$port"
    fi

    # Versão do PostgreSQL (DEPLOY_SERVER.md pré-req: >= 16). Requer psql + senha.
    # Skip controlado se psql ausente ou senha vazia.
    if command -v psql >/dev/null 2>&1 && [ -n "$password" ] && [ -n "$user" ] && [ -n "$db" ]; then
        ver_raw=$(PGPASSWORD="$password" psql -h "$host" -p "$port" -U "$user" -d "$db" \
                    -tAc "SHOW server_version" 2>/dev/null | head -1)
        if [ -n "$ver_raw" ]; then
            ver_major=$(echo "$ver_raw" | cut -d. -f1)
            if [ "$ver_major" -ge 16 ] 2>/dev/null; then
                add_ok "$category" pg "$port" "${host}/${db}" "PostgreSQL $ver_raw (>= 16)"
            elif [ "$ver_major" -ge 14 ] 2>/dev/null; then
                add_ok "$category" pg "$port" "${host}/${db}" "PostgreSQL $ver_raw (anterior ao alvo 16 mas funcional)"
            else
                add_fail "$category" pg "$port" "${host}/${db}" "PostgreSQL $ver_raw muito antigo — DEPLOY_SERVER.md exige >= 16"
            fi
        else
            info "psql disponível mas SHOW server_version falhou (auth/network?) — versão não verificada"
        fi
    elif ! command -v psql >/dev/null 2>&1; then
        info "psql ausente (apt install postgresql-client) — versão do PostgreSQL não verificada"
    fi
}

CAT_LOCAL_DB="Banco principal do produto"
CAT_RPA_DB="Banco do RPA (visto pelo dashboard via RPA_DATABASE_URL)"

# ────────────────────────────────────────────────────────────────────────────
# Banco principal do produto
# ────────────────────────────────────────────────────────────────────────────
print_category_header "$CAT_LOCAL_DB" "DATABASE_HOST do .env — o banco onde os containers app/migrate/sync escrevem. Tráfego interno na VLAN do servidor parceiro."

db_host=$(_read_env DATABASE_HOST)
db_port=$(_read_env DATABASE_PORT)
db_port="${db_port:-5432}"
db_user=$(_read_env DATABASE_USER)
db_name=$(_read_env DATABASE_NAME)
db_pass=$(_read_env DATABASE_PASSWORD)

if [ -z "$db_host" ] || [ "$db_host" = "db" ]; then
    add_fail "$CAT_LOCAL_DB" env 0 "DATABASE_HOST" "vazio ou inválido ('$db_host') — rode check-env"
else
    _check_db_target "$CAT_LOCAL_DB" "$db_host" "$db_port" "$db_user" "$db_name" "$db_pass"
fi

if [ "$FAIL_COUNT" -eq 0 ] && [ -n "$db_host" ]; then
    print_category_guidance ok "PostgreSQL respondendo. Próximo passo: containers conseguem conectar. Se aplicação ainda dá erro de banco, verifique credenciais (DATABASE_PASSWORD) e migrations."
else
    print_category_guidance fail "Banco não está acessível desta VM. AÇÃO: (a) confirmar que a VM do banco está ligada e o postgres aceitando conexões em $db_host:$db_port; (b) verificar firewall interno do servidor parceiro / VLAN — porta 5432 entre VMs deve estar liberada (seção 9 do PDF de whitelist); (c) confirmar pg_hba.conf no banco aceita conexões desta VM."
fi

# ────────────────────────────────────────────────────────────────────────────
# Banco do RPA visto pelo dashboard (só se produto exigir RPA_DATABASE_URL)
# Antes: case "$SISCAN_PRODUCT" in dashboard|full)
# Agora: extras.rpa_database_url_required do manifesto
# ────────────────────────────────────────────────────────────────────────────
if [ -n "$SISCAN_PRODUCT" ] && product_validate >/dev/null 2>&1 && product_has_extra rpa_database_url_required; then
        print_category_header "$CAT_RPA_DB" "RPA_DATABASE_URL — o container 'sync' do dashboard lê o banco do RPA pra importar exames. Sem isso, sync_exames não funciona."

        rpa_url=$(_read_env RPA_DATABASE_URL)
        if [ -z "$rpa_url" ]; then
            add_fail "$CAT_RPA_DB" env 0 "RPA_DATABASE_URL" "vazio — rode check-env"
        elif [[ ! "$rpa_url" =~ ^postgresql://[^:]+:[^@]+@([^:]+):([0-9]+)/([^?]+)$ ]]; then
            add_fail "$CAT_RPA_DB" env 0 "RPA_DATABASE_URL" "formato inválido — rode check-env"
        else
            # Parse: postgresql://USER:PASS@HOST:PORT/DB
            rpa_user="${rpa_url#postgresql://}"
            rpa_user="${rpa_user%%:*}"
            rpa_pass="${rpa_url#postgresql://*:}"
            rpa_pass="${rpa_pass%%@*}"
            rpa_rest="${rpa_url#postgresql://*:*@}"
            rpa_host="${rpa_rest%%:*}"
            rpa_rest="${rpa_rest#*:}"
            rpa_port="${rpa_rest%%/*}"
            rpa_db="${rpa_rest#*/}"
            rpa_db="${rpa_db%%\?*}"

            _check_db_target "$CAT_RPA_DB" "$rpa_host" "$rpa_port" "$rpa_user" "$rpa_db" "$rpa_pass"
        fi

        # Veredito específico desta categoria
        if [ "$FAIL_COUNT" -gt 0 ]; then
            print_category_guidance fail "Container 'sync' do dashboard NÃO vai conseguir importar exames do RPA. AÇÃO: confirmar VLAN do servidor parceiro permite tráfego 5432 entre a VM do dashboard e a VM do RPA (registro interno 27/03 — RPA_DATABASE_URL foi configurado com formato errado, esse specialist captura isso via check-env + esse check)."
        else
            print_category_guidance ok "Dashboard consegue ler dados do RPA. Próximo passo: sync_exames vai funcionar (re-rode 'docker compose exec app python -m src.commands.sync_exames --full' após restauração de backup)."
        fi
fi

render_results
finalize_exit
