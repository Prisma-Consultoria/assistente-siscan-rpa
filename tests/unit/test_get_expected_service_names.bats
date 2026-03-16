#!/usr/bin/env bats
# Testes para get_expected_service_names

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

FIXTURES_DIR="${BATS_TEST_DIRNAME}/../fixtures"

setup() {
    source "${BATS_TEST_DIRNAME}/../../siscan-assistente.sh"
}

@test "retorna os 3 serviços do compose válido" {
    run get_expected_service_names "${FIXTURES_DIR}/compose_valid.yml"
    assert_success
    assert_line "migrate"
    assert_line "app"
    assert_line "rpa-scheduler"
}

@test "retorna exatamente 3 linhas para o compose válido" {
    run get_expected_service_names "${FIXTURES_DIR}/compose_valid.yml"
    assert_success
    [ "$(echo "$output" | wc -l)" -eq 3 ]
}

@test "retorna vazio quando arquivo não existe" {
    run get_expected_service_names "/nao/existe.yml"
    assert_success
    assert_output ""
}

@test "não inclui 'volumes' como serviço" {
    run get_expected_service_names "${FIXTURES_DIR}/compose_valid.yml"
    assert_success
    refute_line "volumes"
    refute_line "siscan-data-artifacts"
}
