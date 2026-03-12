#!/usr/bin/env bats
# Testes para check_env_configured

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

FIXTURES_DIR="${BATS_TEST_DIRNAME}/../fixtures"

setup() {
    TEST_DIR="$(mktemp -d)"
    source "${BATS_TEST_DIRNAME}/../../siscan-assistente.sh"
    # Sobrescreve SCRIPT_DIR para isolar o .env do host real
    SCRIPT_DIR="$TEST_DIR"
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "retorna falso quando .env está ausente" {
    run check_env_configured "false"
    assert_failure
}

@test "retorna falso quando SECRET_KEY está vazia" {
    cp "${FIXTURES_DIR}/env_missing_secret" "${TEST_DIR}/.env"
    run check_env_configured "false"
    assert_failure
}

@test "retorna falso quando variáveis HOST_* obrigatórias estão ausentes" {
    cp "${FIXTURES_DIR}/env_missing_host" "${TEST_DIR}/.env"
    run check_env_configured "false"
    assert_failure
}

@test "retorna verdadeiro quando todas as variáveis obrigatórias estão presentes" {
    cp "${FIXTURES_DIR}/env_complete" "${TEST_DIR}/.env"
    run check_env_configured "false"
    assert_success
}

@test "exibe mensagem de configuração necessária quando .env ausente e show_message=true" {
    run check_env_configured "true"
    assert_failure
    assert_output --partial "CONFIGURAÇÃO NECESSÁRIA"
}

@test "exibe variáveis faltando quando show_message=true" {
    cp "${FIXTURES_DIR}/env_missing_host" "${TEST_DIR}/.env"
    run check_env_configured "true"
    assert_failure
    assert_output --partial "HOST_DATABASE_PATH"
    assert_output --partial "HOST_SISCAN_REPORTS_INPUT_DIR"
    assert_output --partial "HOST_REPORTS_OUTPUT_CONSOLIDATED_PDFS_DIR"
}

@test "não exibe mensagem quando show_message=false" {
    run check_env_configured "false"
    assert_failure
    assert_output ""
}
