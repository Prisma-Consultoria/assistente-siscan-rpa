#!/usr/bin/env bats
# Testes para os subcomandos `schedule`/`unschedule` de
# siscan-assistente-autoupdate.sh (TSK00.06.02).
#
# Cobre:
#   - parse de frequência → cron (--daily, --every-days N) + --at HH:MM.
#   - idempotência (re-schedule substitui o bloco, não duplica).
#   - unschedule cirúrgico (preserva o resto do crontab).
#   - validação de horário (HH:MM 24h).
#
# crontab é substituído por um stub em PATH que persiste num arquivo
# (FAKE_CRONTAB_FILE) — não toca no crontab real do usuário/CI. systemctl
# também é stubado para silenciar o aviso de daemon de cron.

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

SCRIPT_NAME="siscan-assistente-autoupdate.sh"

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    TEST_DIR="$(mktemp -d)"
    CLONE="${TEST_DIR}/clone"
    STATE_FILE="${TEST_DIR}/state/update-state.json"
    FAKE_CRONTAB_FILE="${TEST_DIR}/fake_crontab"
    export SISCAN_UPDATE_STATE_FILE="${STATE_FILE}"
    export DIR_SISCAN_ASSISTENTE="${CLONE}"
    export FAKE_CRONTAB_FILE

    # Clone git mínimo (schedule chama require_commands git jq mas não pulla).
    git init -q -b main "${CLONE}"
    git -C "${CLONE}" config user.email "t@example.test"
    git -C "${CLONE}" config user.name "tester"
    git -C "${CLONE}" commit -q --allow-empty -m "c1"

    cp "${REPO_ROOT}/${SCRIPT_NAME}" "${CLONE}/"
    mkdir -p "${CLONE}/scripts/deploy_server"
    cp "${REPO_ROOT}/scripts/deploy_server/_common.sh" "${CLONE}/scripts/deploy_server/"
    SCRIPT="${CLONE}/${SCRIPT_NAME}"

    # Stub bin dir em PATH: crontab + systemctl.
    STUB_BIN="${TEST_DIR}/bin"
    mkdir -p "${STUB_BIN}"
    cat > "${STUB_BIN}/crontab" <<'EOF'
#!/usr/bin/env bash
STORE="${FAKE_CRONTAB_FILE}"
case "$1" in
  -l) [ -f "$STORE" ] && cat "$STORE" || { echo "no crontab for user" >&2; exit 1; } ;;
  -r) rm -f "$STORE" ;;
  -)  cat > "$STORE" ;;
  *)  echo "crontab stub: unsupported $*" >&2; exit 2 ;;
esac
EOF
    chmod +x "${STUB_BIN}/crontab"
    # systemctl stub: reporta cron ativo (silencia o warn).
    cat > "${STUB_BIN}/systemctl" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "is-active" ] && exit 0
exit 0
EOF
    chmod +x "${STUB_BIN}/systemctl"
    export PATH="${STUB_BIN}:${PATH}"
}

teardown() {
    rm -rf "${TEST_DIR}"
    unset SISCAN_UPDATE_STATE_FILE DIR_SISCAN_ASSISTENTE FAKE_CRONTAB_FILE
}

# ── parse de frequência → cron ──────────────────────────────────────────────

@test "schedule --daily --at 03:00 gera cron '0 3 * * *' e interval_days=1" {
    run bash "${SCRIPT}" schedule --daily --at 03:00
    assert_success
    grep -q '^0 3 \* \* \*' "${FAKE_CRONTAB_FILE}"
    assert_equal "$(jq -r '.schedule.cron' "${STATE_FILE}")" "0 3 * * *"
    assert_equal "$(jq -r '.schedule.interval_days' "${STATE_FILE}")" "1"
    assert_equal "$(jq -r '.schedule.at' "${STATE_FILE}")" "03:00"
}

@test "schedule --every-days 3 --at 04:30 grava cron '30 4 * * *' + interval_days=3" {
    run bash "${SCRIPT}" schedule --every-days 3 --at 04:30
    assert_success
    assert_equal "$(jq -r '.schedule.cron' "${STATE_FILE}")" "30 4 * * *"
    assert_equal "$(jq -r '.schedule.interval_days' "${STATE_FILE}")" "3"
    grep -q '^30 4 \* \* \*' "${FAKE_CRONTAB_FILE}"
}

@test "schedule remove zero à esquerda do horário (08:05 -> '5 8 * * *')" {
    run bash "${SCRIPT}" schedule --daily --at 08:05
    assert_success
    assert_equal "$(jq -r '.schedule.cron' "${STATE_FILE}")" "5 8 * * *"
}

# ── bloco gerenciado por marcadores ─────────────────────────────────────────

@test "schedule instala bloco com marcadores begin/end" {
    bash "${SCRIPT}" schedule --daily --at 01:00
    grep -qF '# >>> siscan-assistente autoupdate (managed) >>>' "${FAKE_CRONTAB_FILE}"
    grep -qF '# <<< siscan-assistente autoupdate <<<' "${FAKE_CRONTAB_FILE}"
    grep -q 'run --quiet' "${FAKE_CRONTAB_FILE}"
}

# ── idempotência ────────────────────────────────────────────────────────────

@test "re-schedule substitui o bloco sem duplicar" {
    bash "${SCRIPT}" schedule --daily --at 01:00
    bash "${SCRIPT}" schedule --daily --at 02:00
    # Apenas UM bloco gerenciado.
    assert_equal "$(grep -cF '# >>> siscan-assistente autoupdate (managed) >>>' "${FAKE_CRONTAB_FILE}")" "1"
    assert_equal "$(grep -cF '# <<< siscan-assistente autoupdate <<<' "${FAKE_CRONTAB_FILE}")" "1"
    # E reflete o NOVO horário.
    grep -q '^0 2 \* \* \*' "${FAKE_CRONTAB_FILE}"
    ! grep -q '^0 1 \* \* \*' "${FAKE_CRONTAB_FILE}"
}

# ── unschedule cirúrgico ────────────────────────────────────────────────────

@test "unschedule remove só o bloco gerenciado, preservando o resto do crontab" {
    # Entrada de usuário pré-existente.
    cat > "${FAKE_CRONTAB_FILE}" <<'EOF'
# job do usuário
0 0 * * * echo ola
EOF
    bash "${SCRIPT}" schedule --daily --at 05:00
    grep -qF 'managed' "${FAKE_CRONTAB_FILE}"

    run bash "${SCRIPT}" unschedule
    assert_success
    # Bloco gerenciado sumiu, job do usuário permanece.
    ! grep -qF 'managed' "${FAKE_CRONTAB_FILE}"
    grep -qF '0 0 * * * echo ola' "${FAKE_CRONTAB_FILE}"
    grep -qF '# job do usuário' "${FAKE_CRONTAB_FILE}"
}

@test "unschedule sem crontab é no-op e sai 0" {
    rm -f "${FAKE_CRONTAB_FILE}"
    run bash "${SCRIPT}" unschedule
    assert_success
}

@test "unschedule sem bloco gerenciado preserva crontab e sai 0" {
    cat > "${FAKE_CRONTAB_FILE}" <<'EOF'
0 0 * * * echo ola
EOF
    run bash "${SCRIPT}" unschedule
    assert_success
    grep -qF '0 0 * * * echo ola' "${FAKE_CRONTAB_FILE}"
}

# ── validação de horário ────────────────────────────────────────────────────

@test "schedule rejeita horário inválido (25:00) com exit 2" {
    run bash "${SCRIPT}" schedule --daily --at 25:00
    assert_failure 2
    assert_output --partial "Horário inválido"
}

@test "schedule rejeita horário sem dois pontos (0300) com exit 2" {
    run bash "${SCRIPT}" schedule --daily --at 0300
    assert_failure 2
}

@test "schedule --every-days exige N>=2" {
    run bash "${SCRIPT}" schedule --every-days 1 --at 03:00
    assert_failure 2
}

@test "schedule --every-days rejeita N não-numérico" {
    run bash "${SCRIPT}" schedule --every-days abc --at 03:00
    assert_failure 2
}
