#!/usr/bin/env bats
# Testes para _load_env_help_json

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

FIXTURES_DIR="${BATS_TEST_DIRNAME}/../fixtures"

setup() {
    TEST_DIR="$(mktemp -d)"
    source "${BATS_TEST_DIRNAME}/../../siscan-assistente.sh"
    SCRIPT_DIR="$TEST_DIR"
}

teardown() {
    rm -rf "$TEST_DIR"
}

_require_jq() {
    if ! command -v jq &>/dev/null; then
        skip "jq não disponível"
    fi
}

@test "não falha quando .env.help.json está ausente" {
    run _load_env_help_json
    assert_success
}

@test "carrega help text de SECRET_KEY a partir do fixture" {
    _require_jq
    cp "${FIXTURES_DIR}/env_help.json" "${TEST_DIR}/.env.help.json"
    _load_env_help_json
    [ -n "${ENV_HELP_TEXTS[SECRET_KEY]}" ]
}

@test "carrega required=true para SECRET_KEY" {
    _require_jq
    cp "${FIXTURES_DIR}/env_help.json" "${TEST_DIR}/.env.help.json"
    _load_env_help_json
    [ "${ENV_HELP_ENTRIES[SECRET_KEY__required]}" = "true" ]
}

@test "carrega type=generated_secret para SECRET_KEY" {
    _require_jq
    cp "${FIXTURES_DIR}/env_help.json" "${TEST_DIR}/.env.help.json"
    _load_env_help_json
    [ "${ENV_HELP_ENTRIES[SECRET_KEY__type]}" = "generated_secret" ]
}

@test "carrega secret=true para SECRET_KEY" {
    _require_jq
    cp "${FIXTURES_DIR}/env_help.json" "${TEST_DIR}/.env.help.json"
    _load_env_help_json
    [ "${ENV_HELP_ENTRIES[SECRET_KEY__secret]}" = "true" ]
}

@test "carrega required=false para APP_LOG_LEVEL" {
    _require_jq
    cp "${FIXTURES_DIR}/env_help.json" "${TEST_DIR}/.env.help.json"
    _load_env_help_json
    [ "${ENV_HELP_ENTRIES[APP_LOG_LEVEL__required]}" = "false" ]
}

@test "carrega example de HOST_DATABASE_PATH" {
    _require_jq
    cp "${FIXTURES_DIR}/env_help.json" "${TEST_DIR}/.env.help.json"
    _load_env_help_json
    [ -n "${ENV_HELP_ENTRIES[HOST_DATABASE_PATH__example]}" ]
}
