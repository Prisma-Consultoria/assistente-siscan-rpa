#!/usr/bin/env bash
# -------------------------------------------
# Specialist: check-network
# -------------------------------------------
# Arquivo: scripts/deploy_server/check-network.sh
# Propósito: Validar a liberação de saída no firewall para os endpoints
#            exigidos pelos runners self-hosted do GitHub Actions, pelo GHCR,
#            pelo Docker Hub e pela validação OCSP/CRL.
#
# Fonte de verdade dos FQDNs: scripts/data/network-endpoints.json
#   (atualize esse arquivo para refletir mudanças no PDF de whitelist
#    ou na referência oficial atual do GitHub)
#
# Uso (standalone):
#   bash scripts/deploy_server/check-network.sh [--quiet | --json] [--timeout SEC] [--endpoints-file FILE]
#
# Uso (via doctor):
#   bash siscan-server-doctor.sh             # roda todos os specialists, incluindo este
#   bash siscan-server-doctor.sh --only check-network
#
# Exit code:
#   0  todos os endpoints alcançáveis
#   1  pelo menos um FAIL
#   2  uso inválido / dependência ausente / JSON inválido
#
# Critério: PDF v2.0, seção 11.4 — qualquer resposta HTTP (!= 000) conta como sucesso.
# -------------------------------------------

set -uo pipefail

SPECIALIST_NAME="check-network"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ────────────────────────────────────────────────────────────────────────────
# Source da biblioteca comum (cores, helpers, acumulador, renderização)
# ────────────────────────────────────────────────────────────────────────────
# shellcheck source=./_common.sh
source "$SCRIPT_DIR/_common.sh"

# ────────────────────────────────────────────────────────────────────────────
# Defaults específicos deste specialist
# ────────────────────────────────────────────────────────────────────────────
TIMEOUT_SEC=10
ENDPOINTS_FILE="${REPO_ROOT}/scripts/data/network-endpoints.json"

usage() {
    cat <<EOF
Uso: bash $(basename "$0") [opções]

Opções:
  --quiet                  Imprime somente linhas FAIL (cron de monitoramento)
  --json                   Saída estruturada em JSON
  --timeout SEC            Timeout por check em segundos (padrão: 10)
  --endpoints-file FILE    Override do JSON de endpoints
                           (padrão: scripts/data/network-endpoints.json)
  -h, --help               Exibe esta ajuda

Exit code:
  0 = todos os endpoints OK
  1 = pelo menos um FAIL
  2 = uso inválido / dependência ausente / JSON inválido
EOF
}

# ────────────────────────────────────────────────────────────────────────────
# Parsing de args
# ────────────────────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --endpoints-file)   ENDPOINTS_FILE="${2:-}"; shift 2 ;;
        --endpoints-file=*) ENDPOINTS_FILE="${1#*=}"; shift ;;
        -h|--help)          usage; exit 0 ;;
        *)
            if common_parse_arg "$@"; then
                shift "$shift_count"
            else
                echo "argumento desconhecido: $1" >&2
                usage >&2
                exit 2
            fi
            ;;
    esac
done

# ────────────────────────────────────────────────────────────────────────────
# Pré-requisitos
# ────────────────────────────────────────────────────────────────────────────
command -v curl >/dev/null 2>&1 || fail "curl não está instalado. Instale com: sudo apt install -y curl"
command -v jq   >/dev/null 2>&1 || fail "jq não está instalado. Instale com: sudo apt install -y jq"
[ -f "$ENDPOINTS_FILE" ] || fail "arquivo de endpoints não encontrado: $ENDPOINTS_FILE"
jq -e . "$ENDPOINTS_FILE" >/dev/null 2>&1 || fail "arquivo de endpoints não é um JSON válido: $ENDPOINTS_FILE"

# ────────────────────────────────────────────────────────────────────────────
# Checks específicos deste specialist
# ────────────────────────────────────────────────────────────────────────────
# _check_https CATEGORY FQDN PORT EXPECTED_TEXT
#   EXPECTED_TEXT: do JSON, formato "200 — descrição" (opcional).
_check_https() {
    local category="$1" fqdn="$2" port="${3:-443}" expected="${4:-}"
    local code
    code=$(curl -k -s -o /dev/null -w "%{http_code}" \
                --max-time "$TIMEOUT_SEC" \
                "https://${fqdn}:${port}/" 2>/dev/null) || code="000"

    # Critério (PDF v2.0, seção 11.4): qualquer resposta HTTP != 000 indica TLS subiu.
    if [ -z "$code" ] || [ "$code" = "000" ]; then
        add_fail "$category" https "$port" "$fqdn" "timeout/conexão recusada"
        return
    fi

    # Formatar detalhe: se houver expected do JSON ("CODE — texto"), comparar
    # com observado. Match → exibe só o texto. Diferente → exibe ambos.
    local detail="$code"
    if [ -n "$expected" ]; then
        local exp_code="${expected%% — *}"
        local exp_text="${expected#*— }"
        if [ "$code" = "$exp_code" ]; then
            detail="$code  $exp_text"
        else
            detail="$code  (esperado $exp_code: $exp_text)"
        fi
    fi
    add_ok "$category" https "$port" "$fqdn" "$detail"
}

# _check_tcp CATEGORY FQDN PORT EXPECTED_TEXT
_check_tcp() {
    local category="$1" fqdn="$2" port="$3" expected="${4:-}"
    if ! timeout "$TIMEOUT_SEC" bash -c "exec 3<>/dev/tcp/${fqdn}/${port}" 2>/dev/null; then
        add_fail "$category" tcp "$port" "$fqdn" "timeout/conexão recusada"
        return
    fi
    # Strip leading "TCP/<port> aberto — " do expected pra evitar duplicar.
    local detail="conectou"
    if [ -n "$expected" ]; then
        local clean="${expected#TCP/${port} aberto — }"
        [ "$clean" = "$expected" ] && detail="conectou  $expected" || detail="conectou  $clean"
    fi
    add_ok "$category" tcp "$port" "$fqdn" "$detail"
}

# ────────────────────────────────────────────────────────────────────────────
# Iteração: categoria por categoria
#   - Antes de cada categoria: print_category_header com label + description
#     (orientação fica no JSON, não no código).
#   - Para cada endpoint da categoria: dispara o check correspondente.
# ────────────────────────────────────────────────────────────────────────────
cat_count=$(jq '.categories | length' "$ENDPOINTS_FILE")
for i in $(seq 0 $((cat_count - 1))); do
    cat_label=$(jq -r ".categories[$i].label" "$ENDPOINTS_FILE")
    cat_desc=$(jq -r ".categories[$i].description // \"\"" "$ENDPOINTS_FILE")
    on_ok=$(jq -r   ".categories[$i].guidance.on_all_ok // \"\"" "$ENDPOINTS_FILE")
    on_fail=$(jq -r ".categories[$i].guidance.on_any_fail // \"\"" "$ENDPOINTS_FILE")

    print_category_header "$cat_label" "$cat_desc"

    fail_before=$FAIL_COUNT

    while IFS=$'\t' read -r fqdn protocol port expected; do
        case "$protocol" in
            https) _check_https "$cat_label" "$fqdn" "$port" "$expected" ;;
            tcp)   _check_tcp   "$cat_label" "$fqdn" "$port" "$expected" ;;
            *)     warn "protocolo desconhecido '$protocol' para $fqdn — ignorado" ;;
        esac
    done < <(jq -r ".categories[$i].endpoints[] | [.fqdn, .protocol, (.port|tostring), (.expected // \"\")] | @tsv" "$ENDPOINTS_FILE")

    # Veredito da categoria + ação correspondente, AO VIVO (logo após os checks).
    if [ "$FAIL_COUNT" -eq "$fail_before" ]; then
        print_category_guidance ok "$on_ok"
    else
        print_category_guidance fail "$on_fail"
    fi
done

# ────────────────────────────────────────────────────────────────────────────
# Renderização final (resumo + interpretação) e exit
# ────────────────────────────────────────────────────────────────────────────
render_results
finalize_exit
