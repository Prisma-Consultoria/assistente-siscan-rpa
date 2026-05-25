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
# Specialists disponíveis: descobertos dinamicamente em scripts/deploy_server/
# Source of truth: 'bash siscan-server-doctor.sh --list' (com Summary inline
# do header de cada specialist). Não manter lista estática aqui — vira
# desalinhamento toda vez que um specialist for criado/removido/renomeado.
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

# Conjuntos pré-definidos de specialists pra cenários conhecidos.
# Centralizar aqui evita o operador ter que lembrar quais specialists pular
# em cada momento do ciclo de vida da VM.
#
#   --pre-setup  → pula 3 specialists que dependem de coisas que o setup
#                  ainda vai instalar:
#                    check-runner  (runner ainda não foi instalado)
#                    check-stack   (containers ainda não foram subidos)
#                    check-db      (.env final com DATABASE_HOST só sai
#                                   da Fase 5 do setup)
EXCEPT_PRE_SETUP="check-runner,check-stack,check-db"

usage() {
    cat <<EOF
Uso: bash $(basename "$0") [opções]

Modos pré-definidos (mutuamente exclusivos):
  (sem flag)        Roda TODOS os specialists — modo padrão (post-setup),
                    validação completa após setup/deploy.
  --pre-setup       Roda subset apropriado pra ANTES do setup completar:
                    pula check-runner, check-stack e check-db (que
                    dependem de coisas que o setup ainda vai criar).

Filtros granulares:
  --only LIST       Roda só os specialists listados (separados por vírgula)
                    Ex: --only check-network,check-db
  --except LIST     Roda todos exceto os listados
                    (--pre-setup é açúcar pra --except $EXCEPT_PRE_SETUP)

Outras:
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
        --only)       ONLY="${2:-}"; shift 2 ;;
        --only=*)     ONLY="${1#*=}"; shift ;;
        --except)     EXCEPT="${2:-}"; shift 2 ;;
        --except=*)   EXCEPT="${1#*=}"; shift ;;
        --pre-setup)  EXCEPT="$EXCEPT_PRE_SETUP"; shift ;;
        --list)       LIST_ONLY=true; shift ;;
        -h|--help)    usage; exit 0 ;;
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
        # Extrai metadado "# Summary: <texto>" do header do specialist
        summary=$(grep -m1 -E '^# Summary:' "$SPECIALISTS_DIR/$name.sh" 2>/dev/null | sed -E 's/^# Summary:[[:space:]]*//')
        if [ -n "$summary" ]; then
            printf "  ${WHITE}%-20s${NC} %s\n" "$name" "$summary"
        else
            printf "  ${WHITE}%-20s${NC} ${YELLOW}(sem descrição — adicione '# Summary:' no header)${NC}\n" "$name"
        fi
    done
    exit 0
fi

[ ${#TO_RUN[@]} -gt 0 ] || fail "nenhum specialist a rodar (--only/--except não casou com nada)"

# ────────────────────────────────────────────────────────────────────────────
# Preflight: utilitários Linux essenciais do próprio doctor
#
# jq é obrigatório SOMENTE em --json, onde o doctor agrega o output JSON dos
# specialists com `echo "$output" | jq -e .` (validação) e
# `jq -r '"\(.summary.ok)/\(.summary.total)"'` (totais no progresso).
#
# Em human/quiet o doctor NÃO usa jq (só faz `bash "$script"` direto e
# encaminha stdout/stderr). Condicionar o preflight a OUTPUT_MODE=json evita
# bloquear execuções úteis em hosts sem jq — ex: `--only check-resources`,
# que não depende de jq nem de manifesto.
#
# Specialists que precisam de jq individualmente (check-env, check-permissions,
# check-network, check-runner, check-stack, check-docker) têm seu próprio
# require_commands em _common.sh — esses sim falham consistentemente, mesmo
# em human/quiet, e a stderr fica visível pro operador.
#
# Posicionado APÓS --list pra não exigir jq pra inventário (--list usa só grep).
# ────────────────────────────────────────────────────────────────────────────
[ "$OUTPUT_MODE" = "json" ] && require_commands jq

# ────────────────────────────────────────────────────────────────────────────
# Execução
# Cada specialist é invocado num subshell com o mesmo OUTPUT_MODE.
# Para JSON, o doctor agrega os JSONs individuais em um envelope consolidado.
# ────────────────────────────────────────────────────────────────────────────
SPECIALIST_EXIT_CODES=()
SPECIALIST_OUTPUTS=()

# Tempfile único reutilizado pra capturar stderr de cada specialist no modo --json.
# Cleanup garantido por trap (EXIT cobre exits normais; INT/TERM cobre Ctrl+C
# entre iterações). mktemp com fallback pra /dev/null: se /tmp estiver
# corrompido/cheio, ainda rodamos — só perdemos a captura da stderr (sem
# regressão funcional comparado ao comportamento original 2>/dev/null).
STDERR_BUFFER=""
if [ "$OUTPUT_MODE" = "json" ]; then
    STDERR_BUFFER=$(mktemp 2>/dev/null) || STDERR_BUFFER=""
    [ -n "$STDERR_BUFFER" ] && trap 'rm -f "$STDERR_BUFFER"' EXIT INT TERM
fi

# tty detection: emite progresso em --json e --quiet se stderr é tty
# (em --json não polui o stdout do JSON; em --quiet evita sensação de hang
#  quando todos os specialists passam silenciosamente sem FAIL).
# Em CI (stderr não-tty) fica desligado — não polui logs.
PROGRESS_ENABLED=false
case "$OUTPUT_MODE" in
    json|quiet) [ -t 2 ] && PROGRESS_ENABLED=true ;;
esac

total_specs=${#TO_RUN[@]}
idx=0
for name in "${TO_RUN[@]}"; do
    idx=$((idx + 1))
    script="$SPECIALISTS_DIR/$name.sh"
    rc=0

    case "$OUTPUT_MODE" in
        human)
            printf "\n${WHITE}▸ Specialist: %s${NC}\n" "$name"
            bash "$script"
            rc=$?
            # Specialists com exit=2 fizeram pre-fail (ex: .env ausente) — saem
            # via fail() antes do render_results, então não há '=== Resumo ===' pra
            # esse specialist. Sintetiza um marker visível pra alinhar com o
            # envelope JSON (que tem entrada {total:1,ok:0,fail:1} pro pre-fail).
            if [ "$rc" -eq 2 ]; then
                printf "\n  ${RED}✘${NC} ${RED}%s pré-falhou (exit=2) — conta como 1 FAIL no consolidado${NC}\n" "$name"
            fi
            ;;
        quiet)
            if [ "$PROGRESS_ENABLED" = true ]; then
                printf "  ⟳ [%d/%d] %s... " "$idx" "$total_specs" "$name" >&2
            fi
            bash "$script" --quiet
            rc=$?
            if [ "$PROGRESS_ENABLED" = true ]; then
                if [ "$rc" -eq 0 ]; then
                    printf "${GREEN}✓${NC} OK\n" >&2
                else
                    printf "${RED}✗${NC} FAIL (exit=%d)\n" "$rc" >&2
                fi
            fi
            ;;
        json)
            # Progresso no stderr — não polui o JSON do stdout
            if [ "$PROGRESS_ENABLED" = true ]; then
                printf "  ⟳ [%d/%d] %s... " "$idx" "$total_specs" "$name" >&2
            fi
            # Captura stderr no STDERR_BUFFER (alocado antes do loop, cleanup via trap).
            # Quando o specialist pre-falha (fail() em _common.sh escreve em stderr e
            # sai com 2), a stderr é a única pista do erro real — antes era descartada
            # via 2>/dev/null e o diagnóstico do operador ficava "voando às cegas".
            #
            # Se STDERR_BUFFER ficou vazio (mktemp falhou), cai no fallback 2>/dev/null
            # — perdemos a captura mas não regredimos vs comportamento original.
            if [ -n "$STDERR_BUFFER" ]; then
                : > "$STDERR_BUFFER"  # trunca antes da próxima captura
                output="$(bash "$script" --json 2>"$STDERR_BUFFER")"
                rc=$?
            else
                output="$(bash "$script" --json 2>/dev/null)"
                rc=$?
            fi
            # Specialist que pre-falha (exit 2, ex: .env ausente) sai com stdout vazio.
            # Substitui por envelope de erro pra não quebrar o JSON final do doctor.
            if [ -z "$output" ] || ! echo "$output" | jq -e . >/dev/null 2>&1; then
                # Cauda da stderr (últimos 500 chars) — captura ERROR: ...
                # do fail() + qualquer ruído de set -u/pipefail antes do abort.
                if [ -n "$STDERR_BUFFER" ]; then
                    stderr_tail=$(tail -c 500 "$STDERR_BUFFER" 2>/dev/null)
                else
                    stderr_tail="(captura de stderr indisponível — mktemp falhou)"
                fi
                [ -z "$stderr_tail" ] && stderr_tail="(stderr vazio)"
                # IMPORTANTE: não usar jq aqui — jq pode ser exatamente o binário
                # ausente que causou o pre-fail do specialist. Usamos _json_escape
                # (em _common.sh) que faz escape em bash puro. Sem essa precaução,
                # ambiente sem jq teria stdout vazio e o doctor cuspiria JSON
                # consolidado quebrado (regressão diagnosticada pelo Copilot).
                stderr_escaped=$(_json_escape "$stderr_tail")
                name_escaped=$(_json_escape "$name")
                output=$(printf '{"specialist": "%s", "summary": {"total": 1, "ok": 0, "fail": 1}, "checks": [{"category": "Pré-requisito do specialist", "target": "%s", "protocol": "err", "port": 0, "status": "fail", "detail": "specialist saiu com exit=%s sem JSON válido. stderr: %s"}]}' \
                    "$name_escaped" "$name_escaped" "$rc" "$stderr_escaped")
            fi
            SPECIALIST_OUTPUTS+=("$output")
            # Resumo da execução no stderr (OK/FAIL + totais quando jq disponível)
            if [ "$PROGRESS_ENABLED" = true ]; then
                if [ "$rc" -eq 0 ]; then
                    totals=$(echo "$output" | jq -r '"\(.summary.ok)/\(.summary.total)"' 2>/dev/null || echo "")
                    if [ -n "$totals" ]; then
                        printf "${GREEN}✓${NC} %s OK\n" "$totals" >&2
                    else
                        printf "${GREEN}✓${NC} OK\n" >&2
                    fi
                else
                    totals=$(echo "$output" | jq -r '"\(.summary.ok)/\(.summary.total)"' 2>/dev/null || echo "")
                    if [ -n "$totals" ]; then
                        printf "${RED}✗${NC} %s OK (FAIL)\n" "$totals" >&2
                    else
                        printf "${RED}✗${NC} FAIL (exit=%d)\n" "$rc" >&2
                    fi
                fi
            fi
            ;;
    esac

    SPECIALIST_EXIT_CODES+=("$rc")
done

# Linha em branco no stderr separando progresso do JSON final
[ "$PROGRESS_ENABLED" = true ] && printf "\n" >&2

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
