#!/usr/bin/env bats
# Testes de contrato entre docker-compose.yml, .env.sample e .env.help.json

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

REPO_DIR="${BATS_TEST_DIRNAME}/../.."
ENV_SAMPLE="${REPO_DIR}/.env.sample"
ENV_HELP_JSON="${REPO_DIR}/.env.help.json"
COMPOSE_FILE="${REPO_DIR}/docker-compose.yml"

required_vars=(
    "HOST_DATABASE_PATH"
    "HOST_LOG_DIR"
    "HOST_SISCAN_REPORTS_INPUT_DIR"
    "HOST_REPORTS_OUTPUT_CONSOLIDATED_DIR"
    "HOST_REPORTS_OUTPUT_CONSOLIDATED_PDFS_DIR"
    "HOST_CONFIG_DIR"
    "SECRET_KEY"
)

bind_source_vars=(
    "HOST_DATABASE_PATH"
    "HOST_SISCAN_REPORTS_INPUT_DIR"
    "HOST_REPORTS_OUTPUT_CONSOLIDATED_DIR"
    "HOST_REPORTS_OUTPUT_CONSOLIDATED_PDFS_DIR"
    "HOST_CONFIG_DIR"
    "HOST_LOG_DIR"
)

@test ".env.sample contém todas as variáveis obrigatórias do assistente" {
    for var_name in "${required_vars[@]}"; do
        run grep -E "^${var_name}=" "${ENV_SAMPLE}"
        assert_success "variável ausente em .env.sample: ${var_name}"
    done
}

@test ".env.help.json documenta todas as variáveis obrigatórias do assistente" {
    for var_name in "${required_vars[@]}"; do
        run jq -er --arg key "${var_name}" '.keys[$key].help | strings | length > 0' "${ENV_HELP_JSON}"
        assert_success "variável sem help em .env.help.json: ${var_name}"
    done
}

@test "todas as variáveis HOST_* usadas como bind source no compose existem no .env.sample" {
    for var_name in "${bind_source_vars[@]}"; do
        run grep -F "source: \${${var_name}}" "${COMPOSE_FILE}"
        assert_success "variável não usada como bind source no compose: ${var_name}"

        run grep -E "^${var_name}=" "${ENV_SAMPLE}"
        assert_success "variável usada no compose mas ausente em .env.sample: ${var_name}"
    done
}
