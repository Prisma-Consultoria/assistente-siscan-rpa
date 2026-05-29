#!/usr/bin/env bats
# Testes para o specialist scripts/deploy_server/check-runner-tls.sh
# (TSK00.04.10 #89 — extrai runner_diagnose_tls_failure de _runner.sh
# como specialist standalone com modos --pre-flight e --reactive).
#
# Cobertura:
#   - Modo --pre-flight emite seções [2] [3] [4] sem precisar de log
#   - Modo --reactive delega ao helper completo (6 seções) em _runner.sh
#   - Default (sem args) cai em --pre-flight (descoberta via doctor)
#   - Argparse: --pre-flight, --reactive [DIR], --runner-dir, --help
#   - Fallback de erros: RUNNER_DIR ausente em --reactive
#   - Integração: doctor inclui o specialist automaticamente

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

setup() {
    PROJECT_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    SPECIALIST="${PROJECT_DIR}/scripts/deploy_server/check-runner-tls.sh"
    RUNNER_TMPDIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$RUNNER_TMPDIR"
}

# ────────────────────────────────────────────────────────────────────────────
# Modo --pre-flight
# ────────────────────────────────────────────────────────────────────────────

@test "--pre-flight emite header com 'modo pre-flight'" {
    run bash "$SPECIALIST" --pre-flight
    assert_success
    assert_output --partial "CHECK-RUNNER-TLS — modo pre-flight"
}

@test "--pre-flight emite seções [2] [3] [4]" {
    run bash "$SPECIALIST" --pre-flight
    assert_success
    assert_output --partial "[2] Variáveis de proxy/http"
    assert_output --partial "[3] CAs custom"
    assert_output --partial "[4] Resolução DNS de api.github.com"
}

@test "--pre-flight emite hint para --reactive ao final" {
    run bash "$SPECIALIST" --pre-flight
    assert_success
    assert_output --partial "diagnóstico completo"
    assert_output --partial "--reactive"
}

@test "--pre-flight tem rc=0 (best-effort)" {
    run bash "$SPECIALIST" --pre-flight
    assert_equal "$status" 0
}

# ────────────────────────────────────────────────────────────────────────────
# Default (sem args) → --pre-flight (descoberta via doctor)
# ────────────────────────────────────────────────────────────────────────────

@test "sem argumentos: assume --pre-flight" {
    run bash "$SPECIALIST"
    assert_success
    assert_output --partial "CHECK-RUNNER-TLS — modo pre-flight"
}

# ────────────────────────────────────────────────────────────────────────────
# Modo --reactive
# ────────────────────────────────────────────────────────────────────────────

@test "--reactive com dir válido delega ao helper de 6 seções" {
    run bash "$SPECIALIST" --reactive "$RUNNER_TMPDIR"
    assert_success
    # Helper canônico em _runner.sh emite 6 seções com header próprio
    assert_output --partial "DIAGNÓSTICO TLS — config.sh falhou no handshake"
    assert_output --partial "[1]"
    assert_output --partial "[2]"
    assert_output --partial "[3]"
    assert_output --partial "[4]"
    assert_output --partial "[5]"
    assert_output --partial "[6]"
    assert_output --partial "FIM DO DIAGNÓSTICO TLS"
}

@test "--reactive com dir inexistente → erro com exit 2" {
    run bash "$SPECIALIST" --reactive /tmp/nonexistent-dir-$$
    assert_equal "$status" 2
    assert_output --partial "RUNNER_DIR não existe"
}

@test "--reactive sem dir usa default \$HOME/actions-runner" {
    # Não dá pra testar sem mexer em $HOME; smoke test de argparse.
    # Verifica que aceita --reactive sem dir e tenta o default.
    run bash "$SPECIALIST" --reactive
    # Pode dar exit 0 (helper executa) ou 2 (default não existe).
    # Importante: NÃO da erro de argparse "argumento desconhecido".
    refute_output --partial "argumento desconhecido"
}

# ────────────────────────────────────────────────────────────────────────────
# Argparse e ajuda
# ────────────────────────────────────────────────────────────────────────────

@test "--help mostra os dois modos" {
    run bash "$SPECIALIST" --help
    assert_success
    assert_output --partial "--pre-flight"
    assert_output --partial "--reactive"
}

@test "--help mostra exit codes" {
    run bash "$SPECIALIST" --help
    assert_success
    assert_output --partial "Exit code"
    assert_output --partial "0"
    assert_output --partial "2"
}

@test "--help cita TSK00.04.10" {
    run bash "$SPECIALIST" --help
    assert_success
    assert_output --partial "TSK00.04.10"
}

@test "--runner-dir alternativa para --reactive [DIR]" {
    run bash "$SPECIALIST" --reactive --runner-dir "$RUNNER_TMPDIR"
    assert_success
    assert_output --partial "DIAGNÓSTICO TLS"
}

@test "argumento desconhecido → exit 2 com mensagem clara" {
    run bash "$SPECIALIST" --foo-bar-unknown
    assert_equal "$status" 2
    assert_output --partial "argumento desconhecido"
}

# ────────────────────────────────────────────────────────────────────────────
# Integração com doctor
# ────────────────────────────────────────────────────────────────────────────

@test "doctor --list inclui check-runner-tls" {
    run bash "${PROJECT_DIR}/siscan-server-doctor.sh" --list
    assert_success
    assert_output --partial "check-runner-tls"
    assert_output --partial "Diagnóstico estruturado de TLS"
}

@test "doctor --only check-runner-tls executa apenas o specialist" {
    run bash "${PROJECT_DIR}/siscan-server-doctor.sh" --only check-runner-tls
    assert_success
    assert_output --partial "CHECK-RUNNER-TLS — modo pre-flight"
    assert_output --partial "1/1 specialists OK"
}
