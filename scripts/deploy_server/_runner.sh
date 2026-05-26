#!/usr/bin/env bash
# -------------------------------------------
# _runner.sh — Biblioteca idempotente do GitHub Actions self-hosted runner
# -------------------------------------------
# Arquivo: scripts/deploy_server/_runner.sh
# Propósito: funções de detecção e ação compartilhadas entre
#            siscan-server-setup.sh (Fase 7) e siscan-runner-recover.sh.
#            Single-source-of-truth pra manipulação do runner.
#
# Sourcing:
#   source "$(dirname "${BASH_SOURCE[0]}")/_runner.sh"
#
# Convenções:
#   - Detecção (read-only): funções `runner_get_*`, `runner_validate_*`,
#     `runner_*_present`, `runner_*_active` ecoam valores ou retornam 0/1
#     sem side-effects.
#   - Ações (mutadoras): `runner_download_binaries`, `runner_register`,
#     `runner_*_service`, `runner_remove_registration` retornam 0 em
#     sucesso e !=0 em falha; logam progresso via ok()/info()/warn() do
#     caller (não chamam fail/exit — caller decide).
#
# Pré-condições do caller:
#   - ok(), info(), warn() definidos (compatíveis com _common.sh ou com os
#     helpers locais do siscan-server-setup.sh).
#   - $RUNNER_DIR é parâmetro explícito (não lido de variável global).
#
# Não deve ter side-effects quando sourceado.
# -------------------------------------------

# Guard contra source duplicado (idempotência)
[ -n "${_RUNNER_SH_LOADED:-}" ] && return 0
_RUNNER_SH_LOADED=1

# ════════════════════════════════════════════════════════════════════════════
# Detecção — read-only (ecoam valores, retornam 0/1)
# ════════════════════════════════════════════════════════════════════════════

# runner_validate_binaries RUNNER_DIR
#   Retorna 0 se config.sh e svc.sh presentes e executáveis.
runner_validate_binaries() {
    local dir="$1"
    [ -x "$dir/config.sh" ] && [ -x "$dir/svc.sh" ]
}

# runner_validate_dot_runner RUNNER_DIR
#   Retorna 0 se .runner existe (sinal de runner já registrado no GitHub).
runner_validate_dot_runner() {
    local dir="$1"
    [ -f "$dir/.runner" ]
}

# runner_unit_name RUNNER_DIR
#   Ecoa o nome da systemd unit associada a este RUNNER_DIR, ou vazio se
#   não houver. O svc.sh do GitHub grava o nome da unit (ex.:
#   'actions.runner.OWNER-REPO.NAME.service') no marker `$dir/.service`
#   durante `svc.sh install`. Esse marker é o único vínculo confiável
#   entre um diretório de runner e sua unit específica em hosts com
#   múltiplos runners.
runner_unit_name() {
    local dir="$1"
    [ -f "$dir/.service" ] || { echo ""; return 0; }
    tr -d '[:space:]' < "$dir/.service" 2>/dev/null
}

# runner_systemd_present RUNNER_DIR
#   Retorna 0 se a systemd unit *deste* RUNNER_DIR está instalada.
#   Usa o marker `$dir/.service` (escrito por `svc.sh install`) — em VMs
#   com múltiplos runners, isso garante que detectemos só a unit do dir
#   passado, não qualquer `actions.runner.*.service` do host.
runner_systemd_present() {
    local dir="$1"
    command -v systemctl >/dev/null 2>&1 || return 1
    local unit
    unit=$(runner_unit_name "$dir")
    [ -n "$unit" ] || return 1
    systemctl list-unit-files "$unit" --no-legend 2>/dev/null | grep -q .
}

# runner_systemd_active RUNNER_DIR
#   Retorna 0 se a unit *deste* RUNNER_DIR está com state=active.
runner_systemd_active() {
    local dir="$1"
    command -v systemctl >/dev/null 2>&1 || return 1
    local unit
    unit=$(runner_unit_name "$dir")
    [ -n "$unit" ] || return 1
    [ "$(systemctl is-active "$unit" 2>/dev/null)" = "active" ]
}

# runner_get_state RUNNER_DIR
#   Ecoa o estado da instalação local:
#     N/A  - diretório RUNNER_DIR não existe
#     1    - dir existe mas binários (config.sh/svc.sh) ausentes
#     2    - binários presentes, .runner ausente (registro não feito)
#     3    - binários + .runner presentes, systemd unit ausente
#     4    - tudo presente (caller pode usar runner_systemd_active pra
#            distinguir 4-ativo de 4-inativo)
runner_get_state() {
    local dir="$1"
    if [ ! -d "$dir" ]; then
        echo "N/A"; return 0
    fi
    if ! runner_validate_binaries "$dir"; then
        echo "1"; return 0
    fi
    if ! runner_validate_dot_runner "$dir"; then
        echo "2"; return 0
    fi
    if ! runner_systemd_present "$dir"; then
        echo "3"; return 0
    fi
    echo "4"
}

# runner_local_age_days RUNNER_DIR
#   Ecoa idade em dias da última auto-atualização do runner.
#   Prioridade: .runner_migrated > _diag/Runner_*.log > .runner.
#   Ecoa 999 se não conseguiu determinar.
runner_local_age_days() {
    local dir="$1"
    local age_file=""
    if [ -f "$dir/.runner_migrated" ]; then
        age_file="$dir/.runner_migrated"
    elif [ -d "$dir/_diag" ]; then
        age_file=$(ls -t "$dir/_diag"/Runner_*.log 2>/dev/null | head -1)
    elif [ -f "$dir/.runner" ]; then
        age_file="$dir/.runner"
    fi
    if [ -z "$age_file" ] || [ ! -e "$age_file" ]; then
        echo 999; return 0
    fi
    local age_epoch now_epoch
    age_epoch=$(stat -c '%Y' "$age_file" 2>/dev/null || echo 0)
    now_epoch=$(date +%s)
    echo $(( (now_epoch - age_epoch) / 86400 ))
}

# runner_query_api OWNER REPO
#   Ecoa o JSON de repos/OWNER/REPO/actions/runners (resposta da API).
#   Usa gh CLI se autenticado; senão curl com GH_TOKEN; senão ecoa vazio.
runner_query_api() {
    local owner="$1" repo="$2"
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
        gh api "repos/$owner/$repo/actions/runners" 2>/dev/null || echo ""
    elif [ -n "${GH_TOKEN:-}" ]; then
        curl -s -H "Authorization: Bearer $GH_TOKEN" \
            "https://api.github.com/repos/$owner/$repo/actions/runners" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# runner_diagnose RUNNER_DIR EXPECTED_NAME OWNER REPO [HAS_TOKEN_ARG]
#   Detecta o cenário cruzando estado local + remoto.
#   HAS_TOKEN_ARG (opcional, "true"|"false"): se "true", força UNKNOWN→A2
#   quando a API não está disponível mas a operadora forneceu --token
#   (re-registro defensivo).
#   Ecoa: N/A|1|2|C|A|A2|B|WARN|OK|UNKNOWN
runner_diagnose() {
    local dir="$1" expected_name="$2" owner="$3" repo="$4"
    local has_token="${5:-false}"
    local state age_days runners_json total remote_status

    state=$(runner_get_state "$dir")
    case "$state" in
        N/A|1|2|3)
            # Estados locais antecedem qualquer consulta remota.
            # N/A, 1, 2 → caller decide (bootstrap incremental).
            # 3        → cenário C (serviço ausente; .runner válido).
            case "$state" in
                3) echo "C" ;;
                *) echo "$state" ;;
            esac
            return 0
            ;;
    esac

    # state=4: tudo local presente, decidir entre A/A2/B/WARN/OK via API + idade
    age_days=$(runner_local_age_days "$dir")
    runners_json=$(runner_query_api "$owner" "$repo")

    if [ -z "$runners_json" ]; then
        # Precedência: --token (operadora forneceu = sinal forte de auto-removal
        # suspeito) > idade ≥30d > faixa de aviso 25-29d > UNKNOWN.
        # Fix #53/Bug 1: antes, idade 25-29d vencia o has_token e ignorava o
        # --token fornecido, fazendo cair em WARN (run.sh --check) em vez de A2
        # (re-registro). Observado em campo na VMPRDAPP-RPADASHBOARD 26/05/2026.
        if [ "$has_token" = "true" ]; then
            echo "A2"; return 0
        elif [ "$age_days" -ge 30 ]; then
            echo "B"; return 0
        elif [ "$age_days" -ge 25 ]; then
            echo "WARN"; return 0
        else
            echo "UNKNOWN"; return 0
        fi
    fi

    total=$(echo "$runners_json" | jq -r '.total_count // 0')
    if [ "$total" -eq 0 ]; then
        echo "A"; return 0
    fi

    remote_status=$(echo "$runners_json" | jq -r ".runners[] | select(.name == \"$expected_name\") | .status" | head -1)
    if [ -z "$remote_status" ] || [ "$remote_status" = "offline" ]; then
        echo "A2"; return 0
    fi

    # Runner online na API — só pode ser B/WARN/OK pela idade
    if [ "$age_days" -ge 30 ]; then
        echo "B"
    elif [ "$age_days" -ge 25 ]; then
        echo "WARN"
    else
        echo "OK"
    fi
}

# ════════════════════════════════════════════════════════════════════════════
# Ações — mutadoras (retornam 0 em sucesso, !=0 em falha)
# ════════════════════════════════════════════════════════════════════════════

# runner_download_binaries RUNNER_DIR
#   Detecta arquitetura, consulta versão mais recente, baixa e extrai.
#   Retorna 1 em erro de arch/rede/extração.
runner_download_binaries() {
    local dir="$1"
    local arch runner_arch version url tarball
    arch=$(uname -m)
    case "$arch" in
        x86_64)  runner_arch="x64" ;;
        aarch64) runner_arch="arm64" ;;
        *) printf "Arquitetura não suportada pelo runner: %s\n" "$arch" >&2; return 1 ;;
    esac
    info "Arquitetura: $arch → linux-$runner_arch"
    info "Consultando versão mais recente do runner..."
    version=$(curl -fsSL \
        "https://api.github.com/repos/actions/runner/releases/latest" 2>/dev/null \
        | grep '"tag_name"' \
        | sed 's/.*"v\([^"]*\)".*/\1/' \
        | head -1)
    if [ -z "$version" ]; then
        printf "Não foi possível obter a versão do runner. Verifique conectividade com github.com.\n" >&2
        return 1
    fi
    info "Versão: $version"
    mkdir -p "$dir"
    tarball="$dir/actions-runner-linux-${runner_arch}-${version}.tar.gz"
    url="https://github.com/actions/runner/releases/download/v${version}/actions-runner-linux-${runner_arch}-${version}.tar.gz"
    info "Baixando runner em $tarball..."
    if ! curl -fsSL --progress-bar -o "$tarball" "$url"; then
        rm -f "$tarball"
        printf "Falha ao baixar o runner. Verifique a conectividade.\n" >&2
        return 1
    fi
    info "Extraindo em $dir..."
    if ! tar xzf "$tarball" -C "$dir"; then
        rm -f "$tarball"
        printf "Falha ao extrair tarball do runner.\n" >&2
        return 1
    fi
    rm -f "$tarball"
    ok "Runner extraído (versão $version)"
}

# runner_register RUNNER_DIR URL TOKEN NAME LABEL
#   Registra o runner via config.sh --token. Usa --unattended --replace
#   (idempotente quanto a nome+label).
runner_register() {
    local dir="$1" url="$2" token="$3" name="$4" label="$5"
    [ -n "$token" ] || { printf "Token vazio — abortando registro.\n" >&2; return 1; }
    info "Registrando runner (name=$name, label=$label)..."
    if ! (cd "$dir" && ./config.sh \
            --url "$url" \
            --token "$token" \
            --labels "$label" \
            --name "$name" \
            --unattended \
            --replace); then
        printf "Falha ao registrar o runner. Verifique URL e token (tokens expiram em poucos minutos).\n" >&2
        return 1
    fi
    ok "Runner registrado: $name [$label]"
}

# runner_install_service RUNNER_DIR USER
#   Instala o systemd unit do runner como serviço para USER.
runner_install_service() {
    local dir="$1" user="$2"
    info "Instalando runner como serviço systemd (usuário: $user)..."
    if ! sudo bash -c "cd '$dir' && ./svc.sh install '$user'"; then
        printf "Falha ao instalar serviço systemd.\n" >&2
        return 1
    fi
    ok "svc.sh install"
}

# runner_start_service RUNNER_DIR
runner_start_service() {
    local dir="$1"
    info "Iniciando serviço do runner..."
    if ! sudo bash -c "cd '$dir' && ./svc.sh start"; then
        printf "Falha ao iniciar serviço do runner.\n" >&2
        return 1
    fi
    ok "svc.sh start"
}

# runner_stop_service RUNNER_DIR
#   Idempotente — warn (não fail) se já estava parado/ausente.
runner_stop_service() {
    local dir="$1"
    info "Parando serviço do runner..."
    if sudo bash -c "cd '$dir' && ./svc.sh stop" 2>/dev/null; then
        ok "svc.sh stop"
    else
        warn "svc.sh stop (já parado ou serviço ausente?)"
    fi
}

# runner_uninstall_service RUNNER_DIR
#   Idempotente — warn se já estava desinstalado.
runner_uninstall_service() {
    local dir="$1"
    info "Desinstalando serviço systemd..."
    if sudo bash -c "cd '$dir' && ./svc.sh uninstall" 2>/dev/null; then
        ok "svc.sh uninstall"
    else
        warn "svc.sh uninstall (já desinstalado?)"
    fi
}

# runner_remove_registration RUNNER_DIR TOKEN
#   Remove o registro local via config.sh remove. Idempotente quanto a
#   404 (runner já foi auto-removido pelo GitHub).
runner_remove_registration() {
    local dir="$1" token="$2"
    info "Removendo registro local (config.sh remove)..."
    if (cd "$dir" && ./config.sh remove --token "$token") 2>/dev/null; then
        ok "config remove"
    else
        warn "config remove (404 esperado se runner já foi auto-removido)"
    fi
}

# runner_service_status_active RUNNER_DIR
#   Retorna 0 se 'svc.sh status' reporta active/running.
#   Usado por callers que querem checar antes de tentar install+start.
runner_service_status_active() {
    local dir="$1"
    local status_output
    status_output=$(sudo "$dir/svc.sh" status 2>/dev/null || true)
    echo "$status_output" | grep -qi "active\|running"
}
