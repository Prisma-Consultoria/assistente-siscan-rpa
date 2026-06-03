#!/usr/bin/env bats
# Testes para o subcomando `run` de siscan-assistente-autoupdate.sh (TSK00.06.01).
#
# Cobre os 4 desfechos do `run`:
#   updated          — repo atrasado avança via git pull --ff-only.
#   already-current  — repo já na ponta de origin/main.
#   skipped-interval — interval_days>1 e último sucesso recente (guarda).
#   failed-dirty     — árvore suja (arquivos rastreados) → repo intacto, exit 2.
#
# Estratégia: monta um "origin" git local + um clone, copia o script + a
# dependência _common.sh para dentro do clone (igual ao layout de produção,
# onde o script roda da raiz do clone). Estado e DIR são injetados por env var,
# sem tocar no $HOME real.

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

SCRIPT_NAME="siscan-assistente-autoupdate.sh"

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    TEST_DIR="$(mktemp -d)"
    ORIGIN="${TEST_DIR}/origin"
    CLONE="${TEST_DIR}/clone"
    STATE_FILE="${TEST_DIR}/state/update-state.json"
    export SISCAN_UPDATE_STATE_FILE="${STATE_FILE}"
    export DIR_SISCAN_ASSISTENTE="${CLONE}"

    # Origin com 2 commits.
    git init -q -b main "${ORIGIN}"
    git -C "${ORIGIN}" config user.email "t@example.test"
    git -C "${ORIGIN}" config user.name "tester"
    echo "v1" > "${ORIGIN}/file.txt"
    git -C "${ORIGIN}" add . && git -C "${ORIGIN}" commit -qm "c1"
    git -C "${ORIGIN}" commit -q --allow-empty -m "c2"

    git clone -q "${ORIGIN}" "${CLONE}"
    git -C "${CLONE}" config user.email "t@example.test"
    git -C "${CLONE}" config user.name "tester"

    # Replica o layout de produção: script na raiz + _common.sh disponível.
    cp "${REPO_ROOT}/${SCRIPT_NAME}" "${CLONE}/"
    mkdir -p "${CLONE}/scripts/deploy_server"
    cp "${REPO_ROOT}/scripts/deploy_server/_common.sh" "${CLONE}/scripts/deploy_server/"

    SCRIPT="${CLONE}/${SCRIPT_NAME}"
}

teardown() {
    rm -rf "${TEST_DIR}"
    unset SISCAN_UPDATE_STATE_FILE DIR_SISCAN_ASSISTENTE
}

# Helper: lê um campo escalar do estado gravado.
state_field() { jq -r "$1" "${STATE_FILE}"; }

# ── updated ─────────────────────────────────────────────────────────────────

@test "run: repo atrasado avança e grava outcome=updated com SHAs corretos" {
    git -C "${CLONE}" reset -q --hard HEAD~1   # clone fica 1 commit atrás
    local before after
    before="$(git -C "${CLONE}" rev-parse --short HEAD)"

    run bash "${SCRIPT}" run
    assert_success

    after="$(git -C "${CLONE}" rev-parse --short HEAD)"
    [ "${before}" != "${after}" ]
    assert_equal "$(state_field '.outcome')" "updated"
    assert_equal "$(state_field '.commit_before')" "${before}"
    assert_equal "$(state_field '.commit_after')" "${after}"
    assert_equal "$(state_field '.commits_pulled')" "1"
    assert_equal "$(state_field '.branch')" "main"
    # last_success_utc preenchido em sucesso.
    [ "$(state_field '.last_success_utc')" != "null" ]
}

# ── already-current ─────────────────────────────────────────────────────────

@test "run: repo na ponta grava outcome=already-current sem erro" {
    run bash "${SCRIPT}" run
    assert_success
    assert_equal "$(state_field '.outcome')" "already-current"
    assert_equal "$(state_field '.commits_pulled')" "0"
    assert_equal "$(state_field '.commit_before')" "$(state_field '.commit_after')"
}

# ── skipped-interval ────────────────────────────────────────────────────────

@test "run: dentro do intervalo (interval_days>1, sucesso recente) grava skipped-interval e sai 0" {
    git -C "${CLONE}" reset -q --hard HEAD~1   # clone atrás (haveria o que puxar)
    local head_before
    head_before="$(git -C "${CLONE}" rev-parse HEAD)"

    # Estado pré-existente: interval 3, sucesso agora.
    mkdir -p "$(dirname "${STATE_FILE}")"
    local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    cat > "${STATE_FILE}" <<EOF
{"schema":"1.0","outcome":"updated","branch":"main","commit_before":"x","commit_after":"x","commit_subject":"s","commits_pulled":0,"last_attempt_utc":"${now}","last_success_utc":"${now}","schedule":{"interval_days":3,"at":"03:00","cron":"0 3 * * *"}}
EOF

    run bash "${SCRIPT}" run
    assert_success
    assert_equal "$(state_field '.outcome')" "skipped-interval"
    # Repo NÃO foi atualizado (guarda saiu antes do pull).
    assert_equal "$(git -C "${CLONE}" rev-parse HEAD)" "${head_before}"
    # interval_days preservado.
    assert_equal "$(state_field '.schedule.interval_days')" "3"
}

@test "run: interval_days=2 com ~47.5h decorridas NÃO pula (folga de 1h)" {
    # Guarda de intervalo compara em segundos com folga de 1h
    # (interval*86400 - 3600). Para interval=2 o limiar é 169200s (47h).
    # Com 47.5h (171000s) decorridos, o ciclo está cumprido → o run DEVE puxar,
    # não gravar skipped-interval. Antes (truncando p/ dias), 47h virava "1 dia"
    # < 2 → SKIP indevido. Este teste guarda contra essa derrapagem.
    git -C "${CLONE}" reset -q --hard HEAD~1   # clone atrás → há o que puxar
    local before; before="$(git -C "${CLONE}" rev-parse --short HEAD)"

    mkdir -p "$(dirname "${STATE_FILE}")"
    # last_success = agora - 47.5h (171000s).
    local past; past="$(date -u -d "@$(( $(date -u +%s) - 171000 ))" +%Y-%m-%dT%H:%M:%SZ)"
    cat > "${STATE_FILE}" <<EOF
{"schema":"1.0","outcome":"updated","branch":"main","commit_before":"x","commit_after":"x","commit_subject":"s","commits_pulled":0,"last_attempt_utc":"${past}","last_success_utc":"${past}","schedule":{"interval_days":2,"at":"03:00","cron":"0 3 * * *"}}
EOF

    run bash "${SCRIPT}" run
    assert_success
    # NÃO pulou: ciclo cumprido → puxou e avançou.
    assert_equal "$(state_field '.outcome')" "updated"
    [ "${before}" != "$(git -C "${CLONE}" rev-parse --short HEAD)" ]
}

@test "run: interval_days=2 com ~24h decorridas pula (skipped-interval)" {
    # Contraprova: 24h (86400s) << limiar 169200s → ainda dentro do ciclo de 2d.
    git -C "${CLONE}" reset -q --hard HEAD~1
    local head_before; head_before="$(git -C "${CLONE}" rev-parse HEAD)"

    mkdir -p "$(dirname "${STATE_FILE}")"
    local past; past="$(date -u -d "@$(( $(date -u +%s) - 86400 ))" +%Y-%m-%dT%H:%M:%SZ)"
    cat > "${STATE_FILE}" <<EOF
{"schema":"1.0","outcome":"updated","branch":"main","commit_before":"x","commit_after":"x","commit_subject":"s","commits_pulled":0,"last_attempt_utc":"${past}","last_success_utc":"${past}","schedule":{"interval_days":2,"at":"03:00","cron":"0 3 * * *"}}
EOF

    run bash "${SCRIPT}" run
    assert_success
    assert_equal "$(state_field '.outcome')" "skipped-interval"
    assert_equal "$(git -C "${CLONE}" rev-parse HEAD)" "${head_before}"
}

# ── lock (M2) ────────────────────────────────────────────────────────────────

@test "run: degrada gracioso sem flock no PATH (segue sem lock)" {
    # PATH restrito a um bin sem 'flock', mas com git/jq via symlink p/ os reais.
    local fakebin="${TEST_DIR}/nolock_bin"
    mkdir -p "${fakebin}"
    for c in bash git jq date mktemp mkdir mv rm sed awk cat dirname basename env tail printf grep; do
        local p; p="$(command -v "$c" 2>/dev/null)" && ln -sf "$p" "${fakebin}/$c"
    done
    run env PATH="${fakebin}" bash "${SCRIPT}" run
    assert_success
    assert_equal "$(state_field '.outcome')" "already-current"
}

# ── failed-dirty ────────────────────────────────────────────────────────────

@test "run: árvore suja (rastreado modificado) grava failed, repo intacto, exit 2" {
    git -C "${CLONE}" reset -q --hard HEAD~1
    echo "edição local" >> "${CLONE}/file.txt"   # arquivo RASTREADO modificado
    local head_before
    head_before="$(git -C "${CLONE}" rev-parse HEAD)"

    run bash "${SCRIPT}" run
    assert_failure 2
    assert_equal "$(state_field '.outcome')" "failed"
    # Repo não tocado: HEAD igual e modificação local preservada.
    assert_equal "$(git -C "${CLONE}" rev-parse HEAD)" "${head_before}"
    grep -q "edição local" "${CLONE}/file.txt"
}

@test "run: arquivo NÃO-rastreado não bloqueia o pull" {
    git -C "${CLONE}" reset -q --hard HEAD~1
    touch "${CLONE}/arquivo_novo_nao_rastreado.txt"

    run bash "${SCRIPT}" run
    assert_success
    assert_equal "$(state_field '.outcome')" "updated"
}

# ── precondições ────────────────────────────────────────────────────────────

@test "run: branch != main grava failed e sai 2" {
    git -C "${CLONE}" checkout -q -b outra
    run bash "${SCRIPT}" run
    assert_failure 2
    assert_equal "$(state_field '.outcome')" "failed"
    assert_equal "$(state_field '.branch')" "outra"
}

@test "status --json sem estado retorna {} e sai 0" {
    rm -f "${STATE_FILE}"
    run bash "${SCRIPT}" status --json
    assert_success
    assert_output "{}"
}

@test "status --json após run reflete o estado gravado" {
    bash "${SCRIPT}" run >/dev/null
    run bash "${SCRIPT}" status --json
    assert_success
    assert_output --partial '"outcome"'
    assert_output --partial '"schema": "1.0"'
}
