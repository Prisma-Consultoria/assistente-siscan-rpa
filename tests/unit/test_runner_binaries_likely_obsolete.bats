#!/usr/bin/env bats
# Testes para runner_binaries_likely_obsolete em scripts/deploy_server/_runner.sh
# (TSK00.04.02 — auto-detecção de obsolescência via mtime).
#
# Critério adotado: opção A do comentário em #78 — mtime > N dias.
# Default 30d justificado pelo lab 2026-05-27 (Runner.Listener com mtime
# de ~36d falhou TLS handshake mesmo com curl do sistema OK).

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

setup() {
    source "${BATS_TEST_DIRNAME}/../../scripts/deploy_server/_runner.sh"

    RUNNER_DIR="$(mktemp -d)"
    mkdir -p "${RUNNER_DIR}/bin"
    : > "${RUNNER_DIR}/bin/Runner.Listener"; chmod +x "${RUNNER_DIR}/bin/Runner.Listener"

    # Reset env entre testes
    unset RUNNER_OBSOLETE_DAYS
}

teardown() {
    command rm -rf "${RUNNER_DIR}"
    unset RUNNER_OBSOLETE_DAYS
}

# ────────────────────────────────────────────────────────────────────────────
# Comportamento padrão — threshold default 30d
# ────────────────────────────────────────────────────────────────────────────

@test "binário fresco (mtime hoje) → retorna 1 (não obsoleto)" {
    touch "${RUNNER_DIR}/bin/Runner.Listener"
    run runner_binaries_likely_obsolete "${RUNNER_DIR}"
    assert_failure
}

@test "binário recente (mtime 5d atrás) → retorna 1 (não obsoleto)" {
    touch -d "5 days ago" "${RUNNER_DIR}/bin/Runner.Listener"
    run runner_binaries_likely_obsolete "${RUNNER_DIR}"
    assert_failure
}

@test "binário no limite (mtime 30d atrás) → retorna 1 (threshold é estritamente maior que)" {
    touch -d "30 days ago" "${RUNNER_DIR}/bin/Runner.Listener"
    run runner_binaries_likely_obsolete "${RUNNER_DIR}"
    assert_failure
}

@test "binário acima do limite (mtime 31d atrás) → retorna 0 (obsoleto)" {
    touch -d "31 days ago" "${RUNNER_DIR}/bin/Runner.Listener"
    run runner_binaries_likely_obsolete "${RUNNER_DIR}"
    assert_success
}

@test "binário muito antigo (mtime 90d atrás) → retorna 0 (obsoleto)" {
    touch -d "90 days ago" "${RUNNER_DIR}/bin/Runner.Listener"
    run runner_binaries_likely_obsolete "${RUNNER_DIR}"
    assert_success
}

# ────────────────────────────────────────────────────────────────────────────
# Configuração de threshold — via argumento posicional
# ────────────────────────────────────────────────────────────────────────────

@test "argumento posicional: threshold 7d, binário com 10d → obsoleto" {
    touch -d "10 days ago" "${RUNNER_DIR}/bin/Runner.Listener"
    run runner_binaries_likely_obsolete "${RUNNER_DIR}" 7
    assert_success
}

@test "argumento posicional: threshold 60d, binário com 40d → não obsoleto" {
    touch -d "40 days ago" "${RUNNER_DIR}/bin/Runner.Listener"
    run runner_binaries_likely_obsolete "${RUNNER_DIR}" 60
    assert_failure
}

# ────────────────────────────────────────────────────────────────────────────
# Configuração de threshold — via env RUNNER_OBSOLETE_DAYS
# ────────────────────────────────────────────────────────────────────────────

@test "env RUNNER_OBSOLETE_DAYS=7, binário 10d → obsoleto" {
    touch -d "10 days ago" "${RUNNER_DIR}/bin/Runner.Listener"
    export RUNNER_OBSOLETE_DAYS=7
    run runner_binaries_likely_obsolete "${RUNNER_DIR}"
    assert_success
}

@test "env RUNNER_OBSOLETE_DAYS=60, binário 40d → não obsoleto" {
    touch -d "40 days ago" "${RUNNER_DIR}/bin/Runner.Listener"
    export RUNNER_OBSOLETE_DAYS=60
    run runner_binaries_likely_obsolete "${RUNNER_DIR}"
    assert_failure
}

@test "argumento posicional tem precedência sobre env" {
    touch -d "10 days ago" "${RUNNER_DIR}/bin/Runner.Listener"
    export RUNNER_OBSOLETE_DAYS=99
    # Arg 5d sobrescreve env 99d → 10d > 5d → obsoleto
    run runner_binaries_likely_obsolete "${RUNNER_DIR}" 5
    assert_success
}

# ────────────────────────────────────────────────────────────────────────────
# Robustez — arquivo ausente, threshold em valor inesperado
# ────────────────────────────────────────────────────────────────────────────

@test "arquivo ausente → retorna 1 (indeterminado, não obsoleto)" {
    rm -f "${RUNNER_DIR}/bin/Runner.Listener"
    run runner_binaries_likely_obsolete "${RUNNER_DIR}"
    assert_failure
}

@test "diretório bin/ ausente → retorna 1 (indeterminado)" {
    rm -rf "${RUNNER_DIR}/bin"
    run runner_binaries_likely_obsolete "${RUNNER_DIR}"
    assert_failure
}

# ────────────────────────────────────────────────────────────────────────────
# Regressão — caso operacional do lab #220
# ────────────────────────────────────────────────────────────────────────────

@test "regressão lab 2026-05-27: mtime 36d com threshold default → obsoleto" {
    # Reproduz exatamente o cenário observado em VM operacional: o
    # Runner.Listener original tinha mtime de 2026-04-21 (~36d antes do
    # incidente). A heurística precisa detectar isso sem ajuste manual.
    touch -d "36 days ago" "${RUNNER_DIR}/bin/Runner.Listener"
    run runner_binaries_likely_obsolete "${RUNNER_DIR}"
    assert_success
}
