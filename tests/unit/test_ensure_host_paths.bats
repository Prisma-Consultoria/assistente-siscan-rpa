#!/usr/bin/env bats
# Testes para ensure_host_paths

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

setup() {
    TEST_DIR="$(mktemp -d)"
    DATA_DIR="$(mktemp -d)"
    source "${BATS_TEST_DIRNAME}/../../siscan-assistente.sh"
    SCRIPT_DIR="$TEST_DIR"

    # Monta .env com caminhos dentro do DATA_DIR temporário (stack PostgreSQL — sem HOST_DATABASE_PATH)
    cat > "${TEST_DIR}/.env" <<EOF
HOST_LOG_DIR=${DATA_DIR}/logs
HOST_SISCAN_REPORTS_INPUT_DIR=${DATA_DIR}/media/downloads
HOST_REPORTS_OUTPUT_CONSOLIDATED_DIR=${DATA_DIR}/media/reports/consolidated
HOST_REPORTS_OUTPUT_CONSOLIDATED_PDFS_DIR=${DATA_DIR}/media/reports/consolidated/laudos
HOST_CONFIG_DIR=${DATA_DIR}/config
SECRET_KEY=aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899
EOF
}

teardown() {
    rm -rf "$TEST_DIR" "$DATA_DIR"
}

@test "cria todos os diretórios definidos no .env" {
    ensure_host_paths
    [ -d "${DATA_DIR}/logs" ]
    [ -d "${DATA_DIR}/media/downloads" ]
    [ -d "${DATA_DIR}/media/reports/consolidated" ]
    [ -d "${DATA_DIR}/media/reports/consolidated/laudos" ]
    [ -d "${DATA_DIR}/config" ]
}

@test "não falha quando diretórios já existem" {
    mkdir -p "${DATA_DIR}/logs"
    mkdir -p "${DATA_DIR}/media/downloads"
    run ensure_host_paths
    assert_success
}

@test "retorna 0 (sucesso) quando todos os caminhos são criados" {
    run ensure_host_paths
    assert_success
}
