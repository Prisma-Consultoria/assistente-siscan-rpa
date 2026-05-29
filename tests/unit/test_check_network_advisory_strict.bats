#!/usr/bin/env bats
# Testes para flag --advisory-strict em scripts/deploy_server/check-network.sh
# (TSK00.04.11 #90 — Variante A da decisão arquitetural).
#
# Default (TSK00.04.09 mantida): categorias advisory contam falhas como SKIPPED;
# exit code do specialist não é bloqueado. Setup/recover/operador one-off não
# freakam com exit 1 falso por variantes regionais que dependem do roteamento
# dinâmico da VM.
#
# Strict opt-in (esta TSK): falhas em advisory viram FAIL bloqueante. Para
# CI/automação rígida (provisionamento estrito que requer wildcard liberado).

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

setup() {
    PROJECT_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    SPECIALIST="${PROJECT_DIR}/scripts/deploy_server/check-network.sh"
    # JSON sintético com 1 categoria principal OK + 1 categoria advisory FAIL
    # garantido (FQDNs inexistentes). Cobertura controlada sem rede real.
    JSON_FIXTURE="$(mktemp)"
    cat > "$JSON_FIXTURE" <<'JSON'
{
  "version": "test-1.0",
  "description": "Fixture de teste para --advisory-strict",
  "categories": [
    {
      "id": "main_ok",
      "label": "Categoria principal (deve passar)",
      "description": "Endpoint que existe, vai passar.",
      "guidance": {"on_all_ok": "ok", "on_any_fail": "fail"},
      "endpoints": [
        {"fqdn": "github.com", "protocol": "https", "port": 443, "expected": "200 — homepage"}
      ]
    },
    {
      "id": "advisory_fail",
      "label": "Categoria advisory (vai falhar)",
      "description": "Endpoint inexistente, vai falhar.",
      "advisory": true,
      "guidance": {"on_all_ok": "ok", "on_any_fail": "fail"},
      "endpoints": [
        {"fqdn": "nonexistent-fqdn-for-test-tsk00041.example.invalid", "protocol": "https", "port": 443, "expected": "any"}
      ]
    }
  ]
}
JSON
}

teardown() {
    rm -f "$JSON_FIXTURE"
}

# ────────────────────────────────────────────────────────────────────────────
# Default: advisory = warning (SKIPPED), exit 0
# ────────────────────────────────────────────────────────────────────────────

@test "default (sem --advisory-strict): advisory falha → SKIPPED, exit 0" {
    run bash "$SPECIALIST" --endpoints-file "$JSON_FIXTURE" --timeout 3 --quiet
    # Exit 0 mesmo com advisory falhando — comportamento TSK00.04.09
    assert_equal "$status" 0
}

@test "default: advisory falha vira SKIPPED visível na saída human" {
    run bash "$SPECIALIST" --endpoints-file "$JSON_FIXTURE" --timeout 3
    assert_equal "$status" 0
    # Output deve incluir SKIPPED para o endpoint advisory
    assert_output --partial "SKIPPED"
}

# ────────────────────────────────────────────────────────────────────────────
# Opt-in: advisory = FAIL bloqueante, exit 1
# ────────────────────────────────────────────────────────────────────────────

@test "--advisory-strict: advisory falha → FAIL, exit 1" {
    run bash "$SPECIALIST" --endpoints-file "$JSON_FIXTURE" --advisory-strict --timeout 3 --quiet
    # Exit 1 — advisory promovido a FAIL bloqueante
    assert_equal "$status" 1
}

@test "--advisory-strict: detail menciona 'modo --advisory-strict' (rastreabilidade)" {
    run bash "$SPECIALIST" --endpoints-file "$JSON_FIXTURE" --advisory-strict --timeout 3
    # Detail diferencia advisory-strict de fail normal — operador entende por que falhou
    assert_output --partial "advisory-strict"
}

# ────────────────────────────────────────────────────────────────────────────
# Argparse
# ────────────────────────────────────────────────────────────────────────────

@test "--advisory-strict é aceito como flag CLI" {
    run bash "$SPECIALIST" --advisory-strict --help
    assert_equal "$status" 0
}

@test "--advisory-strict aparece no --help" {
    run bash "$SPECIALIST" --help
    assert_output --partial "--advisory-strict"
    assert_output --partial "FAIL"
    assert_output --partial "advisory"
}
