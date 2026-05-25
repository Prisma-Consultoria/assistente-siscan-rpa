#!/usr/bin/env bash
# -------------------------------------------
# SISCAN Server Doctor — Diagnóstico amplo de saúde
# -------------------------------------------
# Arquivo: siscan-server-doctor.sh
# Propósito: Orquestrar a execução de todos os specialists de diagnóstico em
#            scripts/deploy_server/check-*.sh, agregando os resultados num único
#            relatório consolidado.
#
# Cada specialist é callable standalone, mas o doctor é o entry point recomendado
# para o operador: roda todos os checks, com saída agrupada por categoria, e
# resume "X/N specialists OK" no final.
#
# Uso:
#   bash siscan-server-doctor.sh                          # todos os specialists
#   bash siscan-server-doctor.sh --only check-network     # subset
#   bash siscan-server-doctor.sh --except check-db        # tudo exceto
#   bash siscan-server-doctor.sh --quiet                  # só FAIL
#   bash siscan-server-doctor.sh --json                   # JSON consolidado
#   bash siscan-server-doctor.sh --list                   # lista specialists disponíveis
#   bash siscan-server-doctor.sh --help
#
# Exit code:
#   0  todos os specialists passaram
#   1  pelo menos um specialist falhou
#   2  uso inválido
#
# Specialists planejados (status atual entre []):
#   check-network    [✓ implementado]      ← rede, GHCR, Docker Hub, OCSP/CRL
#   check-deps       [pendente — #28]      ← Docker, Compose, curl, sudo, jq, NTP
#   check-env        [pendente — #28]      ← .env, RPA_DATABASE_URL, APP_LOG_LEVEL
#   check-docker     [pendente — #28]      ← daemon, pool /24, grupo docker
#   check-runner     [pendente — #28]      ← .runner local + API + regra dos 30 dias
#   check-stack      [pendente — #28]      ← compose ps, port collision, restart loop
#   check-permissions [pendente — #28]     ← ownership, git safe.directory, UID 1000
#   check-db         [pendente — #28]      ← TCP/5432 + pg_isready
# -------------------------------------------

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPECIALISTS_DIR="$SCRIPT_DIR/scripts/deploy_server"
SPECIALIST_NAME="doctor"

# Source da biblioteca comum (cores, helpers, OUTPUT_MODE)
# shellcheck source=scripts/deploy_server/_common.sh
source "$SPECIALISTS_DIR/_common.sh"

# ────────────────────────────────────────────────────────────────────────────
# Parsing de args
# ────────────────────────────────────────────────────────────────────────────
ONLY=""
EXCEPT=""
LIST_ONLY=false

usage() {
    cat <<EOF
Uso: bash $(basename "$0") [opções]

Opções:
  --only LIST       Roda só os specialists listados (separados por vírgula)
                    Ex: --only check-network,check-db
  --except LIST     Roda todos exceto os listados
  --quiet           Suprime saída legível; imprime só linhas FAIL
  --json            Saída estruturada em JSON consolidado
  --list            Lista specialists disponíveis e sai
  -h, --help        Exibe esta ajuda

Exit code:
  0 = todos os specialists OK
  1 = pelo menos um specialist FAIL
  2 = uso inválido
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --only)     ONLY="${2:-}"; shift 2 ;;
        --only=*)   ONLY="${1#*=}"; shift ;;
        --except)   EXCEPT="${2:-}"; shift 2 ;;
        --except=*) EXCEPT="${1#*=}"; shift ;;
        --list)     LIST_ONLY=true; shift ;;
        -h|--help)  usage; exit 0 ;;
        *)
            if common_parse_arg "$@"; then
                shift "$shift_count"
            else
                echo "argumento desconhecido: $1" >&2; usage >&2; exit 2
            fi
            ;;
    esac
done

# ────────────────────────────────────────────────────────────────────────────
# Descoberta dos specialists
# ────────────────────────────────────────────────────────────────────────────
[ -d "$SPECIALISTS_DIR" ] || fail "diretório de specialists não encontrado: $SPECIALISTS_DIR"

AVAILABLE=()
for spec in "$SPECIALISTS_DIR"/check-*.sh; do
    [ -f "$spec" ] || continue
    AVAILABLE+=("$(basename "$spec" .sh)")
done

# Aplicar --only / --except
_in_list() {
    local needle="$1" haystack="$2"
    IFS=',' read -ra items <<<"$haystack"
    for item in "${items[@]}"; do
        [ "$item" = "$needle" ] && return 0
    done
    return 1
}

TO_RUN=()
for name in "${AVAILABLE[@]}"; do
    if [ -n "$ONLY" ]; then
        _in_list "$name" "$ONLY" && TO_RUN+=("$name")
    elif [ -n "$EXCEPT" ]; then
        _in_list "$name" "$EXCEPT" || TO_RUN+=("$name")
    else
        TO_RUN+=("$name")
    fi
done

if [ "$LIST_ONLY" = true ]; then
    printf "${CYAN}Specialists disponíveis em %s/${NC}\n" "${SPECIALISTS_DIR#$SCRIPT_DIR/}"
    for name in "${AVAILABLE[@]}"; do
        echo "  - $name"
    done
    exit 0
fi

[ ${#TO_RUN[@]} -gt 0 ] || fail "nenhum specialist a rodar (--only/--except não casou com nada)"

# ────────────────────────────────────────────────────────────────────────────
# Execução
# Cada specialist é invocado num subshell com o mesmo OUTPUT_MODE.
# Para JSON, o doctor agrega os JSONs individuais em um envelope consolidado.
# ────────────────────────────────────────────────────────────────────────────
SPECIALIST_EXIT_CODES=()
SPECIALIST_OUTPUTS=()

for name in "${TO_RUN[@]}"; do
    script="$SPECIALISTS_DIR/$name.sh"

    case "$OUTPUT_MODE" in
        human)
            printf "\n${WHITE}▸ Specialist: %s${NC}\n" "$name"
            bash "$script"
            ;;
        quiet)
            bash "$script" --quiet
            ;;
        json)
            output="$(bash "$script" --json)"
            SPECIALIST_OUTPUTS+=("$output")
            ;;
    esac

    SPECIALIST_EXIT_CODES+=("$?")
done

# ────────────────────────────────────────────────────────────────────────────
# Resumo final
# ────────────────────────────────────────────────────────────────────────────
PASSED=0
FAILED=0
for code in "${SPECIALIST_EXIT_CODES[@]}"; do
    if [ "$code" -eq 0 ]; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
    fi
done

case "$OUTPUT_MODE" in
    human)
        printf "\n${CYAN}════════════════════════════════════════${NC}\n"
        printf "${WHITE}  Diagnóstico consolidado${NC}\n"
        printf "${CYAN}════════════════════════════════════════${NC}\n"
        if [ "$FAILED" -eq 0 ]; then
            printf "  ${GREEN}%d/%d specialists OK${NC}\n\n" "$PASSED" "${#TO_RUN[@]}"
        else
            printf "  ${YELLOW}%d/%d specialists OK · %d com FAIL${NC}\n" "$PASSED" "${#TO_RUN[@]}" "$FAILED"
            printf "  Consulte ${WHITE}docs/TROUBLESHOOTING.md${NC} para resolução por problema.\n\n"
        fi
        ;;
    quiet)
        # Output dos specialists já saiu; nada adicional a imprimir
        ;;
    json)
        printf '{\n'
        printf '  "summary": {"specialists_total": %d, "ok": %d, "fail": %d},\n' "${#TO_RUN[@]}" "$PASSED" "$FAILED"
        printf '  "specialists": [\n'
        last=$((${#SPECIALIST_OUTPUTS[@]} - 1))
        for i in "${!SPECIALIST_OUTPUTS[@]}"; do
            sep=","
            [ "$i" -eq "$last" ] && sep=""
            printf '%s%s\n' "${SPECIALIST_OUTPUTS[$i]}" "$sep"
        done
        printf '  ]\n'
        printf '}\n'
        ;;
esac

[ "$FAILED" -eq 0 ] && exit 0 || exit 1
