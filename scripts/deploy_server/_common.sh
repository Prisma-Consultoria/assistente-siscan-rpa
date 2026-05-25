#!/usr/bin/env bash
# -------------------------------------------
# Biblioteca comum dos specialists de diagnóstico
# -------------------------------------------
# Arquivo: scripts/deploy_server/_common.sh
# Propósito: helpers compartilhados entre os specialists em scripts/deploy_server/
#            (cores ANSI, output formatado, acumulador de resultados,
#             renderização human/quiet/json, parsing de args comum).
#
# Sourcing:
#   source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
#
# Após o source, os specialists devem:
#   1. Parsear seus próprios args (mas chamar _common_parse_arg "$1" para flags comuns)
#   2. Definir SPECIALIST_NAME (ex.: "check-network")
#   3. Executar seus checks via add_ok / add_fail
#   4. Chamar render_results no final
#   5. Sair com finalize_exit
#
# Não deve ter side effects quando sourceado.
# -------------------------------------------

# ────────────────────────────────────────────────────────────────────────────
# Estado global (compartilhado entre o specialist e este lib)
# ────────────────────────────────────────────────────────────────────────────
SPECIALIST_NAME="${SPECIALIST_NAME:-unknown}"
OUTPUT_MODE="${OUTPUT_MODE:-human}"   # human | quiet | json
TOTAL=0
OK_COUNT=0
FAIL_COUNT=0
RESULTS=()
# Cada entrada em RESULTS é uma linha pipe-separada:
#   category|protocol|port|target|status|detail
#     status: ok | fail
#     detail: para ok -> "200"/"hostname"; para fail -> "timeout"/"refused"/...

# ────────────────────────────────────────────────────────────────────────────
# Cores ANSI — desativadas se NO_COLOR, ou se stdout não é TTY, ou em --json/--quiet
# ────────────────────────────────────────────────────────────────────────────
_setup_colors() {
    if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ] || [ "$OUTPUT_MODE" != "human" ]; then
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
# Helpers de output (para mensagens fora do RESULTS — ex.: erros de pré-req)
# ────────────────────────────────────────────────────────────────────────────
ok()   { printf "  ${GREEN}✔${NC}  %s\n" "$1"; }
info() { printf "  ${GRAY}→${NC}  %s\n" "$1"; }
warn() { printf "  ${YELLOW}⚠${NC}  %s\n" "$1" >&2; }
fail() { printf "\n${RED}ERRO: %s${NC}\n\n" "$1" >&2; exit 2; }

# ────────────────────────────────────────────────────────────────────────────
# Acumuladores de resultado
# add_ok   CATEGORY PROTOCOL PORT TARGET DETAIL
# add_fail CATEGORY PROTOCOL PORT TARGET DETAIL
# ────────────────────────────────────────────────────────────────────────────
add_ok() {
    RESULTS+=("$1|$2|$3|$4|ok|$5")
    TOTAL=$((TOTAL + 1)); OK_COUNT=$((OK_COUNT + 1))
}
add_fail() {
    RESULTS+=("$1|$2|$3|$4|fail|$5")
    TOTAL=$((TOTAL + 1)); FAIL_COUNT=$((FAIL_COUNT + 1))
}

# ────────────────────────────────────────────────────────────────────────────
# Renderização
# ────────────────────────────────────────────────────────────────────────────
_render_human() {
    local last_cat=""
    for entry in "${RESULTS[@]}"; do
        IFS='|' read -r cat proto port target status detail <<<"$entry"
        if [ "$cat" != "$last_cat" ]; then
            printf "\n${CYAN}=== %s ===${NC}\n" "$cat"
            last_cat="$cat"
        fi
        if [ "$status" = "ok" ]; then
            printf "  ${GREEN}✔${NC}  %-54s ${GRAY}%s${NC}\n" "$target" "$detail"
        else
            printf "  ${RED}✘${NC}  %-54s ${RED}FAIL${NC} %s\n" "$target" "$detail"
        fi
    done
    printf "\n${CYAN}=== Resumo (%s) ===${NC}\n" "$SPECIALIST_NAME"
    if [ "$FAIL_COUNT" -eq 0 ]; then
        printf "  ${GREEN}%d/%d OK${NC}\n\n" "$OK_COUNT" "$TOTAL"
    else
        printf "  ${YELLOW}%d/%d OK · %d FAIL${NC}\n\n" "$OK_COUNT" "$TOTAL" "$FAIL_COUNT"
    fi
}

_render_quiet() {
    for entry in "${RESULTS[@]}"; do
        IFS='|' read -r cat proto port target status detail <<<"$entry"
        [ "$status" = "fail" ] && printf "FAIL [%s] %s/%s %s: %s\n" "$SPECIALIST_NAME" "$proto" "$port" "$target" "$detail"
    done
}

_render_json() {
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
        human) _render_human ;;
        quiet) _render_quiet ;;
        json)  _render_json ;;
        *)     fail "OUTPUT_MODE desconhecido: $OUTPUT_MODE" ;;
    esac
}

finalize_exit() {
    [ "$FAIL_COUNT" -eq 0 ] && exit 0 || exit 1
}

# ────────────────────────────────────────────────────────────────────────────
# Parsing de flags comuns
# Uso: while [ $# -gt 0 ]; do common_parse_arg "$1" && shift && continue; ...; done
# Retorna 0 se consumiu o argumento; 1 se não reconheceu.
# Pode consumir 1 ou 2 args (caso de --timeout SEC); ajusta o shift via $shift_count.
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
