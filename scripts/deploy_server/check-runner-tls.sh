#!/usr/bin/env bash
# -------------------------------------------
# Specialist: check-runner-tls
# Summary: Diagnóstico estruturado de TLS para registro do runner self-hosted
# -------------------------------------------
# Arquivo: scripts/deploy_server/check-runner-tls.sh
# Propósito: Encapsular a função `runner_diagnose_tls_failure` de _runner.sh
#            como specialist standalone, com dois modos:
#
#   --pre-flight   Diagnóstico proativo do ambiente: env proxy, CAs custom,
#                  DNS de api.github.com (seções [2], [3], [4] parciais
#                  do diagnóstico completo). NÃO requer log do runner;
#                  pode rodar ANTES de tentar registrar.
#                  Usado pelo doctor para validar prerequisitos de TLS.
#
#   --reactive [RUNNER_DIR]  Diagnóstico completo (6 seções) invocado
#                  quando `runner_register` falha. Lê o log mais recente
#                  em RUNNER_DIR/_diag/Runner_*.log, extrai a URL alvo,
#                  emite triagem e teste de alcance direto.
#                  Default RUNNER_DIR=$HOME/actions-runner.
#
# Uso (standalone — pre-flight):
#   bash scripts/deploy_server/check-runner-tls.sh --pre-flight
#
# Uso (standalone — reactive, debug pós-falha):
#   bash scripts/deploy_server/check-runner-tls.sh --reactive ~/actions-runner
#
# Uso (via doctor):
#   bash siscan-server-doctor.sh                          # roda todos
#   bash siscan-server-doctor.sh --only check-runner-tls  # roda apenas este
#
# Invocação automática:
#   `runner_register` em scripts/deploy_server/_runner.sh delega para este
#   specialist em caso de falha de config.sh — fallback gracioso para o
#   helper inline se o specialist não estiver presente.
#
# Exit code:
#   0  diagnóstico emitido (sempre rc=0 em modo human/best-effort)
#   2  uso inválido / RUNNER_DIR não existe
#
# Origem: TSK00.04.10 (#89) — refatorou helper `runner_diagnose_tls_failure`
# (que vivia inline em _runner.sh) para specialist próprio, mantendo o
# helper como fallback. Razões: descobribilidade via doctor, reaproveitamento
# em modo pre-flight, alinhamento com o padrão arquitetural dos demais
# specialists (check-network, check-runner, check-stack, etc.).
# -------------------------------------------

set -uo pipefail

SPECIALIST_NAME="check-runner-tls"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ────────────────────────────────────────────────────────────────────────────
# Source da biblioteca comum (cores, helpers de saída)
# ────────────────────────────────────────────────────────────────────────────
# shellcheck source=./_common.sh
source "$SCRIPT_DIR/_common.sh"

# Source do _runner.sh para reaproveitar runner_diagnose_tls_failure no
# modo --reactive. Sem isso teríamos que duplicar 234 linhas de lógica
# de extração de URL, triagem, redação de tokens, etc.
# shellcheck source=./_runner.sh
source "$SCRIPT_DIR/_runner.sh"

# ────────────────────────────────────────────────────────────────────────────
# Defaults específicos deste specialist
# ────────────────────────────────────────────────────────────────────────────
MODE=""
RUNNER_DIR="${RUNNER_DIR:-${HOME}/actions-runner}"

usage() {
    cat <<EOF
Uso: bash $(basename "$0") --pre-flight | --reactive [RUNNER_DIR]

Diagnóstico estruturado de TLS para o GitHub Actions self-hosted runner.

Modos:
  --pre-flight             Diagnóstico proativo do ambiente (sem log).
                           Seções [2] proxy env, [3] CAs custom, [4] DNS
                           de api.github.com. Usado em pre-setup, doctor
                           e debug preventivo.

  --reactive [RUNNER_DIR]  Diagnóstico completo pós-falha (6 seções).
                           Lê \$RUNNER_DIR/_diag/Runner_*.log mais recente,
                           extrai URL alvo, emite triagem e curl direto.
                           Default RUNNER_DIR=\${HOME}/actions-runner.

Opções:
  --quiet                  Suprime saída human (não-funcional aqui — o
                           diagnóstico TLS é human-only por design).
  --json                   Saída JSON-encapsulada (não-funcional aqui —
                           idem.) Reservado para futura extensão.
  -h, --help               Exibe esta ajuda

Exit code:
  0 = diagnóstico emitido (sempre — best-effort)
  2 = uso inválido / RUNNER_DIR não existe em modo --reactive

Exemplo (pre-flight):
  bash scripts/deploy_server/check-runner-tls.sh --pre-flight

Exemplo (reactive, debug pós-falha):
  bash scripts/deploy_server/check-runner-tls.sh --reactive ~/actions-runner

Especificação completa: TSK00.04.10 (#89)
EOF
}

# ────────────────────────────────────────────────────────────────────────────
# Parsing de args
# ────────────────────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --pre-flight)
            MODE="pre-flight"
            shift
            ;;
        --reactive)
            MODE="reactive"
            shift
            # RUNNER_DIR opcional após --reactive
            if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then
                RUNNER_DIR="$1"
                shift
            fi
            ;;
        --runner-dir)    RUNNER_DIR="${2:-}"; shift 2 ;;
        --runner-dir=*)  RUNNER_DIR="${1#*=}"; shift ;;
        -h|--help)       usage; exit 0 ;;
        *)
            if common_parse_arg "$@"; then shift "$shift_count"
            else echo "argumento desconhecido: $1" >&2; usage >&2; exit 2; fi
            ;;
    esac
done

# Sem modo explícito: assume --pre-flight (default seguro).
# Permite que o doctor invoque o specialist sem passar argumentos
# extras — mesmo padrão dos demais specialists.
if [ -z "$MODE" ]; then
    MODE="pre-flight"
fi

# ────────────────────────────────────────────────────────────────────────────
# Modo --pre-flight: diagnóstico proativo do ambiente (sem log do runner).
# Subset das seções [2], [3] e [4] (parcial — só api.github.com) do diagnóstico
# completo. Pode ser invocado a qualquer momento; ideal para validar TLS
# antes de tentar registrar o runner pela primeira vez.
# ────────────────────────────────────────────────────────────────────────────
_run_pre_flight() {
    {
        printf '\n══════════════════════════════════════════════════\n'
        printf '  CHECK-RUNNER-TLS — modo pre-flight\n'
        printf '══════════════════════════════════════════════════\n\n'

        # [2] Variáveis de proxy/http (com redação de credenciais)
        printf '[2] Variáveis de proxy/http:\n'
        local proxy_vars
        proxy_vars=$(env 2>/dev/null | grep -iE '^(http_proxy|https_proxy|no_proxy|all_proxy|ftp_proxy)=' | sort)
        if [ -n "$proxy_vars" ]; then
            printf '%s\n' "$proxy_vars" \
                | sed -E 's|(://)[^:@/]+:[^@/]+@|\1***:***@|g' \
                | sed 's/^/    /'
        else
            printf '    (nenhuma variável de proxy definida no ambiente)\n'
        fi
        printf '\n'

        # [3] CAs internas custom
        printf '[3] CAs custom em /usr/local/share/ca-certificates/:\n'
        if [ -d /usr/local/share/ca-certificates ]; then
            local ca_list
            ca_list=$(ls /usr/local/share/ca-certificates/ 2>/dev/null)
            if [ -n "$ca_list" ]; then
                printf '%s\n' "$ca_list" | sed 's/^/    /'
            else
                printf '    (diretório vazio — nenhuma CA custom instalada)\n'
            fi
        else
            printf '    (diretório não existe)\n'
        fi
        printf '\n'

        # [4] Resolução DNS de api.github.com — endpoint canônico
        printf '[4] Resolução DNS de api.github.com:\n'
        if command -v getent >/dev/null 2>&1; then
            local resolved
            resolved=$(getent hosts api.github.com 2>/dev/null)
            if [ -n "$resolved" ]; then
                printf '%s\n' "$resolved" | sed 's/^/    /'
            else
                printf '    (sem resposta — DNS pode estar bloqueado)\n'
            fi
        else
            printf '    (getent ausente — tente: dig api.github.com)\n'
        fi
        printf '\n'

        printf '══════════════════════════════════════════════════\n'
        printf '  FIM DO PRE-FLIGHT\n'
        printf '══════════════════════════════════════════════════\n\n'
        printf 'Para diagnóstico completo (após tentar registrar e falhar):\n'
        printf '  bash %s --reactive %s\n\n' "$(basename "$0")" "$RUNNER_DIR"
    } >&2
}

# ────────────────────────────────────────────────────────────────────────────
# Modo --reactive: diagnóstico completo pós-falha. Delega ao helper canônico
# em _runner.sh que mantém a lógica completa de 6 seções (TSK00.04.05/08).
# Mantém o helper em _runner.sh como fonte de verdade — specialist é wrapper
# que torna a função descobrível via doctor.
# ────────────────────────────────────────────────────────────────────────────
_run_reactive() {
    if [ ! -d "$RUNNER_DIR" ]; then
        printf 'erro: RUNNER_DIR não existe: %s\n' "$RUNNER_DIR" >&2
        printf 'forneça via --reactive <dir> ou --runner-dir <dir>.\n' >&2
        exit 2
    fi
    runner_diagnose_tls_failure "$RUNNER_DIR"
}

# ────────────────────────────────────────────────────────────────────────────
# Dispatch
# ────────────────────────────────────────────────────────────────────────────
case "$MODE" in
    pre-flight) _run_pre_flight ;;
    reactive)   _run_reactive ;;
    *)
        echo "erro interno: modo desconhecido '$MODE'" >&2
        exit 2
        ;;
esac

exit 0
