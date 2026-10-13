#!/usr/bin/env bash
# -------------------------------------------
# Specialist: check-stack
# Summary: Compose file, imagens, serviços, restart loops, healthchecks, exec, processos, daemon, portas externas
# -------------------------------------------
# Verifica saúde da stack Docker (todos os parâmetros vêm do manifesto):
#   - Compose file correto presente (products.json: compose_file)
#   - docker compose config valida (parsing OK)
#   - Imagem esperada disponível localmente (products.json: image)
#   - Serviços esperados rodando (products.json: expected_services)
#   - Nenhum container em "Restarting (n)" loop (registro interno 20/03)
#   - Containers com healthcheck reportam "healthy" (e, se não, por quê)
#   - Cada serviço aceita `docker compose exec` dentro do prazo
#   - Processos por container (total e defunct)
#   - Nenhum cliente `docker exec` preso no host
#   - Daemon do Docker responde
#   - Portas externas livres (products.json: expected_external_ports)
#
# Todo comando novo roda sob `timeout`: o diagnóstico existe justamente para
# o caso em que o Docker ou um container param de responder, e não pode
# travar junto (siscan-rpa#1915: CD preso 6h em `exec -T app`).
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
Uso: bash $(basename "$0") [--env-file FILE] [--product NAME] [--quiet | --json] [--help]

Verifica saúde da stack Docker conforme o manifesto products.json:
compose file presente + parse OK, imagem disponível, serviços esperados
rodando sem restart loop, portas externas livres.

Opções específicas:
  --product NAME   Define SISCAN_PRODUCT explicitamente (rpa | dashboard | full).
                   Prioridade: --product > \$SISCAN_PRODUCT (env) > .env.

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

# jq é usado por product_validate (via _common.sh) pra ler products.json
require_commands docker jq timeout

# Prazos (segundos) e limite de idade dos checks que falam com o Docker.
# Declarados aqui e só aqui; o ambiente sobrescreve sem editar o script.
STACK_EXEC_TIMEOUT="${SISCAN_STACK_EXEC_TIMEOUT:-15}"
STACK_DOCKER_TIMEOUT="${SISCAN_STACK_DOCKER_TIMEOUT:-10}"
STACK_EXEC_STALE_SECONDS="${SISCAN_STACK_EXEC_STALE_SECONDS:-900}"

# Detectar produto + validar manifesto
# TSK00.05.05: resolve SISCAN_PRODUCT por prioridade --product > $SISCAN_PRODUCT > .env
resolve_product
[ -n "${SISCAN_PRODUCT:-}" ] || fail "SISCAN_PRODUCT não definido (sem --product na CLI, sem env var, sem entrada em $ENV_FILE) — rode check-env ou passe --product"
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
CAT_EXEC="Exec nos containers"
CAT_PROCS="Processos nos containers"
CAT_HOST_PROCS="Processos no host"
CAT_DAEMON="Daemon Docker"

# one_line TEXTO MAX — achata em uma linha e trunca. O `|` vira `/` porque é
# o separador dos acumuladores de _common.sh (add_ok/add_fail).
one_line() {
    printf '%s' "$1" | tr '\n\r\t|' '   /' | tr -s ' ' | head -c "$2"
}

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
print_category_header "$CAT_HEALTH" "Detecta containers em 'Restarting (n)' loop (registro interno 20/03 — jinja2 ausente) e healthchecks unhealthy."

restart_count=$(echo "$services_json" | jq '[.[] | select(.State == "restarting")] | length' 2>/dev/null || echo "0")
if [ "$restart_count" -gt 0 ]; then
    restarting=$(echo "$services_json" | jq -r '.[] | select(.State == "restarting") | .Name' 2>/dev/null | paste -sd, -)
    add_fail "$CAT_HEALTH" loop 0 "restart loop" "containers reiniciando: $restarting — docker logs <container> --tail=50"
else
    add_ok "$CAT_HEALTH" loop 0 "restart loop" "nenhum container em loop"
fi

unhealthy_count=$(echo "$services_json" | jq '[.[] | select(.Health == "unhealthy")] | length' 2>/dev/null || echo "0")
if [ "$unhealthy_count" -gt 0 ]; then
    # O nome sozinho não diz por quê. `.State.Health` traz a sequência de
    # falhas e a última tentativa — o que antes só se via por SSH.
    reasons=()
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        health=$(timeout -k 2 "$STACK_DOCKER_TIMEOUT" docker inspect --format '{{json .State.Health}}' "$name" 2>/dev/null || true)
        why=$(echo "$health" | jq -r '
            if (.Log // []) | length == 0 then "sem registro de tentativa"
            else (.Log | last) as $l
                 | "FailingStreak=\(.FailingStreak // "?"), última tentativa exit=\($l.ExitCode // "?"): \($l.Output // "" | gsub("\\s+"; " "))"
            end' 2>/dev/null || true)
        [ -n "$why" ] || why="docker inspect não respondeu em ${STACK_DOCKER_TIMEOUT}s"
        reasons+=("${name} ($(one_line "$why" 160))")
    done < <(echo "$services_json" | jq -r '.[] | select(.Health == "unhealthy") | .Name' 2>/dev/null)
    add_fail "$CAT_HEALTH" health 0 "healthcheck" "unhealthy: $(IFS=';'; echo "${reasons[*]}")"
else
    add_ok "$CAT_HEALTH" health 0 "healthcheck" "todos healthy ou sem healthcheck"
fi

# ────────────────────────────────────────────────────────────────────────────
# 5b. Exec nos containers — "running" não prova que o container aceita comando
# ────────────────────────────────────────────────────────────────────────────
print_category_header "$CAT_EXEC" "Cada serviço deve responder a 'docker compose exec -T <serviço> true' em até ${STACK_EXEC_TIMEOUT}s (SISCAN_STACK_EXEC_TIMEOUT)."

for svc in "${EXPECTED_SERVICES[@]}"; do
    state=$(echo "$services_json" | jq -r ".[] | select(.Service == \"$svc\") | .State" 2>/dev/null | head -1)
    if [ "$state" != "running" ]; then
        add_skipped "$CAT_EXEC" exec 0 "service $svc" "não está running — exec não se aplica"
        continue
    fi
    started=$(date +%s)
    rc=0
    (cd "$(dirname "$COMPOSE_FILE")" && timeout -k 5 "$STACK_EXEC_TIMEOUT" \
        docker compose -f "$(basename "$COMPOSE_FILE")" exec -T "$svc" true) >/dev/null 2>&1 || rc=$?
    elapsed=$(( $(date +%s) - started ))
    case "$rc" in
        0)       add_ok   "$CAT_EXEC" exec 0 "service $svc" "respondeu em ${elapsed}s" ;;
        124|137) add_fail "$CAT_EXEC" exec 0 "service $svc" "exec não respondeu em ${STACK_EXEC_TIMEOUT}s — o container não aceita comandos; healthcheck e todo 'docker compose exec' nele travam" ;;
        *)       add_fail "$CAT_EXEC" exec 0 "service $svc" "exec falhou com rc=${rc} em ${elapsed}s" ;;
    esac
done

# ────────────────────────────────────────────────────────────────────────────
# 5c. Processos por container (total e defunct)
# ────────────────────────────────────────────────────────────────────────────
print_category_header "$CAT_PROCS" "Total de processos e quantos estão defunct em cada container (docker top, prazo ${STACK_DOCKER_TIMEOUT}s)."

while IFS=$'\t' read -r svc name; do
    [ -n "$name" ] || continue
    top=$(timeout -k 2 "$STACK_DOCKER_TIMEOUT" docker top "$name" -o stat 2>/dev/null) || {
        add_fail "$CAT_PROCS" top 0 "service $svc" "docker top não respondeu em ${STACK_DOCKER_TIMEOUT}s"
        continue
    }
    total=$(echo "$top" | tail -n +2 | grep -c . || true)
    defunct=$(echo "$top" | tail -n +2 | grep -c '^Z' || true)
    if [ "$defunct" -gt 0 ]; then
        add_fail "$CAT_PROCS" top 0 "service $svc" "${total} processo(s), ${defunct} defunct (zumbis sem processo que os recolha)"
    else
        add_ok "$CAT_PROCS" top 0 "service $svc" "${total} processo(s), nenhum defunct"
    fi
done < <(echo "$services_json" | jq -r '.[] | select(.State == "running") | "\(.Service)\t\(.Name)"' 2>/dev/null)

# ────────────────────────────────────────────────────────────────────────────
# 5d. Clientes `docker exec` presos no host
# ────────────────────────────────────────────────────────────────────────────
print_category_header "$CAT_HOST_PROCS" "Nenhum 'docker exec' / 'docker compose exec' vivo há mais de ${STACK_EXEC_STALE_SECONDS}s (SISCAN_STACK_EXEC_STALE_SECONDS)."

if command -v ps >/dev/null 2>&1; then
    # Só PID e idade saem no detail: a linha de comando pode carregar `-e VAR=valor`.
    stale=$(ps -eo pid=,etimes=,args= 2>/dev/null | awk -v lim="$STACK_EXEC_STALE_SECONDS" '
        $2 > lim && $0 ~ /(^|[[:space:]]|\/)docker(-compose)?([[:space:]].*)?[[:space:]]exec([[:space:]]|$)/ { print $1, $2 }' | sort -k2,2nr)
    if [ -n "$stale" ]; then
        n=$(echo "$stale" | grep -c .)
        oldest_pid=$(echo "$stale" | head -1 | cut -d' ' -f1)
        oldest_age=$(echo "$stale" | head -1 | cut -d' ' -f2)
        add_fail "$CAT_HOST_PROCS" ps 0 "docker exec" "${n} cliente(s) exec vivo(s) há mais de ${STACK_EXEC_STALE_SECONDS}s; o mais antigo (PID ${oldest_pid}) há ${oldest_age}s"
    else
        add_ok "$CAT_HOST_PROCS" ps 0 "docker exec" "nenhum cliente exec com mais de ${STACK_EXEC_STALE_SECONDS}s"
    fi
else
    add_skipped "$CAT_HOST_PROCS" ps 0 "docker exec" "'ps' indisponível no host"
fi

# ────────────────────────────────────────────────────────────────────────────
# 5e. Daemon do Docker
# ────────────────────────────────────────────────────────────────────────────
print_category_header "$CAT_DAEMON" "O daemon deve responder a 'docker info' em até ${STACK_DOCKER_TIMEOUT}s; com systemd, o serviço deve estar active."

if version=$(timeout -k 2 "$STACK_DOCKER_TIMEOUT" docker info --format '{{.ServerVersion}}' 2>/dev/null) && [ -n "$version" ]; then
    add_ok "$CAT_DAEMON" daemon 0 "docker info" "responde (servidor $(one_line "$version" 40))"
else
    add_fail "$CAT_DAEMON" daemon 0 "docker info" "não respondeu em ${STACK_DOCKER_TIMEOUT}s"
fi

if command -v systemctl >/dev/null 2>&1; then
    active=$(timeout -k 2 "$STACK_DOCKER_TIMEOUT" systemctl is-active docker 2>/dev/null || true)
    if [ "$active" = "active" ]; then
        add_ok "$CAT_DAEMON" daemon 0 "systemctl docker" "active"
    else
        add_fail "$CAT_DAEMON" daemon 0 "systemctl docker" "estado: ${active:-sem resposta em ${STACK_DOCKER_TIMEOUT}s}"
    fi
fi

# ────────────────────────────────────────────────────────────────────────────
# 6. Port collision
# ────────────────────────────────────────────────────────────────────────────
print_category_header "$CAT_PORTS" "Portas externas do produto (expected_external_ports no manifesto) não devem estar ocupadas por outro processo (registro interno 27/03)."

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
