#!/usr/bin/env bats
# Testes para runner_diagnose_tls_failure em scripts/deploy_server/_runner.sh
# (TSK00.04.05).
#
# Função emite bloco estruturado em stderr quando config.sh falha no TLS
# handshake. Always-rc=0 (best-effort). Cinco seções: log .NET / proxy env /
# CAs custom / DNS resolution / triagem por padrão conhecido no log.
#
# Origem: lab #220 (2026-05-27/28) perdeu múltiplas rodadas operacionais
# coletando esses 4 sinais manualmente.

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

setup() {
    source "${BATS_TEST_DIRNAME}/../../scripts/deploy_server/_runner.sh"

    RUNNER_DIR="$(mktemp -d)"
    # Limpa env entre testes — proxy vars são globais e bagunçam testes
    unset HTTP_PROXY HTTPS_PROXY NO_PROXY ALL_PROXY FTP_PROXY \
          http_proxy https_proxy no_proxy all_proxy ftp_proxy
}

teardown() {
    command rm -rf "${RUNNER_DIR}"
    unset HTTP_PROXY HTTPS_PROXY NO_PROXY ALL_PROXY FTP_PROXY \
          http_proxy https_proxy no_proxy all_proxy ftp_proxy 2>/dev/null || true
}

# ────────────────────────────────────────────────────────────────────────────
# Forma do bloco — header/footer, sempre rc=0
# ────────────────────────────────────────────────────────────────────────────

@test "sempre retorna 0 (best-effort), mesmo sem _diag/ nem env nada" {
    run runner_diagnose_tls_failure "${RUNNER_DIR}"
    assert_success
}

@test "imprime header/footer visual e as 5 seções numeradas" {
    run runner_diagnose_tls_failure "${RUNNER_DIR}"
    assert_success
    assert_output --partial "DIAGNÓSTICO TLS — config.sh falhou no handshake"
    assert_output --partial "[1]"
    assert_output --partial "[2]"
    assert_output --partial "[3]"
    assert_output --partial "[4]"
    assert_output --partial "FIM DO DIAGNÓSTICO TLS"
}

# ────────────────────────────────────────────────────────────────────────────
# Seção [1] — _diag/Runner_*.log
# ────────────────────────────────────────────────────────────────────────────

@test "[1] sem _diag/ → informa que runner pode não ter inicializado" {
    run runner_diagnose_tls_failure "${RUNNER_DIR}"
    assert_success
    assert_output --partial "Nenhum log em"
    assert_output --partial "runner pode não ter chegado a inicializar"
}

@test "[1] _diag/ existe mas vazio → mesma mensagem que sem _diag" {
    mkdir -p "${RUNNER_DIR}/_diag"
    run runner_diagnose_tls_failure "${RUNNER_DIR}"
    assert_success
    assert_output --partial "Nenhum log em"
}

@test "[1] _diag/Runner_*.log presente → emite tail do conteúdo" {
    mkdir -p "${RUNNER_DIR}/_diag"
    cat > "${RUNNER_DIR}/_diag/Runner_20260528-110000-utc.log" <<'LOG'
[2026-05-28 11:00:01Z INFO Listener] Runner.Listener starting
[2026-05-28 11:00:02Z ERR  Listener] System.Net.Http.HttpRequestException: The SSL connection could not be established
[2026-05-28 11:00:02Z ERR  Listener]    at System.Net.Security.SslStream.ThrowIfExceptional()
LOG
    run runner_diagnose_tls_failure "${RUNNER_DIR}"
    assert_success
    assert_output --partial "Runner_20260528-110000-utc.log"
    assert_output --partial "SSL connection could not be established"
    assert_output --partial "SslStream"
}

@test "[1] múltiplos logs → pega o mais recente (mtime maior)" {
    mkdir -p "${RUNNER_DIR}/_diag"
    cat > "${RUNNER_DIR}/_diag/Runner_old.log" <<<"LOG ANTIGO QUE NAO QUEREMOS"
    sleep 0.1  # garante mtime distinto
    cat > "${RUNNER_DIR}/_diag/Runner_new.log" <<<"LOG NOVO ESCOLHIDO"
    touch -d "1 hour ago" "${RUNNER_DIR}/_diag/Runner_old.log"

    run runner_diagnose_tls_failure "${RUNNER_DIR}"
    assert_success
    assert_output --partial "LOG NOVO ESCOLHIDO"
    refute_output --partial "LOG ANTIGO QUE NAO QUEREMOS"
}

# ────────────────────────────────────────────────────────────────────────────
# Seção [2] — env proxy vars
# ────────────────────────────────────────────────────────────────────────────

@test "[2] sem proxy vars no env → emite 'nenhuma variável de proxy'" {
    run runner_diagnose_tls_failure "${RUNNER_DIR}"
    assert_success
    assert_output --partial "nenhuma variável de proxy"
}

@test "[2] HTTPS_PROXY definida → aparece no output da seção" {
    export HTTPS_PROXY="http://proxy.exemplo.local:3128"
    run runner_diagnose_tls_failure "${RUNNER_DIR}"
    assert_success
    assert_output --partial "HTTPS_PROXY=http://proxy.exemplo.local:3128"
}

@test "[2] múltiplas proxy vars → todas aparecem ordenadas" {
    export HTTPS_PROXY="http://p1.local:3128"
    export HTTP_PROXY="http://p2.local:3128"
    export NO_PROXY="localhost,127.0.0.1"
    run runner_diagnose_tls_failure "${RUNNER_DIR}"
    assert_success
    assert_output --partial "HTTP_PROXY="
    assert_output --partial "HTTPS_PROXY="
    assert_output --partial "NO_PROXY="
}

# ────────────────────────────────────────────────────────────────────────────
# Seção [3] — CAs em /usr/local/share/ca-certificates/
# ────────────────────────────────────────────────────────────────────────────

@test "[3] sempre cita o caminho /usr/local/share/ca-certificates/" {
    run runner_diagnose_tls_failure "${RUNNER_DIR}"
    assert_success
    assert_output --partial "/usr/local/share/ca-certificates/"
}

# ────────────────────────────────────────────────────────────────────────────
# Seção [4] — DNS api.github.com
# ────────────────────────────────────────────────────────────────────────────

@test "[4] sempre tenta resolver api.github.com" {
    run runner_diagnose_tls_failure "${RUNNER_DIR}"
    assert_success
    assert_output --partial "api.github.com"
}

# ────────────────────────────────────────────────────────────────────────────
# Seção [5] — triagem por padrão conhecido no log
# ────────────────────────────────────────────────────────────────────────────

@test "[5] log com AuthenticationException → emite triagem de CA bundle" {
    mkdir -p "${RUNNER_DIR}/_diag"
    cat > "${RUNNER_DIR}/_diag/Runner_x.log" <<'LOG'
System.Security.Authentication.AuthenticationException: The remote certificate is invalid
   at System.Net.Security.SslStream.ThrowIfExceptional()
LOG
    run runner_diagnose_tls_failure "${RUNNER_DIR}"
    assert_success
    assert_output --partial "Sinal de CA bundle"
    assert_output --partial "update-ca-certificates"
}

@test "[5] log com NameResolution → emite triagem de DNS/IPv6" {
    mkdir -p "${RUNNER_DIR}/_diag"
    cat > "${RUNNER_DIR}/_diag/Runner_x.log" <<'LOG'
System.Net.Http.HttpRequestException: Name or service not known (api.github.com:443)
   at System.Net.Sockets.NameResolutionPal.HostentToIPAddress
LOG
    run runner_diagnose_tls_failure "${RUNNER_DIR}"
    assert_success
    assert_output --partial "Sinal de DNS / IPv6"
}

@test "[5] log mencionando proxy → emite triagem de proxy" {
    mkdir -p "${RUNNER_DIR}/_diag"
    cat > "${RUNNER_DIR}/_diag/Runner_x.log" <<'LOG'
Establishing tunnel through proxy proxy.exemplo.local:3128
The proxy server returned 'HTTP/1.1 502 Bad Gateway'
LOG
    run runner_diagnose_tls_failure "${RUNNER_DIR}"
    assert_success
    assert_output --partial "Sinal de proxy"
    assert_output --partial "HTTPS_PROXY="
}

# ────────────────────────────────────────────────────────────────────────────
# [5] — padrão "Received unexpected EOF" (firewall/MITM bloqueando handshake)
# Lab #220 (2026-05-28): pipelinesghubeus6.actions.githubusercontent.com
# bloqueado pelo firewall corporativo (whitelist tinha só a base sem o
# prefixo regional ghubeus6).
# ────────────────────────────────────────────────────────────────────────────

@test "[5] log com 'Received unexpected EOF' + URL → triagem firewall + extração do host" {
    mkdir -p "${RUNNER_DIR}/_diag"
    cat > "${RUNNER_DIR}/_diag/Runner_x.log" <<'LOG'
[2026-05-28 14:26:46Z ERR  GitHubActionsService] GET request to https://pipelinesghubeus6.actions.githubusercontent.com/dS9YvtfB8FuhPc/_apis/connectionData?connectOptions=1 failed. System.Net.Http.HttpRequestException: The SSL connection could not be established.
 ---> System.IO.IOException: Received an unexpected EOF or 0 bytes from the transport stream.
   at System.Net.Security.SslStream.ReceiveHandshakeFrameAsync[TIOAdapter](CancellationToken cancellationToken)
LOG
    run runner_diagnose_tls_failure "${RUNNER_DIR}"
    assert_success
    assert_output --partial "Sinal de firewall/proxy interrompendo TLS handshake"
    # Match exato do print (ANTES capitalizado pra ênfase) — case-sensitive
    assert_output --partial "ANTES da validação de certificado"
    assert_output --partial "Endpoint que falhou: pipelinesghubeus6.actions.githubusercontent.com"
    assert_output --partial "Variantes regionais"
    assert_output --partial "*.actions.githubusercontent.com"
}

@test "[5] log com 'Received unexpected EOF' SEM URL → triagem genérica sem host" {
    mkdir -p "${RUNNER_DIR}/_diag"
    cat > "${RUNNER_DIR}/_diag/Runner_x.log" <<'LOG'
System.IO.IOException: Received an unexpected EOF or 0 bytes from the transport stream.
   at System.Net.Security.SslStream.ReceiveHandshakeFrameAsync[TIOAdapter]
LOG
    run runner_diagnose_tls_failure "${RUNNER_DIR}"
    assert_success
    assert_output --partial "Sinal de firewall/proxy interrompendo TLS handshake"
    assert_output --partial "*.actions.githubusercontent.com"
    refute_output --partial "Endpoint que falhou:"  # sem URL no log → não emite linha de host
}

@test "[5] log com 'POST request to' (não GET) → também extrai URL" {
    mkdir -p "${RUNNER_DIR}/_diag"
    cat > "${RUNNER_DIR}/_diag/Runner_x.log" <<'LOG'
POST request to https://pipelinesghubwestus.actions.githubusercontent.com/_apis/runner/registration failed.
System.IO.IOException: Received an unexpected EOF or 0 bytes from the transport stream.
LOG
    run runner_diagnose_tls_failure "${RUNNER_DIR}"
    assert_success
    assert_output --partial "Endpoint que falhou: pipelinesghubwestus.actions.githubusercontent.com"
}

@test "[5] 'Received unexpected EOF' não dispara CA bundle (são padrões distintos)" {
    mkdir -p "${RUNNER_DIR}/_diag"
    cat > "${RUNNER_DIR}/_diag/Runner_x.log" <<'LOG'
System.IO.IOException: Received an unexpected EOF or 0 bytes from the transport stream.
LOG
    run runner_diagnose_tls_failure "${RUNNER_DIR}"
    assert_success
    assert_output --partial "Sinal de firewall/proxy interrompendo"
    refute_output --partial "Sinal de CA bundle"
}

@test "[5] log sem nenhum padrão conhecido → emite mensagem de fallback" {
    mkdir -p "${RUNNER_DIR}/_diag"
    cat > "${RUNNER_DIR}/_diag/Runner_x.log" <<'LOG'
some completely unrelated runtime error
no recognizable TLS pattern in this output
LOG
    run runner_diagnose_tls_failure "${RUNNER_DIR}"
    assert_success
    assert_output --partial "nenhum padrão conhecido bate"
}

@test "[5] múltiplos padrões no mesmo log → emite triagem cumulativa" {
    mkdir -p "${RUNNER_DIR}/_diag"
    cat > "${RUNNER_DIR}/_diag/Runner_x.log" <<'LOG'
AuthenticationException: certificate chain invalid
NameResolution failed for api.github.com
proxy returned error
LOG
    run runner_diagnose_tls_failure "${RUNNER_DIR}"
    assert_success
    assert_output --partial "Sinal de CA bundle"
    assert_output --partial "Sinal de DNS"
    assert_output --partial "Sinal de proxy"
}

# ────────────────────────────────────────────────────────────────────────────
# Integração — runner_register failure path chama runner_diagnose_tls_failure
# ────────────────────────────────────────────────────────────────────────────

@test "runner_register em falha invoca runner_diagnose_tls_failure" {
    # Stub info/ok pra silenciar saída acessória
    info() { :; }
    ok() { :; }
    export -f info ok

    # Marker via tempfile (sobrevive ao subshell de `run`)
    DIAG_FLAG="$(mktemp)"; rm -f "$DIAG_FLAG"
    export DIAG_FLAG
    runner_diagnose_tls_failure() { touch "$DIAG_FLAG"; return 0; }
    export -f runner_diagnose_tls_failure

    # Stub config.sh para falhar (cd $dir && ./config.sh → exit 1)
    mkdir -p "${RUNNER_DIR}/bin"
    cat > "${RUNNER_DIR}/config.sh" <<'SHELL'
#!/usr/bin/env bash
exit 1
SHELL
    chmod +x "${RUNNER_DIR}/config.sh"

    run runner_register "${RUNNER_DIR}" "https://github.com/x/y" "TOKEN123" "name" "label"
    assert_failure
    [ -f "$DIAG_FLAG" ] || { echo "runner_diagnose_tls_failure NÃO foi invocado"; return 1; }

    rm -f "$DIAG_FLAG"
}

# ────────────────────────────────────────────────────────────────────────────
# [4] estendida + [6] novo — TSK00.04.08
# ────────────────────────────────────────────────────────────────────────────

@test "[4] resolve api.github.com SEMPRE + endpoint extraído quando disponível" {
    mkdir -p "${RUNNER_DIR}/_diag"
    cat > "${RUNNER_DIR}/_diag/Runner_x.log" <<'LOG'
GET request to https://pipelinesghubeus6.actions.githubusercontent.com/_apis/connectionData failed.
System.IO.IOException: Received an unexpected EOF or 0 bytes from the transport stream.
LOG
    run runner_diagnose_tls_failure "${RUNNER_DIR}"
    assert_success
    # Sempre tenta api.github.com primeiro
    assert_output --partial "api.github.com:"
    # E também o endpoint que falhou (extraído de [5d])
    assert_output --partial "pipelinesghubeus6.actions.githubusercontent.com (endpoint que falhou):"
}

@test "[4] log sem URL extraível → resolve apenas api.github.com" {
    mkdir -p "${RUNNER_DIR}/_diag"
    cat > "${RUNNER_DIR}/_diag/Runner_x.log" <<'LOG'
some unrelated content without the canonical pattern
LOG
    run runner_diagnose_tls_failure "${RUNNER_DIR}"
    assert_success
    assert_output --partial "api.github.com:"
    refute_output --partial "(endpoint que falhou):"
}

@test "[6] log com URL extraída + curl disponível → emite teste de alcance HTTP=000 → firewall confirmado" {
    mkdir -p "${RUNNER_DIR}/_diag"
    cat > "${RUNNER_DIR}/_diag/Runner_x.log" <<'LOG'
GET request to https://pipelinesghubeus6.actions.githubusercontent.com/_apis/connectionData failed.
System.IO.IOException: Received an unexpected EOF or 0 bytes from the transport stream.
LOG
    # Stub curl pra simular firewall (HTTP=000)
    curl() {
        printf 'HTTP=000 TLS=0'
        return 28
    }
    export -f curl

    run runner_diagnose_tls_failure "${RUNNER_DIR}"
    assert_success
    assert_output --partial "[6] Teste de alcance direto"
    assert_output --partial "https://pipelinesghubeus6.actions.githubusercontent.com"
    assert_output --partial "HTTP=000"
    assert_output --partial "firewall confirmado"
}

@test "[6] curl retorna HTTP=200 → interpreta como TLS subiu (NÃO é firewall)" {
    mkdir -p "${RUNNER_DIR}/_diag"
    cat > "${RUNNER_DIR}/_diag/Runner_x.log" <<'LOG'
GET request to https://api.github.com/repos/foo/bar failed.
System.IO.IOException: Received an unexpected EOF or 0 bytes from the transport stream.
LOG
    curl() {
        printf 'HTTP=200 TLS=0'
        return 0
    }
    export -f curl

    run runner_diagnose_tls_failure "${RUNNER_DIR}"
    assert_success
    assert_output --partial "[6] Teste de alcance direto"
    assert_output --partial "HTTP=200"
    assert_output --partial "TLS subiu (NÃO é firewall)"
    refute_output --partial "firewall confirmado"
}

@test "[6] curl retorna HTTP=404 também conta como TLS subiu" {
    mkdir -p "${RUNNER_DIR}/_diag"
    cat > "${RUNNER_DIR}/_diag/Runner_x.log" <<'LOG'
POST request to https://pipelines.actions.githubusercontent.com/api/foo failed.
Received an unexpected EOF or 0 bytes from the transport stream.
LOG
    curl() {
        printf 'HTTP=404 TLS=0'
        return 0
    }
    export -f curl

    run runner_diagnose_tls_failure "${RUNNER_DIR}"
    assert_success
    assert_output --partial "HTTP=404"
    assert_output --partial "TLS subiu (NÃO é firewall)"
}

@test "[6] log sem URL extraída → seção [6] inteira é skipped (graceful)" {
    mkdir -p "${RUNNER_DIR}/_diag"
    cat > "${RUNNER_DIR}/_diag/Runner_x.log" <<'LOG'
some runtime error without the canonical GET/POST request pattern
LOG
    run runner_diagnose_tls_failure "${RUNNER_DIR}"
    assert_success
    refute_output --partial "[6] Teste de alcance direto"
}

@test "[6] curl ausente no sistema → mensagem orientativa, não falha" {
    mkdir -p "${RUNNER_DIR}/_diag"
    cat > "${RUNNER_DIR}/_diag/Runner_x.log" <<'LOG'
GET request to https://pipelinesghubeus6.actions.githubusercontent.com/foo failed.
Received an unexpected EOF from the transport stream.
LOG
    # Stub command pra fazer curl parecer ausente
    command() {
        if [ "$1" = "-v" ] && [ "$2" = "curl" ]; then
            return 1
        fi
        builtin command "$@"
    }
    export -f command

    run runner_diagnose_tls_failure "${RUNNER_DIR}"
    assert_success
    assert_output --partial "[6] Teste de alcance direto"
    assert_output --partial "curl ausente"

    unset -f command
}

@test "runner_register em sucesso NÃO invoca runner_diagnose_tls_failure" {
    info() { :; }
    ok() { :; }
    export -f info ok

    DIAG_FLAG="$(mktemp)"; rm -f "$DIAG_FLAG"
    export DIAG_FLAG
    runner_diagnose_tls_failure() { touch "$DIAG_FLAG"; return 0; }
    export -f runner_diagnose_tls_failure

    mkdir -p "${RUNNER_DIR}/bin"
    cat > "${RUNNER_DIR}/config.sh" <<'SHELL'
#!/usr/bin/env bash
exit 0
SHELL
    chmod +x "${RUNNER_DIR}/config.sh"

    run runner_register "${RUNNER_DIR}" "https://github.com/x/y" "TOKEN123" "name" "label"
    assert_success
    [ ! -f "$DIAG_FLAG" ] || { echo "regressão: diagnose invocado em sucesso"; return 1; }

    rm -f "$DIAG_FLAG"
}
