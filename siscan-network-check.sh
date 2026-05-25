#!/usr/bin/env bash
# -------------------------------------------
# Validação de Conectividade — VMs SISCAN
# -------------------------------------------
# Arquivo: siscan-network-check.sh
# Propósito: Validar a liberação de saída no firewall para os endpoints
#            exigidos pelos runners self-hosted do GitHub Actions, pelo GHCR
#            (pull da imagem do siscan-dashboard/siscan-rpa) e pelo Docker Hub
#            (pull do Redis). Cobre também os endpoints OCSP/CRL (HTTP/80)
#            usados pelo runtime do runner para validar certificados.
#
# Lista canônica baseada no documento
# "Reativação de whitelist - VMs siscan-dashboard e siscan-rpa" v2.0
# (requisição ICI 753315), seções 3 a 7.
#
# Uso:
#   bash ./siscan-network-check.sh                       # saída legível p/ humano
#   bash ./siscan-network-check.sh --quiet               # imprime só linhas FAIL
#   bash ./siscan-network-check.sh --json                # saída estruturada
#   bash ./siscan-network-check.sh --timeout 15          # timeout por check (s)
#   bash ./siscan-network-check.sh --endpoints-file FILE # override do JSON de endpoints
#   bash ./siscan-network-check.sh --help
#
# Exit code:
#   0  todos os endpoints alcançáveis
#   1  pelo menos um FAIL — consulte docs/TROUBLESHOOTING.md
#   2  uso inválido / dependência ausente / JSON inválido
#
# Critério de aceitação (PDF v2.0, seção 11.4):
#   HTTPS — qualquer código HTTP do servidor (!= 000) conta como sucesso (TLS subiu).
#   HTTP/80 (OCSP/CRL) — conexão TCP suficiente.
#
# Fonte de verdade dos FQDNs: scripts/data/network-endpoints.json
#   Atualize esse arquivo para refletir mudanças no PDF ou na referência do GitHub.
#
# Dependências: curl, jq, timeout, bash (/dev/tcp). Não exige root.
# -------------------------------------------

set -uo pipefail

# ────────────────────────────────────────────────────────────────────────────
# Cores ANSI (desligadas se stdout não é TTY ou em modo --quiet/--json)
# ────────────────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    GRAY='\033[0;90m'
    WHITE='\033[1;37m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' CYAN='' GRAY='' WHITE='' NC=''
fi

# ────────────────────────────────────────────────────────────────────────────
# Parse de argumentos
# ────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_MODE="human"   # human | quiet | json
TIMEOUT_SEC=10
ENDPOINTS_FILE="${SCRIPT_DIR}/scripts/data/network-endpoints.json"

usage() {
    cat <<EOF
Uso: bash $(basename "$0") [opções]

Opções:
  --quiet                  Imprime somente linhas FAIL (útil em cron de monitoramento)
  --json                   Saída estruturada em JSON
  --timeout SEC            Timeout por check em segundos (padrão: 10)
  --endpoints-file FILE    Override do JSON de endpoints (padrão: ${ENDPOINTS_FILE#$SCRIPT_DIR/})
  -h, --help               Exibe esta ajuda

Exit code:
  0 = todos os endpoints OK
  1 = pelo menos um FAIL
  2 = uso inválido / dependência ausente / JSON inválido
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --quiet)   OUTPUT_MODE="quiet"; shift ;;
        --json)    OUTPUT_MODE="json"; shift ;;
        --timeout) TIMEOUT_SEC="${2:-10}"; shift 2 ;;
        --timeout=*) TIMEOUT_SEC="${1#*=}"; shift ;;
        --endpoints-file) ENDPOINTS_FILE="${2:-}"; shift 2 ;;
        --endpoints-file=*) ENDPOINTS_FILE="${1#*=}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "argumento desconhecido: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# Em --json ou --quiet, suprime cores (mesmo se TTY).
if [ "$OUTPUT_MODE" != "human" ]; then
    RED='' GREEN='' YELLOW='' CYAN='' GRAY='' WHITE='' NC=''
fi

# ────────────────────────────────────────────────────────────────────────────
# Pré-requisitos: curl + jq + arquivo de endpoints
# ────────────────────────────────────────────────────────────────────────────
command -v curl >/dev/null 2>&1 || {
    echo "ERRO: curl não está instalado. Instale com: sudo apt install -y curl" >&2
    exit 2
}
command -v jq >/dev/null 2>&1 || {
    echo "ERRO: jq não está instalado. Instale com: sudo apt install -y jq" >&2
    exit 2
}
[ -f "$ENDPOINTS_FILE" ] || {
    echo "ERRO: arquivo de endpoints não encontrado: $ENDPOINTS_FILE" >&2
    echo "Use --endpoints-file para apontar para outro caminho." >&2
    exit 2
}
jq -e . "$ENDPOINTS_FILE" >/dev/null 2>&1 || {
    echo "ERRO: arquivo de endpoints não é um JSON válido: $ENDPOINTS_FILE" >&2
    exit 2
}

# Códigos HTTP que indicam sucesso (TLS subiu e o servidor respondeu).
# Critério: PDF v2.0, seção 11.4 — "qualquer resposta HTTP significa que o
# TLS subiu". Falha real do firewall manifesta como 000 (sem resposta).
_http_code_is_ok() {
    [ "$1" != "000" ] && [ -n "$1" ]
}

# ────────────────────────────────────────────────────────────────────────────
# Coletores de resultado
# Cada entrada em RESULTS é uma linha pipe-separada:
#   category|protocol|port|fqdn|status|detail
#     status: ok | fail
#     detail: para ok -> "200"/"404"/etc; para fail -> "timeout"/"refused"/...
# ────────────────────────────────────────────────────────────────────────────
RESULTS=()
TOTAL=0
OK_COUNT=0
FAIL_COUNT=0

# _check_https CATEGORY FQDN PORT
_check_https() {
    local category="$1" fqdn="$2" port="${3:-443}"
    TOTAL=$((TOTAL + 1))

    # -k        aceita certs sem validar (firewall pode reescrever cert) — irrelevante aqui,
    #           porque o objetivo é confirmar que TLS subiu, não validar cadeia
    local code
    code=$(curl -k -s -o /dev/null -w "%{http_code}" \
                --max-time "$TIMEOUT_SEC" \
                "https://${fqdn}:${port}/" 2>/dev/null) || code="000"

    if _http_code_is_ok "$code"; then
        RESULTS+=("${category}|https|${port}|${fqdn}|ok|${code}")
        OK_COUNT=$((OK_COUNT + 1))
    else
        RESULTS+=("${category}|https|${port}|${fqdn}|fail|timeout/conexão recusada")
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# _check_tcp CATEGORY FQDN PORT
_check_tcp() {
    local category="$1" fqdn="$2" port="$3"
    TOTAL=$((TOTAL + 1))

    if timeout "$TIMEOUT_SEC" bash -c "exec 3<>/dev/tcp/${fqdn}/${port}" 2>/dev/null; then
        RESULTS+=("${category}|tcp|${port}|${fqdn}|ok|conectou")
        OK_COUNT=$((OK_COUNT + 1))
    else
        RESULTS+=("${category}|tcp|${port}|${fqdn}|fail|timeout/conexão recusada")
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# ────────────────────────────────────────────────────────────────────────────
# Execução — itera categorias e endpoints do JSON
# Stream: <category_label>\t<fqdn>\t<protocol>\t<port>
# ────────────────────────────────────────────────────────────────────────────
while IFS=$'\t' read -r category fqdn protocol port; do
    case "$protocol" in
        https) _check_https "$category" "$fqdn" "$port" ;;
        tcp)   _check_tcp   "$category" "$fqdn" "$port" ;;
        *)     echo "AVISO: protocolo desconhecido '$protocol' para $fqdn — ignorado" >&2 ;;
    esac
done < <(jq -r '.categories[] as $c | $c.endpoints[] | [$c.label, .fqdn, .protocol, (.port|tostring)] | @tsv' "$ENDPOINTS_FILE")

# ────────────────────────────────────────────────────────────────────────────
# Renderização
# ────────────────────────────────────────────────────────────────────────────
_render_human() {
    local last_cat=""
    for entry in "${RESULTS[@]}"; do
        IFS='|' read -r cat proto port fqdn status detail <<<"$entry"

        if [ "$cat" != "$last_cat" ]; then
            printf "\n${CYAN}=== %s ===${NC}\n" "$cat"
            last_cat="$cat"
        fi

        if [ "$status" = "ok" ]; then
            printf "  ${GREEN}✔${NC}  %-54s ${GRAY}%s${NC}\n" "$fqdn" "$detail"
        else
            printf "  ${RED}✘${NC}  %-54s ${RED}FAIL${NC} %s\n" "$fqdn" "$detail"
        fi
    done

    printf "\n${CYAN}=== Resumo ===${NC}\n"
    if [ "$FAIL_COUNT" -eq 0 ]; then
        printf "  ${GREEN}%d/%d OK${NC}\n\n" "$OK_COUNT" "$TOTAL"
    else
        printf "  ${YELLOW}%d/%d OK · %d FAIL${NC}\n" "$OK_COUNT" "$TOTAL" "$FAIL_COUNT"
        printf "  Consulte ${WHITE}docs/TROUBLESHOOTING.md${NC} (firewall) ou o documento de\n"
        printf "  reativação de whitelist (requisição ICI 753315).\n\n"
    fi
}

_render_quiet() {
    for entry in "${RESULTS[@]}"; do
        IFS='|' read -r cat proto port fqdn status detail <<<"$entry"
        [ "$status" = "fail" ] && printf "FAIL %s/%s %s: %s\n" "$proto" "$port" "$fqdn" "$detail"
    done
}

_render_json() {
    printf '{\n'
    printf '  "summary": {"total": %d, "ok": %d, "fail": %d},\n' "$TOTAL" "$OK_COUNT" "$FAIL_COUNT"
    printf '  "checks": [\n'
    local i=0 last=$((${#RESULTS[@]} - 1))
    for entry in "${RESULTS[@]}"; do
        IFS='|' read -r cat proto port fqdn status detail <<<"$entry"
        local sep=","
        [ "$i" -eq "$last" ] && sep=""
        printf '    {"category": "%s", "fqdn": "%s", "protocol": "%s", "port": %s, "status": "%s", "detail": "%s"}%s\n' \
            "$cat" "$fqdn" "$proto" "$port" "$status" "$detail" "$sep"
        i=$((i + 1))
    done
    printf '  ]\n'
    printf '}\n'
}

case "$OUTPUT_MODE" in
    human) _render_human ;;
    quiet) _render_quiet ;;
    json)  _render_json ;;
esac

[ "$FAIL_COUNT" -eq 0 ] && exit 0 || exit 1
