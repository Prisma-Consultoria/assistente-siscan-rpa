#!/usr/bin/env bats
# Testes para runner_validate_binaries em scripts/deploy_server/_runner.sh
#
# Hotfix F00.04 (2026-05-27): a função era shallow (só config.sh + svc.sh)
# e fazia `runner_get_state` devolver state 2 mesmo após `rm -rf bin/
# externals/`. Resultado: config.sh era invocado em ramo 2 e crashava com
# "./bin/Runner.Listener: No such file or directory". Validação agora é
# profunda: checa também bin/Runner.Listener (entry-point do .NET) e
# diretório externals/ (node runtime).

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

setup() {
    source "${BATS_TEST_DIRNAME}/../../scripts/deploy_server/_runner.sh"

    RUNNER_DIR="$(mktemp -d)"
    # Instalação completa de referência — todos os 4 artefatos presentes.
    : > "${RUNNER_DIR}/config.sh";           chmod +x "${RUNNER_DIR}/config.sh"
    : > "${RUNNER_DIR}/svc.sh";              chmod +x "${RUNNER_DIR}/svc.sh"
    mkdir -p "${RUNNER_DIR}/bin" "${RUNNER_DIR}/externals/node20/bin"
    : > "${RUNNER_DIR}/bin/Runner.Listener"; chmod +x "${RUNNER_DIR}/bin/Runner.Listener"
}

teardown() {
    command rm -rf "${RUNNER_DIR}"
}

@test "instalação completa: 4 artefatos presentes → retorna 0" {
    run runner_validate_binaries "${RUNNER_DIR}"
    assert_success
}

@test "falta config.sh → retorna 1" {
    rm -f "${RUNNER_DIR}/config.sh"
    run runner_validate_binaries "${RUNNER_DIR}"
    assert_failure
}

@test "falta svc.sh → retorna 1" {
    rm -f "${RUNNER_DIR}/svc.sh"
    run runner_validate_binaries "${RUNNER_DIR}"
    assert_failure
}

@test "regressão lab 2026-05-27: falta bin/Runner.Listener → retorna 1 (não 0)" {
    # Reproduz exatamente o cenário operacional: operador apaga bin/ e
    # externals/ (pra forçar re-download) mas deixa config.sh e svc.sh
    # intactos. Antes do hotfix isso passava como state 2 e config.sh
    # crashava. Agora retorna 1 → state 1 → ramo de download dispara.
    rm -rf "${RUNNER_DIR}/bin" "${RUNNER_DIR}/externals"
    run runner_validate_binaries "${RUNNER_DIR}"
    assert_failure
}

@test "falta só bin/Runner.Listener (mas dir bin/ existe) → retorna 1" {
    rm -f "${RUNNER_DIR}/bin/Runner.Listener"
    run runner_validate_binaries "${RUNNER_DIR}"
    assert_failure
}

@test "falta diretório externals/ → retorna 1" {
    rm -rf "${RUNNER_DIR}/externals"
    run runner_validate_binaries "${RUNNER_DIR}"
    assert_failure
}

@test "bin/Runner.Listener sem permissão de execução → retorna 1" {
    chmod -x "${RUNNER_DIR}/bin/Runner.Listener"
    run runner_validate_binaries "${RUNNER_DIR}"
    assert_failure
}

@test "config.sh sem permissão de execução → retorna 1" {
    chmod -x "${RUNNER_DIR}/config.sh"
    run runner_validate_binaries "${RUNNER_DIR}"
    assert_failure
}

# ────────────────────────────────────────────────────────────────────────────
# Integração com runner_get_state — comportamento do classificador
# ────────────────────────────────────────────────────────────────────────────

@test "runner_get_state: dir com launchers mas sem bin/Runner.Listener → state 1 (não 2)" {
    # Antes do hotfix: state 2 (binários "presentes"); recover pulava
    # download e crashava em config.sh. Agora: state 1; recover dispara
    # runner_download_binaries.
    rm -rf "${RUNNER_DIR}/bin" "${RUNNER_DIR}/externals"
    # .runner ausente — irrelevante quando state ≤ 1
    run runner_get_state "${RUNNER_DIR}"
    assert_success
    assert_output "1"
}

@test "runner_get_state: dir completo + .runner ausente → state 2" {
    run runner_get_state "${RUNNER_DIR}"
    assert_success
    assert_output "2"
}
