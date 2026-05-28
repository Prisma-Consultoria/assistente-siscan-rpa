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
#   Retorna 0 se a instalação do runner está COMPLETA o suficiente pra
#   register/install/start funcionarem. Checa quatro artefatos:
#
#     - config.sh        — launcher do registro (raiz do RUNNER_DIR)
#     - svc.sh           — launcher do systemd unit (raiz)
#     - bin/Runner.Listener — runtime .NET que config.sh exec'a
#     - externals/       — runtime de actions (node*/bin/node)
#
#   Antes do hotfix (lab 2026-05-27, F00.04), a função checava apenas
#   config.sh + svc.sh. Resultado: `rm -rf bin/ externals/` (workaround
#   clássico pra forçar re-download) deixava o classificador em state 2
#   ("binários presentes"), pulando runner_download_binaries — mas
#   config.sh quebrava em seguida com `./bin/Runner.Listener: No such
#   file or directory`. Checar o entry-point real fecha esse buraco.
#
#   Mantém-se shallow no nome — não valida versão/idade dos binários.
#   Esse caso (binários completos mas obsoletos) é coberto pela
#   auto-detecção da TSK00.04.02 e pela flag --force-download-binaries
#   da TSK00.04.01.
runner_validate_binaries() {
    local dir="$1"
    [ -x "$dir/config.sh" ]           || return 1
    [ -x "$dir/svc.sh" ]              || return 1
    [ -x "$dir/bin/Runner.Listener" ] || return 1
    [ -d "$dir/externals" ]           || return 1
    return 0
}

# runner_binaries_likely_obsolete RUNNER_DIR [THRESHOLD_DAYS]
#   Heurística mtime-based para sinalizar que os binários do runner
#   podem estar fora da janela de TLS suportada por api.github.com.
#
#   Retorna 0 (= obsoleto) se mtime de bin/Runner.Listener é mais antigo
#   que THRESHOLD_DAYS dias. Retorna 1 (= fresco ou indeterminado) caso
#   contrário, ou se o arquivo não existe.
#
#   Resolução do threshold (precedência decrescente):
#     1. Argumento posicional THRESHOLD_DAYS (se passado e não-vazio)
#     2. Variável de ambiente RUNNER_OBSOLETE_DAYS
#     3. Default 30
#
#   Critério adotado em TSK00.04.02 (opção A — mtime, ver comentário
#   da issue para análise de A/B/C/D com prós e contras). Default 30d
#   ancorado na evidência operacional do lab 2026-05-27: Runner.Listener
#   com mtime de ~36d falhou TLS handshake mesmo com curl do sistema OK.
#
#   Limitações conscientes:
#     - mtime é proxy imperfeito: rsync -t, cp -p, tar --preserve-times,
#       e restore de snapshot preservam o mtime original → falso positivo
#       em VMs restauradas
#     - Falso positivo custa 1 download extra (~50MB, ~30s) — idempotente
#     - Falso negativo se algum processo `touch`-ou o arquivo recentemente
#
#   Escapes operacionais:
#     - Flag --force-download-binaries (TSK00.04.01) override total
#     - Env RUNNER_OBSOLETE_DAYS pra ajustar threshold sem code change
runner_binaries_likely_obsolete() {
    local dir="$1"
    local threshold="${2:-${RUNNER_OBSOLETE_DAYS:-30}}"
    local file="$dir/bin/Runner.Listener"
    [ -f "$file" ] || return 1
    local mtime now age_days
    mtime=$(stat -c %Y "$file" 2>/dev/null) || return 1
    now=$(date +%s)
    age_days=$(( (now - mtime) / 86400 ))
    [ "$age_days" -gt "$threshold" ]
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
    # Invocar installdependencies.sh + ldd validation imediatamente após
    # cada extração (TSK00.04.04). Falha não-fatal — operador pode seguir
    # e tentar register; se quebrar em TLS, fica claro pela mensagem de
    # erro embutida nessas funções.
    runner_install_runtime_deps "$dir" || true
    runner_verify_runtime_deps "$dir" || true
}

# runner_install_runtime_deps RUNNER_DIR
#   Invoca o installdependencies.sh do tarball oficial do runner para
#   instalar pacotes do SO (libssl, libicu, libkrb5, libcrypto...) que o
#   .NET embarcado no runner precisa para TLS handshake com api.github.com.
#
#   Idempotente: apt/yum/dnf skip pacotes já presentes na versão correta.
#   Requer sudo — coerente com requisitos de svc.sh install (systemd) e
#   demais operações privilegiadas do setup.
#
#   Retorna 0 se:
#     - installdependencies.sh ausente (runner muito antigo ou tarball
#       customizado) — degradação suave, operador segue e descobre via
#       config.sh se algo quebrar
#     - installdependencies.sh rodou com sucesso
#   Retorna 1 se installdependencies.sh existe mas falhou.
#
#   Lab 2026-05-27 (TSK00.04.04 #80) evidenciou: VM operacional rodava
#   binários LATEST do runner (v2.334.0 baixados in-place via ramo 1) e
#   ainda assim config.sh falhava com "SSL connection could not be
#   established". Recover/setup atuais nunca invocavam installdependencies
#   — operador descobria via diagnóstico manual (ldd) num caso por caso.
runner_install_runtime_deps() {
    local dir="$1"
    local script="$dir/bin/installdependencies.sh"
    if [ ! -x "$script" ]; then
        # Runner pré-2.x ou tarball customizado — nada a fazer; não é
        # erro do nosso lado. Operador descobrirá no register se houver
        # dep faltando.
        return 0
    fi
    info "Instalando runtime deps do SO (libssl/libicu/libkrb5) via installdependencies.sh — requer sudo..."
    # Silenciamos stdout pra não poluir log do recover com progresso verboso
    # do apt/yum/dnf ("Reading package lists...", etc.), mas mantemos stderr
    # visível: quando o install falha em ambiente restritivo (sem rede, proxy
    # apt quebrado, repositório indisponível, sudo sem permissão), o motivo
    # real vai pro stderr do apt — operador precisa ver pra remediar.
    if sudo "$script" >/dev/null; then
        ok "Runtime deps do SO instaladas/validadas"
        return 0
    fi
    warn "installdependencies.sh falhou — config.sh pode quebrar em TLS handshake."
    warn "  Mensagem de erro acima (stderr do apt/yum/dnf) indica a causa."
    return 1
}

# runner_verify_runtime_deps RUNNER_DIR
#   Roda ldd em bin/Runner.Listener procurando por "not found" — sinal
#   de biblioteca dinâmica linkada no .NET embarcado mas ausente no SO.
#
#   Retorna 0 se nenhuma lib faltando OU se ldd indisponível (a verificação
#   é best-effort; ausência de ldd não bloqueia operação).
#   Retorna 1 se libs faltando — imprime lista no stderr pra o operador
#   poder agir (ex.: apt install libssl3 libicu70).
runner_verify_runtime_deps() {
    local dir="$1"
    local binary="$dir/bin/Runner.Listener"
    [ -x "$binary" ] || return 0
    command -v ldd >/dev/null 2>&1 || return 0
    local missing
    missing=$(ldd "$binary" 2>&1 | grep "not found" || true)
    if [ -n "$missing" ]; then
        printf "AVISO: bibliotecas dinâmicas requeridas pelo Runner.Listener não encontradas:\n%s\n" "$missing" >&2
        printf "  Tente: sudo %s/bin/installdependencies.sh\n" "$dir" >&2
        return 1
    fi
    return 0
}

# runner_diagnose_tls_failure RUNNER_DIR
#   Coleta e emite um bloco de diagnóstico estruturado quando o
#   config.sh do runner falha no TLS handshake. Best-effort — sempre
#   retorna 0; quaisquer comandos auxiliares ausentes (getent, ldd,
#   ls de dir inexistente) são tratados graciosamente.
#
#   Output em stderr (não polui stdout / JSON envelope do _common.sh).
#   Cinco seções:
#     [1] tail -100 do _diag/Runner_*.log mais recente (a exception real
#         do .NET com URL alvo, código de erro, stack trace)
#     [2] env vars de proxy/http (HTTPS_PROXY pode afetar .NET)
#     [3] CAs internas em /usr/local/share/ca-certificates/ (proxy MITM
#         precisa instalar root CA aqui pra .NET confiar)
#     [4] resolução de api.github.com (DNS / IPv6 corporativo)
#     [5] triagem orientativa baseada em padrões conhecidos do .NET
#         encontrados no log da seção [1]
#
#   Origem: lab #220 (2026-05-27/28) perdeu múltiplas rodadas operacionais
#   coletando esses 4 sinais manualmente. Ver TSK00.04.05 (#82).
runner_diagnose_tls_failure() {
    local dir="$1"
    {
        printf '\n══════════════════════════════════════════════════\n'
        printf '  DIAGNÓSTICO TLS — config.sh falhou no handshake\n'
        printf '══════════════════════════════════════════════════\n\n'

        # [1] Exception detalhada do .NET (a fonte da verdade)
        local latest_log=""
        if [ -d "$dir/_diag" ]; then
            latest_log=$(ls -t "$dir/_diag"/Runner_*.log 2>/dev/null | head -1)
        fi
        if [ -n "$latest_log" ] && [ -f "$latest_log" ]; then
            printf '[1] Exception detalhada (últimas 100 linhas de %s):\n\n' \
                "$(basename "$latest_log")"
            tail -100 "$latest_log" 2>/dev/null | sed 's/^/    /' || true
            printf '\n'
        else
            printf '[1] Nenhum log em %s/_diag/ — runner pode não ter chegado a inicializar.\n\n' "$dir"
        fi

        # [2] Variáveis de proxy
        printf '[2] Variáveis de proxy/http:\n'
        local proxy_vars
        proxy_vars=$(env 2>/dev/null | grep -iE '^(http_proxy|https_proxy|no_proxy|all_proxy|ftp_proxy)=' | sort)
        if [ -n "$proxy_vars" ]; then
            printf '%s\n' "$proxy_vars" | sed 's/^/    /'
        else
            printf '    (nenhuma variável de proxy definida no ambiente)\n'
        fi
        printf '\n'

        # [3] CAs internas custom (proxy MITM, CA corporativa)
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

        # [4] Resolução de api.github.com
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

        # [5] Triagem por padrões conhecidos do .NET no log
        if [ -n "$latest_log" ] && [ -f "$latest_log" ]; then
            local triage_emitted=""
            printf '[5] Triagem (padrões conhecidos do .NET detectados no log):\n'
            if grep -qiE 'AuthenticationException|X509|certificate' "$latest_log" 2>/dev/null; then
                printf '    ⚠ Sinal de CA bundle (cert/X509 inválido pro .NET).\n'
                printf '      → Adicione a CA do proxy/corporativa em /usr/local/share/\n'
                printf '        ca-certificates/ + sudo update-ca-certificates.\n'
                triage_emitted="yes"
            fi
            if grep -qiE 'NameResolution|host not known|host.*unreachable|network.*unreachable' "$latest_log" 2>/dev/null; then
                printf '    ⚠ Sinal de DNS / IPv6 bloqueado.\n'
                printf '      → Verifique resolução acima [4]; considere desabilitar\n'
                printf '        IPv6 ou configurar DNS resolver confiável.\n'
                triage_emitted="yes"
            fi
            if grep -qi 'proxy' "$latest_log" 2>/dev/null; then
                printf '    ⚠ Sinal de proxy (.NET respeitando HTTPS_PROXY).\n'
                printf '      → Tente bypass: HTTPS_PROXY="" ./config.sh ...\n'
                triage_emitted="yes"
            fi
            # Sinal de firewall/proxy MITM interrompendo o handshake — peer
            # fecha conexão DURANTE o handshake (TCP RST/FIN), antes de
            # qualquer validação de certificado. Padrão canônico do .NET
            # quando o destino é bloqueado por middlebox de rede.
            # Lab #220 (2026-05-28) revelou esse padrão pra
            # pipelinesghubeus6.actions.githubusercontent.com — variante
            # regional que estava fora do whitelist do firewall corporativo
            # (que só cobria o endpoint base "pipelines.actions.github
            # usercontent.com"). Ver TSK00.04.05 #82.
            if grep -qiE 'Received an unexpected EOF|0 bytes from the transport stream' "$latest_log" 2>/dev/null; then
                printf '    ⚠ Sinal de firewall/proxy interrompendo TLS handshake (peer fechou conexão).\n'
                printf '      Distinto de CA bundle: o erro acontece ANTES da validação de certificado.\n'
                # Extrai o URL/host que falhou da mensagem canônica do .NET:
                # "GET request to <URL> failed" ou "POST request to <URL>".
                local failed_url failed_host
                failed_url=$(grep -oE '(GET|POST) request to https?://[^[:space:]]+' "$latest_log" 2>/dev/null \
                    | head -1 \
                    | sed -E 's/^(GET|POST) request to //')
                if [ -n "$failed_url" ]; then
                    failed_host=$(printf '%s' "$failed_url" \
                        | sed -E 's|^https?://([^/]+)/.*|\1|; s|^https?://([^/]+)$|\1|')
                    printf '      → Endpoint que falhou: %s\n' "$failed_host"
                    printf '      → Verifique se esse FQDN está liberado no firewall corporativo.\n'
                    printf '      → Variantes regionais (pipelinesghub<region>*.actions.githubusercontent.com)\n'
                    printf '        NÃO são cobertas por whitelist da base "pipelines.actions.githubusercontent.com".\n'
                    printf '        Peça wildcard: *.actions.githubusercontent.com\n'
                else
                    printf '      → Verifique whitelist do firewall para *.actions.githubusercontent.com\n'
                    printf '        (variantes regionais aparecem dinamicamente).\n'
                fi
                triage_emitted="yes"
            fi
            [ -z "$triage_emitted" ] && \
                printf '    (nenhum padrão conhecido bate — leia o log [1] manualmente)\n'
            printf '\n'
        fi

        printf '══════════════════════════════════════════════════\n'
        printf '  FIM DO DIAGNÓSTICO TLS\n'
        printf '══════════════════════════════════════════════════\n\n'
    } >&2
    return 0
}

# runner_register RUNNER_DIR URL TOKEN NAME LABEL
#   Registra o runner via config.sh --token. Usa --unattended --replace
#   (idempotente quanto a nome+label).
#   Quando o config.sh falha, invoca runner_diagnose_tls_failure pra
#   emitir bloco de diagnóstico antes de retornar erro — caller (recover
#   e setup) imprime sua mensagem genérica, mas o operador já tem o
#   contexto pra resolver sem ida-e-volta operacional (TSK00.04.05).
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
        runner_diagnose_tls_failure "$dir"
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

# runner_purge_local_config RUNNER_DIR
#   Apaga TODOS os artefatos locais de configuração do runner que podem
#   ser lidos pelo Runner.Listener como "ainda configurado". Lista
#   exaustiva (5 arquivos):
#     - .runner                — config principal (agentId, gitHubUrl, serverUrl)
#     - .runner_migrated       — cópia gerada por auto-update (≥ 2.334 lê como
#                                evidência de "configurado" se .runner sumiu)
#     - .credentials           — JWT do runner
#     - .credentials_rsaparams — chave RSA para rotação de credenciais
#     - .path                  — work folder path (lixo residual após uninstall)
#
#   NÃO toca em .env (variáveis persistidas via setup, ex.: COMPOSE_DIR) nem
#   em .service (marker da unit systemd — gerenciado por svc.sh install/uninstall).
#
#   Idempotente: silencioso quando arquivos já estão ausentes.
#   Retorna 1 se RUNNER_DIR vier vazio, ou se algum dos 5 artefatos persistir
#   em disco após a limpeza (caso raro de permissão/IO), permitindo fail-fast
#   no caller.
runner_purge_local_config() {
    local dir="$1"
    # Guarda contra invocação sem RUNNER_DIR ou com path começando com "-"
    # (rm interpretaria como flag): mensagem neutra, prefixo "ERRO:" é
    # responsabilidade do fail() do caller.
    if [ -z "$dir" ]; then
        printf "runner_purge_local_config: RUNNER_DIR não informado\n" >&2
        return 1
    fi
    # `--` impede que valores começando com `-` virem option para rm.
    rm -f -- "$dir/.runner" \
             "$dir/.runner_migrated" \
             "$dir/.credentials" \
             "$dir/.credentials_rsaparams" \
             "$dir/.path"
    # Verifica os 5 artefatos — contrato é "todos foram apagados",
    # então qualquer resíduo (ex.: .path sem permissão) é falha.
    local f leftover=""
    for f in .runner .runner_migrated .credentials .credentials_rsaparams .path; do
        if [ -e "$dir/$f" ]; then
            leftover="${leftover:+$leftover, }$f"
        fi
    done
    if [ -n "$leftover" ]; then
        printf "não foi possível remover artefatos do runner em %s: %s — verifique permissões.\n" \
            "$dir" "$leftover" >&2
        return 1
    fi
    return 0
}

# runner_remove_registration RUNNER_DIR OWNER REPO
#   Remove o registro do runner em três camadas, de cima pra baixo:
#     1. Se o runner já não existe remotamente (total_count=0), pula
#        config.sh remove — não há nada a desregistrar no GitHub.
#     2. Caso contrário, tenta obter remove-token via API (endpoint distinto
#        do registration-token) e usa ./config.sh remove --token <remove>.
#     3. Sempre encerra com `runner_purge_local_config` — apaga os 5
#        artefatos locais (.runner, .runner_migrated, .credentials,
#        .credentials_rsaparams, .path).
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

    # Camada 3: limpeza local determinística (sempre executada).
    # Inclui .runner_migrated (cópia gerada por auto-update do runner que,
    # se permanecer, faz config.sh --replace falhar com "already configured")
    # e .path (resíduo de svc.sh uninstall). Ver runner_purge_local_config.
    runner_purge_local_config "$dir" || return 1
    ok "Registro local removido (.runner + .runner_migrated + .credentials* + .path)"
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
