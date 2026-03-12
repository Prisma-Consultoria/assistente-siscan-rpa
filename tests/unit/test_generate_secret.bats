#!/usr/bin/env bats
# Testes para _generate_secret

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

setup() {
    source "${BATS_TEST_DIRNAME}/../../siscan-assistente.sh"
}

@test "_generate_secret retorna string de 64 caracteres hexadecimais" {
    run _generate_secret
    assert_success
    assert_output --regexp '^[0-9a-f]{64}$'
}

@test "_generate_secret gera valores diferentes a cada chamada" {
    local a b
    a="$(_generate_secret)"
    b="$(_generate_secret)"
    [ "$a" != "$b" ]
}

@test "_generate_secret não produz saída vazia" {
    local result
    result="$(_generate_secret)"
    [ -n "$result" ]
}
