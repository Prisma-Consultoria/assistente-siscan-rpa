#!/usr/bin/env bats
# Testes para o helper `add_skipped` em _common.sh (issue #66).
#
# Antes do fix: specialists que pulavam checks (ex.: registro remoto sem
#               credencial) usavam `warn` solto, que não contava no resumo.
#               O sumário reportava "4/4 OK" mesmo quando só 3/4 rodaram.
# Depois do fix: `add_skipped` distingue SKIPPED no resumo textual e JSON,
#                preservando exit code 0 (não-bloqueante).

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

setup() {
    OUTPUT_MODE=human
    export OUTPUT_MODE
    SPECIALIST_NAME="test-skipped"
    export SPECIALIST_NAME
    # Cores neutralizadas pra facilitar grep dos outputs
    GREEN="" YELLOW="" RED="" GRAY="" CYAN="" NC=""
    export GREEN YELLOW RED GRAY CYAN NC

    source "${BATS_TEST_DIRNAME}/../../scripts/deploy_server/_common.sh"
}

@test "add_skipped incrementa SKIPPED_COUNT e TOTAL, sem mexer em OK/FAIL" {
    add_ok      "cat" proto 0 "alvo1" "passou"
    add_skipped "cat" proto 0 "alvo2" "sem credencial"

    [ "$TOTAL" -eq 2 ]
    [ "$OK_COUNT" -eq 1 ]
    [ "$FAIL_COUNT" -eq 0 ]
    [ "$SKIPPED_COUNT" -eq 1 ]
}

@test "add_skipped grava entrada no RESULTS com status='skipped'" {
    add_skipped "cat" api 0 "alvo" "credencial ausente"

    [ "${#RESULTS[@]}" -eq 1 ]
    [[ "${RESULTS[0]}" == *"|skipped|credencial ausente" ]]
}

@test "Resumo human: mostra '· N SKIPPED' quando há skipped sem fail" {
    add_ok      "cat" proto 0 "alvo1" "ok1"
    add_ok      "cat" proto 0 "alvo2" "ok2"
    add_ok      "cat" proto 0 "alvo3" "ok3"
    add_skipped "cat" api   0 "alvo4" "sem credencial"

    run _render_summary_human
    assert_success
    assert_output --partial "3/4 OK · 1 SKIPPED"
}

@test "Resumo human: mostra FAIL e SKIPPED juntos quando ambos > 0" {
    add_ok      "cat" proto 0 "a" "ok"
    add_fail    "cat" proto 0 "b" "falhou"
    add_skipped "cat" proto 0 "c" "pulado"

    run _render_summary_human
    assert_success
    assert_output --partial "1/3 OK · 1 FAIL · 1 SKIPPED"
}

@test "Resumo human: omite SKIPPED quando count=0 (compatível com cenário antigo)" {
    add_ok "cat" proto 0 "a" "ok"
    add_ok "cat" proto 0 "b" "ok"

    run _render_summary_human
    assert_success
    refute_output --partial "SKIPPED"
}

@test "Resumo JSON inclui campo 'skipped' no sumário" {
    OUTPUT_MODE=json
    add_ok      "cat" api 0 "alvo1" "ok"
    add_skipped "cat" api 0 "alvo2" "pulado"

    run _render_json_envelope
    assert_success
    assert_output --partial '"skipped": 1'
    assert_output --partial '"total": 2'
    assert_output --partial '"ok": 1'
    assert_output --partial '"fail": 0'
}

@test "finalize_exit retorna 0 quando há SKIPPED sem FAIL (não-bloqueante)" {
    add_ok      "cat" proto 0 "a" "ok"
    add_skipped "cat" proto 0 "b" "pulado"

    # finalize_exit chama exit; usar subshell pra capturar
    run bash -c '
        source "'"${BATS_TEST_DIRNAME}/../../scripts/deploy_server/_common.sh"'"
        SPECIALIST_NAME=t
        OUTPUT_MODE=quiet
        add_ok cat proto 0 a ok
        add_skipped cat proto 0 b pulado
        finalize_exit
    '
    assert_success
}

@test "Issue #66: emite mensagem 'SKIPPED [specialist] ...' em modo quiet" {
    OUTPUT_MODE=quiet
    run add_skipped "Registro remoto no GitHub" api 0 "API GitHub" "sem credencial"
    assert_success
    assert_output --partial "SKIPPED [test-skipped]"
    assert_output --partial "API GitHub"
}
