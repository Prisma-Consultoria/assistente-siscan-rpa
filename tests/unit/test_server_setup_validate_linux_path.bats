#!/usr/bin/env bats
# Testes para _validate_linux_path (siscan-server-setup.sh)

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

setup() {
    source "${BATS_TEST_DIRNAME}/../../siscan-server-setup.sh"
}

# ── Caminhos válidos (Linux) ─────────────────────────────────────────────────

@test "aceita caminho Linux absoluto" {
    run _validate_linux_path "HOST_LOG_DIR" "/opt/siscan-rpa/logs"
    assert_success
}

@test "aceita caminho Linux com subdiretórios" {
    run _validate_linux_path "HOST_CONFIG_DIR" "/opt/siscan-rpa/media/reports/consolidated"
    assert_success
}

@test "aceita valor vazio (variável não preenchida)" {
    run _validate_linux_path "HOST_LOG_DIR" ""
    assert_success
}

@test "aceita caminho relativo (sem barra inicial)" {
    run _validate_linux_path "HOST_LOG_DIR" "logs/app"
    assert_success
}

# ── Drive letter Windows ─────────────────────────────────────────────────────

@test "rejeita caminho com drive letter maiúsculo (C:\\...)" {
    run _validate_linux_path "HOST_LOG_DIR" 'C:\siscan-rpa\logs'
    assert_failure
}

@test "rejeita caminho com drive letter minúsculo (c:\\...)" {
    run _validate_linux_path "HOST_LOG_DIR" 'c:\siscan-rpa\logs'
    assert_failure
}

@test "rejeita caminho com drive letter e barra normal (C:/...)" {
    run _validate_linux_path "HOST_LOG_DIR" 'C:/siscan-rpa/logs'
    assert_failure
}

@test "mensagem de erro menciona drive letter ao detectar C:\\" {
    run _validate_linux_path "HOST_LOG_DIR" 'C:\siscan-rpa\logs'
    assert_output --partial "drive Windows"
}

# ── Caminho UNC ──────────────────────────────────────────────────────────────

@test "rejeita caminho UNC (\\\\servidor\\share)" {
    run _validate_linux_path "HOST_CONFIG_DIR" '\\servidor\share\siscan'
    assert_failure
}

@test "mensagem de erro menciona UNC ao detectar \\\\" {
    run _validate_linux_path "HOST_CONFIG_DIR" '\\servidor\share\siscan'
    assert_output --partial "UNC"
}

# ── Backslash como separador ─────────────────────────────────────────────────

@test "rejeita caminho com backslash como separador" {
    run _validate_linux_path "HOST_LOG_DIR" '/opt\siscan-rpa\logs'
    assert_failure
}

@test "mensagem de erro menciona separador ao detectar backslash" {
    run _validate_linux_path "HOST_LOG_DIR" '/opt\siscan-rpa\logs'
    assert_output --partial "separador"
}

# ── Exibição do nome da variável ─────────────────────────────────────────────

@test "mensagem de aviso exibe o nome da variável" {
    run _validate_linux_path "HOST_SISCAN_REPORTS_INPUT_DIR" 'C:\dados'
    assert_output --partial "HOST_SISCAN_REPORTS_INPUT_DIR"
}
