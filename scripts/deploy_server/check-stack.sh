#!/usr/bin/env bash
# -------------------------------------------
# Specialist: check-stack
# -------------------------------------------
# Verifica saúde da stack Docker:
#   - Compose file correto presente para o produto
#   - Serviços esperados rodando (docker compose ps)
#   - Nenhum container em "Restarting (n)" loop (problema do chat ICI 20/03)
#   - Containers com healthcheck reportam "healthy"
#   - Portas externas livres (sem conflito com nginx/processo local)
# -------------------------------------------

set -uo pipefail

SPECIALIST_NAME="check-stack"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./_common.sh
source "$SCRIPT_DIR/_common.sh"

ENV_FILE="${COMPOSE_DIR:-$(pwd)}/.env"

usage() {
    cat <<EOF
Uso: bash $(basename "$0") [--env-file FILE] [--quiet | --json] [--help]

Verifica saúde da stack Docker atualmente em execução.

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

command -v docker >/dev/null 2>&1 || fail "docker não está instalado (rode check-deps primeiro)"

# Detectar produto via .env
SISCAN_PRODUCT=""
if [ -f "$ENV_FILE" ]; then
    SISCAN_PRODUCT=$(grep -E '^SISCAN_PRODUCT=' "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2-)
fi

CAT_COMPOSE="Compose file"
CAT_CONTAINERS="Containers esperados"
CAT_HEALTH="Saúde dos containers"
CAT_PORTS="Portas externas"

# ────────────────────────────────────────────────────────────────────────────
# Compose file por produto
# ────────────────────────────────────────────────────────────────────────────
print_category_header "$CAT_COMPOSE" "Compose file correspondente ao SISCAN_PRODUCT do .env (rpa, dashboard ou full)."

case "$SISCAN_PRODUCT" in
    rpa)
        COMPOSE_FILE="docker-compose.prd.rpa.yml"
        EXPECTED_SERVICES=("app" "rpa-scheduler")
        EXTERNAL_PORTS=(5001)
        ;;
    dashboard)
        COMPOSE_FILE="docker-compose.prd.dashboard.yml"
        EXPECTED_SERVICES=("app" "sync" "redis")
        EXTERNAL_PORTS=(5000)
        ;;
    full)
        COMPOSE_FILE="docker-compose.prd.host.yml"
        EXPECTED_SERVICES=("db" "app" "rpa-scheduler")
        EXTERNAL_PORTS=(5000 5001)
        ;;
    *)
        add_fail "$CAT_COMPOSE" env 0 "SISCAN_PRODUCT" "não definido ou inválido ($SISCAN_PRODUCT) — rode check-env"
        render_results
        finalize_exit
        ;;
esac

if [ -f "$COMPOSE_FILE" ]; then
    add_ok "$CAT_COMPOSE" file 0 "$COMPOSE_FILE" "presente"
else
    add_fail "$CAT_COMPOSE" file 0 "$COMPOSE_FILE" "ausente — esperado na raiz do assistente"
    render_results
    finalize_exit
fi

# ────────────────────────────────────────────────────────────────────────────
# Containers esperados rodando
# ────────────────────────────────────────────────────────────────────────────
print_category_header "$CAT_CONTAINERS" "Cada serviço de '$COMPOSE_FILE' deve estar em execução (exceto 'migrate', que sai com 0 ao completar)."

# docker compose ps com --format json (suportado em Compose v2.20+)
ps_output=$(docker compose -f "$COMPOSE_FILE" ps --all --format json 2>/dev/null || echo "")

if [ -z "$ps_output" ]; then
    add_fail "$CAT_CONTAINERS" compose 0 "$COMPOSE_FILE" "docker compose ps não retornou output — stack não foi inicializada (docker compose up)?"
    render_results
    finalize_exit
fi

# Normalizar: pode ser um JSON array (v2.21+) ou linhas separadas (v2.20)
if echo "$ps_output" | head -c1 | grep -q '\['; then
    services_json="$ps_output"
else
    services_json="[$(echo "$ps_output" | grep -v '^$' | paste -sd,)]"
fi

for svc in "${EXPECTED_SERVICES[@]}"; do
    state=$(echo "$services_json" | jq -r ".[] | select(.Service == \"$svc\") | .State" 2>/dev/null | head -1)
    if [ -z "$state" ]; then
        add_fail "$CAT_CONTAINERS" svc 0 "service $svc" "container ausente — docker compose -f $COMPOSE_FILE up -d"
    elif [ "$state" = "running" ]; then
        add_ok "$CAT_CONTAINERS" svc 0 "service $svc" "running"
    else
        add_fail "$CAT_CONTAINERS" svc 0 "service $svc" "estado: $state"
    fi
done

# ────────────────────────────────────────────────────────────────────────────
# Restart loop e healthchecks
# ────────────────────────────────────────────────────────────────────────────
print_category_header "$CAT_HEALTH" "Detecta containers em 'Restarting (n)' loop (chat ICI 20/03 — jinja2 ausente) e healthchecks unhealthy."

# Para todos os containers (incl. nomeados pelo compose)
restart_count=$(echo "$services_json" | jq '[.[] | select(.State == "restarting")] | length' 2>/dev/null || echo "0")
if [ "$restart_count" -gt 0 ]; then
    restarting=$(echo "$services_json" | jq -r '.[] | select(.State == "restarting") | .Name' 2>/dev/null | paste -sd, -)
    add_fail "$CAT_HEALTH" loop 0 "restart loop" "containers reiniciando: $restarting — docker logs <container> --tail=50"
else
    add_ok "$CAT_HEALTH" loop 0 "restart loop" "nenhum container em loop"
fi

# Healthchecks unhealthy
unhealthy_count=$(echo "$services_json" | jq '[.[] | select(.Health == "unhealthy")] | length' 2>/dev/null || echo "0")
if [ "$unhealthy_count" -gt 0 ]; then
    unhealthy=$(echo "$services_json" | jq -r '.[] | select(.Health == "unhealthy") | .Name' 2>/dev/null | paste -sd, -)
    add_fail "$CAT_HEALTH" health 0 "healthcheck" "unhealthy: $unhealthy"
else
    add_ok "$CAT_HEALTH" health 0 "healthcheck" "todos healthy ou sem healthcheck"
fi

# ────────────────────────────────────────────────────────────────────────────
# Port collision
# ────────────────────────────────────────────────────────────────────────────
print_category_header "$CAT_PORTS" "Portas externas do produto não devem estar ocupadas por outro processo (chat ICI 27/03 — porta 80 em uso)."

for port in "${EXTERNAL_PORTS[@]}"; do
    # Verifica se a porta está LISTEN — exclui processos do Docker (que SÃO o stack)
    if command -v ss >/dev/null 2>&1; then
        listeners=$(ss -tlnp 2>/dev/null | awk -v p=":$port " '$4 ~ p {print $7}' | head -1)
    elif command -v netstat >/dev/null 2>&1; then
        listeners=$(netstat -tlnp 2>/dev/null | awk -v p=":$port " '$4 ~ p {print $7}' | head -1)
    else
        warn "nem 'ss' nem 'netstat' disponíveis — pulando check de port collision"
        break
    fi

    if [ -z "$listeners" ]; then
        add_ok "$CAT_PORTS" port "$port" "porta $port" "livre"
    elif echo "$listeners" | grep -qiE "docker|com.docker|containerd"; then
        add_ok "$CAT_PORTS" port "$port" "porta $port" "ocupada pelo Docker (esperado)"
    else
        add_fail "$CAT_PORTS" port "$port" "porta $port" "ocupada por processo não-Docker: $listeners"
    fi
done

render_results
finalize_exit
