#!/usr/bin/env bats
# Testes para ensure_host_paths (siscan-server-setup.sh)
# Diferença em relação ao assistente: sem HOST_DATABASE_PATH (PostgreSQL externo)

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

setup() {
    source "${BATS_TEST_DIRNAME}/../../siscan-server-setup.sh"
    DATA_DIR="$(mktemp -d)"
    ENV_FILE="$(mktemp)"

    cat > "${ENV_FILE}" <<EOF
HOST_LOG_DIR=${DATA_DIR}/logs
HOST_SISCAN_REPORTS_INPUT_DIR=${DATA_DIR}/media/downloads
HOST_REPORTS_OUTPUT_CONSOLIDATED_DIR=${DATA_DIR}/media/reports/consolidated
HOST_REPORTS_OUTPUT_CONSOLIDATED_PDFS_DIR=${DATA_DIR}/media/reports/consolidated/laudos
HOST_CONFIG_DIR=${DATA_DIR}/config
EOF
}

teardown() {
    rm -rf "${DATA_DIR}"
    rm -f "${ENV_FILE}"
}

@test "cria todos os diretórios HOST_* definidos no .env" {
    run ensure_host_paths "${ENV_FILE}"
    assert_success
    [ -d "${DATA_DIR}/logs" ]
    [ -d "${DATA_DIR}/media/downloads" ]
    [ -d "${DATA_DIR}/media/reports/consolidated" ]
    [ -d "${DATA_DIR}/media/reports/consolidated/laudos" ]
    [ -d "${DATA_DIR}/config" ]
}

@test "retorna 0 quando todos os diretórios são criados com sucesso" {
    run ensure_host_paths "${ENV_FILE}"
    assert_success
}

@test "não falha quando diretórios já existem (idempotente)" {
    mkdir -p "${DATA_DIR}/logs"
    mkdir -p "${DATA_DIR}/media/downloads"
    run ensure_host_paths "${ENV_FILE}"
    assert_success
}

@test "cria diretórios aninhados com mkdir -p" {
    run ensure_host_paths "${ENV_FILE}"
    assert_success
    [ -d "${DATA_DIR}/media/reports/consolidated/laudos" ]
}

@test "não cria HOST_DATABASE_PATH (não existe nesta stack — banco é externo)" {
    run ensure_host_paths "${ENV_FILE}"
    # Nenhum arquivo .db deve ter sido criado
    local db_files
    db_files=$(find "${DATA_DIR}" -name "*.db" 2>/dev/null | wc -l)
    [ "${db_files}" -eq 0 ]
}

@test "tolera variável HOST_* não definida no .env sem falhar" {
    # .env sem HOST_CONFIG_DIR
    cat > "${ENV_FILE}" <<EOF
HOST_LOG_DIR=${DATA_DIR}/logs
HOST_SISCAN_REPORTS_INPUT_DIR=${DATA_DIR}/media/downloads
HOST_REPORTS_OUTPUT_CONSOLIDATED_DIR=${DATA_DIR}/media/reports/consolidated
HOST_REPORTS_OUTPUT_CONSOLIDATED_PDFS_DIR=${DATA_DIR}/media/reports/consolidated/laudos
EOF
    run ensure_host_paths "${ENV_FILE}"
    assert_success
}

@test "cria HOST_CONFIG_DIR mesmo quando é o único definido" {
    cat > "${ENV_FILE}" <<EOF
HOST_CONFIG_DIR=${DATA_DIR}/config
EOF
    ensure_host_paths "${ENV_FILE}"
    [ -d "${DATA_DIR}/config" ]
}
