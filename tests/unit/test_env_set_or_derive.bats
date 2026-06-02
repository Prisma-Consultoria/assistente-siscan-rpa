#!/usr/bin/env bats
# Testes para env_set_or_derive + env_apply_derivation + ensure_host_paths_derived
# (siscan-server-setup.sh — TSK00.05.01 #95)
#
# Cobre:
#   - Derivação correta com `dirname + /<subdir>`
#   - Preservação de valor pré-existente no .env (operador customizou)
#   - Criação do diretório quando auto_create=true
#   - Aplicação de default_mode (chmod) — secrets em 700
#   - Comportamento gracioso quando parent_var está vazio (warn + return 1)
#   - Compatibilidade com `dashboard` (sem variáveis derivadas — no-op)

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

setup() {
    source "${BATS_TEST_DIRNAME}/../../siscan-server-setup.sh"
    DATA_DIR="$(mktemp -d)"
    ENV_FILE="${DATA_DIR}/.env"
    PRODUCTS_FILE="${BATS_TEST_DIRNAME}/../../scripts/data/products.json"
    export PRODUCTS_FILE
}

teardown() {
    rm -rf "${DATA_DIR}"
}

# ── env_apply_derivation ────────────────────────────────────────────────────

@test "env_apply_derivation: 'dirname + /secrets' extrai parent + concatena subdir" {
    run env_apply_derivation "dirname + /secrets" "/opt/siscan/log"
    assert_success
    assert_output "/opt/siscan/secrets"
}

@test "env_apply_derivation: 'dirname + /backups' funciona com path aninhado" {
    run env_apply_derivation "dirname + /backups" "/var/data/siscan/log"
    assert_success
    assert_output "/var/data/siscan/backups"
}

@test "env_apply_derivation: parent vazio retorna vazio (return 0, sem erro)" {
    run env_apply_derivation "dirname + /secrets" ""
    assert_success
    assert_output ""
}

@test "env_apply_derivation: expressão desconhecida retorna 1" {
    run env_apply_derivation "expressao_inventada" "/tmp/foo"
    assert_failure
}

# ── env_set_or_derive — derivação ────────────────────────────────────────────

@test "env_set_or_derive: deriva HOST_SECRETS_DIR de HOST_LOG_DIR (caso ausente)" {
    cat > "${ENV_FILE}" <<EOF
HOST_LOG_DIR=${DATA_DIR}/log
EOF
    run env_set_or_derive "${ENV_FILE}" HOST_SECRETS_DIR HOST_LOG_DIR "dirname + /secrets" "700" "true"
    assert_success
    run _read_env_value "${ENV_FILE}" HOST_SECRETS_DIR
    assert_output "${DATA_DIR}/secrets"
}

@test "env_set_or_derive: cria diretório quando auto_create=true" {
    cat > "${ENV_FILE}" <<EOF
HOST_LOG_DIR=${DATA_DIR}/log
EOF
    env_set_or_derive "${ENV_FILE}" HOST_SECRETS_DIR HOST_LOG_DIR "dirname + /secrets" "700" "true"
    [ -d "${DATA_DIR}/secrets" ]
}

@test "env_set_or_derive: aplica default_mode (700) em diretório criado" {
    cat > "${ENV_FILE}" <<EOF
HOST_LOG_DIR=${DATA_DIR}/log
EOF
    env_set_or_derive "${ENV_FILE}" HOST_SECRETS_DIR HOST_LOG_DIR "dirname + /secrets" "700" "true"
    local perms
    perms=$(stat -c '%a' "${DATA_DIR}/secrets")
    [ "${perms}" = "700" ]
}

@test "env_set_or_derive: omite chmod quando default_mode vazio" {
    cat > "${ENV_FILE}" <<EOF
HOST_LOG_DIR=${DATA_DIR}/log
EOF
    env_set_or_derive "${ENV_FILE}" HOST_BACKUPS_DIR HOST_LOG_DIR "dirname + /backups" "" "true"
    [ -d "${DATA_DIR}/backups" ]
    # Sem chmod customizado → mode default (depende do umask, tipicamente 755)
    local perms
    perms=$(stat -c '%a' "${DATA_DIR}/backups")
    [ "${perms}" != "700" ]
}

# ── env_set_or_derive — preservação ─────────────────────────────────────────

@test "env_set_or_derive: preserva valor pré-existente no .env (operador customizou)" {
    mkdir -p "${DATA_DIR}/custom/path"
    cat > "${ENV_FILE}" <<EOF
HOST_LOG_DIR=${DATA_DIR}/log
HOST_SECRETS_DIR=${DATA_DIR}/custom/path
EOF
    env_set_or_derive "${ENV_FILE}" HOST_SECRETS_DIR HOST_LOG_DIR "dirname + /secrets" "700" "true"
    run _read_env_value "${ENV_FILE}" HOST_SECRETS_DIR
    assert_output "${DATA_DIR}/custom/path"
}

@test "env_set_or_derive: aplica chmod no caminho customizado quando preservado" {
    mkdir -p "${DATA_DIR}/custom/path"
    cat > "${ENV_FILE}" <<EOF
HOST_LOG_DIR=${DATA_DIR}/log
HOST_SECRETS_DIR=${DATA_DIR}/custom/path
EOF
    env_set_or_derive "${ENV_FILE}" HOST_SECRETS_DIR HOST_LOG_DIR "dirname + /secrets" "700" "true"
    local perms
    perms=$(stat -c '%a' "${DATA_DIR}/custom/path")
    [ "${perms}" = "700" ]
}

@test "env_set_or_derive: é idempotente (rodar 2x não muda nada)" {
    cat > "${ENV_FILE}" <<EOF
HOST_LOG_DIR=${DATA_DIR}/log
EOF
    env_set_or_derive "${ENV_FILE}" HOST_SECRETS_DIR HOST_LOG_DIR "dirname + /secrets" "700" "true"
    local first_md5
    first_md5=$(md5sum "${ENV_FILE}" | awk '{print $1}')
    env_set_or_derive "${ENV_FILE}" HOST_SECRETS_DIR HOST_LOG_DIR "dirname + /secrets" "700" "true"
    local second_md5
    second_md5=$(md5sum "${ENV_FILE}" | awk '{print $1}')
    [ "${first_md5}" = "${second_md5}" ]
}

# ── env_set_or_derive — erros ────────────────────────────────────────────────

@test "env_set_or_derive: warn + return 1 quando parent_var está vazio no .env" {
    cat > "${ENV_FILE}" <<EOF
# HOST_LOG_DIR não declarado
SOMETHING=else
EOF
    run env_set_or_derive "${ENV_FILE}" HOST_SECRETS_DIR HOST_LOG_DIR "dirname + /secrets" "700" "true"
    assert_failure
}

@test "env_set_or_derive: return 2 quando argumentos obrigatórios faltam" {
    run env_set_or_derive "" "" "" ""
    [ "${status}" -eq 2 ]
}

# ── ensure_host_paths_derived (integração com manifesto) ────────────────────

@test "ensure_host_paths_derived (rpa): popula HOST_SECRETS_DIR + HOST_BACKUPS_DIR" {
    cat > "${ENV_FILE}" <<EOF
HOST_LOG_DIR=${DATA_DIR}/log
EOF
    SISCAN_PRODUCT=rpa
    run ensure_host_paths_derived "${ENV_FILE}"
    assert_success
    grep -q "^HOST_SECRETS_DIR=${DATA_DIR}/secrets$" "${ENV_FILE}"
    grep -q "^HOST_BACKUPS_DIR=${DATA_DIR}/backups$" "${ENV_FILE}"
}

@test "ensure_host_paths_derived (rpa): cria ambos os diretórios com modos corretos" {
    cat > "${ENV_FILE}" <<EOF
HOST_LOG_DIR=${DATA_DIR}/log
EOF
    SISCAN_PRODUCT=rpa
    ensure_host_paths_derived "${ENV_FILE}"
    [ -d "${DATA_DIR}/secrets" ]
    [ -d "${DATA_DIR}/backups" ]
    local secrets_perms
    secrets_perms=$(stat -c '%a' "${DATA_DIR}/secrets")
    [ "${secrets_perms}" = "700" ]
}

@test "ensure_host_paths_derived (dashboard): no-op (não tem objetos em host_dir_vars)" {
    cat > "${ENV_FILE}" <<EOF
HOST_LOG_DIR=${DATA_DIR}/log
EOF
    SISCAN_PRODUCT=dashboard
    local before_md5
    before_md5=$(md5sum "${ENV_FILE}" | awk '{print $1}')
    run ensure_host_paths_derived "${ENV_FILE}"
    assert_success
    local after_md5
    after_md5=$(md5sum "${ENV_FILE}" | awk '{print $1}')
    [ "${before_md5}" = "${after_md5}" ]
}

@test "ensure_host_paths_derived (full): também popula HOST_SECRETS_DIR + HOST_BACKUPS_DIR" {
    cat > "${ENV_FILE}" <<EOF
HOST_LOG_DIR=${DATA_DIR}/log
EOF
    SISCAN_PRODUCT=full
    run ensure_host_paths_derived "${ENV_FILE}"
    assert_success
    grep -q "^HOST_SECRETS_DIR=${DATA_DIR}/secrets$" "${ENV_FILE}"
    grep -q "^HOST_BACKUPS_DIR=${DATA_DIR}/backups$" "${ENV_FILE}"
}

@test "ensure_host_paths_derived: no-op quando PRODUCTS_FILE não definido (backward compat)" {
    cat > "${ENV_FILE}" <<EOF
HOST_LOG_DIR=${DATA_DIR}/log
EOF
    PRODUCTS_FILE=""
    SISCAN_PRODUCT=rpa
    run ensure_host_paths_derived "${ENV_FILE}"
    assert_success
    ! grep -q "^HOST_SECRETS_DIR=" "${ENV_FILE}"
}

# ── product_get_host_dir_vars_derived (manifesto v2.0) ──────────────────────

@test "product_get_host_dir_vars_derived (rpa): retorna 2 entradas TSV" {
    SISCAN_PRODUCT=rpa
    run product_get_host_dir_vars_derived
    assert_success
    local n
    n=$(printf '%s\n' "${output}" | grep -c '^HOST_')
    [ "${n}" -eq 2 ]
}

@test "product_get_host_dir_vars_derived (dashboard): vazio (sem objetos)" {
    SISCAN_PRODUCT=dashboard
    run product_get_host_dir_vars_derived
    assert_success
    assert_output ""
}

# ── product_get_array preserva semântica legada ─────────────────────────────

@test "product_get_array host_dir_vars (rpa): emite SÓ strings (5 entradas, não 7)" {
    SISCAN_PRODUCT=rpa
    run product_get_array host_dir_vars
    assert_success
    local n
    n=$(printf '%s\n' "${output}" | grep -c '^HOST_')
    [ "${n}" -eq 5 ]
}

@test "product_get_array host_dir_vars (rpa): NÃO inclui HOST_SECRETS_DIR nem HOST_BACKUPS_DIR" {
    SISCAN_PRODUCT=rpa
    run product_get_array host_dir_vars
    refute_output --partial "HOST_SECRETS_DIR"
    refute_output --partial "HOST_BACKUPS_DIR"
}
