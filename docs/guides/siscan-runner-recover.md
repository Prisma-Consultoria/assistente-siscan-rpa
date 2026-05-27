---
title: "siscan-runner-recover.sh — Recuperação cirúrgica do runner"
type: guide
status: aceita
confidencialidade: interno
owner: Time DevOps SISCAN
updated: 2026-05-26
versao: "2.1"
related:
  - docs/DEPLOY_SERVER.md
  - docs/TROUBLESHOOTING.md
  - docs/CHECKLISTS.md
  - docs/guides/siscan-server-doctor/specialists/check-network.md
tags:
  - runner
  - github-actions
  - self-hosted
  - troubleshooting
  - deploy
tldr: |
  Guia operacional de `siscan-runner-recover.sh` — script que recupera o
  GitHub Actions self-hosted runner em **9 cenários auto-resolvíveis**
  (OK, N/A, 1, 2, C, A, A2, B, WARN) + 1 inconclusivo (UNKNOWN). Cobre
  desde "bootstrap do zero em VM nova" até "runner auto-removido após 14d
  offline" e "regra dos 30 dias de auto-update". Compartilha o módulo
  `scripts/deploy_server/_runner.sh` com `siscan-server-setup.sh`.
  Documenta como gerar PAT classic, diferença entre `--token` (registro)
  e `--pat` (run.sh --check), e os 4 bugs corrigidos em #53.
---

# `siscan-runner-recover.sh` — Recuperação cirúrgica do runner

Recupera o GitHub Actions self-hosted runner em **9 cenários auto-resolvíveis** (OK, N/A, 1, 2, C, A, A2, B, WARN) + 1 inconclusivo (UNKNOWN, que orienta passos manuais). A lógica de download/registro/instalação é compartilhada com `siscan-server-setup.sh` via o módulo `scripts/deploy_server/_runner.sh` (issue [#51](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/issues/51)).

Histórico de cenários cobertos:
- **A e B** descobertos no servidor parceiro (incidente 15/04 → 25/05/2026, issue [#31](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/issues/31)).
- **C, N/A, 1, 2** + flag `--token` adicionados em [#51](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/issues/51).
- **4 bugs** corrigidos em [#53](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/issues/53) — observados na <HOST-DASHBOARD> em 26/05/2026.

## Pré-requisitos

- **`bash`** ≥ 4 + **`jq`** + **`curl`** instalados (já vêm garantidos pelo `siscan-server-setup.sh`).
- **`sudo`** configurado para o usuário corrente — necessário em `svc.sh install/stop/start/uninstall` e em `sudo -u $USER run.sh --check`.
- **`~/actions-runner/`** existindo (para os cenários OK, C, A, A2, B, WARN) **ou** ausente (cenário N/A — script faz bootstrap completo).
- **Manifesto** `scripts/data/products.json` legível — fonte de `repo`, `runner_label`, `runner_name_suffix`.
- **`.env`** com `SISCAN_PRODUCT=<rpa|dashboard|full>` em `$COMPOSE_DIR/.env` (ou explicitar via `--product`).
- **Conectividade** com `github.com`, `objects.githubusercontent.com` e `api.github.com` (validada pelo pré-flight do doctor).
- **Token de registro** (cenários N/A, 1, 2, A, A2): gerado em Settings → Actions → Runners → New self-hosted runner (expira em ~5 min).
- **PAT classic com scope `repo`** (cenários B, WARN): para `run.sh --check`. Pode vir de `--pat`, `$GH_TOKEN`, `gh auth token` ou prompt interativo.

## Invocações suportadas

Catálogo de formas sintáticas aceitas pelo script. Para a sequência operacional onde cada invocação é usada, ver [`../DEPLOY_SERVER.md`](../DEPLOY_SERVER.md).

```bash
# Sem flags → infere produto do $COMPOSE_DIR/.env (SISCAN_PRODUCT)
bash siscan-runner-recover.sh

# Produto explícito
bash siscan-runner-recover.sh --product rpa
bash siscan-runner-recover.sh --product dashboard
bash siscan-runner-recover.sh --product full

# .env em outro caminho
bash siscan-runner-recover.sh --env-file /path/to/.env

# Pular pré-flight do doctor
bash siscan-runner-recover.sh --skip-doctor

# Token de registro via CLI (cenários N/A, 1, 2, A, A2)
bash siscan-runner-recover.sh --token ghr_xxx

# PAT classic via CLI (cenários B, WARN)
bash siscan-runner-recover.sh --pat ghp_xxx

# Diretório do runner customizado
bash siscan-runner-recover.sh --runner-dir /opt/actions-runner

# Combinações
bash siscan-runner-recover.sh --product rpa --token ghr_xxx
bash siscan-runner-recover.sh --env-file /path/to/.env --skip-doctor
bash siscan-runner-recover.sh --product full --runner-dir /opt/actions-runner --pat ghp_xxx

# Ajuda
bash siscan-runner-recover.sh -h
bash siscan-runner-recover.sh --help
```

## Flags

| Flag | Valor | Default | Quando usar |
|---|---|---|---|
| `--product` | `rpa\|dashboard\|full` | inferido do `.env` | Sem `.env` ou para sobrescrever |
| `--env-file` | caminho do arquivo | `$COMPOSE_DIR/.env` (ou `$PWD/.env`) | `.env` está em outro caminho |
| `--runner-dir` | caminho do diretório | `${HOME}/actions-runner` | Instalação custom |
| `--skip-doctor` | flag | `false` | Debug — pula pré-flight |
| `--token` | string opaca | (prompt) | Automação; força A2 defensivo |
| `--pat` | string opaca | `$GH_TOKEN` → `gh auth token` → prompt | Automação dos ramos B/WARN |
| `-h`, `--help` | flag | — | Ajuda inline |

### Resolução de `ENV_FILE`

A ordem é determinística:

1. `--env-file VALOR` explícito vence sempre.
2. Senão, `$COMPOSE_DIR/.env`.
3. Senão (se `COMPOSE_DIR` não exportada), `$PWD/.env`.

Quando `--product` é omitido, o script lê `SISCAN_PRODUCT` do `ENV_FILE` efetivo via `grep -E "^SISCAN_PRODUCT=" | tail -1 | cut | sed`. **NÃO usa `source .env` nem `eval`** — proteção contra command injection em valores com chars especiais.

## Cenários detectados

Matriz completa — 10 estados possíveis após o diagnóstico:

| Cenário | Trigger | Token? | PAT? | Re-registra? | Instala systemd? | Exit |
|---|---|---|---|---|---|---|
| **OK** | tudo online + idade <25d | não | não | não | não | 0 |
| **N/A** | `~/actions-runner/` não existe | **sim** | não | sim (bootstrap) | sim | 0 |
| **1** | dir existe mas binários ausentes | **sim** | não | sim (bootstrap incremental) | sim | 0 |
| **2** | binários OK, `.runner` ausente | **sim** | não | sim | sim | 0 |
| **C** | `.runner` OK, systemd unit ausente | não | não | não | sim (cirúrgico) | 0 |
| **A** | API `total_count=0` (auto-removed >14d) | **sim** | não | sim (uninstall + remove + register) | sim | 0 |
| **A2** | API: runner `offline` ou nome mismatch | **sim** | não | sim (idem A) | sim | 0 |
| **B** | idade ≥30d | não | **sim** | não | não (só `run.sh --check` + start) | 0 |
| **WARN** | idade 25-29d | não | **sim** | não | preventivo (idem B) | 0 |
| **UNKNOWN** | sem gh/`GH_TOKEN`/`--token` + estado inconclusivo | — | — | — | — (orienta) | 1 |

### Tabela de precedência

`runner_diagnose` (em `scripts/deploy_server/_runner.sh`) cruza estado local + remoto nesta ordem:

| Estado local | Estado remoto | Idade | Cenário | Ação |
|---|---|---|---|---|
| dir ausente | — | — | **N/A** | Bootstrap completo (pede token) |
| dir OK, binários ausentes | — | — | **1** | Bootstrap incremental (pede token) |
| binários OK, `.runner` ausente | — | — | **2** | Register + install + start (pede token) |
| binários + `.runner` OK, systemd ausente | `total_count: 0` | — | **A2** | Re-registro defensivo (refinado em [#65](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/issues/65) — pede token) |
| binários + `.runner` OK, systemd ausente | `total_count > 0` | — | **C** | Install + start (sem token) |
| binários + `.runner` OK, systemd ausente | API indisponível, `--token` setado | — | **A2** (defensivo) | Idem A |
| binários + `.runner` OK, systemd ausente | API indisponível, sem `--token` | — | **C** | Install + start (sem token; pressuposto otimista) |
| tudo local OK | `total_count: 0` | qualquer | **A** | Uninstall + remove + re-register + install + start |
| tudo local OK | runner offline ou nome mismatch | qualquer | **A2** | Idem A |
| tudo local OK | runner online | ≥30d | **B** | `run.sh --check` + start |
| tudo local OK | runner online | 25-29d | **WARN** | Idem B (preventivo) |
| tudo local OK | runner online | <25d | **OK** | Nada — exit 0 |
| tudo local OK | API indisponível | qualquer, `--token` setado | **A2** (defensivo) | Idem A |
| tudo local OK | API indisponível | ≥30d, sem `--token` | **B** | Idem B |
| tudo local OK | API indisponível | 25-29d, sem `--token` | **WARN** | Idem B |
| tudo local OK | API indisponível | <25d, sem `--token` | **UNKNOWN** | Orienta `--token` ou `gh` |

> **Fix #53/Bug 1**: antes, a faixa de idade vencia o `--token`. Agora `--token` tem **precedência absoluta** sobre idade quando a API não está consultável — assume que o operador desconfia de auto-removal e quer re-registrar.

### Cenário OK

**Quando aparece**: runner instalado, registrado, systemd unit ativo, `.runner_migrated` (ou `_diag/` ou `.runner`) com mtime <25 dias, API GitHub reporta `online`.

**Saída esperada**:
```
1/6 — Detecção do produto e validação do manifesto      → ok
2/6 — Inspeção da instalação local                       → ok (Instalação local completa)
3/6 — Pré-flight via doctor                              → ok
4/6 — Diagnóstico do estado do runner
        ✔  Runner saudável (online, X d desde último update) — nada a fazer.
exit 0
```

### Cenário N/A — bootstrap completo (novo em #51)

**Quando aparece**: VM nova, ou após `rm -rf ~/actions-runner`. Antes de #51, o script abortava — agora faz bootstrap completo.

**Ações** (em ordem):
1. `runner_download_binaries` → detecta arquitetura, baixa tarball, extrai
2. `prompt_token_if_needed` → usa `--token` ou prompt
3. `runner_register` → `config.sh --url $REPO --token $TOKEN --name $EXPECTED_NAME --labels $LABEL --unattended --replace`
4. `runner_install_service` → `sudo svc.sh install $USER`
5. `runner_start_service` → `sudo svc.sh start`

**Como reproduzir**:
```bash
mv ~/actions-runner ~/actions-runner.bak
bash siscan-runner-recover.sh --token <novo>
```

### Cenário 1 — binários ausentes (novo em #51)

**Quando aparece**: diretório `~/actions-runner/` existe mas `config.sh` ou `svc.sh` ausentes — estado raro (limpeza parcial manual).

**Ações**: idem N/A (download + register + install + start).

### Cenário 2 — `.runner` ausente (novo em #51)

**Quando aparece**: binários presentes, mas `.runner` (arquivo de registro) ausente.

**Ações**:
1. `prompt_token_if_needed`
2. `runner_register`
3. `runner_install_service`
4. `runner_start_service`

### Cenário C — systemd unit ausente, runner ainda registrado remotamente (novo em #51, refinado em #65)

**Quando aparece**: `.runner` presente, `config.sh`/`svc.sh` presentes, `systemctl list-unit-files 'actions.runner.*.service'` retorna vazio E:

- **Caso 1 — API confirma**: `gh api .../actions/runners` retorna `total_count > 0` (runner ainda existe no GitHub).
- **Caso 2 — API indisponível**: sem `gh`/`GH_TOKEN`/`PAT`, **e** sem `--token` passado pela operadora. O recover assume otimismo (caminho cirúrgico local).

> **Refinamento #65**: antes, qualquer estado 3 (sem systemd) caía em Cenário C, mesmo com runner já auto-removido remotamente. Resultado: o serviço subia local com `.runner` órfão e ficava em loop 401. A partir de #65 (PR #67), o diagnóstico consulta a API em estado 3. Se `total_count: 0`, redireciona para **A2** (re-registro defensivo). Se a API responde com `total_count > 0` (ou é inconsultável **sem** `--token`), mantém Cenário C original.

**Ações** (sem token):
1. `runner_install_service` → `sudo svc.sh install $USER`
2. `runner_start_service` → `sudo svc.sh start`

**Como reproduzir**:
```bash
# Pressuposto: runner registrado no GitHub recentemente (não auto-removido)
sudo ~/actions-runner/svc.sh stop
sudo ~/actions-runner/svc.sh uninstall
bash siscan-runner-recover.sh
```

**Saída esperada** (recorte da Fase 4):
```
4/6 — Diagnóstico do estado do runner
        →  Cenário C: systemd unit ausente, .runner aceito (API confirmou registro remoto ou API indisponível) — install + start (sem token)
```

**Quando estado 3 NÃO cai em C** (refinamento #65):
- Estado 3 + `gh api → total_count: 0` → **Cenário A2** (re-registro defensivo, exige `--token`).
- Estado 3 + API indisponível + `--token` fornecido → **Cenário A2** (heurística defensiva — operadora sinaliza desconfiança de auto-removal).

### Cenário A — Auto-removal após 14 dias offline

**Quando aparece**: GitHub remove runners offline há >14 dias. Diagnóstico:
```
gh api repos/<owner>/<repo>/actions/runners → total_count: 0
```

**Pré-requisito**: `gh` autenticado **ou** `GH_TOKEN` exportado (sem isso, cai em UNKNOWN).

**Ações** (em ordem, todas em `~/actions-runner/`):

| # | Comando | Idempotente? | Sudo? |
|---|---|---|---|
| 1 | `./svc.sh stop` | sim — `warn` se já parado | sim |
| 2 | `./svc.sh uninstall` | sim — `warn` se já desinstalado | sim |
| 3 | `runner_remove_registration` — estratégia em 3 camadas (ver detalhes abaixo) | sim — sempre encerra com `.runner` ausente | não |
| 4 | `./config.sh --url $REPO --token $TOKEN --name $EXPECTED_NAME --labels $RUNNER_LABEL --unattended --replace` | sim — `--replace` sobrescreve | não |
| 5 | `./svc.sh install $CURRENT_USER` | recria | sim |
| 6 | `./svc.sh start` | recria | sim |

> **Detalhe do passo 3 — `runner_remove_registration`** (corrigido na [issue #63](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/issues/63)):
>
> 1. **Camada 1 — atalho remoto**: consulta `gh api repos/<owner>/<repo>/actions/runners`. Se `total_count == 0`, o runner já não existe no GitHub (auto-removal); o `config.sh remove` é pulado.
> 2. **Camada 2 — remove-token via API**: se o runner ainda existe remotamente e há credencial disponível (`gh` autenticado ou `GH_TOKEN`/`PAT`), o script obtém um **remove-token dedicado** via `POST /actions/runners/remove-token` (endpoint distinto do registration-token) e usa-o em `./config.sh remove --token <remove-token>`.
> 3. **Camada 3 — limpeza local determinística**: sempre executa `rm -f .runner .credentials .credentials_rsaparams` ao final. Garante que o `.runner` nunca fica órfão (sintoma do bug original: *"Cannot configure the runner because it is already configured"* na etapa 4 seguinte, com `--replace` ignorado).
>
> Antes do fix, o passo 3 usava o registration-token em `config.sh remove` (endpoint errado), a remoção falhava em silêncio, e o passo 4 abortava — cenário A/A2 nunca destravava automaticamente.

**Estado da VM após sucesso**:
- `~/actions-runner/.runner` regenerado com `id` novo e timestamp atual.
- `~/actions-runner/.credentials*` regenerado.
- `/etc/systemd/system/actions.runner.<owner>-<repo>.<host>-<suffix>.service` instalado.
- `systemctl is-active actions.runner.*`: `active (running)`.

**Saída esperada**:
```
4/6 — Diagnóstico do estado do runner
        →  Cenário A (auto-removal): total_count=0 na API — re-registro completo
5/6 — Execução do recovery
        Token de registro requerido — expira em poucos minutos; gere agora.
        URL: https://github.com/Prisma-Consultoria/siscan-dashboard/settings/actions/runners/new
        Token: ****
        →  Parando serviço do runner...                  → svc.sh stop
        →  Desinstalando serviço systemd...              → svc.sh uninstall
        →  Removendo registro do runner...               → Registro local removido (.runner + .credentials*)
        →  Registrando runner (name=..., label=...)...   → Runner registrado
        →  Instalando runner como serviço systemd...     → svc.sh install
        →  Iniciando serviço do runner...                → svc.sh start
6/6 — Validação pós-recovery                              → ok
exit 0
```

### Cenário A' / A2 — Offline na API ou nome mismatch

**Quando aparece**: API retorna `total_count > 0`, mas:
- (a) o runner com nome esperado (`<hostname>-<suffix>`) **não está** na lista, OU
- (b) está, mas com `status: "offline"` (heartbeats parados — serviço parado há dias).

**Pré-requisito**: `gh` autenticado **ou** `GH_TOKEN` exportado.

**Ação**: idêntica ao A.

**Variante defensiva** (A2 sem API): quando `--token` é fornecido mas a API não é consultável (sem gh/`GH_TOKEN`), o script força A2 — assume que o operador desconfia de auto-removal.

**Como reproduzir**:
```bash
sudo ~/actions-runner/svc.sh stop
# Aguardar ~2-3 min para o GitHub registrar como offline
bash siscan-runner-recover.sh --token <novo>   # com gh ou GH_TOKEN setado
```

### Cenário B — Regra dos 30 dias de auto-update

**Quando aparece**: runner online + serviço ativo, mas GitHub recusa jobs porque o runner ficou >30 dias sem atualizar sua versão.

[GitHub docs](https://docs.github.com/en/actions/reference/runners/self-hosted-runners#runner-software-updates-on-self-hosted-runners):

> "If you do not perform a software update within 30 days, the GitHub Actions service will not queue jobs to your runner."

**Ações** (não pede token — pede PAT):

| # | Comando | Idempotente? | Sudo? |
|---|---|---|---|
| 1 | `./svc.sh stop` | sim — `warn` se já parado | sim |
| 2 | `sudo -u $CURRENT_USER ./run.sh --check --url $REPO_URL --pat $PAT` | repetível; noop em runner já atualizado | sim (para `sudo -u`) |
| 3 | `./svc.sh start` | recria | sim |

**Estado da VM após sucesso**:
- `~/actions-runner/bin/` com binários atualizados.
- `~/actions-runner/.runner_migrated` com mtime renovado (próxima janela de 30d resetada).
- `.runner` + `.credentials*` intactos.

**Fix #53/Bug 2 (parser FAIL)**: `run.sh --check` retorna exit 0 mesmo com falhas internas. O script agora captura o output e procura `F A I L` no texto — se encontrar, aborta com mensagem orientativa.

**Fix #53/Bug 3 (flags --url/--pat)**: antes, `run.sh --check` era chamado sem `--url`/`--pat` e caía em prompt interativo bloqueando o fluxo automatizado.

**Como reproduzir**:
```bash
sudo touch -d "35 days ago" ~/actions-runner/.runner_migrated
bash siscan-runner-recover.sh --pat ghp_xxx
```

### Cenário WARN — Faixa de aviso (25-29d)

**Quando aparece**: idade entre 25 e 29 dias. Ainda não disparou a regra dos 30d, mas o recover age preventivamente.

**Ações**: idênticas ao B (stop + `run.sh --check --url --pat` + start). Pede PAT.

### Cenário UNKNOWN

**Quando aparece**: nenhum cenário acima foi detectado. Tipicamente:
- API GitHub não consultável (sem `gh`/`GH_TOKEN`/`--token`).
- Idade local <25d (não dispara B nem WARN).
- Estado local 4 (tudo presente — não dispara N/A, 1, 2, C).

**Saída esperada**:
```
4/6 — Diagnóstico do estado do runner
        ⚠  API GitHub indisponível (sem gh/GH_TOKEN/--token) e idade local
            insuficiente pra disparar B/WARN.
5/6 — Execução do recovery
        ✘ Cenário desconhecido — nada a fazer automaticamente.
          Rode 'bash siscan-server-doctor.sh --only check-runner' para diagnóstico detalhado,
          ou 'bash siscan-server-setup.sh --product ...' para re-instalação completa.
          Alternativa: forneça --token <novo> para forçar fluxo A2 defensivo.
exit 1
```

## Tokens

São **dois tokens diferentes** — fornecer um no lugar do outro vai falhar com mensagens enganosas.

| Aspecto | `--token` (registro) | `--pat` (Personal Access Token) |
|---|---|---|
| **Cenários** | N/A, 1, 2, A, A2 | B, WARN |
| **Prefixo típico** | `ghr_` | `ghp_` |
| **Geração** | Settings → Actions → Runners → New self-hosted runner | Settings → Developer settings → Personal access tokens → Tokens classic |
| **Escopo** | Vinculado ao repo + uso único pelo `config.sh` | Conta-wide; scope `repo` necessário |
| **Validade** | ~5 minutos | configurável (horas/dias/meses/sem-expiração) |
| **Uso interno** | `config.sh --token $TOKEN` | `run.sh --check --pat $PAT` |
| **Onde obter** | `https://github.com/<owner>/<repo>/settings/actions/runners/new` | `https://github.com/settings/tokens` |

### Token de registro (`--token`) — para cenários N/A, 1, 2, A, A2

**Como gerar**:
1. Acessar `https://github.com/<owner>/<repo>/settings/actions/runners/new` no navegador.
2. Selecionar Linux + arquitetura correta.
3. Copiar o token do bloco `./config.sh --url ... --token ghr_xxx`.
4. Passar para o recover via `--token ghr_xxx` (CLI) ou colar no prompt interativo.

> Tokens de registro **expiram em ~5 minutos** e são **uso único**. Gere imediatamente antes de rodar o script.

### PAT (`--pat`) — para cenários B, WARN

PAT classic com scope `repo` é necessário para `run.sh --check` autenticar com a API.

#### Como gerar PAT classic — 9 passos

1. Acessar `https://github.com/settings/tokens` (ou Account menu → Settings → Developer settings → Personal access tokens → Tokens (classic)).
2. Clicar em **Generate new token (classic)**.
3. (Se solicitado) confirmar senha do GitHub.
4. **Note**: descrição livre, ex.: `siscan-runner-recover · <HOST-DASHBOARD>`.
5. **Expiration**: escolher janela (recomenda-se 90 dias para reduzir rotação; ou No expiration se for usado por automação em VM dedicada com proteção adequada).
6. **Select scopes**: marcar apenas **`repo`** (acesso ao repositório — suficiente para `run.sh --check`).
7. Clicar em **Generate token** no fim da página.
8. **Copiar o token imediatamente** — o GitHub não mostra de novo após esta tela.
9. Armazenar no cofre da equipe (1Password, Bitwarden, etc.) e fornecer ao recover via `--pat ghp_xxx`, exportar `GH_TOKEN=ghp_xxx`, ou rodar `gh auth login` na VM (recomendado).

#### Modos de fornecer o PAT — precedência

| # | Mecanismo | Quando usar |
|---|---|---|
| 1 | `--pat ghp_xxx` na CLI | Automação ad-hoc; debug local |
| 2 | `export GH_TOKEN=ghp_xxx` no ambiente | CI/CD; sessão de troubleshooting longa |
| 3 | `gh auth token` (se `gh` CLI autenticado) | **Recomendado em produção** |
| 4 | Prompt interativo `read -srp "PAT: "` | Operação manual sem automação |

#### Recomendação operacional: instalar `gh` CLI na VM

Para evitar rotação manual de PAT em cada execução:

```bash
# Ubuntu/Debian
sudo apt update
sudo apt install gh

# Autenticação via device flow (uma vez)
gh auth login
# → escolher GitHub.com → HTTPS → autenticar via navegador (device code)

# Validar
gh auth status
```

Após isso, o recover obterá o PAT automaticamente via `gh auth token` em todas as execuções — sem precisar de `--pat` nem `$GH_TOKEN`.

## Funcionamento técnico

### Diagnóstico (`runner_diagnose`)

Implementado em `scripts/deploy_server/_runner.sh:159`. Combina estado local e remoto em 4 passos:

1. **Estado local** (`runner_get_state`) — verifica presença de diretório, binários, `.runner` e systemd unit. Retorna `N/A|1|2|3|4`.
2. **Idade do runner** (`runner_local_age_days`) — mtime de `.runner_migrated` (preferência), `_diag/Runner_*.log`, ou `.runner`. Default 999 se nenhum existir.
3. **Estado remoto** (`runner_query_api`) — `gh api repos/<owner>/<repo>/actions/runners` ou `curl` com `$GH_TOKEN`. Vazio se não conseguir consultar.
4. **Decisão** — cruza local + remoto + idade + `has_token_arg` para emitir um dos 10 cenários.

### Pré-flight via doctor

Antes de tocar no runner, invoca:
```bash
bash siscan-server-doctor.sh --quiet \
    --only check-network,check-deps,check-docker,check-permissions
```

Por que esses 4 e não `check-runner`? `check-runner` é o que vamos consertar — não faz sentido falhar nele antes de tentar. Mas se a rede está fora, o daemon caiu, ou as permissões mudaram, o recovery vai falhar do mesmo jeito — vale abortar cedo (exit 2).

Use `--skip-doctor` para pular o pré-flight em cenários de debug.

### Ações por cenário (o que o script faz na VM)

**Variáveis resolvidas internamente**:
- `$TOKEN` — pedido interativamente (ou via `--token`)
- `$REPO_URL` — `https://github.com/<owner>/<repo>` derivado de `products.json[<product>].repo`
- `$EXPECTED_NAME` — `<hostname>-<runner_name_suffix>`
- `$RUNNER_LABEL` — `products.json[<product>].runner_label`
- `$CURRENT_USER` — saída de `whoami`
- `$PAT` — resolvido via `--pat` > `$GH_TOKEN` > `gh auth token` > prompt

> **Não é um runbook copy/paste** — mostradas aqui para você entender o blast radius antes de rodar — especialmente porque os cenários A/A2 consomem um token de admin que expira em ~5 min.

### Reuso com `siscan-server-setup.sh`

A Fase 7 do setup e o recover compartilham as **mesmas funções** do módulo `scripts/deploy_server/_runner.sh`:

```
runner_get_state          → echo N/A|1|2|3|4
runner_diagnose           → echo OK|N/A|1|2|C|A|A2|B|WARN|UNKNOWN
runner_local_age_days     → idade em dias (999 = indet.)
runner_query_api          → JSON da API ou vazio
runner_download_binaries  → baixa tarball (estado 1→2)
runner_register           → config.sh --token (estado 2→3)
runner_install_service    → svc.sh install (estado 3→4)
runner_start_service      → svc.sh start
runner_stop_service       → svc.sh stop (idempotente)
runner_uninstall_service  → svc.sh uninstall (idempotente)
runner_remove_registration → config.sh remove (idempotente)
```

Bugs ou melhorias na lógica de runner se propagam automaticamente para ambos os scripts.

## Configuração

### Manifesto: `products.json`

O script lê de `scripts/data/products.json`:

| Chave | Uso |
|---|---|
| `products[<product>].repo` | `owner/name` → `https://github.com/owner/name` (`config.sh --url`) |
| `products[<product>].runner_name_suffix` | `<hostname>-<suffix>` (nome esperado do runner) |
| `products[<product>].runner_label` | `config.sh --labels` |

Adicionar um produto novo é só editar o manifesto — o recover descobre automaticamente.

### Detecção de `SISCAN_PRODUCT` a partir do `.env`

Quando você roda sem `--product`, o script tenta inferir o produto do `.env` da VM. **Não há "magia": é grep simples sobre arquivo de dados.**

```bash
# Pipeline em uma linha (copy-paste seguro)
# 1. grep   → linhas começando com 'SISCAN_PRODUCT='
# 2. tail   → última atribuição vence (override permitido)
# 3. cut    → pega tudo após o primeiro '='
# 4. sed    → remove aspas envolventes
_read_env_var() {
    grep -E "^SISCAN_PRODUCT=" "$ENV_FILE" 2>/dev/null \
        | tail -1 | cut -d= -f2- | sed 's/^["'\'']\(.*\)["'\'']$/\1/'
}
```

Características:
- **Lê como dados, não como código** — NÃO usa `source .env` nem `eval`. Proteção contra command injection.
- **Última atribuição vence** (`tail -1`) — consistente com `docker compose`.
- **Aspas envolventes são strippadas** — aceita `SISCAN_PRODUCT=rpa`, `="rpa"` ou `='rpa'`.

**Pré-requisitos para detecção via `.env`**:

1. `ENV_FILE` aponta para um caminho legível.
2. O arquivo existe e é legível pelo usuário corrente.
3. Tem uma linha `SISCAN_PRODUCT=<rpa|dashboard|full>`.

Se qualquer um dos 3 falhar, o script aborta com `ERRO: SISCAN_PRODUCT não definido. Use --product rpa|dashboard|full ou preencha .env.`

### Variáveis de ambiente reconhecidas

| Variável | Default | Uso |
|---|---|---|
| `RUNNER_DIR` | `${HOME}/actions-runner` | Diretório do runner (override via `--runner-dir`) |
| `COMPOSE_DIR` | `$(pwd)` | Base para `ENV_FILE` |
| `GH_TOKEN` | (vazio) | API GitHub + fallback de PAT (cenários B/WARN) |
| `HOME` | (system) | Pista para `RUNNER_DIR` default |

## Solução de problemas

Sintomas observáveis ao usar este utilitário estão catalogados em [`../TROUBLESHOOTING.md`](../TROUBLESHOOTING.md) com diagnóstico passo-a-passo e ação corretiva. Cada problema referencia o specialist do doctor que cobre a verificação automatizada. Para sequência operacional do deploy completo, ver [`../DEPLOY_SERVER.md`](../DEPLOY_SERVER.md).

## Exit codes

| Code | Significado |
|---|---|
| `0` | Runner saudável (nada a fazer) **OU** recovery bem-sucedido |
| `1` | Falha em alguma etapa do recovery (token inválido, svc.sh falhou, FAIL em `run.sh --check`, cenário UNKNOWN, etc.) |
| `2` | Pré-condição não atendida: produto indefinido, doctor reportou problemas em outras dimensões, ou uso inválido (`--flag` sem valor) |

## Histórico de mudanças relevantes (PRs)

| PR / Issue | Mudança | Cenários afetados |
|---|---|---|
| [#31](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/issues/31) | Entrega original | A, B |
| [#51](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/issues/51) | Refatoração `_runner.sh` + cenários C/N/A/1/2 + flag `--token` | C, N/A, 1, 2 |
| [#53](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/issues/53) | 4 bugs corrigidos (precedência `--token`, parser FAIL, flags `--url`/`--pat` em run.sh --check, export `RUNNER_DIR`) | Todos |
| [#57](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/issues/57) | Migração doc para `docs/guides/` + PAT detalhado + 4 modos de fornecer PAT | docs |

### 4 bugs corrigidos em #53 (PR `fix/runner-recover-4-bugs`)

**Bug 1 — Precedência `--token` vs faixa de idade**

Antes: idade 25-29d vencia o `--token` fornecido, fazendo cair em WARN (run.sh --check) em vez de A2 (re-registro). Observado em campo na <HOST-DASHBOARD> 26/05/2026.

Agora: `--token` tem **precedência absoluta** sobre faixa de idade quando a API não está consultável. Implementado em `_runner.sh:188`:

```bash
if [ "$has_token" = "true" ]; then
    echo "A2"; return 0          # ← vence a faixa de idade
elif [ "$age_days" -ge 30 ]; then
    echo "B"; return 0
elif [ "$age_days" -ge 25 ]; then
    echo "WARN"; return 0
else
    echo "UNKNOWN"; return 0
fi
```

**Bug 2 — Parser `F A I L` em `run.sh --check`**

Antes: `run.sh --check` retorna exit 0 mesmo com FAILs internos (PAT sem scope, endpoint bloqueado, etc.). O recover declarava sucesso mesmo com falhas.

Agora: captura output e procura `F A I L` (com espaços — formato literal do output do binário do runner). Implementado em `siscan-runner-recover.sh:356-362`:

```bash
check_output=$(sudo -u "$CURRENT_USER" "$RUNNER_DIR/run.sh" --check \
    --url "$REPO_URL" --pat "$PAT" 2>&1)
check_exit=$?
printf '%s\n' "$check_output"
if [ "$check_exit" -ne 0 ] || printf '%s' "$check_output" | grep -q "F A I L"; then
    fail "run.sh --check reportou falha..."
fi
```

**Bug 3 — `run.sh --check` sem `--url`/`--pat`**

Antes: chamado como `./run.sh --check` puro — caía em prompt interativo bloqueando o fluxo automatizado.

Agora: passa `--url $REPO_URL --pat $PAT` explicitamente. Implementado junto com o Bug 2 acima.

**Bug 4 — `RUNNER_DIR` não exportado para subshell**

Antes: o validador pós-recovery `check-runner.sh` rodava como subshell e podia cair no default `${HOME}/actions-runner` em contextos onde `HOME` era inconsistente com o `RUNNER_DIR` usado pelo recover — gerando falso positivo `config.sh: ausente`.

Agora: `export RUNNER_DIR` antes de invocar o validador. Implementado em `siscan-runner-recover.sh:389`:

```bash
# Fix #53/Bug 4: exportar RUNNER_DIR pra propagação garantida pra subshell
export RUNNER_DIR

if bash "$SPECIALISTS_DIR/check-runner.sh" --quiet; then
    ...
fi
```

## Veja também

- [`../DEPLOY_SERVER.md`](../DEPLOY_SERVER.md) — guia completo de deploy + atualização da VM
- [`../TROUBLESHOOTING.md`](../TROUBLESHOOTING.md) — sintomas e diagnóstico manual (problemas 6 e 7 cobrem auto-removal e regra dos 30d)
- [`../CHECKLISTS.md`](../CHECKLISTS.md) — checklists operacionais
- [`./siscan-server-doctor/specialists/check-network.md`](./siscan-server-doctor/specialists/check-network.md) — primeiro specialist invocado no pré-flight
- [Self-hosted runners reference (GitHub docs)](https://docs.github.com/en/actions/reference/runners/self-hosted-runners)
- [Issue #31](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/issues/31) — entrega original (cenários A e B)
- [Issue #51](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/issues/51) — refatoração `_runner.sh` + cenários C/N/A/1/2 ([comment 4545084925](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/issues/51#issuecomment-4545084925) descreve outputs detalhados por cenário)
- [Issue #53](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/issues/53) — 4 bugs corrigidos em campo
- [Issue #57](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/issues/57) — migração desta doc para `docs/guides/`
