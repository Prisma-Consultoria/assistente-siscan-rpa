#!/usr/bin/env bash
# -------------------------------------------
# Biblioteca comum dos specialists de diagnóstico
# -------------------------------------------
# Arquivo: scripts/deploy_server/_common.sh
# Propósito: helpers compartilhados entre os specialists em scripts/deploy_server/
#            (cores ANSI, output formatado, acumulador de resultados,
#             renderização live ou em JSON final, parsing de args comum).
#
# Modelo de renderização:
#   - human/quiet  → resultado renderizado AO VIVO conforme add_ok/add_fail
#                    (feedback de progresso para o operador). Categoria é
#                    aberta com print_category_header antes dos checks.
#   - json         → acumula em RESULTS, renderiza envelope no final
#                    (sem ruído durante a coleta).
#
# Sourcing:
#   source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
#
# Após o source, os specialists devem:
#   1. Parsear seus args (delegando flags comuns via common_parse_arg)
#   2. Definir SPECIALIST_NAME
#   3. Para cada categoria de checks:
#        print_category_header "<label>" "<descrição opcional>"
#        <chamadas de check que usam add_ok / add_fail>
#   4. Opcional: print_interpretation_footer "<texto>"
#   5. render_results (imprime resumo / envelope JSON)
#   6. finalize_exit (exit 0 se FAIL_COUNT==0, senão 1)
#
# Não deve ter side effects quando sourceado.
# -------------------------------------------

# ────────────────────────────────────────────────────────────────────────────
# Estado global
# ────────────────────────────────────────────────────────────────────────────
SPECIALIST_NAME="${SPECIALIST_NAME:-unknown}"
OUTPUT_MODE="${OUTPUT_MODE:-human}"   # human | quiet | json
TOTAL=0
OK_COUNT=0
FAIL_COUNT=0
RESULTS=()                              # category|protocol|port|target|status|detail
INTERPRETATION_FOOTER=""

# ────────────────────────────────────────────────────────────────────────────
# Cores ANSI — desativadas se NO_COLOR, ou se stdout não é TTY, ou --json
# ────────────────────────────────────────────────────────────────────────────
_setup_colors() {
    if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ] || [ "$OUTPUT_MODE" = "json" ]; then
        RED='' GREEN='' YELLOW='' CYAN='' GRAY='' WHITE='' NC=''
    else
        RED='\033[0;31m'
        GREEN='\033[0;32m'
        YELLOW='\033[1;33m'
        CYAN='\033[0;36m'
        GRAY='\033[0;90m'
        WHITE='\033[1;37m'
        NC='\033[0m'
    fi
}
_setup_colors

# ────────────────────────────────────────────────────────────────────────────
# Helpers de output (mensagens fora do RESULTS — pré-req, avisos)
# ────────────────────────────────────────────────────────────────────────────
ok()   { [ "$OUTPUT_MODE" = "human" ] && printf "  ${GREEN}✔${NC}  %s\n" "$1"; }
info() { [ "$OUTPUT_MODE" = "human" ] && printf "  ${GRAY}→${NC}  %s\n" "$1"; }
# warn() vai pra stderr apenas em human mode. Em quiet/json fica suprimido
# pra honrar o contrato dos modos (quiet = só FAIL lines; json = só JSON).
# Avisos relevantes que precisem ser observáveis em quiet/json devem virar
# add_ok com 'warn' no detalhe (entram no fluxo padrão de saída).
warn() { [ "$OUTPUT_MODE" = "human" ] && printf "  ${YELLOW}⚠${NC}  %s\n" "$1" >&2; return 0; }
fail() { printf "\n${RED}ERRO: %s${NC}\n\n" "$1" >&2; exit 2; }

# _json_escape STRING
#   Escapa uma string arbitrária pra interior de um valor JSON usando só
#   primitivas de bash + tr (sem jq, sem python). Saída vai pra stdout sem
#   aspas envolventes — o caller adiciona "...".
#
#   Por que sem jq: callers que precisam disso são fallbacks pra cenários
#   onde jq pode estar ausente (ex: envelope sintético de erro no doctor,
#   require_commands quando jq está entre os faltantes).
#
#   Cobre o subset que aparece em stderr de fail() / set -u / pipefail:
#   backslash, aspas duplas, \n \r \t. Outros control chars (0x00-0x1F)
#   são removidos — JSON estrito exigiria \uXXXX, mas tr -d é seguro pro
#   nosso uso (não estamos serializando dados binários).
_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"           # \  → \\   (PRIMEIRO — evita escape duplo)
    s="${s//\"/\\\"}"           # "  → \"
    s="${s//$'\n'/\\n}"         # LF → \n
    s="${s//$'\r'/\\r}"         # CR → \r
    s="${s//$'\t'/\\t}"         # TAB → \t
    # Remove control chars restantes (0x00-0x08, 0x0B, 0x0C, 0x0E-0x1F)
    s=$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037')
    printf '%s' "$s"
}

# _pkg_for_cmd CMD
#   Retorna o nome do pacote .deb que provê CMD via stdout. Muitos comandos
#   têm nome != pacote (timeout vem de coreutils, getent de libc-bin, etc.) —
#   `sudo apt install -y timeout` falha porque não existe pacote 'timeout'.
#   Pra binários onde nome=pacote, retorna o próprio cmd.
#
#   Fallback explícito: docker é controverso (Docker CE upstream tem
#   instruções próprias, fora do alvo de `apt install`); aqui retornamos
#   docker.io (pacote Ubuntu) mas o ideal é o operador seguir o guia oficial.
_pkg_for_cmd() {
    case "$1" in
        timeout|nproc|tr|head|tail|cut|sed|sort|wc) printf 'coreutils' ;;
        getent)                                    printf 'libc-bin' ;;
        docker)                                    printf 'docker.io' ;;
        # Pacotes 1:1 com o nome do comando
        jq|curl|openssl|sudo|git)                  printf '%s' "$1" ;;
        # Fallback: assume nome=pacote (operador descobre na hora se errado)
        *)                                         printf '%s' "$1" ;;
    esac
}

# require_commands cmd1 cmd2 ...
#
# Preflight de utilitários Linux: aborta o specialist antes de qualquer check
# se algum dos comandos pedidos estiver ausente, com uma única mensagem
# orientativa consolidada (sudo apt install -y pkg1 pkg2 ...).
#
# Substitui o padrão antigo de N chamadas seriais de `command -v X || fail "X..."`
# espalhadas pelos specialists, que falhavam na PRIMEIRA ausência sem mostrar as
# demais — operador instalava uma, rodava de novo, descobria a próxima, etc.
#
# IMPORTANTE: a montagem do envelope JSON aqui NÃO pode usar jq, porque jq pode
# ser exatamente o binário ausente. Por isso o JSON é construído com printf, com
# escape manual aceitável já que nomes de comandos são alfanuméricos simples
# (sem aspas, newlines, etc).
#
# Em human: callout consolidado em stderr (visível tanto standalone quanto via
# doctor, que captura stderr no envelope sintético desde a melhoria do mascaramento).
# Em quiet: linha FAIL em stdout (alinhada com _print_live_result do quiet, que
# também emite FAIL em stdout — contrato de "quiet = só linhas FAIL no stdout").
# Em json: envelope com 1 check FAIL por cmd ausente. detail traz a orientação
# CONSOLIDADA (mesmo install_cmd em todos os checks) — o consumidor agrupa por
# specialist e usa qualquer linha do array como referência de instalação.
# Exit code: 2 (uso inválido / pré-requisito do host não atendido).
require_commands() {
    local missing_cmds=() missing_pkgs=()
    local cmd pkg
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 && continue
        missing_cmds+=("$cmd")
        pkg=$(_pkg_for_cmd "$cmd")
        # Dedup: timeout E nproc ambos mapeiam pra coreutils — não repetir
        local already=false p
        for p in "${missing_pkgs[@]}"; do
            [ "$p" = "$pkg" ] && already=true && break
        done
        $already || missing_pkgs+=("$pkg")
    done
    [ ${#missing_cmds[@]} -eq 0 ] && return 0

    local cmds_csv="${missing_cmds[*]}"
    local install_cmd="sudo apt install -y ${missing_pkgs[*]}"
    local total="${#missing_cmds[@]}"

    case "$OUTPUT_MODE" in
        json)
            # Constrói JSON com printf (jq pode estar entre os ausentes).
            # detail reutiliza install_cmd consolidado — não repete fragmentos
            # diferentes por item; quem consome o JSON encontra a mesma linha de
            # ação em qualquer check do array.
            printf '{\n'
            printf '  "specialist": "%s",\n' "$SPECIALIST_NAME"
            printf '  "summary": {"total": %d, "ok": 0, "fail": %d},\n' "$total" "$total"
            printf '  "checks": [\n'
            local i=0 last=$((total - 1)) sep
            for cmd in "${missing_cmds[@]}"; do
                sep=","
                [ "$i" -eq "$last" ] && sep=""
                printf '    {"category": "Utilitário Linux ausente", "target": "%s", "protocol": "cmd", "port": 0, "status": "fail", "detail": "binário ausente — instale TODOS os faltantes com: %s"}%s\n' \
                    "$cmd" "$install_cmd" "$sep"
                i=$((i + 1))
            done
            printf '  ]\n}\n'
            ;;
        human)
            printf "\n${RED}═══ Pré-requisito ausente: utilitário Linux ═══${NC}\n" >&2
            printf "  Faltam (cmd → pacote): ${YELLOW}%s${NC}\n\n" "$(_zip_cmd_pkg "${missing_cmds[@]}")" >&2
            printf "  Instale com:\n" >&2
            printf "    ${CYAN}%s${NC}\n\n" "$install_cmd" >&2
            ;;
        quiet)
            # Stdout (sem >&2) — alinhado com _print_live_result do quiet.
            printf "FAIL [%s] preflight: utilitário(s) ausente(s) (%s) — %s\n" \
                "$SPECIALIST_NAME" "$cmds_csv" "$install_cmd"
            ;;
    esac
    exit 2
}

# _zip_cmd_pkg cmd1 cmd2 ...
#   Helper interno do require_commands em human mode: formata "cmd → pkg" pra
#   cada cmd, separados por vírgula. Útil quando cmd != pkg (timeout → coreutils).
_zip_cmd_pkg() {
    local out="" cmd pkg sep=""
    for cmd in "$@"; do
        pkg=$(_pkg_for_cmd "$cmd")
        if [ "$cmd" = "$pkg" ]; then
            out+="${sep}${cmd}"
        else
            out+="${sep}${cmd} → ${pkg}"
        fi
        sep=", "
    done
    printf '%s' "$out"
}

# ────────────────────────────────────────────────────────────────────────────
# Renderização live
# ────────────────────────────────────────────────────────────────────────────
# print_category_header LABEL [DESCRIPTION]
#   Imprime o banner da categoria + descrição em human mode (feedback de progresso).
#   Em quiet/json é noop.
print_category_header() {
    local label="$1" description="${2:-}"
    if [ "$OUTPUT_MODE" = "human" ]; then
        printf "\n${CYAN}=== %s ===${NC}\n" "$label"
        [ -n "$description" ] && printf "${GRAY}%s${NC}\n" "$description"
    fi
}

# print_interpretation_footer TEXT
#   Armazena texto que será exibido após o resumo em human mode.
#   Útil pra orientação de como interpretar o resultado.
print_interpretation_footer() {
    INTERPRETATION_FOOTER="$1"
}

# print_category_guidance STATUS TEXT
#   Imprime, AO VIVO após uma categoria, o veredito (Resultado: tudo OK / ação necessária)
#   seguido do texto orientativo (próximo passo ou ação corretiva).
#   Em quiet/json é noop — a orientação fica embutida no JSON / é desnecessária no quiet.
#   STATUS: ok | fail
print_category_guidance() {
    local status="$1" text="$2"
    [ -z "$text" ] && return
    [ "$OUTPUT_MODE" != "human" ] && return

    if [ "$status" = "ok" ]; then
        printf "\n  ${GREEN}→ Resultado: tudo OK${NC}\n"
    else
        printf "\n  ${YELLOW}→ Resultado: ação necessária${NC}\n"
    fi
    if command -v fold >/dev/null 2>&1; then
        printf "%s\n" "$text" | fold -s -w 90 | sed 's/^/     /'
    else
        printf "     %s\n" "$text"
    fi
}

# _print_live_result CATEGORY PROTOCOL PORT TARGET STATUS DETAIL
#
# Human mode: ✔ verde para OK, ✘ vermelho para FAIL. O detalhe é mostrado em
# cor (GRAY para OK, RED para FAIL) — o símbolo+cor já comunicam o veredito,
# não precisa de label "FAIL" hardcoded no meio (que ficaria redundante quando
# o detalhe já carrega a mensagem da falha).
_print_live_result() {
    local cat="$1" proto="$2" port="$3" target="$4" status="$5" detail="$6"
    case "$OUTPUT_MODE" in
        human)
            if [ "$status" = "ok" ]; then
                printf "  ${GREEN}✔${NC}  %-54s ${GRAY}%s${NC}\n" "$target" "$detail"
            else
                printf "  ${RED}✘${NC}  %-54s ${RED}%s${NC}\n" "$target" "$detail"
            fi
            ;;
        quiet)
            [ "$status" = "fail" ] && printf "FAIL [%s] %s/%s %s: %s\n" "$SPECIALIST_NAME" "$proto" "$port" "$target" "$detail"
            ;;
        json)
            : # acumula em RESULTS; renderiza no final
            ;;
    esac
}

# ────────────────────────────────────────────────────────────────────────────
# Acumuladores de resultado (renderizam live em human/quiet)
# add_ok   CATEGORY PROTOCOL PORT TARGET DETAIL
# add_fail CATEGORY PROTOCOL PORT TARGET DETAIL
# ────────────────────────────────────────────────────────────────────────────
add_ok() {
    RESULTS+=("$1|$2|$3|$4|ok|$5")
    TOTAL=$((TOTAL + 1)); OK_COUNT=$((OK_COUNT + 1))
    _print_live_result "$1" "$2" "$3" "$4" ok "$5"
}
add_fail() {
    RESULTS+=("$1|$2|$3|$4|fail|$5")
    TOTAL=$((TOTAL + 1)); FAIL_COUNT=$((FAIL_COUNT + 1))
    _print_live_result "$1" "$2" "$3" "$4" fail "$5"
}

# ────────────────────────────────────────────────────────────────────────────
# Renderização final (resumo + JSON envelope)
# ────────────────────────────────────────────────────────────────────────────
_render_summary_human() {
    printf "\n${CYAN}=== Resumo (%s) ===${NC}\n" "$SPECIALIST_NAME"
    if [ "$FAIL_COUNT" -eq 0 ]; then
        printf "  ${GREEN}%d/%d OK${NC}\n" "$OK_COUNT" "$TOTAL"
    else
        printf "  ${YELLOW}%d/%d OK · %d FAIL${NC}\n" "$OK_COUNT" "$TOTAL" "$FAIL_COUNT"
    fi
    if [ -n "$INTERPRETATION_FOOTER" ]; then
        printf "\n${CYAN}=== Como interpretar ===${NC}\n"
        printf "%s\n" "$INTERPRETATION_FOOTER"
    fi
    printf "\n"
}

_render_json_envelope() {
    printf '{\n'
    printf '  "specialist": "%s",\n' "$SPECIALIST_NAME"
    printf '  "summary": {"total": %d, "ok": %d, "fail": %d},\n' "$TOTAL" "$OK_COUNT" "$FAIL_COUNT"
    printf '  "checks": [\n'
    local i=0 last=$((${#RESULTS[@]} - 1))
    for entry in "${RESULTS[@]}"; do
        IFS='|' read -r cat proto port target status detail <<<"$entry"
        local sep=","
        [ "$i" -eq "$last" ] && sep=""
        printf '    {"category": "%s", "target": "%s", "protocol": "%s", "port": %s, "status": "%s", "detail": "%s"}%s\n' \
            "$cat" "$target" "$proto" "$port" "$status" "$detail" "$sep"
        i=$((i + 1))
    done
    printf '  ]\n'
    printf '}\n'
}

render_results() {
    case "$OUTPUT_MODE" in
        human) _render_summary_human ;;
        quiet) : ;;  # FAIL lines já saíram live
        json)  _render_json_envelope ;;
        *)     fail "OUTPUT_MODE desconhecido: $OUTPUT_MODE" ;;
    esac
}

finalize_exit() {
    [ "$FAIL_COUNT" -eq 0 ] && exit 0 || exit 1
}

# ────────────────────────────────────────────────────────────────────────────
# Manifesto de produtos (scripts/data/products.json)
#
# Specialists que precisam diferenciar produto (rpa/dashboard/full) leem
# do manifesto em vez de hardcodar 'case "$SISCAN_PRODUCT"'. Use:
#
#   PRODUCTS_FILE=/path/to/products.json   # geralmente $REPO_ROOT/scripts/data/products.json
#   SISCAN_PRODUCT=$(read_env SISCAN_PRODUCT)
#   product_validate                       # falha se PRODUCTS_FILE ou produto inválido
#   compose=$(product_get compose_file)
#   services=( $(product_get_array expected_services) )
#   product_has_extra rsa_keys_required && check_rsa_keys
# ────────────────────────────────────────────────────────────────────────────
PRODUCTS_FILE="${PRODUCTS_FILE:-}"

# product_validate
#   Confere que PRODUCTS_FILE existe, é JSON válido, e SISCAN_PRODUCT está no
#   conjunto conhecido. Falha (exit 2) caso contrário.
product_validate() {
    [ -n "$PRODUCTS_FILE" ] || fail "PRODUCTS_FILE não foi definido pelo specialist (especialist mal configurado)"
    command -v jq >/dev/null 2>&1 || fail "jq não está instalado — necessário pra parse do manifesto. Instale com: sudo apt install -y jq"
    [ -f "$PRODUCTS_FILE" ] || fail "manifesto de produtos não encontrado: $PRODUCTS_FILE"
    jq -e . "$PRODUCTS_FILE" >/dev/null 2>&1 || fail "manifesto de produtos não é JSON válido: $PRODUCTS_FILE"
    [ -n "${SISCAN_PRODUCT:-}" ] || fail "SISCAN_PRODUCT não definido no .env — rode check-env"
    local known
    known=$(jq -r ".products | has(\"$SISCAN_PRODUCT\")" "$PRODUCTS_FILE")
    if [ "$known" != "true" ]; then
        local list
        list=$(jq -r '.products | keys | join(", ")' "$PRODUCTS_FILE")
        fail "SISCAN_PRODUCT='$SISCAN_PRODUCT' não existe em $PRODUCTS_FILE. Conhecidos: $list"
    fi
}

# product_get FIELD [DEFAULT]
#   Lê um campo string do produto atual. Retorna DEFAULT se ausente/null.
product_get() {
    local field="$1" default="${2:-}"
    local val
    val=$(jq -r ".products.\"$SISCAN_PRODUCT\".$field // empty" "$PRODUCTS_FILE" 2>/dev/null)
    echo "${val:-$default}"
}

# product_get_array FIELD
#   Emite cada elemento do array em linha separada (use com mapfile/<<<).
product_get_array() {
    local field="$1"
    jq -r ".products.\"$SISCAN_PRODUCT\".$field[]?" "$PRODUCTS_FILE" 2>/dev/null
}

# product_has_extra KEY
#   Retorna 0 se extras.KEY == true, 1 caso contrário.
product_has_extra() {
    local key="$1"
    local val
    val=$(jq -r ".products.\"$SISCAN_PRODUCT\".extras.\"$key\" // false" "$PRODUCTS_FILE" 2>/dev/null)
    [ "$val" = "true" ]
}

# product_extra KEY [DEFAULT]
#   Lê extras.KEY (string ou número). DEFAULT se ausente.
product_extra() {
    local key="$1" default="${2:-}"
    local val
    val=$(jq -r ".products.\"$SISCAN_PRODUCT\".extras.\"$key\" // empty" "$PRODUCTS_FILE" 2>/dev/null)
    echo "${val:-$default}"
}

# ────────────────────────────────────────────────────────────────────────────
# Parsing de flags comuns
# common_parse_arg "$@" — retorna 0 se consumiu, 1 se não
# Ajusta $shift_count (1 ou 2) conforme o tipo do arg.
# ────────────────────────────────────────────────────────────────────────────
common_parse_arg() {
    shift_count=1
    case "$1" in
        --quiet)     OUTPUT_MODE="quiet"; _setup_colors; return 0 ;;
        --json)      OUTPUT_MODE="json";  _setup_colors; return 0 ;;
        --timeout)   TIMEOUT_SEC="${2:-10}"; shift_count=2; return 0 ;;
        --timeout=*) TIMEOUT_SEC="${1#*=}"; return 0 ;;
        *) return 1 ;;
    esac
}
