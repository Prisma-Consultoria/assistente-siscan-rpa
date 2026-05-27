#!/usr/bin/env bats
# Testes para runner_remove_registration em scripts/deploy_server/_runner.sh
#
# Cobre as 3 camadas da estratégia de remoção (issue #63):
#   1. Atalho remoto    — runner já não existe no GitHub (total_count=0).
#   2. Remove-token API — runner remoto presente + credencial disponível.
#   3. Fallback local   — sem credencial ou config.sh remove falhou.
#
# A camada 3 (rm -f dos arquivos locais) é exercida em todos os cenários:
# .runner + .credentials + .credentials_rsaparams devem terminar ausentes.

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

setup() {
    # Stubs dos helpers de log esperados pelo _runner.sh — silenciam saída
    # mas mantêm rc=0, equivalente ao contrato do _common.sh
    info() { :; }
    ok() { :; }
    warn() { :; }
    export -f info ok warn

    # Source da biblioteca sob teste
    source "${BATS_TEST_DIRNAME}/../../scripts/deploy_server/_runner.sh"

    # Diretório de runner sintético com os 3 arquivos do registro local
    RUNNER_DIR="$(mktemp -d)"
    touch "${RUNNER_DIR}/.runner" \
          "${RUNNER_DIR}/.credentials" \
          "${RUNNER_DIR}/.credentials_rsaparams"
    # Stub do config.sh — registra args recebidos em $CONFIG_LOG e fail/pass
    # controlados por CONFIG_REMOVE_EXIT (default 0)
    CONFIG_LOG="$(mktemp)"
    cat > "${RUNNER_DIR}/config.sh" <<'SHELL'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "${CONFIG_LOG}"
exit "${CONFIG_REMOVE_EXIT:-0}"
SHELL
    chmod +x "${RUNNER_DIR}/config.sh"
    export CONFIG_LOG
}

teardown() {
    rm -rf "${RUNNER_DIR}"
    rm -f "${CONFIG_LOG}"
}

# ────────────────────────────────────────────────────────────────────────────
# Camada 1 — atalho remoto (total_count=0)
# ────────────────────────────────────────────────────────────────────────────

@test "Camada 1: total_count=0 — pula config.sh remove e limpa arquivos locais" {
    runner_query_api() { printf '{"total_count":0,"runners":[]}'; }
    runner_get_remove_token() { echo "SHOULD_NOT_BE_CALLED"; }
    export -f runner_query_api runner_get_remove_token

    run runner_remove_registration "${RUNNER_DIR}" "owner" "repo"
    assert_success

    [ ! -f "${RUNNER_DIR}/.runner" ]
    [ ! -f "${RUNNER_DIR}/.credentials" ]
    [ ! -f "${RUNNER_DIR}/.credentials_rsaparams" ]
    # config.sh remove não deve ter sido invocado
    [ ! -s "${CONFIG_LOG}" ]
}

# ────────────────────────────────────────────────────────────────────────────
# Camada 2 — remove-token via API (runner remoto presente)
# ────────────────────────────────────────────────────────────────────────────

@test "Camada 2: total_count>0 + remove-token OK — chama config.sh remove com remove-token" {
    runner_query_api() { printf '{"total_count":1,"runners":[{"id":123}]}'; }
    runner_get_remove_token() { echo "AAAAREMOVETOKENBBBB"; }
    export -f runner_query_api runner_get_remove_token

    run runner_remove_registration "${RUNNER_DIR}" "owner" "repo"
    assert_success

    # config.sh foi chamado com argumentos esperados
    grep -q '^remove$' "${CONFIG_LOG}"
    grep -q '^--token$' "${CONFIG_LOG}"
    grep -q '^AAAAREMOVETOKENBBBB$' "${CONFIG_LOG}"
    # Limpeza local mantida (camada 3 sempre executa)
    [ ! -f "${RUNNER_DIR}/.runner" ]
    [ ! -f "${RUNNER_DIR}/.credentials" ]
    [ ! -f "${RUNNER_DIR}/.credentials_rsaparams" ]
}

@test "Camada 2: config.sh remove falha — fallback local ainda limpa arquivos" {
    runner_query_api() { printf '{"total_count":1,"runners":[{"id":123}]}'; }
    runner_get_remove_token() { echo "AAAAREMOVETOKENBBBB"; }
    export -f runner_query_api runner_get_remove_token
    export CONFIG_REMOVE_EXIT=1

    run runner_remove_registration "${RUNNER_DIR}" "owner" "repo"
    assert_success
    # config.sh foi tentado (mesmo falhando)
    grep -q '^remove$' "${CONFIG_LOG}"
    # E os arquivos locais foram removidos no fallback
    [ ! -f "${RUNNER_DIR}/.runner" ]
    [ ! -f "${RUNNER_DIR}/.credentials" ]
    [ ! -f "${RUNNER_DIR}/.credentials_rsaparams" ]
}

# ────────────────────────────────────────────────────────────────────────────
# Camada 3 — fallback (sem credencial / API indisponível)
# ────────────────────────────────────────────────────────────────────────────

@test "Camada 3: API indisponível — limpa local sem tentar config.sh remove" {
    runner_query_api() { echo ""; }
    runner_get_remove_token() { echo ""; }
    export -f runner_query_api runner_get_remove_token

    run runner_remove_registration "${RUNNER_DIR}" "owner" "repo"
    assert_success
    # config.sh remove não tem como rodar sem token
    [ ! -s "${CONFIG_LOG}" ]
    # Mas limpeza local ocorreu
    [ ! -f "${RUNNER_DIR}/.runner" ]
    [ ! -f "${RUNNER_DIR}/.credentials" ]
    [ ! -f "${RUNNER_DIR}/.credentials_rsaparams" ]
}

@test "Camada 3: remote presente mas sem credencial pra remove-token — limpa local" {
    runner_query_api() { printf '{"total_count":1,"runners":[{"id":123}]}'; }
    runner_get_remove_token() { echo ""; }
    export -f runner_query_api runner_get_remove_token

    run runner_remove_registration "${RUNNER_DIR}" "owner" "repo"
    assert_success
    [ ! -s "${CONFIG_LOG}" ]
    [ ! -f "${RUNNER_DIR}/.runner" ]
}

# ────────────────────────────────────────────────────────────────────────────
# Idempotência e falhas duras
# ────────────────────────────────────────────────────────────────────────────

@test "Idempotente: arquivos já ausentes — retorna 0 sem erro" {
    runner_query_api() { printf '{"total_count":0,"runners":[]}'; }
    runner_get_remove_token() { echo ""; }
    export -f runner_query_api runner_get_remove_token

    rm -f "${RUNNER_DIR}/.runner" \
          "${RUNNER_DIR}/.credentials" \
          "${RUNNER_DIR}/.credentials_rsaparams"

    run runner_remove_registration "${RUNNER_DIR}" "owner" "repo"
    assert_success
}

@test "Falha: .runner persistente em disco — retorna 1 (não silencia)" {
    runner_query_api() { printf '{"total_count":0,"runners":[]}'; }
    runner_get_remove_token() { echo ""; }
    # Override de rm como no-op: simula falha total de IO. O .runner original
    # (criado em setup) permanece em disco, e a função deve detectar via
    # `[ -f ... ]` e retornar 1 em vez de silenciar.
    rm() { :; }
    export -f runner_query_api runner_get_remove_token rm

    [ -f "${RUNNER_DIR}/.runner" ]  # pré-condição: arquivo está lá

    run runner_remove_registration "${RUNNER_DIR}" "owner" "repo"
    assert_failure
}

# ────────────────────────────────────────────────────────────────────────────
# Cenário operacional clássico — issue #63 reprodução
# ────────────────────────────────────────────────────────────────────────────

@test "Issue #63: cenário A/A2 com runner auto-removido — destrava sem intervenção manual" {
    # Simula o cenário operacional real: runner já foi removido pelo GitHub
    # (total_count=0) e a operadora forneceu apenas registration-token (não
    # tem credencial pra obter remove-token). O fix deve destravar via
    # fallback local — antes do fix, .runner ficaria órfão.
    runner_query_api() { printf '{"total_count":0,"runners":[]}'; }
    runner_get_remove_token() { echo ""; }
    export -f runner_query_api runner_get_remove_token

    run runner_remove_registration "${RUNNER_DIR}" "owner" "repo"
    assert_success
    [ ! -f "${RUNNER_DIR}/.runner" ]
    [ ! -f "${RUNNER_DIR}/.credentials" ]
    [ ! -f "${RUNNER_DIR}/.credentials_rsaparams" ]
    # E config.sh remove (que falharia com registration-token) não foi chamado
    [ ! -s "${CONFIG_LOG}" ]
}
