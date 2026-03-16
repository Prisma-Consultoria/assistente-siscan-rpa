#!/usr/bin/env bats
# Testes para _read_env_value e _set_env_value (siscan-server-setup.sh)

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

setup() {
    source "${BATS_TEST_DIRNAME}/../../siscan-server-setup.sh"
    ENV_FILE="$(mktemp)"
    cat > "${ENV_FILE}" <<'EOF'
# Comentário
APP_LOG_LEVEL=INFO
DATABASE_HOST=192.168.1.10
DATABASE_PASSWORD=senha_segura
SECRET_KEY=
HOST_LOG_DIR=/opt/siscan-rpa/logs
EOF
}

teardown() {
    rm -f "${ENV_FILE}"
}

# ── _read_env_value ──────────────────────────────────────────────────────────

@test "_read_env_value retorna valor de chave existente" {
    run _read_env_value "${ENV_FILE}" "APP_LOG_LEVEL"
    assert_success
    assert_output "INFO"
}

@test "_read_env_value retorna hostname correto" {
    run _read_env_value "${ENV_FILE}" "DATABASE_HOST"
    assert_success
    assert_output "192.168.1.10"
}

@test "_read_env_value retorna vazio para chave com valor vazio" {
    run _read_env_value "${ENV_FILE}" "SECRET_KEY"
    assert_success
    assert_output ""
}

@test "_read_env_value retorna vazio para chave inexistente" {
    run _read_env_value "${ENV_FILE}" "CHAVE_INEXISTENTE"
    assert_output ""
}

@test "_read_env_value retorna caminho completo sem alteração" {
    run _read_env_value "${ENV_FILE}" "HOST_LOG_DIR"
    assert_success
    assert_output "/opt/siscan-rpa/logs"
}

@test "_read_env_value ignora linhas de comentário" {
    run _read_env_value "${ENV_FILE}" "Comentário"
    assert_output ""
}

# ── _set_env_value — atualizar chave existente ───────────────────────────────

@test "_set_env_value atualiza valor de chave existente" {
    _set_env_value "${ENV_FILE}" "APP_LOG_LEVEL" "DEBUG"
    run _read_env_value "${ENV_FILE}" "APP_LOG_LEVEL"
    assert_output "DEBUG"
}

@test "_set_env_value atualiza DATABASE_HOST" {
    _set_env_value "${ENV_FILE}" "DATABASE_HOST" "10.0.0.5"
    run _read_env_value "${ENV_FILE}" "DATABASE_HOST"
    assert_output "10.0.0.5"
}

@test "_set_env_value preenche chave que estava vazia" {
    _set_env_value "${ENV_FILE}" "SECRET_KEY" "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
    run _read_env_value "${ENV_FILE}" "SECRET_KEY"
    assert_output "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
}

# ── _set_env_value — acrescentar chave nova ──────────────────────────────────

@test "_set_env_value acrescenta chave nova ao final do arquivo" {
    _set_env_value "${ENV_FILE}" "NOVA_VARIAVEL" "valor_novo"
    run _read_env_value "${ENV_FILE}" "NOVA_VARIAVEL"
    assert_output "valor_novo"
}

@test "_set_env_value não duplica chave existente" {
    _set_env_value "${ENV_FILE}" "APP_LOG_LEVEL" "WARNING"
    local count
    count=$(grep -c "^APP_LOG_LEVEL=" "${ENV_FILE}")
    [ "${count}" -eq 1 ]
}

@test "_set_env_value preserva outras chaves ao atualizar" {
    _set_env_value "${ENV_FILE}" "APP_LOG_LEVEL" "ERROR"
    run _read_env_value "${ENV_FILE}" "DATABASE_HOST"
    assert_output "192.168.1.10"
}

@test "_set_env_value aceita caminho Linux como valor" {
    _set_env_value "${ENV_FILE}" "HOST_LOG_DIR" "/var/log/siscan"
    run _read_env_value "${ENV_FILE}" "HOST_LOG_DIR"
    assert_output "/var/log/siscan"
}
