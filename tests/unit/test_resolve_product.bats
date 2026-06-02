#!/usr/bin/env bats
# Testes para resolve_product (scripts/deploy_server/_common.sh — TSK00.05.05)
#
# Cobre a política de prioridade do contexto de produto:
#   1. SISCAN_PRODUCT_CLI (CLI --product) — máxima
#   2. $SISCAN_PRODUCT (env var herdada)
#   3. SISCAN_PRODUCT lida do $ENV_FILE — fallback (comportamento histórico)
#
# E o warning emitido quando --product diverge do .env.

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

setup() {
    TEST_DIR="$(mktemp -d)"
    ENV_FILE="${TEST_DIR}/.env"
    export ENV_FILE

    # Sourceia _common.sh em modo human (warn() vai pra stderr) — sem side
    # effects (o módulo não dispara nada no source).
    OUTPUT_MODE="human"
    SPECIALIST_NAME="test_resolve_product"
    # shellcheck source=/dev/null
    source "${BATS_TEST_DIRNAME}/../../scripts/deploy_server/_common.sh"
}

teardown() {
    rm -rf "${TEST_DIR}"
    unset SISCAN_PRODUCT SISCAN_PRODUCT_CLI ENV_FILE
}

# ── Cenário 1: --product CLI vence o .env (+ warning) ───────────────────────

@test "resolve_product: --product CLI vence quando .env tem outro valor (emite warning)" {
    cat > "${ENV_FILE}" <<EOF
SISCAN_PRODUCT=dashboard
EOF
    SISCAN_PRODUCT_CLI="rpa"
    SISCAN_PRODUCT=""
    run resolve_product
    assert_success
    # Re-roda dentro do mesmo shell pra capturar a variável global setada
    SISCAN_PRODUCT_CLI="rpa"
    SISCAN_PRODUCT=""
    resolve_product
    [ "${SISCAN_PRODUCT}" = "rpa" ]
}

@test "resolve_product: emite warning em human mode quando --product != .env" {
    cat > "${ENV_FILE}" <<EOF
SISCAN_PRODUCT=dashboard
EOF
    SISCAN_PRODUCT_CLI="rpa"
    SISCAN_PRODUCT=""
    OUTPUT_MODE="human"
    # warn() escreve em stderr — capturamos com run + 2>&1 não trivial em bats;
    # avaliamos via $output combinado.
    run bash -c "
        OUTPUT_MODE=human
        SPECIALIST_NAME=test
        ENV_FILE='${ENV_FILE}'
        source '${BATS_TEST_DIRNAME}/../../scripts/deploy_server/_common.sh'
        SISCAN_PRODUCT_CLI=rpa
        SISCAN_PRODUCT=''
        resolve_product 2>&1
    "
    assert_success
    assert_output --partial "rpa"
    assert_output --partial "dashboard"
}

# ── Cenário 2: --product CLI sem .env retorna o valor da CLI ────────────────

@test "resolve_product: --product CLI sem .env retorna o valor da CLI" {
    # ENV_FILE não existe (nenhum touch)
    rm -f "${ENV_FILE}"
    SISCAN_PRODUCT_CLI="rpa"
    SISCAN_PRODUCT=""
    resolve_product
    [ "${SISCAN_PRODUCT}" = "rpa" ]
}

@test "resolve_product: --product CLI sem .env e mesmo SISCAN_PRODUCT na env var — CLI vence" {
    rm -f "${ENV_FILE}"
    SISCAN_PRODUCT_CLI="full"
    SISCAN_PRODUCT="dashboard"  # env var deveria ser sobrescrita pela CLI
    resolve_product
    [ "${SISCAN_PRODUCT}" = "full" ]
}

# ── Cenário 3: sem CLI, env var $SISCAN_PRODUCT é usada ─────────────────────

@test "resolve_product: sem CLI, env var \$SISCAN_PRODUCT é usada" {
    rm -f "${ENV_FILE}"
    SISCAN_PRODUCT_CLI=""
    SISCAN_PRODUCT="dashboard"
    resolve_product
    [ "${SISCAN_PRODUCT}" = "dashboard" ]
}

@test "resolve_product: sem CLI, env var vence .env" {
    cat > "${ENV_FILE}" <<EOF
SISCAN_PRODUCT=full
EOF
    SISCAN_PRODUCT_CLI=""
    SISCAN_PRODUCT="rpa"
    resolve_product
    [ "${SISCAN_PRODUCT}" = "rpa" ]
}

# ── Cenário 4: sem CLI nem env var, .env é fallback (comportamento atual) ───

@test "resolve_product: sem CLI nem env var, .env é fallback (comportamento atual)" {
    cat > "${ENV_FILE}" <<EOF
SISCAN_PRODUCT=dashboard
EOF
    SISCAN_PRODUCT_CLI=""
    SISCAN_PRODUCT=""
    resolve_product
    [ "${SISCAN_PRODUCT}" = "dashboard" ]
}

@test "resolve_product: lê valor do .env mesmo com aspas envolventes" {
    cat > "${ENV_FILE}" <<EOF
SISCAN_PRODUCT="rpa"
EOF
    SISCAN_PRODUCT_CLI=""
    SISCAN_PRODUCT=""
    resolve_product
    [ "${SISCAN_PRODUCT}" = "rpa" ]
}

# ── Cenário 5: sem nada, SISCAN_PRODUCT permanece vazio ─────────────────────

@test "resolve_product: sem nada, SISCAN_PRODUCT permanece vazio" {
    rm -f "${ENV_FILE}"
    SISCAN_PRODUCT_CLI=""
    SISCAN_PRODUCT=""
    resolve_product
    [ -z "${SISCAN_PRODUCT}" ]
}

@test "resolve_product: .env existe mas sem SISCAN_PRODUCT — resultado vazio" {
    cat > "${ENV_FILE}" <<EOF
DATABASE_HOST=localhost
APP_LOG_LEVEL=INFO
EOF
    SISCAN_PRODUCT_CLI=""
    SISCAN_PRODUCT=""
    resolve_product
    [ -z "${SISCAN_PRODUCT}" ]
}

# ── Idempotência e export ───────────────────────────────────────────────────

@test "resolve_product: exporta SISCAN_PRODUCT (visível em subshells)" {
    SISCAN_PRODUCT_CLI="rpa"
    SISCAN_PRODUCT=""
    resolve_product
    # SISCAN_PRODUCT foi exportada — bash -c sees the value
    run bash -c 'echo "$SISCAN_PRODUCT"'
    assert_output "rpa"
}

@test "resolve_product: rodar 2x com mesmo input é idempotente" {
    SISCAN_PRODUCT_CLI="dashboard"
    SISCAN_PRODUCT=""
    resolve_product
    local first="${SISCAN_PRODUCT}"
    resolve_product
    [ "${first}" = "${SISCAN_PRODUCT}" ]
    [ "${SISCAN_PRODUCT}" = "dashboard" ]
}
