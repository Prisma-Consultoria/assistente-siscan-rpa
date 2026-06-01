#!/usr/bin/env bats
# Testes para o fallback de SISCAN_PRODUCT no siscan-server-setup.sh
# (correção de fallback ao .env — TSK00.05.05 / PR #101).
#
# Cobre a política de prioridade no setup, alinhada com resolve_product:
#   1. --product NAME na CLI vence sempre
#   2. SISCAN_PRODUCT herdado do ambiente
#   3. SISCAN_PRODUCT lido do .env existente em $COMPOSE_DIR (idempotência)
#   4. Prompt interativo (fluxo histórico — primeira instalação)
#
# Como o fallback vive dentro do bloco MAIN (after `if [[ BASH_SOURCE == $0 ]]`),
# este suite NÃO sourceia o setup: invoca-o como subprocess com timeout curto
# para inspecionar apenas o banner inicial (até a Fase 0 que invoca o doctor).

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

SETUP_SH="${BATS_TEST_DIRNAME}/../../siscan-server-setup.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
}

teardown() {
    rm -rf "${TEST_DIR}"
}

# Roda o setup com timeout curto e devolve stdout+stderr.
# O timeout é deliberado: queremos inspecionar só o banner inicial (que
# precede a Fase 0 do doctor). 0 ou 124 (timeout) ambos são aceitáveis.
_run_setup() {
    COMPOSE_DIR="${TEST_DIR}" timeout 5s bash "${SETUP_SH}" "$@" 2>&1
}

# ── Cenário A: --product CLI vence o .env ───────────────────────────────────

@test "setup: --product dashboard sobrescreve SISCAN_PRODUCT=rpa do .env" {
    echo "SISCAN_PRODUCT=rpa" > "${TEST_DIR}/.env"
    run _run_setup --product dashboard
    assert_output --partial "Produto            : dashboard"
    refute_output --partial "Produto            : rpa"
}

# ── Cenário B: fallback ao .env quando --product ausente ────────────────────

@test "setup: sem --product, .env=rpa → herda rpa (idempotência)" {
    echo "SISCAN_PRODUCT=rpa" > "${TEST_DIR}/.env"
    run _run_setup
    assert_output --partial "herdado de"
    assert_output --partial "Produto            : rpa"
    refute_output --partial "Selecione o produto a instalar"
}

@test "setup: sem --product, .env=dashboard → herda dashboard" {
    echo "SISCAN_PRODUCT=dashboard" > "${TEST_DIR}/.env"
    run _run_setup
    assert_output --partial "Produto            : dashboard"
    refute_output --partial "Selecione o produto a instalar"
}

@test "setup: sem --product, .env=full → herda full" {
    echo "SISCAN_PRODUCT=full" > "${TEST_DIR}/.env"
    run _run_setup
    assert_output --partial "Produto            : full"
    refute_output --partial "Selecione o produto a instalar"
}

# ── Cenário C: .env existe mas SISCAN_PRODUCT inválido → warn + prompt ──────

@test "setup: SISCAN_PRODUCT inválido no .env → warn e cai no prompt interativo" {
    echo "SISCAN_PRODUCT=invalid_xyz" > "${TEST_DIR}/.env"
    # Input vazio derruba o read e o setup falha com "Opção inválida".
    run bash -c "echo '' | COMPOSE_DIR='${TEST_DIR}' timeout 5s bash '${SETUP_SH}' 2>&1"
    assert_output --partial "inválido"
    assert_output --partial "Selecione o produto a instalar"
}

# ── Cenário D: .env ausente → prompt direto (fluxo de primeira instalação) ──

@test "setup: sem .env e sem --product → prompt interativo (fluxo histórico)" {
    # Nenhum .env criado em TEST_DIR; input vazio derruba o read.
    run bash -c "echo '' | COMPOSE_DIR='${TEST_DIR}' timeout 5s bash '${SETUP_SH}' 2>&1"
    assert_output --partial "Selecione o produto a instalar"
    refute_output --partial "herdado de"
}

# ── Cenário E: .env existe mas sem SISCAN_PRODUCT → prompt direto ───────────

@test "setup: .env sem SISCAN_PRODUCT → prompt interativo" {
    cat > "${TEST_DIR}/.env" <<'EOF'
DATABASE_HOST=localhost
APP_LOG_LEVEL=INFO
EOF
    run bash -c "echo '' | COMPOSE_DIR='${TEST_DIR}' timeout 5s bash '${SETUP_SH}' 2>&1"
    assert_output --partial "Selecione o produto a instalar"
    refute_output --partial "herdado de"
}
