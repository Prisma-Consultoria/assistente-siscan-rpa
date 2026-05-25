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
warn() { [ "$OUTPUT_MODE" != "json" ] && printf "  ${YELLOW}⚠${NC}  %s\n" "$1" >&2; return 0; }
fail() { printf "\n${RED}ERRO: %s${NC}\n\n" "$1" >&2; exit 2; }

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
_print_live_result() {
    local cat="$1" proto="$2" port="$3" target="$4" status="$5" detail="$6"
    case "$OUTPUT_MODE" in
        human)
            if [ "$status" = "ok" ]; then
                printf "  ${GREEN}✔${NC}  %-54s ${GRAY}%s${NC}\n" "$target" "$detail"
            else
                printf "  ${RED}✘${NC}  %-54s ${RED}FAIL${NC} %s\n" "$target" "$detail"
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
