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
# _check_https CATEGORY FQDN PORT
_check_https() {
    local category="$1" fqdn="$2" port="${3:-443}"
    local code
    code=$(curl -k -s -o /dev/null -w "%{http_code}" \
                --max-time "$TIMEOUT_SEC" \
                "https://${fqdn}:${port}/" 2>/dev/null) || code="000"

    # Critério (PDF v2.0, seção 11.4): qualquer resposta HTTP != 000 indica TLS subiu.
    if [ -n "$code" ] && [ "$code" != "000" ]; then
        add_ok "$category" https "$port" "$fqdn" "$code"
    else
        add_fail "$category" https "$port" "$fqdn" "timeout/conexão recusada"
    fi
}

# _check_tcp CATEGORY FQDN PORT
_check_tcp() {
    local category="$1" fqdn="$2" port="$3"
    if timeout "$TIMEOUT_SEC" bash -c "exec 3<>/dev/tcp/${fqdn}/${port}" 2>/dev/null; then
        add_ok "$category" tcp "$port" "$fqdn" "conectou"
    else
        add_fail "$category" tcp "$port" "$fqdn" "timeout/conexão recusada"
    fi
}

# ────────────────────────────────────────────────────────────────────────────
# Iteração: categorias e endpoints do JSON
# Stream tab-separado: <category_label>\t<fqdn>\t<protocol>\t<port>
# ────────────────────────────────────────────────────────────────────────────
while IFS=$'\t' read -r category fqdn protocol port; do
    case "$protocol" in
        https) _check_https "$category" "$fqdn" "$port" ;;
        tcp)   _check_tcp   "$category" "$fqdn" "$port" ;;
        *)     warn "protocolo desconhecido '$protocol' para $fqdn — ignorado" ;;
    esac
done < <(jq -r '.categories[] as $c | $c.endpoints[] | [$c.label, .fqdn, .protocol, (.port|tostring)] | @tsv' "$ENDPOINTS_FILE")

# ────────────────────────────────────────────────────────────────────────────
# Renderização e exit
# ────────────────────────────────────────────────────────────────────────────
render_results
finalize_exit
