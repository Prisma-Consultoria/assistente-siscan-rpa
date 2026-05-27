#!/usr/bin/env bats
# Testes para a flag --force-download-binaries em siscan-runner-recover.sh
# e siscan-server-setup.sh (TSK00.04.01).
#
# Comportamento esperado:
#   - Sem flag: parsing aceita argumentos atuais, sem mudança de fluxo
#   - Com flag: classificador retorna state ≥ 2 mas o script força state = 1
#   - State N/A e 1: flag é no-op (download já é o caminho natural)
#
# Testes aqui isolam a lógica de override do classificador (linhas que
# checam $FORCE_DOWNLOAD_BINARIES). Não tentamos exec o script inteiro
# — bootstrap interativo + download real fica fora do escopo unit.

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

# Helper: simula o trecho de override do recover. Idêntico em essência
# ao código de produção em siscan-runner-recover.sh:191-199 e
# siscan-server-setup.sh:712-720.
_apply_override() {
    local state="$1" force="$2"
    if [ "$force" = "true" ] && [ "$state" != "N/A" ] && [ "$state" != "1" ]; then
        echo "1"
    else
        echo "$state"
    fi
}

@test "override no-op quando flag ausente — state 2 permanece 2" {
    run _apply_override "2" "false"
    assert_success
    assert_output "2"
}

@test "flag ativa força state 2 → 1" {
    run _apply_override "2" "true"
    assert_success
    assert_output "1"
}

@test "flag ativa força state 3 → 1" {
    run _apply_override "3" "true"
    assert_success
    assert_output "1"
}

@test "flag ativa força state 4 → 1" {
    run _apply_override "4" "true"
    assert_success
    assert_output "1"
}

@test "flag ativa preserva state 1 (já vai pra download)" {
    run _apply_override "1" "true"
    assert_success
    assert_output "1"
}

@test "flag ativa preserva state N/A (bootstrap já baixa)" {
    run _apply_override "N/A" "true"
    assert_success
    assert_output "N/A"
}

@test "flag ausente preserva state 2 (caminho normal sem download)" {
    run _apply_override "2" "false"
    assert_success
    assert_output "2"
}

@test "flag ausente preserva state 3" {
    run _apply_override "3" "false"
    assert_success
    assert_output "3"
}

@test "flag ausente preserva state 4" {
    run _apply_override "4" "false"
    assert_success
    assert_output "4"
}

# ────────────────────────────────────────────────────────────────────────────
# Smoke test do parsing em recover (não exec o script — só valida a
# presença da flag no usage e no case branch).
# ────────────────────────────────────────────────────────────────────────────

@test "recover: --force-download-binaries documentada em --help" {
    run bash "${BATS_TEST_DIRNAME}/../../siscan-runner-recover.sh" --help
    assert_success
    assert_output --partial "--force-download-binaries"
}

@test "recover: --force-download-binaries reconhecida pelo parser (não diz argumento desconhecido)" {
    # Roda só o parsing — vai falhar depois por falta de ENV_FILE ou similar,
    # mas o stderr não deve conter "argumento desconhecido".
    run bash -c "bash '${BATS_TEST_DIRNAME}/../../siscan-runner-recover.sh' --force-download-binaries --product=invalid 2>&1 || true"
    refute_output --partial "argumento desconhecido: --force-download-binaries"
}

@test "setup: --force-download-binaries reconhecida pelo parser" {
    # Setup com --product inválido falha rápido na validação de produto;
    # garantimos que a flag não é tratada como produto válido nem rejeitada.
    run bash -c "bash '${BATS_TEST_DIRNAME}/../../siscan-server-setup.sh' --force-download-binaries --product=invalid 2>&1 || true"
    refute_output --partial "argumento desconhecido"
}
