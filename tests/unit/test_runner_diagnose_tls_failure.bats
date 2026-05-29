#!/usr/bin/env bats
# Testes para runner_diagnose_tls_failure em scripts/deploy_server/_runner.sh
# (TSK00.04.05 + extensões TSK00.04.08).
#
# Função emite bloco estruturado em stderr quando config.sh falha no TLS
# handshake. Always-rc=0 (best-effort). Seis seções estáveis (sempre
# emitidas, mesmo quando log _diag ausente ou sem URL extraída):
#   [1] log .NET (tail do _diag/Runner_*.log, com redação de token-like paths)
#   [2] proxy env (com redação de userinfo user:pass@)
#   [3] CAs custom (/usr/local/share/ca-certificates/)
#   [4] resolução DNS (api.github.com + endpoint extraído quando disponível)
#   [5] triagem por padrão conhecido (CA, DNS, proxy, firewall/EOF)
#   [6] teste de alcance direto via curl -k ao URL extraído (HTTP=000 =
#       firewall; HTTP=2xx/3xx/4xx/5xx = TLS subiu, causa outra)
#
# Origem: lab #220 (2026-05-27) + lab #259 (2026-05-28) perderam múltiplas
# rodadas operacionais coletando esses sinais manualmente.

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

@test "imprime header/footer visual e as 6 seções numeradas (contrato estável)" {
    run runner_diagnose_tls_failure "${RUNNER_DIR}"
    assert_success
    assert_output --partial "DIAGNÓSTICO TLS — config.sh falhou no handshake"
    assert_output --partial "[1]"
    assert_output --partial "[2]"
    assert_output --partial "[3]"
    assert_output --partial "[4]"
    # [5] e [6] sempre emitidas mesmo sem log/URL — fallback explícito
    assert_output --partial "[5]"
    assert_output --partial "[6]"
    # Sem URL extraída de [5]: fallback do [6] é informativo, não silencioso
    assert_output --partial "(sem URL extraída de [5]"
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

@test "runner_register em falha invoca specialist check-runner-tls.sh quando disponível (TSK00.04.10)" {
    # Revisão Copilot PR #93: a asserção anterior usava "DIAGNÓSTICO TLS",
    # mas esse header é emitido por AMBOS os caminhos (specialist e fallback
    # inline). Para validar que o caminho specialist foi tomado, substituímos
    # temporariamente o specialist por um stub que emite um marker
    # inequívoco e verificamos esse marker.

    # Stub info/ok pra silenciar saída acessória
    info() { :; }
    ok() { :; }
    export -f info ok

    # Substituir o specialist por um stub com marker exclusivo
    local specialist_path saved_path
    specialist_path="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)/scripts/deploy_server/check-runner-tls.sh"
    saved_path="${BATS_TEST_TMPDIR}/check-runner-tls.sh.saved"
    [ -x "$specialist_path" ] && cp "$specialist_path" "$saved_path"
    cat > "$specialist_path" <<'STUB'
#!/usr/bin/env bash
# Stub específico do teste — marker garantido vir DESTE caminho.
echo "MARKER_SPECIALIST_INVOCADO_PR93_TEST" >&2
exit 0
STUB
    chmod +x "$specialist_path"

    # Stub config.sh para falhar
    mkdir -p "${RUNNER_DIR}/bin"
    cat > "${RUNNER_DIR}/config.sh" <<'SHELL'
#!/usr/bin/env bash
exit 1
SHELL
    chmod +x "${RUNNER_DIR}/config.sh"

    run runner_register "${RUNNER_DIR}" "https://github.com/x/y" "TOKEN123" "name" "label"
    local rc=$status

    # Restaurar specialist sempre (mesmo em falha)
    [ -f "$saved_path" ] && mv "$saved_path" "$specialist_path"

    [ "$rc" -ne 0 ] || { echo "runner_register deveria ter falhado"; return 1; }
    # Marker do stub é inequívoco — só aparece se o caminho specialist foi
    # tomado (helper inline runner_diagnose_tls_failure NUNCA emitiria isso).
    assert_output --partial "MARKER_SPECIALIST_INVOCADO_PR93_TEST"
}

@test "runner_register em falha faz fallback ao helper inline quando specialist ausente" {
    # Caso edge: VM com versão antiga do assistente onde
    # check-runner-tls.sh não chegou ainda. Preserva backward compat
    # via fallback explícito no runner_register (TSK00.04.10).

    # Stub info/ok pra silenciar saída acessória
    info() { :; }
    ok() { :; }
    export -f info ok

    # Move o specialist para que não esteja "presente" durante este teste
    local specialist_path saved_path
    specialist_path="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)/scripts/deploy_server/check-runner-tls.sh"
    saved_path="${BATS_TEST_TMPDIR}/check-runner-tls.sh.saved"
    [ -x "$specialist_path" ] && mv "$specialist_path" "$saved_path"

    # Stub do helper inline pra verificar que ELE é invocado no fallback
    DIAG_FLAG="$(mktemp)"; rm -f "$DIAG_FLAG"
    export DIAG_FLAG
    runner_diagnose_tls_failure() { touch "$DIAG_FLAG"; return 0; }
    export -f runner_diagnose_tls_failure

    # Stub config.sh para falhar
    mkdir -p "${RUNNER_DIR}/bin"
    cat > "${RUNNER_DIR}/config.sh" <<'SHELL'
#!/usr/bin/env bash
exit 1
SHELL
    chmod +x "${RUNNER_DIR}/config.sh"

    run runner_register "${RUNNER_DIR}" "https://github.com/x/y" "TOKEN123" "name" "label"
    local rc=$status

    # Restaura specialist sempre (mesmo em falha)
    [ -f "$saved_path" ] && mv "$saved_path" "$specialist_path"

    [ $rc -ne 0 ] || { echo "runner_register deveria ter falhado"; return 1; }
    [ -f "$DIAG_FLAG" ] || { echo "fallback: helper inline NÃO foi invocado"; return 1; }
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

@test "[6] log sem URL extraída → header sempre emitido + fallback explícito (contrato 6 seções)" {
    mkdir -p "${RUNNER_DIR}/_diag"
    cat > "${RUNNER_DIR}/_diag/Runner_x.log" <<'LOG'
some runtime error without the canonical GET/POST request pattern
LOG
    run runner_diagnose_tls_failure "${RUNNER_DIR}"
    assert_success
    # Header de [6] SEMPRE emitido — contrato de 6 seções estáveis
    assert_output --partial "[6] Teste de alcance direto"
    # Fallback explícito quando nada a testar
    assert_output --partial "(sem URL extraída de [5]"
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

# ────────────────────────────────────────────────────────────────────────────
# Revisão Copilot PR #83 — segurança + contrato + precisão diagnóstica
# ────────────────────────────────────────────────────────────────────────────

@test "[2] HTTPS_PROXY com credenciais embutidas → userinfo é redigido" {
    # Caso real do Copilot: HTTPS_PROXY=https://user:password@proxy:3128 vaza
    # credenciais quando colado em tickets. Pattern de redação:
    # scheme://USER:PASS@host → scheme://***:***@host
    export HTTPS_PROXY="http://alice:secret123@proxy.exemplo.local:3128"
    run runner_diagnose_tls_failure "${RUNNER_DIR}"
    assert_success
    assert_output --partial "HTTPS_PROXY=http://***:***@proxy.exemplo.local:3128"
    refute_output --partial "alice"
    refute_output --partial "secret123"
}

@test "[2] proxy SEM credenciais → preservado verbatim (sem alteração)" {
    export HTTPS_PROXY="http://proxy.exemplo.local:3128"
    run runner_diagnose_tls_failure "${RUNNER_DIR}"
    assert_success
    assert_output --partial "HTTPS_PROXY=http://proxy.exemplo.local:3128"
}

@test "[1] token-like path segments no log são redigidos como <TOKEN>" {
    # Caso real do Copilot + F38: log mostra URL com token de registro
    # embutido no path. Pattern: /<>=20 chars alfanuméricos>/ → /<TOKEN>/
    mkdir -p "${RUNNER_DIR}/_diag"
    cat > "${RUNNER_DIR}/_diag/Runner_x.log" <<'LOG'
GET request to https://pipelinesghubeus6.actions.githubusercontent.com/dS9YvtfB8FuhPcKg6BoPW4W2Hf9PopOGXn2yuXschpCBkEhmDo/_apis/connectionData failed.
System.Net.Http.HttpRequestException: The SSL connection could not be established.
LOG
    run runner_diagnose_tls_failure "${RUNNER_DIR}"
    assert_success
    # Host preservado (essencial pra triagem)
    assert_output --partial "pipelinesghubeus6.actions.githubusercontent.com"
    # Token redigido
    assert_output --partial "/<TOKEN>/"
    refute_output --partial "dS9YvtfB8FuhPcKg6BoPW4W2Hf9PopOGXn2yuXschpCBkEhmDo"
}

@test "[1] path com segmentos curtos (não-tokens) NÃO sofre redação" {
    # /repos/foo/bar/ → segmentos curtos, não-token, não redigir.
    mkdir -p "${RUNNER_DIR}/_diag"
    cat > "${RUNNER_DIR}/_diag/Runner_x.log" <<'LOG'
GET request to https://api.github.com/repos/foo/bar/actions/runners failed.
LOG
    run runner_diagnose_tls_failure "${RUNNER_DIR}"
    assert_success
    assert_output --partial "/repos/foo/bar/"
    refute_output --partial "<TOKEN>"
}

@test "[5] log AUSENTE → header da seção [5] ainda é emitido (contrato 6 seções)" {
    # Bug detectado pela revisão Copilot: header de [5] estava DENTRO do
    # guard `if [ -n latest_log ]`, então sem log a seção sumia. Contrato
    # documentado e testado é "6 seções estáveis"; fallback explícito agora.
    run runner_diagnose_tls_failure "${RUNNER_DIR}"
    assert_success
    assert_output --partial "[5] Triagem"
    assert_output --partial "sem log para triagem"
}

@test "[5] log existe mas sem padrão → header emitido + mensagem 'nenhum padrão'" {
    mkdir -p "${RUNNER_DIR}/_diag"
    cat > "${RUNNER_DIR}/_diag/Runner_x.log" <<'LOG'
runtime error sem padrão de TLS conhecido
LOG
    run runner_diagnose_tls_failure "${RUNNER_DIR}"
    assert_success
    assert_output --partial "[5] Triagem"
    assert_output --partial "nenhum padrão conhecido bate"
}

@test "[6] curl é invocado com -k (mesmo critério do check-network specialist)" {
    # Revisão Copilot: sem -k, CA não confiada produz HTTP=000 + TLS!=0,
    # que parece firewall mas é cert error. check-network usa -k pra
    # validar SOMENTE firewall — diagnose helper deve seguir o mesmo critério.
    mkdir -p "${RUNNER_DIR}/_diag"
    cat > "${RUNNER_DIR}/_diag/Runner_x.log" <<'LOG'
GET request to https://pipelinesghubeus6.actions.githubusercontent.com/foo failed.
Received an unexpected EOF or 0 bytes from the transport stream.
LOG
    # Stub curl que captura args em variável e emite resultado
    CURL_ARGS_FILE="$(mktemp)"; rm -f "$CURL_ARGS_FILE"
    export CURL_ARGS_FILE
    curl() {
        # Salva args num arquivo pra assertar
        printf '%s\n' "$@" > "$CURL_ARGS_FILE"
        printf 'HTTP=000 TLS=0'
        return 28
    }
    export -f curl

    run runner_diagnose_tls_failure "${RUNNER_DIR}"
    assert_success
    # Confirma que -k foi passado (mata ambiguidade CA error / firewall)
    grep -q "^-k\$" "$CURL_ARGS_FILE" || { echo "curl chamado SEM -k"; cat "$CURL_ARGS_FILE"; return 1; }

    rm -f "$CURL_ARGS_FILE"
}

@test "[6] HTTP=503 (server response, TLS subiu) → 'NÃO é firewall'" {
    # Revisão Copilot: HTTP=5xx é resposta do servidor — TLS subiu.
    # Antes não era interpretado; agora cai no case "TLS subiu".
    mkdir -p "${RUNNER_DIR}/_diag"
    cat > "${RUNNER_DIR}/_diag/Runner_x.log" <<'LOG'
GET request to https://api.github.com/foo failed.
Received an unexpected EOF.
LOG
    curl() {
        printf 'HTTP=503 TLS=0'
        return 22
    }
    export -f curl

    run runner_diagnose_tls_failure "${RUNNER_DIR}"
    assert_success
    assert_output --partial "HTTP=503"
    assert_output --partial "TLS subiu (NÃO é firewall)"
    refute_output --partial "firewall confirmado"
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
