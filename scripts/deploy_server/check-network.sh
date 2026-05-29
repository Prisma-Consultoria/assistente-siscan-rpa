#!/usr/bin/env bash
# -------------------------------------------
# Specialist: check-network
# Summary: Endpoints HTTPS/TCP do GitHub Actions, GHCR, Docker Hub e OCSP/CRL
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
PRODUCTS_FILE="${REPO_ROOT}/scripts/data/products.json"
ENV_FILE="${COMPOSE_DIR:-$(pwd)}/.env"

# Flag opt-in (TSK00.04.11): categorias advisory contam como FAIL bloqueante em
# vez de SKIPPED não-bloqueante. Default false (preserva TSK00.04.09 — setup,
# recover e operadores one-off não freakam com exit 1 falso por variantes
# regionais que dependem do roteamento da VM). CI/automação rígida opta em.
# Variante A da decisão #90: sem prompt interativo, só flag CLI.
ADVISORY_STRICT=false

usage() {
    cat <<EOF
Uso: bash $(basename "$0") [opções]

Opções:
  --quiet                  Imprime somente linhas FAIL (cron de monitoramento)
  --json                   Saída estruturada em JSON
  --timeout SEC            Timeout por check em segundos (padrão: 10)
  --endpoints-file FILE    Override do JSON de endpoints
                           (padrão: scripts/data/network-endpoints.json)
  --advisory-strict        Falhas em categorias advisory viram FAIL (bloqueante,
                           exit 1) em vez de SKIPPED (não-bloqueante). Útil em
                           CI/CD ou pipeline de provisionamento estrito que
                           requer wildcard liberado. Default: warning (SKIPPED).
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
        --env-file)         ENV_FILE="${2:-}"; shift 2 ;;
        --env-file=*)       ENV_FILE="${1#*=}"; shift ;;
        --advisory-strict)  ADVISORY_STRICT=true; shift ;;
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
require_commands curl jq timeout
[ -f "$ENDPOINTS_FILE" ] || fail "arquivo de endpoints não encontrado: $ENDPOINTS_FILE"
jq -e . "$ENDPOINTS_FILE" >/dev/null 2>&1 || fail "arquivo de endpoints não é um JSON válido: $ENDPOINTS_FILE"

# ────────────────────────────────────────────────────────────────────────────
# Checks específicos deste specialist
# ────────────────────────────────────────────────────────────────────────────
# _check_https CATEGORY FQDN PORT EXPECTED_TEXT [ADVISORY]
#   Detalhe gerado deixa explícito que validamos APENAS firewall (TLS subiu),
#   e que o código HTTP é contexto interpretativo (esperado/inesperado neste FQDN).
#   EXPECTED_TEXT: do JSON, formato "200 — descrição" (opcional).
#   ADVISORY (TSK00.04.09): "true" indica categoria informativa — falha vira
#   add_skipped em vez de add_fail, NÃO conta no exit code do specialist.
#   Usado para variantes regionais cuja falha é esperada em VMs com whitelist
#   estreita (não bloqueia pre-flight, só sinaliza pra construção de pedido à TI).
#   ADVISORY_STRICT (TSK00.04.11): flag global; se true, categorias advisory
#   contam como FAIL bloqueante (override do default warning).
_check_https() {
    local category="$1" fqdn="$2" port="${3:-443}" expected="${4:-}" advisory="${5:-false}"
    local code
    code=$(curl -k -s -o /dev/null -w "%{http_code}" \
                --max-time "$TIMEOUT_SEC" \
                "https://${fqdn}:${port}/" 2>/dev/null) || code="000"

    # Critério (PDF v2.0, seção 11.4): qualquer resposta HTTP != 000 indica TLS subiu.
    if [ -z "$code" ] || [ "$code" = "000" ]; then
        if [ "$advisory" = "true" ] && [ "$ADVISORY_STRICT" != "true" ]; then
            add_skipped "$category" https "$port" "$fqdn" "firewall bloqueou — variante advisory (mapeamento para solicitação à TI)"
        elif [ "$advisory" = "true" ] && [ "$ADVISORY_STRICT" = "true" ]; then
            add_fail "$category" https "$port" "$fqdn" "firewall bloqueou — variante advisory em modo --advisory-strict (upgrade para FAIL bloqueante)"
        else
            add_fail "$category" https "$port" "$fqdn" "firewall bloqueou — sem resposta (TCP/TLS não completou)"
        fi
        return
    fi

    # Firewall passou (TLS subiu). Agora qualificar a resposta HTTP como contexto.
    local detail
    if [ -n "$expected" ]; then
        local exp_code="${expected%% — *}"
        local exp_text="${expected#*— }"
        if [ "$code" = "$exp_code" ]; then
            detail="${code} esperado · ${exp_text}"
        else
            detail="${code} inesperado (esperava ${exp_code}) · ${exp_text}"
        fi
    else
        detail="${code} · resposta HTTP recebida (sem expected definido no JSON)"
    fi
    add_ok "$category" https "$port" "$fqdn" "$detail"
}

# _check_tcp CATEGORY FQDN PORT EXPECTED_TEXT [ADVISORY]
#   ADVISORY (TSK00.04.09): mesmo contrato de _check_https — falha em categoria
#   advisory vira add_skipped (informativa) em vez de add_fail.
_check_tcp() {
    local category="$1" fqdn="$2" port="$3" expected="${4:-}" advisory="${5:-false}"
    if ! timeout "$TIMEOUT_SEC" bash -c "exec 3<>/dev/tcp/${fqdn}/${port}" 2>/dev/null; then
        if [ "$advisory" = "true" ] && [ "$ADVISORY_STRICT" != "true" ]; then
            add_skipped "$category" tcp "$port" "$fqdn" "firewall bloqueou — variante advisory (mapeamento para solicitação à TI)"
        elif [ "$advisory" = "true" ] && [ "$ADVISORY_STRICT" = "true" ]; then
            add_fail "$category" tcp "$port" "$fqdn" "firewall bloqueou — variante advisory em modo --advisory-strict (upgrade para FAIL bloqueante)"
        else
            add_fail "$category" tcp "$port" "$fqdn" "firewall bloqueou — sem TCP/${port}"
        fi
        return
    fi
    # Strip leading "TCP/<port> aberto — " do expected pra evitar duplicar.
    local detail="TCP/${port} aberto"
    if [ -n "$expected" ]; then
        local clean="${expected#TCP/${port} aberto — }"
        [ "$clean" != "$expected" ] && detail="TCP/${port} aberto · ${clean}"
    fi
    add_ok "$category" tcp "$port" "$fqdn" "$detail"
}

# ────────────────────────────────────────────────────────────────────────────
# Iteração: categoria por categoria
#   - Antes de cada categoria: print_category_header com label + description
#     (orientação fica no JSON, não no código).
#   - Para cada endpoint da categoria: dispara o check correspondente.
# ────────────────────────────────────────────────────────────────────────────
# ────────────────────────────────────────────────────────────────────────────
# Header explicativo do escopo (human mode apenas)
# ────────────────────────────────────────────────────────────────────────────
if [ "$OUTPUT_MODE" = "human" ]; then
    printf "\n${CYAN}══════════════════════════════════════════════════════════════════${NC}\n"
    printf "${WHITE}  check-network — validação de FIREWALL${NC}\n"
    printf "${CYAN}══════════════════════════════════════════════════════════════════${NC}\n"
    printf "\n"
    printf "  Cada linha mostra apenas se o ${WHITE}firewall liberou${NC} a conexão (TLS subiu).\n"
    printf "  Códigos HTTP/TCP são ${WHITE}contexto interpretativo${NC}, não validam funcionalidade\n"
    printf "  do endpoint — só credenciais reais validam isso (escopo futuro).\n"
    printf "\n"
    printf "  ${GREEN}✔${NC} = firewall liberou (TLS/TCP completou)\n"
    printf "  ${RED}✘${NC} = firewall bloqueou (sem resposta)\n"
    printf "\n"
fi

cat_count=$(jq '.categories | length' "$ENDPOINTS_FILE")
for i in $(seq 0 $((cat_count - 1))); do
    cat_label=$(jq -r ".categories[$i].label" "$ENDPOINTS_FILE")
    cat_desc=$(jq -r ".categories[$i].description // \"\"" "$ENDPOINTS_FILE")
    on_ok=$(jq -r   ".categories[$i].guidance.on_all_ok // \"\"" "$ENDPOINTS_FILE")
    on_fail=$(jq -r ".categories[$i].guidance.on_any_fail // \"\"" "$ENDPOINTS_FILE")
    # advisory: categorias com "advisory": true tratam falhas como SKIPPED em
    # vez de FAIL — não bloqueiam exit code do specialist. Usado para variantes
    # cujas falhas são esperadas em VMs com whitelist estreita (TSK00.04.09).
    advisory=$(jq -r ".categories[$i].advisory // false" "$ENDPOINTS_FILE")

    print_category_header "$cat_label" "$cat_desc"

    fail_before=$FAIL_COUNT
    skipped_before=$SKIPPED_COUNT

    while IFS=$'\t' read -r fqdn protocol port expected warning_when_alone; do
        local_ok_before=$OK_COUNT
        case "$protocol" in
            https) _check_https "$cat_label" "$fqdn" "$port" "$expected" "$advisory" ;;
            tcp)   _check_tcp   "$cat_label" "$fqdn" "$port" "$expected" "$advisory" ;;
            *)     warn "protocolo desconhecido '$protocol' para $fqdn — ignorado" ;;
        esac
        # warning_when_alone (TSK00.04.11 + revisão Copilot PR #93):
        # Emite warning OPERACIONAL apenas quando o endpoint EFETIVAMENTE
        # passou (OK_COUNT incrementou) — não basta "FAIL_COUNT não cresceu"
        # porque advisory falha = SKIPPED, e nesse caso o endpoint NÃO passou
        # (warning poderia induzir erro). Também gate pelo OUTPUT_MODE do
        # _common.sh — em quiet/json o warning não vaza no output estruturado.
        if [ "$OK_COUNT" -gt "$local_ok_before" ] \
            && [ -n "$warning_when_alone" ] && [ "$warning_when_alone" != "null" ] \
            && [ "${OUTPUT_MODE:-human}" = "human" ]; then
            printf "     ${YELLOW}%s${NC}\n" "$warning_when_alone" >&2
        fi
    done < <(jq -r ".categories[$i].endpoints[] | [.fqdn, .protocol, (.port|tostring), (.expected // \"\"), (.warning_when_alone // \"\")] | @tsv" "$ENDPOINTS_FILE")

    # Veredito da categoria + ação correspondente, AO VIVO (logo após os checks).
    # Para categorias advisory, conta SKIPPED em vez de FAIL — guidance.on_any_fail
    # dispara em qualquer caso onde algum endpoint não respondeu (tratado como
    # advisory ou hard fail), pra manter "vermelho operacional" coerente.
    if [ "$advisory" = "true" ]; then
        if [ "$SKIPPED_COUNT" -gt "$skipped_before" ]; then
            print_category_guidance fail "$on_fail"
        else
            print_category_guidance ok "$on_ok"
        fi
    else
        if [ "$FAIL_COUNT" -eq "$fail_before" ]; then
            print_category_guidance ok "$on_ok"
        else
            print_category_guidance fail "$on_fail"
        fi
    fi
done

# ────────────────────────────────────────────────────────────────────────────
# Categoria condicional: SISCAN portal (P2)
# Só ativa quando SISCAN_PRODUCT define siscan_portal_url_default no manifesto
# (atualmente apenas rpa e full). URL pode ser sobrescrita via .env: SISCAN_URL.
# ────────────────────────────────────────────────────────────────────────────
if [ -f "$ENV_FILE" ] && [ -f "$PRODUCTS_FILE" ]; then
    siscan_product_local=$(grep -E '^SISCAN_PRODUCT=' "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2-)
    if [ -n "$siscan_product_local" ]; then
        SISCAN_PRODUCT="$siscan_product_local"
        if product_validate >/dev/null 2>&1; then
            siscan_default=$(product_extra siscan_portal_url_default)
            if [ -n "$siscan_default" ]; then
                # Lê SISCAN_URL do .env ou cai no default do manifesto
                siscan_url=$(grep -E '^SISCAN_URL=' "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | sed 's/^["'\'']\(.*\)["'\'']$/\1/')
                siscan_url="${siscan_url:-$siscan_default}"
                # Extrair só o host pra exibir
                siscan_host=$(echo "$siscan_url" | sed -E 's|^https?://||;s|/.*||')

                print_category_header "Portal SISCAN ($SISCAN_PRODUCT — opcional)" "URL do portal SISCAN configurada pra este produto (do .env ou default do manifesto). RPA não autentica sem isso."

                fail_before=$FAIL_COUNT
                code=$(curl -k -s -o /dev/null -w "%{http_code}" --max-time "$TIMEOUT_SEC" "$siscan_url" 2>/dev/null) || code="000"
                if [ -z "$code" ] || [ "$code" = "000" ]; then
                    add_fail "Portal SISCAN ($SISCAN_PRODUCT — opcional)" https 443 "$siscan_host" "firewall bloqueou — sem resposta (TCP/TLS não completou)"
                elif [ "$code" -ge 200 ] && [ "$code" -lt 400 ]; then
                    add_ok "Portal SISCAN ($SISCAN_PRODUCT — opcional)" https 443 "$siscan_host" "$code esperado · portal acessível"
                else
                    add_ok "Portal SISCAN ($SISCAN_PRODUCT — opcional)" https 443 "$siscan_host" "$code · TLS OK, portal pode estar fora do ar (verificar manualmente)"
                fi

                if [ "$FAIL_COUNT" -eq "$fail_before" ]; then
                    print_category_guidance ok "Servidor consegue alcançar o portal SISCAN. Próximo passo: RPA poderá autenticar (precisará de credenciais cadastradas em /admin/siscan-credentials)."
                else
                    print_category_guidance fail "Servidor NÃO alcança o portal SISCAN — RPA não vai conseguir autenticar nem baixar PDFs. AÇÃO: verificar firewall/proxy/DNS pro endereço $siscan_url; o destino é externo (internet pública), não VLAN interna do servidor parceiro."
                fi
            fi
        fi
    fi
fi

# ────────────────────────────────────────────────────────────────────────────
# Renderização final (resumo + interpretação) e exit
# ────────────────────────────────────────────────────────────────────────────
render_results
finalize_exit
