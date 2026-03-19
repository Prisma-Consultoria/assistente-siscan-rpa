#!/usr/bin/env bats
# Testes de contrato entre docker-compose.prd.host.yml, .env.host.sample e .env.help.json

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

REPO_DIR="${BATS_TEST_DIRNAME}/../.."
ENV_SAMPLE="${REPO_DIR}/.env.host.sample"
ENV_HELP_JSON="${REPO_DIR}/.env.help.json"
COMPOSE_FILE="${REPO_DIR}/docker-compose.prd.host.yml"

# Variáveis marcadas como required:true no .env.help.json
required_vars=(
    "DATABASE_PASSWORD"
    "SECRET_KEY"
)

# Volumes nomeados declarados no compose de produção HOST
named_volumes=(
    "siscan-data-artifacts"
    "siscan-postgres-data"
)

# Variáveis de banco de dados usadas no compose
database_vars=(
    "DATABASE_NAME"
    "DATABASE_USER"
    "DATABASE_PASSWORD"
)

@test ".env.host.sample contém todas as variáveis obrigatórias do assistente" {
    for var_name in "${required_vars[@]}"; do
        run grep -E "^${var_name}=" "${ENV_SAMPLE}"
        assert_success "variável ausente em .env.host.sample: ${var_name}"
    done
}

@test ".env.help.json documenta todas as variáveis obrigatórias do assistente" {
    for var_name in "${required_vars[@]}"; do
        run jq -er --arg key "${var_name}" '.keys[$key].help | strings | length > 0' "${ENV_HELP_JSON}"
        assert_success "variável sem help em .env.help.json: ${var_name}"
    done
}

@test "volumes nomeados do compose estão declarados na seção volumes:" {
    for vol_name in "${named_volumes[@]}"; do
        run grep -E "^  ${vol_name}:" "${COMPOSE_FILE}"
        assert_success "volume nomeado ausente no compose: ${vol_name}"
    done
}
