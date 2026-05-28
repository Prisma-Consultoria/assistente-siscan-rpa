#!/usr/bin/env bats
# Testes para runner_install_runtime_deps e runner_verify_runtime_deps
# em scripts/deploy_server/_runner.sh (TSK00.04.04 — deps de SO).
#
# Lab 2026-05-27 (#220) expôs: VM com binários LATEST do runner ainda
# falhava TLS handshake porque libssl/libicu/libkrb5 do SO estavam
# desalinhadas com o que o .NET embarcado precisa. O tarball oficial
# inclui bin/installdependencies.sh que instala via apt/yum/dnf, mas o
# assistente nunca invocava. Esta TSK fecha esse gap.

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

setup() {
    # Stubs dos helpers de log — silenciam saída mas mantêm rc=0
    info() { :; }
    ok() { :; }
    warn() { :; }
    export -f info ok warn

    source "${BATS_TEST_DIRNAME}/../../scripts/deploy_server/_runner.sh"

    RUNNER_DIR="$(mktemp -d)"
    mkdir -p "${RUNNER_DIR}/bin"
}

teardown() {
    command rm -rf "${RUNNER_DIR}"
    unset -f sudo ldd 2>/dev/null || true
}

# ────────────────────────────────────────────────────────────────────────────
# runner_install_runtime_deps
# ────────────────────────────────────────────────────────────────────────────

@test "install_runtime_deps: script ausente → retorna 0 (degradação suave)" {
    # bin/installdependencies.sh inexistente. Função não deve falhar —
    # runner antigo ou tarball customizado é cenário legítimo.
    run runner_install_runtime_deps "${RUNNER_DIR}"
    assert_success
}

@test "install_runtime_deps: script presente + sudo OK → retorna 0" {
    : > "${RUNNER_DIR}/bin/installdependencies.sh"
    chmod +x "${RUNNER_DIR}/bin/installdependencies.sh"
    # Stub sudo como no-op com exit 0 — simula install bem-sucedido
    sudo() { return 0; }
    export -f sudo

    run runner_install_runtime_deps "${RUNNER_DIR}"
    assert_success
}

@test "install_runtime_deps: script presente + sudo falha → retorna 1 com warn" {
    : > "${RUNNER_DIR}/bin/installdependencies.sh"
    chmod +x "${RUNNER_DIR}/bin/installdependencies.sh"
    sudo() { return 1; }
    export -f sudo

    run runner_install_runtime_deps "${RUNNER_DIR}"
    assert_failure
}

@test "install_runtime_deps: script existe mas sem permissão de execução → retorna 0" {
    : > "${RUNNER_DIR}/bin/installdependencies.sh"
    # chmod ausente — não-executável
    sudo() { return 0; }  # não deve ser chamado
    export -f sudo

    run runner_install_runtime_deps "${RUNNER_DIR}"
    assert_success
}

# ────────────────────────────────────────────────────────────────────────────
# runner_verify_runtime_deps
# ────────────────────────────────────────────────────────────────────────────

@test "verify_runtime_deps: binário ausente → retorna 0 (best-effort)" {
    # Sem bin/Runner.Listener nada a verificar — não erro.
    run runner_verify_runtime_deps "${RUNNER_DIR}"
    assert_success
}

@test "verify_runtime_deps: ldd reporta tudo presente → retorna 0" {
    : > "${RUNNER_DIR}/bin/Runner.Listener"
    chmod +x "${RUNNER_DIR}/bin/Runner.Listener"
    ldd() {
        printf 'linux-vdso.so.1 (0x00007ffe123)\n'
        printf 'libssl.so.3 => /usr/lib/x86_64-linux-gnu/libssl.so.3 (0x00007f1)\n'
        printf 'libicu.so.72 => /usr/lib/x86_64-linux-gnu/libicu.so.72 (0x00007f2)\n'
    }
    export -f ldd

    run runner_verify_runtime_deps "${RUNNER_DIR}"
    assert_success
}

@test "verify_runtime_deps: ldd reporta 'not found' → retorna 1 com lista" {
    : > "${RUNNER_DIR}/bin/Runner.Listener"
    chmod +x "${RUNNER_DIR}/bin/Runner.Listener"
    # Reproduz o output real visto no lab 2026-05-27 quando bin/ foi
    # apagado e config.sh tentou exec Runner.Listener inexistente.
    ldd() {
        printf 'libicu.so.66 => not found\n'
        printf 'libssl.so.1.1 => not found\n'
        printf 'libcoreclr.so => not found\n'
    }
    export -f ldd

    run runner_verify_runtime_deps "${RUNNER_DIR}"
    assert_failure
    assert_output --partial "libicu.so.66"
    assert_output --partial "libssl.so.1.1"
    assert_output --partial "installdependencies.sh"
}

@test "verify_runtime_deps: ldd indisponível no sistema → retorna 0 (best-effort)" {
    : > "${RUNNER_DIR}/bin/Runner.Listener"
    chmod +x "${RUNNER_DIR}/bin/Runner.Listener"
    # Stub command para fazer ldd parecer ausente
    command() {
        if [ "$1" = "-v" ] && [ "$2" = "ldd" ]; then
            return 1
        fi
        builtin command "$@"
    }
    export -f command

    run runner_verify_runtime_deps "${RUNNER_DIR}"
    assert_success

    unset -f command
}

# ────────────────────────────────────────────────────────────────────────────
# Integração — runner_download_binaries chama install + verify
# ────────────────────────────────────────────────────────────────────────────
# Revisão Copilot PR #81: teste anterior era tautológico (chamava as 2
# funções diretamente sem exercitar runner_download_binaries). Esta versão
# stuba curl + tar pra executar o download de verdade e validar que as
# callees ficam encadeadas no fluxo. Pega regressão se as linhas pós-
# extração de _runner.sh forem removidas.

@test "integração: runner_download_binaries chama install + verify após extração com sucesso" {
    # Markers via tempfile — sobrevivem ao subshell de `run`
    INSTALL_FLAG="$(mktemp)"; rm -f "$INSTALL_FLAG"
    VERIFY_FLAG="$(mktemp)"; rm -f "$VERIFY_FLAG"
    export INSTALL_FLAG VERIFY_FLAG

    runner_install_runtime_deps() { touch "$INSTALL_FLAG"; return 0; }
    runner_verify_runtime_deps()  { touch "$VERIFY_FLAG";  return 0; }
    export -f runner_install_runtime_deps runner_verify_runtime_deps

    # Stub curl: primeira chamada (sem -o) retorna JSON com version pro
    # pipe grep/sed/head extrair; segunda chamada (com -o tarball) cria
    # arquivo placeholder.
    curl() {
        local out=""
        while [ $# -gt 0 ]; do
            if [ "$1" = "-o" ]; then
                out="$2"; shift 2
            else
                shift
            fi
        done
        if [ -n "$out" ]; then
            : > "$out"
        else
            printf '"tag_name": "v2.334.0"\n'
        fi
        return 0
    }
    export -f curl

    # Stub tar: extração no-op (não precisa criar arquivo nenhum — as
    # callees stubadas não verificam conteúdo do dir)
    tar() { return 0; }
    export -f tar

    run runner_download_binaries "${RUNNER_DIR}"
    assert_success

    [ -f "$INSTALL_FLAG" ] || { echo "runner_install_runtime_deps NÃO foi invocado"; return 1; }
    [ -f "$VERIFY_FLAG" ]  || { echo "runner_verify_runtime_deps NÃO foi invocado"; return 1; }

    rm -f "$INSTALL_FLAG" "$VERIFY_FLAG"
}

@test "integração: download falha no curl → install/verify NÃO são invocados" {
    # Confirma que as callees só rodam quando extração foi bem-sucedida.
    # Sem isso, regressão "deixar install + verify rodarem mesmo em falha"
    # passaria despercebida.
    INSTALL_FLAG="$(mktemp)"; rm -f "$INSTALL_FLAG"
    VERIFY_FLAG="$(mktemp)"; rm -f "$VERIFY_FLAG"
    export INSTALL_FLAG VERIFY_FLAG

    runner_install_runtime_deps() { touch "$INSTALL_FLAG"; return 0; }
    runner_verify_runtime_deps()  { touch "$VERIFY_FLAG";  return 0; }
    export -f runner_install_runtime_deps runner_verify_runtime_deps

    # curl falha em todas as invocações
    curl() { return 1; }
    export -f curl

    run runner_download_binaries "${RUNNER_DIR}"
    assert_failure

    [ ! -f "$INSTALL_FLAG" ] || { echo "regressão: install foi invocado em falha de download"; return 1; }
    [ ! -f "$VERIFY_FLAG" ]  || { echo "regressão: verify foi invocado em falha de download"; return 1; }

    rm -f "$INSTALL_FLAG" "$VERIFY_FLAG"
}
