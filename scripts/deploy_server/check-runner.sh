#!/usr/bin/env bash
# -------------------------------------------
# Specialist: check-runner
# Summary: Runner local + systemd + registro GitHub + idade (regras 14d/30d)
# -------------------------------------------
# Cobre estado completo do GitHub Actions self-hosted runner:
#   1. Instalação local (config.sh, .runner, _diag)
#   2. Serviço systemd ativo
#   3. Registro remoto via GitHub API (catch auto-removal de 14 dias)
#   4. Idade da última auto-atualização (catch regra dos 30 dias)
#
# Cenários que esse specialist detecta (todos vistos no chat do servidor parceiro):
#   - Runner nunca instalado nesta VM
#   - Runner instalado mas serviço parado
#   - Runner online mas removido remotamente (>14 dias offline)
#   - Runner online + registrado mas >30 dias sem atualizar (GitHub recusa jobs)
# -------------------------------------------

set -uo pipefail

SPECIALIST_NAME="check-runner"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=./_common.sh
source "$SCRIPT_DIR/_common.sh"

ENV_FILE="${COMPOSE_DIR:-$(pwd)}/.env"
PRODUCTS_FILE="${REPO_ROOT}/scripts/data/products.json"
RUNNER_DIR="${RUNNER_DIR:-${HOME}/actions-runner}"

usage() {
    cat <<EOF
Uso: bash $(basename "$0") [--env-file FILE] [--runner-dir DIR] [--quiet | --json] [--help]

Valida estado do GitHub Actions self-hosted runner — instalação local,
serviço, registro remoto e idade da última atualização (regra dos 30 dias).

Variáveis de ambiente opcionais:
  GH_TOKEN  Token com scope 'repo' (ou via 'gh auth status' configurado).
            Sem token, o check de registro remoto é pulado com aviso.

Exit code: 0 = OK · 1 = FAIL · 2 = uso inválido
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --env-file)    ENV_FILE="${2:-}"; shift 2 ;;
        --env-file=*)  ENV_FILE="${1#*=}"; shift ;;
        --runner-dir)  RUNNER_DIR="${2:-}"; shift 2 ;;
        --runner-dir=*) RUNNER_DIR="${1#*=}"; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)
            if common_parse_arg "$@"; then shift "$shift_count"
            else echo "argumento desconhecido: $1" >&2; usage >&2; exit 2; fi
            ;;
    esac
done

_read_env() {
    grep -E "^${1}=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | sed 's/^["'\'']\(.*\)["'\'']$/\1/'
}

require_commands curl jq

SISCAN_PRODUCT=""
[ -f "$ENV_FILE" ] && SISCAN_PRODUCT=$(_read_env SISCAN_PRODUCT)

# Dados do produto vêm do manifesto (substitui case hardcoded)
REPO_OWNER=""
REPO_NAME=""
EXPECTED_NAME=""
if [ -n "$SISCAN_PRODUCT" ]; then
    product_validate
    repo_full=$(product_get repo)
    REPO_OWNER="${repo_full%%/*}"
    REPO_NAME="${repo_full##*/}"
    suffix=$(product_get runner_name_suffix)
    EXPECTED_NAME="$(hostname)-${suffix}"
fi

CAT_LOCAL="Instalação local do runner"
CAT_SERVICE="Serviço systemd"
CAT_REMOTE="Registro remoto no GitHub"
CAT_AGE="Idade do runner (regra dos 30 dias)"

# ────────────────────────────────────────────────────────────────────────────
# 1. Instalação local
# ────────────────────────────────────────────────────────────────────────────
print_category_header "$CAT_LOCAL" "Arquivos binários + de registro do runner em \$HOME/actions-runner. Sem isso, o runner nunca foi configurado nesta VM."

if [ ! -d "$RUNNER_DIR" ]; then
    add_fail "$CAT_LOCAL" fs 0 "$RUNNER_DIR" "diretório não existe — rode siscan-server-setup.sh"
else
    [ -x "$RUNNER_DIR/config.sh" ] && add_ok "$CAT_LOCAL" fs 0 "config.sh" "presente" \
        || add_fail "$CAT_LOCAL" fs 0 "config.sh" "ausente — binários do runner não extraídos"

    if [ -f "$RUNNER_DIR/.runner" ]; then
        registered_at=$(stat -c '%y' "$RUNNER_DIR/.runner" 2>/dev/null | cut -d'.' -f1)
        add_ok "$CAT_LOCAL" fs 0 ".runner" "registrado em $registered_at"
    else
        add_fail "$CAT_LOCAL" fs 0 ".runner" "ausente — runner nunca foi registrado"
    fi
fi

# ────────────────────────────────────────────────────────────────────────────
# 2. Serviço systemd
# ────────────────────────────────────────────────────────────────────────────
print_category_header "$CAT_SERVICE" "O runner roda como serviço systemd (actions.runner.*). Se inactive, o runner não está pegando jobs."

if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-units --type=service 'actions.runner.*' --no-legend 2>/dev/null | grep -q .; then
        svc=$(systemctl list-units --type=service 'actions.runner.*' --no-legend 2>/dev/null | head -1 | awk '{print $1}')
        state=$(systemctl is-active "$svc" 2>/dev/null)
        if [ "$state" = "active" ]; then
            add_ok "$CAT_SERVICE" systemd 0 "$svc" "active"
        else
            add_fail "$CAT_SERVICE" systemd 0 "$svc" "estado: $state — sudo systemctl start $svc"
        fi
    else
        add_fail "$CAT_SERVICE" systemd 0 "actions.runner.*" "nenhum serviço encontrado — rode sudo \$RUNNER_DIR/svc.sh install"
    fi
else
    warn "systemctl não disponível — pulando check de serviço (provável WSL/container)"
fi

# ────────────────────────────────────────────────────────────────────────────
# 3. Registro remoto no GitHub
# ────────────────────────────────────────────────────────────────────────────
print_category_header "$CAT_REMOTE" "Mesmo com arquivos locais OK, o GitHub pode ter removido o runner após 14 dias offline (auto-removal). Sem registro remoto, o runner não recebe jobs."

if [ -z "$REPO_NAME" ]; then
    warn "SISCAN_PRODUCT não definido no .env — não dá pra inferir nome do repo, pulando check remoto"
elif ! command -v gh >/dev/null 2>&1 && [ -z "${GH_TOKEN:-}" ]; then
    warn "gh CLI ausente e GH_TOKEN não setado — pulando check remoto (defina GH_TOKEN ou instale gh)"
else
    # Tenta usar gh CLI; fallback pra curl com GH_TOKEN
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
        runners_json=$(gh api "repos/$REPO_OWNER/$REPO_NAME/actions/runners" 2>/dev/null || echo "")
    elif [ -n "${GH_TOKEN:-}" ]; then
        runners_json=$(curl -s -H "Authorization: Bearer $GH_TOKEN" \
            "https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/actions/runners" 2>/dev/null || echo "")
    else
        warn "gh auth status falhou e GH_TOKEN não setado — pulando check remoto"
        runners_json=""
    fi

    if [ -n "$runners_json" ]; then
        total=$(echo "$runners_json" | jq -r '.total_count // 0')
        if [ "$total" -eq 0 ]; then
            add_fail "$CAT_REMOTE" api 0 "API GitHub" "total_count=0 — runner AUTO-REMOVIDO após 14d offline; rode siscan-runner-recover.sh"
        else
            match=$(echo "$runners_json" | jq -r ".runners[] | select(.name == \"$EXPECTED_NAME\") | .status" | head -1)
            if [ -z "$match" ]; then
                # Existem runners mas nenhum com o nome esperado
                names=$(echo "$runners_json" | jq -r '.runners[].name' | paste -sd, -)
                add_fail "$CAT_REMOTE" api 0 "runner '$EXPECTED_NAME'" "não encontrado (registrados: $names)"
            elif [ "$match" = "online" ]; then
                add_ok "$CAT_REMOTE" api 0 "runner '$EXPECTED_NAME'" "online"
            else
                add_fail "$CAT_REMOTE" api 0 "runner '$EXPECTED_NAME'" "status remoto: $match"
            fi
        fi
    fi
fi

# ────────────────────────────────────────────────────────────────────────────
# 4. Idade do runner — regra dos 30 dias
# ────────────────────────────────────────────────────────────────────────────
print_category_header "$CAT_AGE" "Se o runner ficou >30 dias sem auto-atualizar, o GitHub para de enviar jobs (sintoma: 'Waiting for a runner' indefinido, descoberto no chat do servidor parceiro 25/05)."

# Sinal mais confiável: mtime do .runner_migrated (atualizado a cada upgrade do runner)
# Fallback: mtime do log mais recente em _diag/
# Pior caso: mtime do .runner original (só pega data do primeiro registro)
age_source=""
age_file=""

if [ -f "$RUNNER_DIR/.runner_migrated" ]; then
    age_file="$RUNNER_DIR/.runner_migrated"
    age_source="último upgrade (.runner_migrated)"
elif [ -d "$RUNNER_DIR/_diag" ]; then
    age_file=$(ls -t "$RUNNER_DIR/_diag"/Runner_*.log 2>/dev/null | head -1)
    [ -n "$age_file" ] && age_source="último log em _diag/"
elif [ -f "$RUNNER_DIR/.runner" ]; then
    age_file="$RUNNER_DIR/.runner"
    age_source="data de registro (.runner — proxy)"
fi

if [ -z "$age_file" ] || [ ! -e "$age_file" ]; then
    warn "não foi possível determinar idade do runner — runner provavelmente nunca foi instalado"
else
    age_epoch=$(stat -c '%Y' "$age_file" 2>/dev/null || echo 0)
    now_epoch=$(date +%s)
    age_days=$(( (now_epoch - age_epoch) / 86400 ))

    if [ "$age_days" -lt 25 ]; then
        add_ok "$CAT_AGE" age 0 "última atualização" "$age_days dia(s) ($age_source) — dentro da janela segura"
    elif [ "$age_days" -lt 30 ]; then
        # Janela de aviso preventivo — não é FAIL, GitHub ainda envia jobs.
        # FAIL só ≥ 30 dias quando a regra realmente bloqueia.
        add_ok "$CAT_AGE" age 0 "última atualização" "$age_days dia(s) (warn) — faltam $((30 - age_days)) dia(s) pro GitHub parar de enviar jobs; rode 'sudo -u siscan ./run.sh --check' preventivamente"
    else
        add_fail "$CAT_AGE" age 0 "última atualização" "$age_days dia(s) — REGRA DOS 30 DIAS ATIVA: GitHub não envia mais jobs até o runner se atualizar; rode 'siscan-runner-recover.sh'"
    fi
fi

# ────────────────────────────────────────────────────────────────────────────
# Veredito por categoria — sem JSON externo (essa lógica é específica do specialist)
# ────────────────────────────────────────────────────────────────────────────
# Como os checks são heterogêneos, dou um veredito global simples.
if [ "$FAIL_COUNT" -eq 0 ]; then
    print_category_guidance ok "Runner saudável: instalado, ativo, registrado no GitHub, atualizado recentemente. Próximo passo: nada — o runner pega jobs normalmente."
else
    print_category_guidance fail "Pelo menos um aspecto do runner está com problema. AÇÃO: dependendo do FAIL acima, rode 'siscan-runner-recover.sh' (cobre auto-removal e regra dos 30 dias) ou 'siscan-server-setup.sh' (se runner nunca foi instalado)."
fi

render_results
finalize_exit
