#!/usr/bin/env bash
# -------------------------------------------
# SISCAN Assistente Autoupdate — Autoatualização agendada do clone do assistente
# -------------------------------------------
# Arquivo: siscan-assistente-autoupdate.sh
# Propósito: automatizar o `git pull --ff-only` do clone do assistente nas VMs
#            de produção (eliminando o pull manual repetido) e expor o estado
#            da última atualização (commit, timestamp, resultado) de forma
#            auditável — inclusive no diagnóstico pre-deploy dos workflows CD.
#
# Feature F00.06 (issue #105). Sub-tasks: #106 (run), #107 (schedule/
# unschedule), #108 (status + template), #109 (docs).
#
# Interface por subcomandos:
#   run         Alvo do cron: git pull --ff-only origin main + grava estado.
#   schedule    Instala bloco de cron gerenciado que dispara `run`.
#   unschedule  Remove o bloco de cron gerenciado.
#   status      Imprime o estado da última atualização (--json para máquina).
#
# Uso:
#   bash ./siscan-assistente-autoupdate.sh run [--quiet]
#   bash ./siscan-assistente-autoupdate.sh schedule [--daily | --every-days N] --at HH:MM
#   bash ./siscan-assistente-autoupdate.sh schedule          # prompt interativo
#   bash ./siscan-assistente-autoupdate.sh unschedule
#   bash ./siscan-assistente-autoupdate.sh status [--json]
#   bash ./siscan-assistente-autoupdate.sh --help
#
# Variáveis de ambiente opcionais:
#   DIR_SISCAN_ASSISTENTE     Raiz do clone do assistente (default: dir do script).
#   SISCAN_UPDATE_STATE_FILE  Caminho do arquivo de estado (default:
#                             ${XDG_STATE_HOME:-$HOME/.local/state}/siscan-assistente/update-state.json).
#
# Decisão de design — árvore suja: se houver modificação em arquivos
# RASTREADOS, o `run` grava outcome=failed + warn e NÃO faz pull. O script
# nunca stasha nem mexe no repo silenciosamente — preserva qualquer alteração
# local (ex.: edição manual emergencial) e deixa a reconciliação para o
# operador. Arquivos não-rastreados (untracked) NÃO bloqueiam o ff-only.
#
# "A cada N dias": cron nativo não expressa N dias de forma confiável
# (*/N no dia-do-mês reinicia na virada). Solução: o cron dispara DIARIAMENTE
# no horário escolhido e o `run` compara last_success_utc com interval_days,
# saindo cedo (outcome=skipped-interval) quando não é o ciclo.
#
# Exit code:
#   0  sucesso (updated / already-current / skipped-interval / status / schedule)
#   2  qualquer falha — uso inválido, pré-condição não atendida, árvore suja,
#      pull rejeitado. O helper fail() de _common.sh sempre sai com 2.
#
# Referência: docs/guides/siscan-assistente-autoupdate.md
# -------------------------------------------

# shellcheck disable=SC2059
# SC2059: o padrão do projeto usa variáveis de cor ($CYAN/$NC/...) dentro do
# format string do printf (ver siscan-runner-recover.sh). Mantido por
# consistência — as variáveis são literais ANSI controladas, não input externo.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPECIALISTS_DIR="$SCRIPT_DIR/scripts/deploy_server"

# Source da biblioteca comum (cores, helpers ok/info/warn/fail, OUTPUT_MODE,
# common_parse_arg, require_commands).
# shellcheck disable=SC2034  # usado por require_commands()/fail() em _common.sh
SPECIALIST_NAME="autoupdate"
# shellcheck source=scripts/deploy_server/_common.sh
source "$SPECIALISTS_DIR/_common.sh"

# Default human; subcomandos ajustam (status --json muda via common_parse_arg).
OUTPUT_MODE="human"
_setup_colors

# ────────────────────────────────────────────────────────────────────────────
# Configuração
# ────────────────────────────────────────────────────────────────────────────
# Raiz do clone a atualizar. Honra DIR_SISCAN_ASSISTENTE (persistida pelo
# siscan-assistente.sh), com fallback para o diretório do próprio script —
# que, em produção, é a raiz do clone (${COMPOSE_DIR}).
DIR_SISCAN_ASSISTENTE="${DIR_SISCAN_ASSISTENTE:-$SCRIPT_DIR}"

# Arquivo de estado fora do repo (não suja o git pull). Caminho canônico
# persistível via SISCAN_UPDATE_STATE_FILE (mesmo padrão do DIR_SISCAN_ASSISTENTE).
_default_state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/siscan-assistente"
SISCAN_UPDATE_STATE_FILE="${SISCAN_UPDATE_STATE_FILE:-${_default_state_dir}/update-state.json}"

SCHEMA_VERSION="1.0"

# Marcadores do bloco de cron gerenciado (não alterar — usados para detecção
# idempotente e remoção cirúrgica).
CRON_BEGIN="# >>> siscan-assistente autoupdate (managed) >>>"
CRON_END="# <<< siscan-assistente autoupdate <<<"

# ────────────────────────────────────────────────────────────────────────────
# Ajuda
# ────────────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Uso: bash $(basename "$0") <subcomando> [opções]

Subcomandos:
  run                       Atualiza o clone (git pull --ff-only origin main) e
                            grava o estado. Alvo do cron.
  schedule                  Instala bloco de cron gerenciado que dispara o run.
  unschedule                Remove o bloco de cron gerenciado.
  status                    Imprime o estado da última atualização.

Opções de 'run':
  --quiet                   Fail-only no stdout (contrato de cron).

Opções de 'schedule':
  --daily                   Dispara todos os dias.
  --every-days N            Dispara a cada N dias (guarda de intervalo no run).
  --at HH:MM                Horário do disparo (24h). Sem --daily/--every-days/--at
                            o script entra em prompt interativo.

Opções de 'status':
  --json                    Imprime o estado bruto em JSON ({} se ausente).

Comuns:
  -h, --help                Esta ajuda.

Variáveis de ambiente:
  DIR_SISCAN_ASSISTENTE     Raiz do clone (default: diretório do script).
  SISCAN_UPDATE_STATE_FILE  Arquivo de estado (default:
                            \${XDG_STATE_HOME:-\$HOME/.local/state}/siscan-assistente/update-state.json).

Exit code: 0 = sucesso · 2 = falha (uso / pré-cond / árvore suja / pull rejeitado)

Referência: docs/guides/siscan-assistente-autoupdate.md
EOF
}

# ────────────────────────────────────────────────────────────────────────────
# Helpers de estado
# ────────────────────────────────────────────────────────────────────────────

# _now_utc — timestamp UTC ISO-8601 (formato do schema do estado).
_now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# _state_read_field FIELD — lê um campo escalar do estado via jq (vazio se
# ausente/arquivo inexistente). Mantém o read tolerante a estado ausente.
_state_read_field() {
    local field="$1"
    [ -f "$SISCAN_UPDATE_STATE_FILE" ] || return 0
    jq -r --arg f "$field" '.[$f] // empty' "$SISCAN_UPDATE_STATE_FILE" 2>/dev/null
}

# _state_read_schedule FIELD — lê schedule.FIELD do estado (vazio se ausente).
_state_read_schedule() {
    local field="$1"
    [ -f "$SISCAN_UPDATE_STATE_FILE" ] || return 0
    jq -r --arg f "$field" '.schedule[$f] // empty' "$SISCAN_UPDATE_STATE_FILE" 2>/dev/null
}

# _state_write — escreve o arquivo de estado atomicamente (tmp + mv).
# Recebe via variáveis os campos correntes; preserva schedule e last_success_utc
# quando o caller não os sobrescreve (lidos ANTES no run/schedule).
#
# Args (posicionais):
#   $1 outcome      $2 branch          $3 commit_before  $4 commit_after
#   $5 commit_subject  $6 commits_pulled  $7 last_attempt_utc  $8 last_success_utc
#   $9 interval_days   $10 schedule_at    $11 schedule_cron
_state_write() {
    local outcome="$1" branch="$2" commit_before="$3" commit_after="$4"
    local commit_subject="$5" commits_pulled="$6" last_attempt="$7" last_success="$8"
    local interval_days="$9" sched_at="${10}" sched_cron="${11}"

    mkdir -p "$(dirname "$SISCAN_UPDATE_STATE_FILE")"
    local tmp
    tmp="$(mktemp "${SISCAN_UPDATE_STATE_FILE}.XXXXXX")" || fail "Falha ao criar arquivo temporário do estado."

    # commits_pulled e interval_days são numéricos; demais são strings.
    # last_success_utc pode ser vazio (nunca houve sucesso) → null no JSON.
    jq -n \
        --arg schema "$SCHEMA_VERSION" \
        --arg outcome "$outcome" \
        --arg branch "$branch" \
        --arg cb "$commit_before" \
        --arg ca "$commit_after" \
        --arg cs "$commit_subject" \
        --argjson cp "${commits_pulled:-0}" \
        --arg la "$last_attempt" \
        --arg ls "$last_success" \
        --argjson idays "${interval_days:-1}" \
        --arg sat "$sched_at" \
        --arg scron "$sched_cron" \
        '{
          schema: $schema,
          outcome: $outcome,
          branch: $branch,
          commit_before: $cb,
          commit_after: $ca,
          commit_subject: $cs,
          commits_pulled: $cp,
          last_attempt_utc: (if $la == "" then null else $la end),
          last_success_utc: (if $ls == "" then null else $ls end),
          schedule: { interval_days: $idays, at: $sat, cron: $scron }
        }' > "$tmp" || { command rm -f "$tmp"; fail "Falha ao serializar o estado (jq)."; }

    mv -f "$tmp" "$SISCAN_UPDATE_STATE_FILE" || { command rm -f "$tmp"; fail "Falha ao gravar o estado."; }
}

# ────────────────────────────────────────────────────────────────────────────
# Subcomando: run
# ────────────────────────────────────────────────────────────────────────────
cmd_run() {
    require_commands git jq

    local repo="$DIR_SISCAN_ASSISTENTE"
    local now; now="$(_now_utc)"

    # Estado pré-existente: preservamos schedule + last_success na regravação.
    local prev_interval prev_at prev_cron prev_success
    prev_interval="$(_state_read_schedule interval_days)"; prev_interval="${prev_interval:-1}"
    prev_at="$(_state_read_schedule at)"
    prev_cron="$(_state_read_schedule cron)"
    prev_success="$(_state_read_field last_success_utc)"

    [ -d "$repo/.git" ] || fail "Não é um repositório git: $repo (defina DIR_SISCAN_ASSISTENTE)."

    local branch
    branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    if [ "$branch" != "main" ]; then
        _state_write "failed" "$branch" "" "" "" 0 "$now" "$prev_success" \
            "$prev_interval" "$prev_at" "$prev_cron"
        warn "Branch atual é '$branch', não 'main' — não atualizo. Estado=failed."
        fail "Branch '$branch' != main. Faça checkout de main antes de agendar a autoatualização."
    fi

    local commit_before
    commit_before="$(git -C "$repo" rev-parse --short HEAD 2>/dev/null)"

    # Guarda de árvore suja: SÓ arquivos rastreados (untracked não bloqueia).
    # Política fixada: nunca stasha/mexe no repo silenciosamente.
    if ! git -C "$repo" diff --quiet || ! git -C "$repo" diff --cached --quiet; then
        _state_write "failed" "$branch" "$commit_before" "$commit_before" "" 0 "$now" "$prev_success" \
            "$prev_interval" "$prev_at" "$prev_cron"
        warn "Árvore de trabalho suja (arquivos rastreados modificados) — não faço pull. Estado=failed."
        fail "Há modificações locais em arquivos rastreados de $repo. Reconcilie manualmente (git stash/commit/checkout) antes da autoatualização."
    fi

    # Guarda de intervalo: se interval_days > 1 e o último sucesso é recente,
    # sai cedo com skipped-interval (cron dispara diário; o run decide o ciclo).
    if [ "${prev_interval:-1}" -gt 1 ] && [ -n "$prev_success" ]; then
        local last_epoch now_epoch elapsed_days
        last_epoch="$(date -u -d "$prev_success" +%s 2>/dev/null || echo 0)"
        now_epoch="$(date -u +%s)"
        if [ "$last_epoch" -gt 0 ]; then
            elapsed_days=$(( (now_epoch - last_epoch) / 86400 ))
            if [ "$elapsed_days" -lt "$prev_interval" ]; then
                _state_write "skipped-interval" "$branch" "$commit_before" "$commit_before" "" 0 "$now" "$prev_success" \
                    "$prev_interval" "$prev_at" "$prev_cron"
                info "Fora do ciclo: ${elapsed_days}d desde o último sucesso < interval_days=${prev_interval}. Estado=skipped-interval."
                return 0
            fi
        fi
    fi

    # Pull fast-forward only — nunca faz merge nem força.
    local pull_out pull_rc
    pull_out="$(git -C "$repo" pull --ff-only origin "$branch" 2>&1)"; pull_rc=$?
    if [ "$pull_rc" -ne 0 ]; then
        _state_write "failed" "$branch" "$commit_before" "$commit_before" "" 0 "$now" "$prev_success" \
            "$prev_interval" "$prev_at" "$prev_cron"
        warn "git pull --ff-only falhou (divergência ou rede): $(printf '%s' "$pull_out" | tail -1)"
        fail "git pull --ff-only rejeitado em $repo. Histórico divergente ou rede indisponível — reconcilie manualmente."
    fi

    local commit_after commits_pulled commit_subject outcome
    commit_after="$(git -C "$repo" rev-parse --short HEAD 2>/dev/null)"
    commit_subject="$(git -C "$repo" log -1 --pretty=%s 2>/dev/null)"
    commits_pulled="$(git -C "$repo" rev-list --count "${commit_before}..${commit_after}" 2>/dev/null || echo 0)"

    if [ "$commit_before" = "$commit_after" ]; then
        outcome="already-current"
        info "Já na ponta de origin/$branch ($commit_after). Nada a atualizar."
    else
        outcome="updated"
        ok "Atualizado: $commit_before → $commit_after (${commits_pulled} commit(s)). HEAD: $commit_subject"
    fi

    _state_write "$outcome" "$branch" "$commit_before" "$commit_after" "$commit_subject" \
        "$commits_pulled" "$now" "$now" "$prev_interval" "$prev_at" "$prev_cron"
    return 0
}

# ────────────────────────────────────────────────────────────────────────────
# Subcomando: schedule / unschedule
# ────────────────────────────────────────────────────────────────────────────

# _validate_hhmm HH:MM — valida horário 24h. Retorna 0 se válido.
_validate_hhmm() {
    [[ "$1" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]
}

# _crontab_without_block — imprime o crontab atual SEM o bloco gerenciado.
# Trata "sem crontab ainda" (crontab -l falha) como vazio.
_crontab_without_block() {
    local current
    current="$(crontab -l 2>/dev/null || true)"
    [ -n "$current" ] || return 0
    printf '%s\n' "$current" | awk -v b="$CRON_BEGIN" -v e="$CRON_END" '
        $0 == b { skip=1; next }
        $0 == e { skip=0; next }
        skip != 1 { print }
    '
}

cmd_schedule() {
    require_commands crontab git jq

    # Aviso (não-bloqueante) se o daemon de cron não parece ativo.
    if command -v systemctl >/dev/null 2>&1; then
        if ! systemctl is-active --quiet cron 2>/dev/null \
           && ! systemctl is-active --quiet crond 2>/dev/null; then
            warn "Daemon de cron não parece ativo (cron/crond). O agendamento só dispara com o daemon rodando."
        fi
    fi

    local freq="" interval_days=1 at=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --daily)         freq="daily"; interval_days=1; shift ;;
            --every-days)
                if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
                    fail "--every-days requer um número de dias."
                fi
                freq="every-days"; interval_days="$2"; shift 2 ;;
            --every-days=*)  freq="every-days"; interval_days="${1#*=}"; shift ;;
            --at)            [ $# -ge 2 ] || fail "--at requer HH:MM."; at="$2"; shift 2 ;;
            --at=*)          at="${1#*=}"; shift ;;
            *)               fail "argumento desconhecido para schedule: $1" ;;
        esac
    done

    # Prompt interativo quando a frequência não foi passada (espelha o estilo
    # interativo dos demais scripts do assistente).
    if [ -z "$freq" ]; then
        printf "${CYAN}Frequência da autoatualização:${NC}\n"
        printf "  ${WHITE}1)${NC} Diária\n"
        printf "  ${WHITE}2)${NC} A cada N dias\n"
        local choice=""
        # shellcheck disable=SC2162
        read -rp "Escolha [1-2]: " choice
        case "$choice" in
            1) freq="daily"; interval_days=1 ;;
            2)
                freq="every-days"
                # shellcheck disable=SC2162
                read -rp "A cada quantos dias? (>=2): " interval_days
                ;;
            *) fail "Escolha inválida: $choice" ;;
        esac
    fi

    # Validação do intervalo.
    if [ "$freq" = "every-days" ]; then
        [[ "$interval_days" =~ ^[0-9]+$ ]] || fail "interval_days deve ser inteiro: $interval_days"
        [ "$interval_days" -ge 2 ] || fail "--every-days exige N >= 2 (use --daily para 1)."
    fi

    # Prompt do horário quando ausente.
    if [ -z "$at" ]; then
        # shellcheck disable=SC2162
        read -rp "Horário do disparo (HH:MM, 24h): " at
    fi
    _validate_hhmm "$at" || fail "Horário inválido: '$at' (use HH:MM, 24h, ex.: 03:00)."

    local hh="${at%%:*}" mm="${at##*:}"
    # Remove zero à esquerda para o cron (campo numérico, sem 08 octal).
    hh="$((10#$hh))"; mm="$((10#$mm))"
    local cron="$mm $hh * * *"

    # Linha de cron: invoca o run com --quiet (contrato de cron: fail-only).
    # Caminho absoluto do script + DIR_SISCAN_ASSISTENTE explícito (cron tem
    # ambiente mínimo, sem garantia das env vars de sessão).
    local self
    self="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
    local cron_line="$cron DIR_SISCAN_ASSISTENTE=\"$DIR_SISCAN_ASSISTENTE\" SISCAN_UPDATE_STATE_FILE=\"$SISCAN_UPDATE_STATE_FILE\" /usr/bin/env bash \"$self\" run --quiet"

    # Instala bloco gerenciado idempotente: remove o bloco antigo, anexa o novo.
    local base new_crontab
    base="$(_crontab_without_block)"
    new_crontab="$(printf '%s\n%s\n%s\n%s\n' "$base" "$CRON_BEGIN" "$cron_line" "$CRON_END")"
    # Normaliza linhas em branco no topo (quando não havia crontab).
    new_crontab="$(printf '%s\n' "$new_crontab" | sed '/^$/N;/^\n$/D')"
    printf '%s\n' "$new_crontab" | crontab - || fail "Falha ao instalar o crontab."

    # Persiste a frequência no estado (a guarda de intervalo vive no run).
    # Preserva os campos de execução existentes (não reseta last_success etc.).
    local now; now="$(_now_utc)"
    local p_outcome p_cb p_ca p_cs p_cp p_la p_ls
    p_outcome="$(_state_read_field outcome)"
    p_cb="$(_state_read_field commit_before)"
    p_ca="$(_state_read_field commit_after)"
    p_cs="$(_state_read_field commit_subject)"
    p_cp="$(_state_read_field commits_pulled)"; p_cp="${p_cp:-0}"
    p_la="$(_state_read_field last_attempt_utc)"
    p_ls="$(_state_read_field last_success_utc)"
    [ -n "$p_outcome" ] || p_outcome="scheduled"

    _state_write "$p_outcome" "main" "$p_cb" "$p_ca" "$p_cs" "$p_cp" \
        "${p_la:-$now}" "$p_ls" "$interval_days" "$at" "$cron"

    if [ "$freq" = "daily" ]; then
        ok "Agendado: diariamente às $at (cron: '$cron')."
    else
        ok "Agendado: a cada $interval_days dias às $at (cron diário '$cron' + guarda de intervalo no run)."
    fi
    info "Estado: $SISCAN_UPDATE_STATE_FILE"
    info "Inspecione com: crontab -l"
    return 0
}

cmd_unschedule() {
    require_commands crontab

    local current
    current="$(crontab -l 2>/dev/null || true)"
    if [ -z "$current" ]; then
        info "Nenhum crontab instalado — nada a remover."
        return 0
    fi
    if ! printf '%s\n' "$current" | grep -qF "$CRON_BEGIN"; then
        info "Bloco gerenciado ausente no crontab — nada a remover."
        return 0
    fi

    local base
    base="$(_crontab_without_block)"
    if [ -z "$base" ]; then
        # Crontab ficaria vazio → remove o crontab por completo.
        crontab -r 2>/dev/null || true
    else
        printf '%s\n' "$base" | crontab - || fail "Falha ao reescrever o crontab sem o bloco gerenciado."
    fi
    ok "Bloco de autoatualização removido do crontab (resto preservado)."
    return 0
}

# ────────────────────────────────────────────────────────────────────────────
# Subcomando: status
# ────────────────────────────────────────────────────────────────────────────
cmd_status() {
    require_commands jq

    if [ "$OUTPUT_MODE" = "json" ]; then
        # Fonte única para o pre-deploy. Ausente → {} (não falha).
        if [ -f "$SISCAN_UPDATE_STATE_FILE" ]; then
            jq '.' "$SISCAN_UPDATE_STATE_FILE" 2>/dev/null || echo '{}'
        else
            echo '{}'
        fi
        return 0
    fi

    # Human: resumo legível.
    if [ ! -f "$SISCAN_UPDATE_STATE_FILE" ]; then
        info "Sem estado de autoatualização registrado ($SISCAN_UPDATE_STATE_FILE)."
        info "Rode 'bash $(basename "${BASH_SOURCE[0]}") run' ou agende com 'schedule'."
        return 0
    fi

    local outcome branch ca cs cp la ls idays sat scron
    outcome="$(_state_read_field outcome)"
    branch="$(_state_read_field branch)"
    ca="$(_state_read_field commit_after)"
    cs="$(_state_read_field commit_subject)"
    cp="$(_state_read_field commits_pulled)"
    la="$(_state_read_field last_attempt_utc)"
    ls="$(_state_read_field last_success_utc)"
    idays="$(_state_read_schedule interval_days)"
    sat="$(_state_read_schedule at)"
    scron="$(_state_read_schedule cron)"

    printf "${WHITE}Estado da autoatualização do assistente${NC}\n"
    info "Arquivo:        $SISCAN_UPDATE_STATE_FILE"
    info "Resultado:      ${outcome:-—}"
    info "Branch:         ${branch:-—}"
    info "HEAD atual:     ${ca:-—}${cs:+  ($cs)}"
    info "Commits puxados:${cp:+ $cp}"
    info "Última tentativa: ${la:-—}"
    info "Último sucesso:   ${ls:-nunca}"
    if [ -n "$scron" ]; then
        if [ "${idays:-1}" -gt 1 ] 2>/dev/null; then
            info "Agendamento:    a cada ${idays} dias às ${sat} (cron '$scron')"
        else
            info "Agendamento:    diário às ${sat} (cron '$scron')"
        fi
    else
        info "Agendamento:    não agendado"
    fi
    return 0
}

# ────────────────────────────────────────────────────────────────────────────
# Dispatch de subcomando
# ────────────────────────────────────────────────────────────────────────────
main() {
    # --help/-h em qualquer posição antes do subcomando.
    if [ $# -eq 0 ]; then
        usage >&2
        exit 2
    fi

    local subcmd="$1"; shift || true
    case "$subcmd" in
        -h|--help) usage; exit 0 ;;
    esac

    # Parse de flags comuns (--quiet/--json) + coleta do resto para o subcomando.
    local rest=()
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
        esac
        if common_parse_arg "$@"; then
            # shellcheck disable=SC2154  # shift_count é setado por common_parse_arg
            shift "$shift_count"
        else
            rest+=("$1"); shift
        fi
    done

    case "$subcmd" in
        run)        cmd_run "${rest[@]:-}" ;;
        schedule)   cmd_schedule "${rest[@]:-}" ;;
        unschedule) cmd_unschedule "${rest[@]:-}" ;;
        status)     cmd_status "${rest[@]:-}" ;;
        *) printf "subcomando desconhecido: %s\n" "$subcmd" >&2; usage >&2; exit 2 ;;
    esac
}

main "$@"
