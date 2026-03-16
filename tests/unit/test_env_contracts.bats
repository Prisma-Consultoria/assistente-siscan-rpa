#!/usr/bin/env bats
# Testes de contrato entre docker-compose.yml, .env.sample e .env.help.json

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

REPO_DIR="${BATS_TEST_DIRNAME}/../.."
ENV_SAMPLE="${REPO_DIR}/.env.sample"
ENV_HELP_JSON="${REPO_DIR}/.env.help.json"
COMPOSE_FILE="${REPO_DIR}/docker-compose.yml"

# Variáveis marcadas como required:true no .env.help.json
required_vars=(
    "DATABASE_PASSWORD"
    "SECRET_KEY"
)

# Variáveis de volume nomeado usadas no compose
volume_vars=(
    "VOLUME_DB"
    "VOLUME_DATA"
    "VOLUME_MEDIA"
    "VOLUME_LOGS"
    "VOLUME_CONFIG"
)

# Variáveis de banco de dados usadas no compose
database_vars=(
    "DATABASE_NAME"
    "DATABASE_USER"
    "DATABASE_PASSWORD"
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

@test "todas as variáveis VOLUME_* do compose existem no .env.sample" {
    for var_name in "${volume_vars[@]}"; do
        run grep -F "\${${var_name}" "${COMPOSE_FILE}"
        assert_success "variável de volume não usada no compose: ${var_name}"

        run grep -E "^${var_name}=" "${ENV_SAMPLE}"
        assert_success "variável de volume ausente em .env.sample: ${var_name}"
    done
}
