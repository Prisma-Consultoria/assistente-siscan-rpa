#!/usr/bin/env bats
# Testes para o specialist scripts/deploy_server/check-resources.sh
# (PR #111 — RAM em camadas + limiares em products.json, issue #112; F1/F2/F4).
#
# Cobertura:
#   - Camada de RAM: >= recomendado (ok), entre piso e recomendado (ok + warn),
#     abaixo do piso (FAIL).
#   - vCPUs e disco abaixo do mínimo => FAIL.
#   - F1: rodar SEM produto (env -u SISCAN_PRODUCT, sem --product) NÃO aborta
#     (exit 0/1 conforme recursos, nunca exit 2 por produto ausente).
#   - F2: rodar SEM jq no PATH degrada via fallback de bootstrap (não aborta).
#   - Override por produto em .products.<p>.resources sobrepõe .defaults.
#
# Estratégia: stubs de free/nproc/df num diretório à frente do PATH, com
# coreutils reais linkados, para fixar as fronteiras das camadas sem depender
# do hardware real do runner.

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

setup() {
    PROJECT_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    SPECIALIST="${PROJECT_DIR}/scripts/deploy_server/check-resources.sh"
    STUB_DIR="$(mktemp -d)"
    WORK_DIR="$(mktemp -d)"   # COMPOSE_DIR existente, p/ o probe de disco
    # Linka os utilitários reais que o script usa, exceto os que vamos stubar.
    for b in bash awk hostname tr tail head cut grep sed sort dirname pwd cat env nproc free df mktemp; do
        real="$(command -v "$b" 2>/dev/null)" && ln -sf "$real" "${STUB_DIR}/${b}"
    done
}

teardown() {
    rm -rf "$STUB_DIR" "$WORK_DIR"
}

# _stub_free MB  — instala um stub de `free` que reporta MB de RAM total.
# rm -f primeiro: os links de setup() apontam pro binário real; escrever via
# `>` no symlink atingiria o alvo (Permission denied). Removemos o link antes.
_stub_free() {
    rm -f "${STUB_DIR}/free"
    cat > "${STUB_DIR}/free" <<EOF
#!/usr/bin/env bash
echo "              total        used        free"
echo "Mem:           $1         100         100"
EOF
    chmod +x "${STUB_DIR}/free"
}

# _stub_nproc N
_stub_nproc() {
    rm -f "${STUB_DIR}/nproc"
    printf '#!/usr/bin/env bash\necho %s\n' "$1" > "${STUB_DIR}/nproc"
    chmod +x "${STUB_DIR}/nproc"
}

# _stub_df GB  — `df -BG --output=avail PATH` imprime header + "<GB>G".
_stub_df() {
    rm -f "${STUB_DIR}/df"
    cat > "${STUB_DIR}/df" <<EOF
#!/usr/bin/env bash
echo "Avail"
echo "${1}G"
EOF
    chmod +x "${STUB_DIR}/df"
}

# _run_specialist [extra args...] — roda o specialist com stubs no PATH,
# COMPOSE_DIR válido e SEM SISCAN_PRODUCT herdado (testa o caminho agnóstico).
_run_specialist() {
    run env -u SISCAN_PRODUCT PATH="${STUB_DIR}" COMPOSE_DIR="${WORK_DIR}" \
        bash "$SPECIALIST" --json "$@"
}

# ── Camadas de RAM ──────────────────────────────────────────────────────────

@test "RAM >= recomendado (8 GB) => ok sem warn" {
    _stub_nproc 4; _stub_free 8192; _stub_df 50
    _run_specialist
    assert_success
    assert_output --partial '"status": "ok"'
    refute_output --partial '(warn)'
}

@test "RAM entre piso (7 GB) e recomendado (8 GB) => ok COM (warn), não bloqueia" {
    _stub_nproc 4; _stub_free 7500; _stub_df 50
    _run_specialist
    assert_success          # aviso não-bloqueante: exit 0
    assert_output --partial '(warn)'
    assert_output --partial '"fail": 0'   # nenhuma falha no sumário
    refute_output --partial '"status": "fail"'
}

@test "RAM exatamente no piso (7168 MB) => ok COM (warn)" {
    _stub_nproc 4; _stub_free 7168; _stub_df 50
    _run_specialist
    assert_success
    assert_output --partial '(warn)'
}

@test "RAM abaixo do piso (6 GB) => FAIL (exit 1)" {
    _stub_nproc 4; _stub_free 6144; _stub_df 50
    _run_specialist
    assert_failure
    assert_output --partial '"status": "fail"'
    assert_output --partial 'abaixo do piso'
}

# ── vCPUs e disco ───────────────────────────────────────────────────────────

@test "vCPUs abaixo do mínimo (2 < 4) => FAIL" {
    _stub_nproc 2; _stub_free 8192; _stub_df 50
    _run_specialist
    assert_failure
    assert_output --partial 'vCPUs'
    assert_output --partial '"status": "fail"'
}

@test "disco abaixo do mínimo (10 < 20 GB) => FAIL" {
    _stub_nproc 4; _stub_free 8192; _stub_df 10
    _run_specialist
    assert_failure
    assert_output --partial '"status": "fail"'
}

# ── F1: product-agnostic (não aborta sem produto) ───────────────────────────

@test "F1: roda SEM --product e SEM SISCAN_PRODUCT — não aborta (exit != 2)" {
    _stub_nproc 4; _stub_free 8192; _stub_df 50
    _run_specialist
    # O ponto do F1: não pode ser exit 2 (uso inválido por produto ausente).
    assert_equal "$status" 0
    refute_output --partial 'SISCAN_PRODUCT não definido'
}

@test "F1: recursos suficientes sem produto => exit 0" {
    _stub_nproc 8; _stub_free 16384; _stub_df 100
    _run_specialist
    assert_success
}

# ── F2: degrada sem jq (fallback de bootstrap) ──────────────────────────────

@test "F2: sem jq no PATH usa fallback de bootstrap e não aborta" {
    _stub_nproc 4; _stub_free 8192; _stub_df 50
    rm -f "${STUB_DIR}/jq" 2>/dev/null || true   # garante ausência de jq
    # PATH só com o stub dir: jq não está presente.
    run env -u SISCAN_PRODUCT PATH="${STUB_DIR}" COMPOSE_DIR="${WORK_DIR}" \
        bash "$SPECIALIST" --json
    assert_success
    assert_output --partial '"status": "ok"'
}

@test "F2: sem jq, RAM abaixo do piso ainda FALHA (fallback 7168 ativo)" {
    _stub_nproc 4; _stub_free 6000; _stub_df 50
    rm -f "${STUB_DIR}/jq" 2>/dev/null || true
    run env -u SISCAN_PRODUCT PATH="${STUB_DIR}" COMPOSE_DIR="${WORK_DIR}" \
        bash "$SPECIALIST" --json
    assert_failure
    assert_output --partial 'abaixo do piso'
}

# ── Override por produto sobrepõe .defaults ─────────────────────────────────

@test "override por produto: .products.<p>.resources sobrepõe .defaults" {
    _stub_nproc 4; _stub_free 8192; _stub_df 50
    # Manifesto temporário onde rpa exige 32 vCPUs (defaults = 4).
    local manifest="${WORK_DIR}/products.json"
    cat > "$manifest" <<'EOF'
{
  "defaults": { "resources": { "min_vcpus": 4, "min_ram_mb": 7168, "recommended_ram_mb": 8192, "min_disk_gb": 20 } },
  "products": { "rpa": { "resources": { "min_vcpus": 32, "min_ram_mb": 7168, "recommended_ram_mb": 8192, "min_disk_gb": 20 } } }
}
EOF
    ln -sf "$(command -v jq)" "${STUB_DIR}/jq"
    run env -u SISCAN_PRODUCT PATH="${STUB_DIR}" COMPOSE_DIR="${WORK_DIR}" \
        PRODUCTS_FILE="$manifest" bash "$SPECIALIST" --product rpa --json
    # 4 vCPUs < 32 exigidos pelo override do produto => FAIL.
    assert_failure
    assert_output --partial '>= 32'
}

@test "sem produto usa .defaults (4 vCPUs) mesmo com override de produto no manifesto" {
    _stub_nproc 4; _stub_free 8192; _stub_df 50
    local manifest="${WORK_DIR}/products.json"
    cat > "$manifest" <<'EOF'
{
  "defaults": { "resources": { "min_vcpus": 4, "min_ram_mb": 7168, "recommended_ram_mb": 8192, "min_disk_gb": 20 } },
  "products": { "rpa": { "resources": { "min_vcpus": 32, "min_ram_mb": 7168, "recommended_ram_mb": 8192, "min_disk_gb": 20 } } }
}
EOF
    ln -sf "$(command -v jq)" "${STUB_DIR}/jq"
    run env -u SISCAN_PRODUCT PATH="${STUB_DIR}" COMPOSE_DIR="${WORK_DIR}" \
        PRODUCTS_FILE="$manifest" bash "$SPECIALIST" --json
    # Sem produto => defaults (4 vCPUs); 4 >= 4 => ok.
    assert_success
    assert_output --partial '>= 4'
}
