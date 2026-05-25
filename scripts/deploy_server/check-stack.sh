#!/usr/bin/env bash
# -------------------------------------------
# Specialist: check-stack
# Summary: Compose file, imagens, serviços, restart loops, healthchecks, portas externas
# -------------------------------------------
# Verifica saúde da stack Docker (todos os parâmetros vêm do manifesto):
#   - Compose file correto presente (products.json: compose_file)
#   - docker compose config valida (parsing OK)
#   - Imagem esperada disponível localmente (products.json: image)
#   - Serviços esperados rodando (products.json: expected_services)
#   - Nenhum container em "Restarting (n)" loop (chat ICI 20/03)
#   - Containers com healthcheck reportam "healthy"
#   - Portas externas livres (products.json: expected_external_ports)
# -------------------------------------------

set -uo pipefail

SPECIALIST_NAME="check-stack"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=./_common.sh
source "$SCRIPT_DIR/_common.sh"

ENV_FILE="${COMPOSE_DIR:-$(pwd)}/.env"
PRODUCTS_FILE="${REPO_ROOT}/scripts/data/products.json"

usage() {
    cat <<EOF
Uso: bash $(basename "$0") [--env-file FILE] [--quiet | --json] [--help]

Verifica saúde da stack Docker conforme o manifesto products.json:
compose file presente + parse OK, imagem disponível, serviços esperados
rodando sem restart loop, portas externas livres.

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

# Detectar produto + validar manifesto
SISCAN_PRODUCT=""
if [ -f "$ENV_FILE" ]; then
    SISCAN_PRODUCT=$(grep -E '^SISCAN_PRODUCT=' "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2-)
fi
[ -n "$SISCAN_PRODUCT" ] || fail "SISCAN_PRODUCT não definido em $ENV_FILE — rode check-env"
product_validate

COMPOSE_FILE="${COMPOSE_DIR:-$(pwd)}/$(product_get compose_file)"
EXPECTED_IMAGE=$(product_get image)
mapfile -t EXPECTED_SERVICES < <(product_get_array expected_services)
mapfile -t EXTERNAL_PORTS < <(product_get_array expected_external_ports)

CAT_COMPOSE="Compose file"
CAT_CONFIG="Compose config (parsing)"
CAT_IMAGE="Imagem do produto"
CAT_CONTAINERS="Containers esperados"
CAT_HEALTH="Saúde dos containers"
CAT_PORTS="Portas externas"

# ────────────────────────────────────────────────────────────────────────────
# 1. Compose file presente
# ────────────────────────────────────────────────────────────────────────────
print_category_header "$CAT_COMPOSE" "Compose file declarado no manifesto deve existir no COMPOSE_DIR."

if [ -f "$COMPOSE_FILE" ]; then
    add_ok "$CAT_COMPOSE" file 0 "$(basename "$COMPOSE_FILE")" "presente"
else
    add_fail "$CAT_COMPOSE" file 0 "$(basename "$COMPOSE_FILE")" "ausente em $(dirname "$COMPOSE_FILE")"
    render_results
    finalize_exit
fi

# ────────────────────────────────────────────────────────────────────────────
# 2. docker compose config valida (P2: novo check)
# ────────────────────────────────────────────────────────────────────────────
print_category_header "$CAT_CONFIG" "Valida que o compose file parseia e que 'networks:' resolve (catch para erros de YAML/interpolação)."

if (cd "$(dirname "$COMPOSE_FILE")" && docker compose -f "$(basename "$COMPOSE_FILE")" config >/dev/null 2>&1); then
    add_ok "$CAT_CONFIG" compose 0 "docker compose config" "parse OK"
else
    err=$(cd "$(dirname "$COMPOSE_FILE")" && docker compose -f "$(basename "$COMPOSE_FILE")" config 2>&1 | tail -1 | head -c 120)
    add_fail "$CAT_CONFIG" compose 0 "docker compose config" "parse falhou: $err"
fi

# ────────────────────────────────────────────────────────────────────────────
# 3. Imagem disponível localmente (P2: novo check)
# ────────────────────────────────────────────────────────────────────────────
print_category_header "$CAT_IMAGE" "Imagem esperada (manifesto) precisa estar em cache local OU pull tem que funcionar."

if [ -n "$EXPECTED_IMAGE" ] && [ "$EXPECTED_IMAGE" != "(múltiplas — siscan-rpa-rpa + siscan-dashboard)" ]; then
    # 3a — Cache local (rápido, sem rede)
    if docker image inspect "$EXPECTED_IMAGE" >/dev/null 2>&1; then
        size=$(docker image inspect "$EXPECTED_IMAGE" --format '{{.Size}}' 2>/dev/null | numfmt --to=iec --suffix=B 2>/dev/null || echo "?")
        add_ok "$CAT_IMAGE" image 0 "$EXPECTED_IMAGE" "presente em cache local ($size)"
    else
        add_fail "$CAT_IMAGE" image 0 "$EXPECTED_IMAGE" "ausente em cache local — 'docker compose -f $(basename "$COMPOSE_FILE") pull' ou aguarde o CD"
    fi

    # 3b — GHCR remoto (catch caso build falhou ou tag nunca foi publicada)
    # Usa 'docker manifest inspect' que aproveita docker login se já feito.
    # Não exige imagem em cache local — vai direto no registry.
    if docker manifest inspect "$EXPECTED_IMAGE" >/dev/null 2>&1; then
        digest=$(docker manifest inspect "$EXPECTED_IMAGE" 2>/dev/null | jq -r '.config.digest // .manifests[0].digest // "?"' 2>/dev/null | head -c 19)
        add_ok "$CAT_IMAGE" image 0 "$EXPECTED_IMAGE (remote)" "tag publicada no GHCR (digest ${digest}...)"
    else
        err=$(docker manifest inspect "$EXPECTED_IMAGE" 2>&1 | tail -1 | head -c 100)
        if echo "$err" | grep -qiE "unauthorized|denied"; then
            info "docker manifest inspect: precisa de 'docker login ghcr.io' (pull funciona via CD com GITHUB_TOKEN)"
        elif echo "$err" | grep -qiE "manifest unknown|not found"; then
            add_fail "$CAT_IMAGE" image 0 "$EXPECTED_IMAGE (remote)" "TAG NÃO EXISTE no GHCR — build workflow falhou ou imagem nunca foi publicada"
        else
            info "docker manifest inspect inconclusivo: $err"
        fi
    fi
fi

# ────────────────────────────────────────────────────────────────────────────
# 4. Containers esperados rodando
# ────────────────────────────────────────────────────────────────────────────
print_category_header "$CAT_CONTAINERS" "Cada serviço de '$(basename "$COMPOSE_FILE")' (expected_services no manifesto) deve estar 'running'."

ps_output=$(cd "$(dirname "$COMPOSE_FILE")" && docker compose -f "$(basename "$COMPOSE_FILE")" ps --all --format json 2>/dev/null || echo "")

if [ -z "$ps_output" ]; then
    add_fail "$CAT_CONTAINERS" compose 0 "$(basename "$COMPOSE_FILE")" "docker compose ps não retornou output — stack não foi inicializada (docker compose up)?"
    render_results
    finalize_exit
fi

# Normalizar — Compose v2.21+ retorna array, v2.20 retorna linhas separadas
if echo "$ps_output" | head -c1 | grep -q '\['; then
    services_json="$ps_output"
else
    services_json="[$(echo "$ps_output" | grep -v '^$' | paste -sd,)]"
fi

for svc in "${EXPECTED_SERVICES[@]}"; do
    state=$(echo "$services_json" | jq -r ".[] | select(.Service == \"$svc\") | .State" 2>/dev/null | head -1)
    if [ -z "$state" ]; then
        add_fail "$CAT_CONTAINERS" svc 0 "service $svc" "container ausente — docker compose -f $(basename "$COMPOSE_FILE") up -d"
    elif [ "$state" = "running" ]; then
        add_ok "$CAT_CONTAINERS" svc 0 "service $svc" "running"
    else
        add_fail "$CAT_CONTAINERS" svc 0 "service $svc" "estado: $state"
    fi
done

# ────────────────────────────────────────────────────────────────────────────
# 5. Restart loop + healthcheck
# ────────────────────────────────────────────────────────────────────────────
print_category_header "$CAT_HEALTH" "Detecta containers em 'Restarting (n)' loop (chat ICI 20/03 — jinja2 ausente) e healthchecks unhealthy."

restart_count=$(echo "$services_json" | jq '[.[] | select(.State == "restarting")] | length' 2>/dev/null || echo "0")
if [ "$restart_count" -gt 0 ]; then
    restarting=$(echo "$services_json" | jq -r '.[] | select(.State == "restarting") | .Name' 2>/dev/null | paste -sd, -)
    add_fail "$CAT_HEALTH" loop 0 "restart loop" "containers reiniciando: $restarting — docker logs <container> --tail=50"
else
    add_ok "$CAT_HEALTH" loop 0 "restart loop" "nenhum container em loop"
fi

unhealthy_count=$(echo "$services_json" | jq '[.[] | select(.Health == "unhealthy")] | length' 2>/dev/null || echo "0")
if [ "$unhealthy_count" -gt 0 ]; then
    unhealthy=$(echo "$services_json" | jq -r '.[] | select(.Health == "unhealthy") | .Name' 2>/dev/null | paste -sd, -)
    add_fail "$CAT_HEALTH" health 0 "healthcheck" "unhealthy: $unhealthy"
else
    add_ok "$CAT_HEALTH" health 0 "healthcheck" "todos healthy ou sem healthcheck"
fi

# ────────────────────────────────────────────────────────────────────────────
# 6. Port collision
# ────────────────────────────────────────────────────────────────────────────
print_category_header "$CAT_PORTS" "Portas externas do produto (expected_external_ports no manifesto) não devem estar ocupadas por outro processo (chat ICI 27/03)."

for port in "${EXTERNAL_PORTS[@]}"; do
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
