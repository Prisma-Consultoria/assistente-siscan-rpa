#!/usr/bin/env bats
# Testes para o tratamento de state=3 no runner_diagnose (issue #65).
#
# Estado 3 = binários (config.sh + svc.sh) + .runner presentes,
#            mas systemd unit ausente (`.service` marker não existe).
#
# Antes do fix: state=3 mapeava sempre para Cenário C, sem consultar API.
#               Quando o runner já tinha sido auto-removido remotamente
#               (total_count=0), o serviço subia local com credencial
#               inválida e ficava em loop de heartbeat 401.
# Depois do fix: state=3 consulta API. Se total_count=0, vai pra A2
#                (re-registro defensivo); senão, mantém C.

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

setup() {
    info() { :; }
    ok() { :; }
    warn() { :; }
    export -f info ok warn

    source "${BATS_TEST_DIRNAME}/../../scripts/deploy_server/_runner.sh"

    RUNNER_DIR="$(mktemp -d)"
    # State 3: binários + .runner OK, sem .service marker
    : > "${RUNNER_DIR}/config.sh"; chmod +x "${RUNNER_DIR}/config.sh"
    : > "${RUNNER_DIR}/svc.sh";    chmod +x "${RUNNER_DIR}/svc.sh"
    : > "${RUNNER_DIR}/.runner"
    # Sanity: state efetivamente é 3
    [ "$(runner_get_state "${RUNNER_DIR}")" = "3" ]
}

teardown() {
    command rm -rf "${RUNNER_DIR}"
}

@test "state=3 + API total_count=0 → retorna A2 (runner auto-removido remotamente)" {
    runner_query_api() { printf '{"total_count":0,"runners":[]}'; }
    export -f runner_query_api

    run runner_diagnose "${RUNNER_DIR}" "host-product" "owner" "repo"
    assert_success
    assert_output "A2"
}

@test "state=3 + API total_count>0 → retorna C (runner válido remotamente)" {
    runner_query_api() { printf '{"total_count":1,"runners":[{"id":42}]}'; }
    export -f runner_query_api

    run runner_diagnose "${RUNNER_DIR}" "host-product" "owner" "repo"
    assert_success
    assert_output "C"
}

@test "state=3 + API indisponível (sem credencial) → retorna C (comportamento original)" {
    runner_query_api() { echo ""; }
    export -f runner_query_api

    run runner_diagnose "${RUNNER_DIR}" "host-product" "owner" "repo"
    assert_success
    assert_output "C"
}

@test "state=3 + API indisponível + --token fornecido → retorna A2 (heurística defensiva)" {
    runner_query_api() { echo ""; }
    export -f runner_query_api

    # 5º arg = has_token=true (operadora desconfia de auto-removal)
    run runner_diagnose "${RUNNER_DIR}" "host-product" "owner" "repo" "true"
    assert_success
    assert_output "A2"
}

@test "Issue #65: cenário reprodutor — VM com .runner órfão pós auto-removal" {
    # Cenário operacional: várias execuções do recover deixaram a VM em
    # state=3 (svc.sh uninstall removeu o systemd; .runner velho permanece).
    # API confirma que o runner já foi removido remotamente. Sem o fix de
    # #65, o recover cairia em C (svc.sh install + start com .runner velho).
    runner_query_api() { printf '{"total_count":0,"runners":[]}'; }
    export -f runner_query_api

    run runner_diagnose "${RUNNER_DIR}" "host-product" "owner" "repo"
    assert_success
    assert_output "A2"
}
