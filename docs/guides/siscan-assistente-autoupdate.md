---
title: "siscan-assistente-autoupdate.sh — Autoatualização agendada do assistente"
type: guide
status: aceita
confidencialidade: público
owner: Time DevOps SISCAN
updated: 2026-06-03
versao: "1.0"
related:
  - docs/DEPLOY_SERVER.md
  - docs/CHECKLISTS.md
  - docs/guides/siscan-assistente.md
  - docs/guides/siscan-runner-recover.md
tags:
  - assistente
  - autoupdate
  - cron
  - git-pull
  - deploy
  - servidor
tldr: |
  Guia operacional de `siscan-assistente-autoupdate.sh` — automatiza o
  `git pull --ff-only` do clone do assistente nas VMs de produção via cron
  e expõe um estado auditável da última atualização (commit, timestamp,
  resultado). Subcomandos: `run` (alvo do cron), `schedule`/`unschedule`
  (instala/remove o bloco de cron gerenciado, com prompt interativo de
  frequência) e `status` (resumo legível ou `--json` para máquina). O estado
  vive fora do repo em `${XDG_STATE_HOME:-$HOME/.local/state}/siscan-assistente/`
  e é fundido no `pre-deploy-diag.json` dos workflows CD (chave
  `assistant_update`). "A cada N dias" via guarda de intervalo no `run`
  (cron dispara diário). Feature F00.06 (issue #105).
---

# `siscan-assistente-autoupdate.sh` — Autoatualização agendada do assistente

Automatiza a atualização do clone do assistente nas VMs de produção, eliminando o `git pull` manual repetido a cada operação, e **expõe o estado da última atualização** (commit, timestamp, resultado) de forma auditável — inclusive no diagnóstico `pre-deploy` dos workflows CD de `siscan-rpa` e `siscan-dashboard`.

> **Issue de origem**: Feature F00.06 ([#105](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/issues/105)).
> **Modo coberto**: VMs de produção (modo SERVIDOR). O clone do assistente é a própria `${COMPOSE_DIR}` (tipicamente `/app/assistente-siscan-rpa`).
> **Escopo**: atualiza **somente o clone do assistente** — não reinicia containers nem faz redeploy da imagem da aplicação (isso é responsabilidade dos workflows CD).

## Motivação

- Hoje cada operação exige rodar manualmente, na VM, `cd $COMPOSE_DIR && git pull origin main` + `git log -1 --oneline` para conferir a versão. É repetitivo, depende de pessoa e não deixa registro.
- Não havia **fonte auditável** da "versão do ferramental em execução na VM" — diagnósticos e post-mortems precisavam inferir pelo comportamento.
- O `pre-deploy` dos workflows CD já coleta diagnóstico; é o ponto natural para anexar *qual versão do assistente rodou este deploy*.

## Subcomandos

| Subcomando | Propósito |
|---|---|
| `run` | Alvo do cron. `git pull --ff-only origin main` no clone + grava o estado. |
| `schedule` | Instala um bloco de cron gerenciado que dispara o `run` na frequência escolhida. |
| `unschedule` | Remove apenas o bloco de cron gerenciado, preservando o resto do crontab. |
| `status` | Imprime o estado da última atualização (resumo legível; `--json` para máquina). |

```bash
bash siscan-assistente-autoupdate.sh run [--quiet]
bash siscan-assistente-autoupdate.sh schedule [--daily | --every-days N] --at HH:MM
bash siscan-assistente-autoupdate.sh schedule          # prompt interativo
bash siscan-assistente-autoupdate.sh unschedule
bash siscan-assistente-autoupdate.sh status [--json]
```

## Pré-requisitos

| Item | Detalhe |
|---|---|
| `git` | O clone deve ser um repositório git na branch `main`. |
| `jq` | Serialização/leitura do arquivo de estado. |
| `crontab` | Necessário só para `schedule`/`unschedule`. |
| Daemon de cron | `cron`/`crond` ativo na VM — o `schedule` avisa (não bloqueia) se inativo. |

O script sourceia `scripts/deploy_server/_common.sh` (helpers `ok/info/warn/fail`, `OUTPUT_MODE`, `require_commands`, `common_parse_arg`) e segue a convenção de exit codes `0` (sucesso) / `2` (falha).

## `run` — atualização do clone

O `run` é o alvo invocado pelo cron. Sequência:

1. **Valida** que `$DIR_SISCAN_ASSISTENTE` é um repositório git na branch `main`. Caso contrário → `outcome: failed`, exit 2.
2. **Guarda de árvore suja** (decisão fixada): se houver modificação em arquivos **rastreados** → grava `outcome: failed` + `warn` e **não faz pull**. O script nunca stasha nem mexe no repo silenciosamente — preserva qualquer edição local emergencial e deixa a reconciliação para o operador. Arquivos **não-rastreados** (untracked) **não** bloqueiam o `--ff-only`.
3. **Guarda de intervalo**: se `interval_days > 1` e o último sucesso for recente, sai cedo com `outcome: skipped-interval`, exit 0 (ver ["A cada N dias"](#a-cada-n-dias)).
4. **`git pull --ff-only origin main`** — nunca faz merge nem força. Histórico divergente → `outcome: failed`, exit 2.
5. Captura `commit_before`/`commit_after`/`commits_pulled`/`commit_subject` e grava o estado **atomicamente** (`tmp` + `mv`).

Desfechos possíveis (`outcome`):

| `outcome` | Significado | Exit |
|---|---|---|
| `updated` | O clone avançou (`commit_before != commit_after`). | 0 |
| `already-current` | Já na ponta de `origin/main`, nada a puxar. | 0 |
| `skipped-interval` | Fora do ciclo de `interval_days` — não puxou. | 0 |
| `failed` | Árvore suja, branch != main, ou `--ff-only` rejeitado. Repo intacto. | 2 |

A flag `--quiet` torna o `run` compatível com cron (fail-only no stdout).

## `schedule` / `unschedule` — agendamento via cron

O `schedule` aceita a frequência por flags ou, quando ausentes, entra em **prompt interativo** (escolha diário × N-dias, depois `HH:MM` com validação 24h):

```bash
# Diariamente às 03:00
bash siscan-assistente-autoupdate.sh schedule --daily --at 03:00

# A cada 3 dias às 04:30
bash siscan-assistente-autoupdate.sh schedule --every-days 3 --at 04:30

# Interativo (pergunta frequência e horário)
bash siscan-assistente-autoupdate.sh schedule
```

O agendamento instala um **bloco gerenciado por marcadores** no crontab do usuário:

```cron
# >>> siscan-assistente autoupdate (managed) >>>
0 3 * * * DIR_SISCAN_ASSISTENTE="/app/assistente-siscan-rpa" SISCAN_UPDATE_STATE_FILE="..." /usr/bin/env bash "/app/assistente-siscan-rpa/siscan-assistente-autoupdate.sh" run --quiet
# <<< siscan-assistente autoupdate <<<
```

- **Idempotente**: re-`schedule` substitui o bloco, não duplica.
- A linha de cron exporta `DIR_SISCAN_ASSISTENTE` e `SISCAN_UPDATE_STATE_FILE` explicitamente, porque o ambiente do cron é mínimo (não herda as env vars de sessão).
- `unschedule` remove **apenas** o bloco entre os marcadores; o resto do crontab é preservado (se o bloco era a única entrada, o crontab é removido).

### "A cada N dias"

Cron nativo não expressa "N dias" de forma confiável (`*/N` no dia-do-mês reinicia na virada do mês). Por isso:

- O cron dispara **diariamente** no horário escolhido (campo de dia = `*`).
- O `run` compara `last_success_utc` com `interval_days` (gravado no estado pelo `schedule`) e sai cedo com `skipped-interval` quando ainda não é o ciclo.

Assim "a cada 3 dias" é exato e independente da virada de mês.

## `status` — estado auditável

```bash
# Resumo legível (operador)
bash siscan-assistente-autoupdate.sh status

# JSON bruto (fonte do pre-deploy; {} quando o estado ainda não existe)
bash siscan-assistente-autoupdate.sh status --json
```

O `status --json` é a **fonte única** consumida pelo step de `pre-deploy` dos workflows CD, que funde o estado no `pre-deploy-diag.json` sob a chave `assistant_update`:

```yaml
- name: Anexar estado de autoatualização do assistente
  run: |
    set -euo pipefail
    : "${COMPOSE_DIR:?COMPOSE_DIR não definido — re-execute Fase 8 do siscan-server-setup.sh}"
    cd "${COMPOSE_DIR}"
    bash siscan-assistente-autoupdate.sh status --json > assistant-update.json || echo '{}' > assistant-update.json
    # Anexação não-bloqueante (diagnóstico): normaliza pre-deploy-diag não-objeto
    # para {} e preserva o original em qualquer falha residual do jq.
    if jq -s 'if (.[0]|type)=="object" then .[0] else {} end + {assistant_update: .[1]}' \
          pre-deploy-diag.json assistant-update.json > merged.json; then
      mv merged.json pre-deploy-diag.json
    else
      rm -f merged.json
      echo "Aviso: merge do estado de autoatualização falhou — mantendo pre-deploy-diag.json original."
    fi
```

Esse step já está no template `docs/guides/workflows/templates/cd_imagem_certificada_selfhosted.template.yml`; a adoção nos consumers (`siscan-rpa`, `siscan-dashboard`) é propagada automaticamente pelo template.

## Arquivo de estado

O estado vive **fora do repo** (não suja o `git pull`):

```
${SISCAN_UPDATE_STATE_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/siscan-assistente/update-state.json}
```

Esquema (versão `1.0`):

```json
{
  "schema": "1.0",
  "outcome": "updated",
  "branch": "main",
  "commit_before": "54c180d",
  "commit_after": "0ddd453",
  "commit_subject": "...",
  "commits_pulled": 3,
  "last_attempt_utc": "2026-06-03T07:30:00Z",
  "last_success_utc": "2026-06-03T07:30:00Z",
  "schedule": { "interval_days": 1, "at": "03:00", "cron": "0 3 * * *" }
}
```

Todos os timestamps são UTC ISO-8601 (`date -u +%Y-%m-%dT%H:%M:%SZ`). O arquivo é gravado atomicamente (`tmp` + `mv`). Apenas campos **sem PII** entram nele (SHAs, timestamps, `outcome`, `schedule`) — sem hostname/IP/nomes.

## Troubleshooting

| Sintoma | Causa provável | Resolução |
|---|---|---|
| `outcome: failed` + "Árvore de trabalho suja" | Arquivos **rastreados** modificados localmente. | Reconcilie manualmente: `git -C $DIR_SISCAN_ASSISTENTE status`, depois `git stash` / `git checkout -- <arquivo>` / `git commit`. O script nunca descarta alterações por conta própria. |
| `outcome: failed` + "Árvore de trabalho suja" **logo após um deploy** | O job de `deploy` dos workflows CD copia `docker-compose`/`.env sample` **para dentro do `${COMPOSE_DIR}`** — o mesmo clone que o `run` atualiza. Se esses arquivos forem rastreados e o conteúdo copiado divergir do `HEAD`, a árvore fica suja e o `run` grava `failed` até a reconciliação. O `flock` protege apenas `run`×`run`, **não** `run`×`deploy`. | Verifique `git -C $COMPOSE_DIR status` — se os únicos arquivos sujos forem os copiados pelo CD (compose/env-sample), restaure-os (`git checkout -- <arquivo>`) ou comite-os; o `run` volta a puxar no próximo ciclo. Falha **segura** (não puxa durante a janela de deploy), mas pode mascarar-se de "autoupdate quebrado". |
| `outcome: failed` + "git pull --ff-only rejeitado" | Histórico divergente (commit local fora de `origin/main`) ou rede indisponível. | Verifique conectividade e `git -C $DIR_SISCAN_ASSISTENTE log --oneline origin/main..HEAD`. Resolva a divergência antes de reagendar. |
| `outcome: failed` + "Branch '...' != main" | O clone não está em `main`. | `git -C $DIR_SISCAN_ASSISTENTE checkout main`. |
| `outcome: skipped-interval` toda execução | `interval_days > 1` e ainda não passou o ciclo. | Esperado. Para forçar agora, rode `run` após zerar/ajustar o intervalo via novo `schedule --daily`. |
| `schedule` avisa "Daemon de cron não parece ativo" | `cron`/`crond` parado na VM. | Inicie o daemon (`sudo systemctl enable --now cron`). O bloco já foi instalado; só não dispara sem o daemon. |
| `status --json` retorna `{}` | Estado ainda não existe (nenhum `run` rodou). | Esperado em VM recém-provisionada — o `pre-deploy` trata `{}` como ausência. |

## Veja também

- [`siscan-assistente.md`](./siscan-assistente.md) — assistente interativo (modo HOST), que também oferece autoatualização do próprio assistente.
- [`../DEPLOY_SERVER.md`](../DEPLOY_SERVER.md) — operação das VMs de produção e atualização do assistente.
- [`../CHECKLISTS.md`](../CHECKLISTS.md) — checklist operacional.
- [`siscan-runner-recover.md`](./siscan-runner-recover.md) — recuperação do self-hosted runner.
