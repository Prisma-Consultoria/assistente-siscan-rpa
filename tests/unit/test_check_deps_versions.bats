#!/usr/bin/env bats
# Testes para o specialist scripts/deploy_server/check-deps.sh
# (PR #111 — requisitos de host em products.json + camadas de versão; issue #113; F4).
#
# Cobertura:
#   - Docker em camadas: >= recomendado (ok), entre piso e alvo (warn), abaixo
#     do piso (warn mais forte) — versão é advisory, nunca FAIL.
#   - Compose comparado via sort -V: >= piso ok; abaixo = warn; sufixo -desktop.1
#     e o caso 2.5 < 2.37 tratados corretamente.
#   - Drift-guard: binário exigido no manifesto sem rotina de verificação => FAIL.
#   - Fallback de bootstrap: sem jq, os limiares caem no default e o specialist
#     ainda roda (degrada, não aborta).
#
# Estratégia: stubs de docker (engine + plugin compose) num PATH controlado.

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

setup() {
    PROJECT_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    SPECIALIST="${PROJECT_DIR}/scripts/deploy_server/check-deps.sh"
    STUB_DIR="$(mktemp -d)"
    WORK_DIR="$(mktemp -d)"
    for b in bash awk hostname tr tail head cut grep sed sort dirname pwd cat env mktemp jq curl openssl sudo timeout getent git; do
        real="$(command -v "$b" 2>/dev/null)" && ln -sf "$real" "${STUB_DIR}/${b}"
    done
}

teardown() {
    rm -rf "$STUB_DIR" "$WORK_DIR"
}

# _stub_docker SERVER_VERSION COMPOSE_VERSION — instala um stub de `docker`
# que responde a `docker version --format '{{.Server.Version}}'` e a
# `docker compose version --short`.
_stub_docker() {
    local server_ver="$1" compose_ver="$2"
    rm -f "${STUB_DIR}/docker"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'if [ "$1" = "version" ]; then echo "%s"; exit 0; fi\n' "$server_ver"
        printf 'if [ "$1" = "compose" ] && [ "$2" = "version" ]; then echo "%s"; exit 0; fi\n' "$compose_ver"
        printf 'exit 0\n'
    } > "${STUB_DIR}/docker"
    chmod +x "${STUB_DIR}/docker"
}

_run_deps() {
    run env PATH="${STUB_DIR}" COMPOSE_DIR="${WORK_DIR}" bash "$SPECIALIST" --json
}

# ── Docker engine em camadas (advisory, nunca FAIL pela versão) ─────────────

@test "Docker >= recomendado (28) => ok sem warn de versão" {
    _stub_docker "28.1.0" "2.40.0"
    _run_deps
    assert_output --partial '"target": "docker"'
    assert_output --partial '28.1.0'
    # A linha do docker engine não deve ter warn de versão.
    run bash -c "env PATH='${STUB_DIR}' COMPOSE_DIR='${WORK_DIR}' bash '$SPECIALIST' --json | jq -r '.checks[] | select(.target==\"docker\") | .detail'"
    refute_output --partial '(warn)'
}

@test "Docker entre piso (24) e alvo (28) => ok com (warn) citando o piso" {
    _stub_docker "25.0.3" "2.40.0"
    run bash -c "env PATH='${STUB_DIR}' COMPOSE_DIR='${WORK_DIR}' bash '$SPECIALIST' --json | jq -r '.checks[] | select(.target==\"docker\") | .detail'"
    assert_output --partial '(warn)'
    assert_output --partial '24'
}

@test "Docker abaixo do piso (23) => ok com (warn), nunca FAIL pela versão" {
    _stub_docker "23.0.1" "2.40.0"
    run bash -c "env PATH='${STUB_DIR}' COMPOSE_DIR='${WORK_DIR}' bash '$SPECIALIST' --json | jq -r '.checks[] | select(.target==\"docker\") | [.status, .detail] | @tsv'"
    assert_output --partial 'ok'
    assert_output --partial '(warn)'
}

# ── Compose via sort -V ─────────────────────────────────────────────────────

@test "Compose >= piso (2.37) => ok" {
    _stub_docker "28.0.0" "2.40.1"
    run bash -c "env PATH='${STUB_DIR}' COMPOSE_DIR='${WORK_DIR}' bash '$SPECIALIST' --json | jq -r '.checks[] | select(.target==\"docker compose\") | .detail'"
    assert_output --partial '>= 2.37'
}

@test "Compose 2.5 é MENOR que 2.37 (sort -V numérico) => warn" {
    _stub_docker "28.0.0" "2.5.0"
    run bash -c "env PATH='${STUB_DIR}' COMPOSE_DIR='${WORK_DIR}' bash '$SPECIALIST' --json | jq -r '.checks[] | select(.target==\"docker compose\") | .detail'"
    assert_output --partial '(warn)'
}

@test "Compose com sufixo -desktop.1 acima do piso => ok" {
    _stub_docker "28.0.0" "2.38.1-desktop.1"
    run bash -c "env PATH='${STUB_DIR}' COMPOSE_DIR='${WORK_DIR}' bash '$SPECIALIST' --json | jq -r '.checks[] | select(.target==\"docker compose\") | .detail'"
    assert_output --partial '>= 2.37'
}

# ── Drift-guard: binário no manifesto sem rotina de verificação => FAIL ──────

@test "drift-guard: binário fantasma no manifesto vira FAIL" {
    _stub_docker "28.0.0" "2.40.0"
    # Manifesto com um binário inexistente em _bin_category (drift).
    local manifest="${WORK_DIR}/products.json"
    cat > "$manifest" <<'EOF'
{
  "defaults": {
    "host_requirements": {
      "min_docker_major": 24, "recommended_docker_major": 28,
      "min_compose_version": "2.37",
      "ubuntu_target_major": 24, "ubuntu_supported_major": 22,
      "required_binaries": ["curl", "binario-fantasma"]
    }
  }
}
EOF
    run env PATH="${STUB_DIR}" COMPOSE_DIR="${WORK_DIR}" PRODUCTS_FILE="$manifest" \
        bash "$SPECIALIST" --json
    assert_output --partial 'binario-fantasma'
    assert_output --partial 'drift'
    assert_output --partial '"status": "fail"'
}

# ── Fallback de bootstrap (sem jq) ──────────────────────────────────────────

@test "sem jq: usa fallback de bootstrap e ainda avalia o docker" {
    _stub_docker "28.0.0" "2.40.0"
    rm -f "${STUB_DIR}/jq"
    run env PATH="${STUB_DIR}" COMPOSE_DIR="${WORK_DIR}" bash "$SPECIALIST" --json
    # jq ausente é reportado como FAIL (binário de rede), mas o specialist
    # roda até o fim e avalia o docker com os limiares de fallback.
    assert_output --partial '"target": "docker"'
    assert_output --partial '28.0.0'
}
