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
#   Precedência de credencial: gh CLI autenticado > GH_TOKEN > PAT.
#   Ecoa vazio se nenhuma fonte estiver disponível.
runner_query_api() {
    local owner="$1" repo="$2"
    local auth
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
        gh api "repos/$owner/$repo/actions/runners" 2>/dev/null || echo ""
        return 0
    fi
    auth="${GH_TOKEN:-${PAT:-}}"
    if [ -n "$auth" ]; then
        curl -s -H "Authorization: Bearer $auth" \
            "https://api.github.com/repos/$owner/$repo/actions/runners" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# runner_get_remove_token OWNER REPO
#   Gera um remove-token via POST /actions/runners/remove-token e ecoa o
#   valor do campo .token. Endpoint distinto do registration-token: o
#   GitHub exige token específico de remoção em ./config.sh remove.
#   Precedência de credencial: gh CLI autenticado > GH_TOKEN > PAT
#   (mesma do runner_query_api — operadora pode fornecer --pat no recover).
runner_get_remove_token() {
    local owner="$1" repo="$2"
    local response token auth
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
        response=$(gh api -X POST "repos/$owner/$repo/actions/runners/remove-token" 2>/dev/null || echo "")
    else
        auth="${GH_TOKEN:-${PAT:-}}"
        if [ -n "$auth" ]; then
            response=$(curl -fsS -X POST \
                -H "Authorization: Bearer $auth" \
                -H "Accept: application/vnd.github+json" \
                "https://api.github.com/repos/$owner/$repo/actions/runners/remove-token" 2>/dev/null || echo "")
        else
            echo ""
            return 0
        fi
    fi
    if command -v jq >/dev/null 2>&1; then
        token=$(printf '%s' "$response" | jq -r '.token // empty' 2>/dev/null)
    else
        token=$(printf '%s' "$response" | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    fi
    echo "$token"
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
        N/A|1|2)
            # Estados locais antecedem qualquer consulta remota.
            # N/A, 1, 2 → caller decide (bootstrap incremental).
            echo "$state"
            return 0
            ;;
        3)
            # state=3: binários + .runner presentes, sem systemd unit.
            # Issue #65: presunção de que .runner é válido era frágil quando
            # o runner foi auto-removido remotamente (>14d offline). O recover
            # caía em Cenário C (apenas install+start) e o serviço subia
            # localmente com credencial inválida — heartbeat 401 em loop.
            # Fix: consultar API antes de mapear; se total_count=0, redirecionar
            # para A2 (re-registro defensivo, cobre auto-removal).
            runners_json=$(runner_query_api "$owner" "$repo")
            if [ -n "$runners_json" ]; then
                if command -v jq >/dev/null 2>&1; then
                    total=$(printf '%s' "$runners_json" | jq -r '.total_count // empty' 2>/dev/null)
                else
                    total=$(printf '%s' "$runners_json" | sed -n 's/.*"total_count"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -1)
                fi
                if [ "$total" = "0" ]; then
                    echo "A2"
                    return 0
                fi
            elif [ "$has_token" = "true" ]; then
                # API indisponível mas operadora forneceu --token = sinal forte
                # de que ela já suspeita do auto-removal. Mesma heurística
                # defensiva do state=4 (linhas abaixo).
                echo "A2"
                return 0
            fi
            # API indisponível sem --token, OU total_count>0: comportamento
            # original (instalar systemd + start; .runner presumido válido).
            echo "C"
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
        # (re-registro). Observado em campo na <HOST-DASHBOARD> 26/05/2026.
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

# runner_remove_registration RUNNER_DIR OWNER REPO
#   Remove o registro do runner em três camadas, de cima pra baixo:
#     1. Se o runner já não existe remotamente (total_count=0), pula
#        config.sh remove — não há nada a desregistrar no GitHub.
#     2. Caso contrário, tenta obter remove-token via API (endpoint distinto
#        do registration-token) e usa ./config.sh remove --token <remove>.
#     3. Sempre encerra com `rm -f` dos arquivos locais de registro
#        (.runner, .credentials, .credentials_rsaparams). Idempotente.
#   Sem este fallback determinístico, registration-token passado a
#   config.sh remove falha em silêncio e deixa .runner órfão — quebra
#   o cenário A/A2 do recover com "Cannot configure the runner because it
#   is already configured" (issue #63).
#
#   Retorna 1 se .runner persistir em disco após a limpeza (caso raro de
#   permissão/IO); 0 nos demais casos (inclusive remove remoto falhar —
#   a limpeza local é suficiente pra destravar o re-registro).
runner_remove_registration() {
    local dir="$1" owner="$2" repo="$3"
    info "Removendo registro do runner..."

    # Camada 1: detectar estado remoto
    local remote_json remote_total remote_known="no"
    remote_json=$(runner_query_api "$owner" "$repo")
    if [ -n "$remote_json" ]; then
        remote_known="yes"
        if command -v jq >/dev/null 2>&1; then
            remote_total=$(printf '%s' "$remote_json" | jq -r '.total_count // empty' 2>/dev/null)
        else
            remote_total=$(printf '%s' "$remote_json" | sed -n 's/.*"total_count"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -1)
        fi
    fi

    if [ "$remote_known" = "yes" ] && [ "$remote_total" = "0" ]; then
        info "Runner já removido remotamente (total_count=0) — pulando config.sh remove"
    else
        # Camada 2: tentar remove-token via API
        local remove_token=""
        remove_token=$(runner_get_remove_token "$owner" "$repo")
        if [ -n "$remove_token" ]; then
            if (cd "$dir" && ./config.sh remove --token "$remove_token"); then
                ok "config.sh remove (com remove-token da API)"
            else
                warn "config.sh remove falhou mesmo com remove-token — caindo no fallback de limpeza local"
            fi
        else
            # Mensagem neutra: vazio pode vir de muitas causas (sem
            # credencial, token sem scope, rate limit, erro HTTP, rede).
            # Operador pode investigar; o fallback local destrava de qualquer forma.
            if [ "$remote_known" = "yes" ]; then
                warn "Não foi possível obter remove-token via API (gh CLI/GH_TOKEN/PAT, scope, rate limit ou HTTP) — caindo no fallback local"
            else
                warn "Não foi possível consultar estado remoto na API (gh CLI/GH_TOKEN/PAT, scope, rate limit ou HTTP) — caindo no fallback local"
            fi
        fi
    fi

    # Camada 3: limpeza local determinística (sempre executada)
    rm -f "$dir/.runner" "$dir/.credentials" "$dir/.credentials_rsaparams"
    if [ -f "$dir/.runner" ]; then
        printf "ERRO: não foi possível remover %s/.runner — verifique permissões.\n" "$dir" >&2
        return 1
    fi
    ok "Registro local removido (.runner + .credentials*)"
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
