#!/usr/bin/env bats
# Testes para scripts/deploy_server/check-db.sh — camada de versão do PostgreSQL
# (PR #111 — limiares de host em products.json; issue #113; F4/F9).
#
# Cobertura:
#   - PG >= alvo (16) => ok citando o alvo.
#   - PG entre piso (14) e alvo (16) => ok, mensagem cita ALVO e PISO (F9).
#   - PG abaixo do piso (13) => FAIL.
#
# Estratégia: stub de `timeout` (TCP sempre "aberto") e `psql` (responde
# SHOW server_version). pg_isready ausente do PATH (skip controlado).

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

setup() {
    PROJECT_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    SPECIALIST="${PROJECT_DIR}/scripts/deploy_server/check-db.sh"
    STUB_DIR="$(mktemp -d)"
    WORK_DIR="$(mktemp -d)"
    for b in bash awk hostname tr tail head cut grep sed sort dirname pwd cat env mktemp jq; do
        real="$(command -v "$b" 2>/dev/null)" && ln -sf "$real" "${STUB_DIR}/${b}"
    done
    # timeout stub: ignora o comando e retorna sucesso (TCP "aberto").
    {
        printf '#!/usr/bin/env bash\n'
        printf 'exit 0\n'
    } > "${STUB_DIR}/timeout"
    chmod +x "${STUB_DIR}/timeout"
    # .env mínimo apontando pro banco principal.
    cat > "${WORK_DIR}/.env" <<EOF
SISCAN_PRODUCT=rpa
DATABASE_HOST=db.exemplo.local
DATABASE_PORT=5432
DATABASE_USER=app
DATABASE_NAME=appdb
DATABASE_PASSWORD=segredo
EOF
}

teardown() {
    rm -rf "$STUB_DIR" "$WORK_DIR"
}

# _stub_psql VERSION — `psql ... -tAc "SHOW server_version"` imprime VERSION.
_stub_psql() {
    rm -f "${STUB_DIR}/psql"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'echo "%s"\n' "$1"
    } > "${STUB_DIR}/psql"
    chmod +x "${STUB_DIR}/psql"
}

_run_db() {
    run env PATH="${STUB_DIR}" COMPOSE_DIR="${WORK_DIR}" \
        bash "$SPECIALIST" --env-file "${WORK_DIR}/.env" --product rpa --json
}

@test "PG >= alvo (16) => ok citando o alvo" {
    _stub_psql "16.4"
    _run_db
    run bash -c "env PATH='${STUB_DIR}' COMPOSE_DIR='${WORK_DIR}' bash '$SPECIALIST' --env-file '${WORK_DIR}/.env' --product rpa --json | jq -r '.checks[] | select(.protocol==\"pg\") | .detail' | grep PostgreSQL"
    assert_output --partial 'PostgreSQL 16.4'
    assert_output --partial '>= 16'
}

@test "F9: PG entre piso (14) e alvo (16) cita ALVO e PISO" {
    _stub_psql "15.6"
    run bash -c "env PATH='${STUB_DIR}' COMPOSE_DIR='${WORK_DIR}' bash '$SPECIALIST' --env-file '${WORK_DIR}/.env' --product rpa --json | jq -r '.checks[] | select(.protocol==\"pg\") | .detail' | grep PostgreSQL"
    assert_output --partial 'anterior ao alvo 16'
    assert_output --partial 'piso 14'
}

@test "PG abaixo do piso (13) => FAIL" {
    _stub_psql "13.10"
    run bash -c "env PATH='${STUB_DIR}' COMPOSE_DIR='${WORK_DIR}' bash '$SPECIALIST' --env-file '${WORK_DIR}/.env' --product rpa --json | jq -r '.checks[] | select(.protocol==\"pg\" and .status==\"fail\") | .detail'"
    assert_output --partial 'muito antigo'
    assert_output --partial '>= 16'
}
