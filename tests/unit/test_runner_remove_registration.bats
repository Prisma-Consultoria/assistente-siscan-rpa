#!/usr/bin/env bats
# Testes para runner_remove_registration em scripts/deploy_server/_runner.sh
#
# Cobre as 3 camadas da estratégia de remoção (issue #63):
#   1. Atalho remoto    — runner já não existe no GitHub (total_count=0).
#   2. Remove-token API — runner remoto presente + credencial disponível.
#   3. Fallback local   — sem credencial ou config.sh remove falhou.
#
# A camada 3 delega para runner_purge_local_config e deve deixar todos os
# 5 artefatos locais ausentes:
#   .runner, .runner_migrated, .credentials, .credentials_rsaparams, .path
#
# .runner_migrated (lab #220 — 2026-05-27): cópia gerada por auto-update do
# runner que, quando .runner é removido manualmente, segura o flag "já
# configurado" do Runner.Listener e faz config.sh --replace falhar.

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

    # Diretório de runner sintético com os 5 arquivos do registro local
    # (inclui .runner_migrated e .path — ver runner_purge_local_config)
    RUNNER_DIR="$(mktemp -d)"
    touch "${RUNNER_DIR}/.runner" \
          "${RUNNER_DIR}/.runner_migrated" \
          "${RUNNER_DIR}/.credentials" \
          "${RUNNER_DIR}/.credentials_rsaparams" \
          "${RUNNER_DIR}/.path"
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
    # `command rm` ignora overrides de função (ex.: teste 7 substitui rm
    # por no-op pra simular falha de IO — sem isso o teardown também
    # vira no-op e acumula lixo entre execuções).
    command rm -rf "${RUNNER_DIR}"
    command rm -f "${CONFIG_LOG}"
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
    [ ! -f "${RUNNER_DIR}/.runner_migrated" ]
    [ ! -f "${RUNNER_DIR}/.credentials" ]
    [ ! -f "${RUNNER_DIR}/.credentials_rsaparams" ]
    [ ! -f "${RUNNER_DIR}/.path" ]
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
    [ ! -f "${RUNNER_DIR}/.runner_migrated" ]
    [ ! -f "${RUNNER_DIR}/.credentials" ]
    [ ! -f "${RUNNER_DIR}/.credentials_rsaparams" ]
    [ ! -f "${RUNNER_DIR}/.path" ]
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
    [ ! -f "${RUNNER_DIR}/.runner_migrated" ]
    [ ! -f "${RUNNER_DIR}/.credentials" ]
    [ ! -f "${RUNNER_DIR}/.credentials_rsaparams" ]
    [ ! -f "${RUNNER_DIR}/.path" ]
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
    [ ! -f "${RUNNER_DIR}/.runner_migrated" ]
    [ ! -f "${RUNNER_DIR}/.credentials" ]
    [ ! -f "${RUNNER_DIR}/.credentials_rsaparams" ]
    [ ! -f "${RUNNER_DIR}/.path" ]
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
          "${RUNNER_DIR}/.runner_migrated" \
          "${RUNNER_DIR}/.credentials" \
          "${RUNNER_DIR}/.credentials_rsaparams" \
          "${RUNNER_DIR}/.path"

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
    [ ! -f "${RUNNER_DIR}/.runner_migrated" ]
    [ ! -f "${RUNNER_DIR}/.credentials" ]
    [ ! -f "${RUNNER_DIR}/.credentials_rsaparams" ]
    [ ! -f "${RUNNER_DIR}/.path" ]
    # E config.sh remove (que falharia com registration-token) não foi chamado
    [ ! -s "${CONFIG_LOG}" ]
}

# ────────────────────────────────────────────────────────────────────────────
# runner_purge_local_config — função standalone (lab #220 — 2026-05-27)
# ────────────────────────────────────────────────────────────────────────────

@test "runner_purge_local_config: remove os 5 artefatos locais" {
    # Pré-condição: os 5 arquivos existem (criados em setup)
    [ -f "${RUNNER_DIR}/.runner" ]
    [ -f "${RUNNER_DIR}/.runner_migrated" ]
    [ -f "${RUNNER_DIR}/.credentials" ]
    [ -f "${RUNNER_DIR}/.credentials_rsaparams" ]
    [ -f "${RUNNER_DIR}/.path" ]

    run runner_purge_local_config "${RUNNER_DIR}"
    assert_success

    [ ! -f "${RUNNER_DIR}/.runner" ]
    [ ! -f "${RUNNER_DIR}/.runner_migrated" ]
    [ ! -f "${RUNNER_DIR}/.credentials" ]
    [ ! -f "${RUNNER_DIR}/.credentials_rsaparams" ]
    [ ! -f "${RUNNER_DIR}/.path" ]
}

@test "runner_purge_local_config: idempotente — diretório já limpo retorna 0" {
    rm -f "${RUNNER_DIR}/.runner" \
          "${RUNNER_DIR}/.runner_migrated" \
          "${RUNNER_DIR}/.credentials" \
          "${RUNNER_DIR}/.credentials_rsaparams" \
          "${RUNNER_DIR}/.path"

    run runner_purge_local_config "${RUNNER_DIR}"
    assert_success
}

@test "runner_purge_local_config: preserva .env e .service (não toca em config persistido)" {
    # .env carrega COMPOSE_DIR e flags do setup; .service é marker do
    # systemd unit gerenciado por svc.sh. Nenhum dos dois pode ser apagado
    # pela função (sob pena de quebrar o próximo run do recover/setup).
    echo "COMPOSE_DIR=/srv/foo" > "${RUNNER_DIR}/.env"
    echo "actions.runner.foo.service" > "${RUNNER_DIR}/.service"

    run runner_purge_local_config "${RUNNER_DIR}"
    assert_success

    [ -f "${RUNNER_DIR}/.env" ]
    [ -f "${RUNNER_DIR}/.service" ]
    # Conteúdo intacto
    grep -q "COMPOSE_DIR=/srv/foo" "${RUNNER_DIR}/.env"
    grep -q "actions.runner.foo.service" "${RUNNER_DIR}/.service"
}

@test "runner_purge_local_config: cenário lab #220 — só .runner_migrated impede config.sh --replace" {
    # Reproduz a situação real do lab: operadora apagou manualmente .runner
    # + .credentials*, mas .runner_migrated (gerado por auto-update) ficou
    # e fez config.sh --replace falhar com "already configured".
    # Após o purge, o diretório fica de fato limpo pra novo register.
    rm -f "${RUNNER_DIR}/.runner" \
          "${RUNNER_DIR}/.credentials" \
          "${RUNNER_DIR}/.credentials_rsaparams"
    # .runner_migrated permanece — esse é o ponto da regressão
    [ -f "${RUNNER_DIR}/.runner_migrated" ]

    run runner_purge_local_config "${RUNNER_DIR}"
    assert_success
    [ ! -f "${RUNNER_DIR}/.runner_migrated" ]
}

@test "runner_purge_local_config: falha de IO em .runner_migrated retorna 1" {
    # Override de rm como no-op: simula falha de permissão/IO. A função
    # deve detectar via `[ -e ... ]` e retornar 1 em vez de silenciar.
    rm() { :; }
    export -f rm

    [ -f "${RUNNER_DIR}/.runner_migrated" ]

    run runner_purge_local_config "${RUNNER_DIR}"
    assert_failure
}
