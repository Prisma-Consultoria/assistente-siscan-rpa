#!/usr/bin/env bats
# Testes para scripts/deploy_server/check-stack.sh — exec, motivo do
# healthcheck, processos, clientes exec presos no host e daemon (issue #116).
#
# Cobertura:
#   - Stack saudável: as categorias novas aprovam.
#   - CA01: exec de um serviço que não retorna reprova em até o prazo
#     declarado, nomeando o serviço; o outro serviço aprova.
#   - CA02: container unhealthy traz FailingStreak, exit e a saída da última
#     tentativa no detail, em uma linha.
#   - CA03: cliente `docker exec` mais velho que o limite reprova com contagem,
#     PID e idade — e a linha de comando NÃO vaza para o detail.
#   - CA04: `docker info` sem resposta reprova o daemon, e o specialist termina.
#   - Processo defunct reprova `Processos nos containers`.
#
# Estratégia: stubs de docker/ps/ss num diretório que É o PATH inteiro, com
# os utilitários reais linkados. O stub de docker que "trava" usa `exec sleep`
# para que o `timeout` mate o próprio sleep, sem órfão segurando a saída.

load '../test_helper/bats-support/load'
load '../test_helper/bats-assert/load'

setup() {
    PROJECT_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    SPECIALIST="${PROJECT_DIR}/scripts/deploy_server/check-stack.sh"
    STUB_DIR="$(mktemp -d)"
    WORK_DIR="$(mktemp -d)"
    for b in bash awk hostname tr tail head cut grep sed sort dirname basename pwd cat env mktemp jq date sleep timeout paste numfmt wc; do
        real="$(command -v "$b" 2>/dev/null)" && ln -sf "$real" "${STUB_DIR}/${b}"
    done
    : > "${WORK_DIR}/docker-compose.prd.rpa.yml"

    # Estado padrão: os dois serviços running e healthy.
    cat > "${WORK_DIR}/ps.json" <<'EOF'
[{"Service":"app","Name":"rpa-app-1","State":"running","Health":"healthy"},
 {"Service":"rpa-scheduler","Name":"rpa-scheduler-1","State":"running","Health":""}]
EOF
    echo 'null' > "${WORK_DIR}/health.json"
    printf 'S\nS\n' > "${WORK_DIR}/top.txt"
    : > "${WORK_DIR}/host-ps.txt"

    cat > "${STUB_DIR}/docker" <<EOF
#!/usr/bin/env bash
W="${WORK_DIR}"
case "\$1" in
    compose)
        shift 3   # compose -f <arquivo>
        case "\$1" in
            config) exit 0 ;;
            ps)     cat "\$W/ps.json" ;;
            exec)
                svc="\$3"
                if grep -qx "\$svc" "\$W/exec-hang.txt" 2>/dev/null; then exec sleep 60; fi
                exit 0 ;;
        esac ;;
    image)    [ "\$3" = "--format" ] && echo 1000; exit 0 ;;
    manifest) echo "unauthorized" >&2; exit 1 ;;
    inspect)  cat "\$W/health.json" ;;
    top)      printf 'STAT\n'; cat "\$W/top.txt" ;;
    info)
        [ -f "\$W/info-hang" ] && exec sleep 60
        echo "28.2.2" ;;
esac
EOF
    printf '#!/usr/bin/env bash\ncat "%s/host-ps.txt"\n' "${WORK_DIR}" > "${STUB_DIR}/ps"
    printf '#!/usr/bin/env bash\nexit 0\n' > "${STUB_DIR}/ss"
    chmod +x "${STUB_DIR}/docker" "${STUB_DIR}/ps" "${STUB_DIR}/ss"
}

teardown() {
    rm -rf "$STUB_DIR" "$WORK_DIR"
}

# _checks — roda o specialist com prazos curtos e grava o JSON em $WORK_DIR/out.json.
_checks() {
    env PATH="${STUB_DIR}" COMPOSE_DIR="${WORK_DIR}" \
        SISCAN_STACK_EXEC_TIMEOUT=2 SISCAN_STACK_DOCKER_TIMEOUT=2 SISCAN_STACK_EXEC_STALE_SECONDS=900 \
        bash "$SPECIALIST" --product rpa --json > "${WORK_DIR}/out.json" 2>/dev/null || true
}

# _detail CATEGORIA TARGET STATUS — imprime o detail do check que casar.
_detail() {
    jq -r --arg c "$1" --arg t "$2" --arg s "$3" \
        '.checks[] | select(.category==$c and .target==$t and .status==$s) | .detail' "${WORK_DIR}/out.json"
}

@test "stack saudável: exec, processos, host e daemon aprovam" {
    _checks
    run _detail "Exec nos containers" "service app" ok
    assert_output --partial "respondeu em"
    run _detail "Exec nos containers" "service rpa-scheduler" ok
    assert_output --partial "respondeu em"
    run _detail "Processos nos containers" "service app" ok
    assert_output "2 processo(s), nenhum defunct"
    run _detail "Processos no host" "docker exec" ok
    assert_output --partial "nenhum cliente exec"
    run _detail "Daemon Docker" "docker info" ok
    assert_output "responde (servidor 28.2.2)"
}

@test "CA01: exec que não retorna reprova o serviço dentro do prazo" {
    echo app > "${WORK_DIR}/exec-hang.txt"
    started=$(date +%s)
    _checks
    elapsed=$(( $(date +%s) - started ))
    # prazo 2s + kill 5s; folga para o resto do specialist
    [ "$elapsed" -lt 20 ]
    run _detail "Exec nos containers" "service app" fail
    assert_output --partial "não respondeu em 2s"
    run _detail "Exec nos containers" "service rpa-scheduler" ok
    assert_output --partial "respondeu em"
}

@test "CA02: unhealthy traz FailingStreak, exit e saída da última tentativa" {
    cat > "${WORK_DIR}/ps.json" <<'EOF'
[{"Service":"app","Name":"rpa-app-1","State":"running","Health":"unhealthy"},
 {"Service":"rpa-scheduler","Name":"rpa-scheduler-1","State":"running","Health":""}]
EOF
    cat > "${WORK_DIR}/health.json" <<'EOF'
{"Status":"unhealthy","FailingStreak":37,"Log":[
 {"ExitCode":0,"Output":"ok"},
 {"ExitCode":-1,"Output":"Health check exceeded timeout (10s)\n"}]}
EOF
    _checks
    run _detail "Saúde dos containers" "healthcheck" fail
    assert_output "unhealthy: rpa-app-1 (FailingStreak=37, última tentativa exit=-1: Health check exceeded timeout (10s) )"
    [ "${#lines[@]}" -eq 1 ]
}

@test "CA03: cliente exec antigo reprova com PID e idade, sem vazar a linha de comando" {
    cat > "${WORK_DIR}/host-ps.txt" <<'EOF'
  4242 21600 docker compose -f docker-compose.prd.rpa.yml exec -T app python -m src.commands.backup_manager backup -e SENHA=segredo
  4300     5 docker exec rpa-app-1 true
  5000 99999 /usr/bin/dockerd -H fd://
EOF
    _checks
    run _detail "Processos no host" "docker exec" fail
    assert_output "1 cliente(s) exec vivo(s) há mais de 900s; o mais antigo (PID 4242) há 21600s"
    refute_output --partial "segredo"
    refute_output --partial "backup_manager"
}

@test "CA03 (controle): sem cliente exec antigo, aprova" {
    printf '  4300     5 docker exec rpa-app-1 true\n' > "${WORK_DIR}/host-ps.txt"
    _checks
    run _detail "Processos no host" "docker exec" ok
    assert_output --partial "nenhum cliente exec"
}

@test "CA04: docker info sem resposta reprova o daemon e o specialist termina" {
    touch "${WORK_DIR}/info-hang"
    _checks
    run _detail "Daemon Docker" "docker info" fail
    assert_output "não respondeu em 2s"
    run jq -r '.summary.total' "${WORK_DIR}/out.json"
    assert [ "$output" -gt 0 ]
}

@test "processo defunct reprova Processos nos containers" {
    printf 'S\nZ\nZ\n' > "${WORK_DIR}/top.txt"
    _checks
    run _detail "Processos nos containers" "service app" fail
    assert_output --partial "3 processo(s), 2 defunct"
}
