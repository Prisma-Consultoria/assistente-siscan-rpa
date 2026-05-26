---
title: siscan-server-doctor.sh — Diagnóstico amplo da VM
type: guide
status: aceita
confidencialidade: interno
owner: Time DevOps SISCAN
updated: 2026-05-26
versao: "1.1"
related:
  - docs/DEPLOY_SERVER.md
  - docs/TROUBLESHOOTING.md
  - docs/siscan-server-doctor/index.md
  - docs/siscan-server-doctor/products-manifest.md
  - docs/guides/siscan-server-setup.md
  - docs/guides/siscan-runner-recover.md
tags:
  - doctor
  - diagnostico
  - specialists
  - siscan
  - deploy
tldr: |
  Guia operacional de `siscan-server-doctor.sh` — orquestrador que executa
  9 specialists em `scripts/deploy_server/check-*.sh` e agrega o resultado
  num único relatório. Suporta 3 modos de saída (`human`, `--quiet`,
  `--json`), subconjuntos via `--only`/`--except`/`--pre-setup`, e produz
  exit codes consumíveis por gates de CI ou cron. Cada specialist cobre
  uma dimensão da saúde da VM (rede, deps, env, docker, runner, stack,
  permissões, banco, recursos) e é callable standalone.
---

# `siscan-server-doctor.sh` — Diagnóstico amplo da VM

`siscan-server-doctor.sh` é o **entry point de diagnóstico** da VM que hospeda os produtos SISCAN. Descobre os specialists em `scripts/deploy_server/check-*.sh`, executa cada um sequencialmente e agrega o resultado em um único relatório consolidado, com **3 modos de saída** e **exit codes** consumíveis por cron / CI gate.

> **Issue de origem (feature F00.01)**: [#28](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/issues/28) — Diagnóstico amplo + recuperação cirúrgica.
> **Implementação inicial**: [PR #32](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/pull/32) — doctor + 8 specialists.
> **Issue do guia**: [#56](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/issues/56).

## Pré-requisitos

- **Bash 4+** (para `mapfile`, parameter expansion, `read -ra`).
- **Utilitários Linux**: `grep`, `awk`, `sed`, `head`, `tail`, `cut`, `tr`, `stat`, `df`, `nproc`, `free`, `paste`, `seq` (do `coreutils`/`util-linux`).
- **`jq`** — obrigatório no modo `--json` (o doctor agrega envelopes JSON dos specialists) e em todos os specialists que leem `products.json`/`network-endpoints.json`. Cada specialist usa `require_commands` para abortar com mensagem orientativa se faltar.
- **`curl`** — usado por `check-network` (probes HTTPS) e `check-runner` (fallback à API GitHub quando `gh` não está autenticado).
- **`timeout`** (de `coreutils`) — usado por `check-network`, `check-db`.
- **`docker`** + **`docker compose v2`** — exigidos por `check-docker`, `check-stack`.
- **`getent`** (de `libc-bin`) — exigido por `check-permissions` para resolver UID/GID.
- **`.env` do produto** no `$COMPOSE_DIR` (ou `$PWD`) — necessário para os specialists que validam configuração: `check-env`, `check-db`, `check-stack`, `check-permissions`, `check-runner`. O specialist `check-env` valida o conteúdo; os demais aceitam que `SISCAN_PRODUCT` esteja preenchido.
- **Manifesto `scripts/data/products.json`** — fonte de verdade dos produtos (`rpa`, `dashboard`, `full`) consumida pelos specialists product-aware.
- **Manifesto `scripts/data/network-endpoints.json`** — lista canônica de FQDNs usada pelo `check-network`.
- **Usuário não-root** — `check-docker` falha (FAIL) se o doctor for executado como root, refletindo a restrição do GitHub Actions runner (recusa instalação como root).

## Invocações suportadas

Catálogo de formas sintáticas aceitas pelo orquestrador. Para a sequência operacional onde cada invocação é usada, ver [`../../DEPLOY_SERVER.md`](../../DEPLOY_SERVER.md).

```bash
# Sem flags → roda todos os 9 specialists em modo human
bash siscan-server-doctor.sh

# Subconjunto pré-setup (--except check-runner,check-stack,check-db)
bash siscan-server-doctor.sh --pre-setup

# --only LIST (CSV de specialists)
bash siscan-server-doctor.sh --only check-network
bash siscan-server-doctor.sh --only check-network,check-db
bash siscan-server-doctor.sh --only check-env,check-docker

# --except LIST (CSV de specialists a excluir)
bash siscan-server-doctor.sh --except check-stack
bash siscan-server-doctor.sh --except check-db,check-stack

# Modos de saída
bash siscan-server-doctor.sh --quiet
bash siscan-server-doctor.sh --json
bash siscan-server-doctor.sh --json | jq '.summary'

# Inventário dos specialists descobertos
bash siscan-server-doctor.sh --list

# Timeout customizado (repassado a check-network, check-db)
bash siscan-server-doctor.sh --timeout 15

# Combinações de subconjunto + modo
bash siscan-server-doctor.sh --only check-network --quiet
bash siscan-server-doctor.sh --pre-setup --json

# Ajuda
bash siscan-server-doctor.sh -h
bash siscan-server-doctor.sh --help
```

## Flags

| Flag | Função |
|---|---|
| (sem flag) | Roda **todos** os specialists em modo `human` — validação completa post-setup |
| `--pre-setup` | Açúcar sintático para `--except check-runner,check-stack,check-db` — usar antes da Fase 5 do `siscan-server-setup.sh` |
| `--only LIST` | Roda apenas os specialists listados (CSV). Ex.: `--only check-network,check-env` |
| `--except LIST` | Roda todos **exceto** os listados (CSV) |
| `--quiet` | Suprime saída pretty-print; imprime apenas linhas `FAIL [<specialist>] ...` |
| `--json` | Saída estruturada — envelope consolidado `{summary, specialists: [...]}` |
| `--list` | Lista specialists descobertos + a primeira linha `# Summary:` do header de cada um, e sai |
| `-h`, `--help` | Exibe ajuda inline e sai |
| `--timeout SEC` | Repassado a specialists que aceitam (`check-network`, `check-db`) |

> **Mutuamente exclusivos**: `--only`, `--except` e `--pre-setup` não devem ser combinados — a precedência vai do mais específico (`--only`) para o mais amplo. `--quiet` e `--json` selecionam o `OUTPUT_MODE` e também são exclusivos entre si.

## Funcionamento técnico

### Orquestração dos specialists

O doctor não conhece os specialists em tempo de compilação. Ele **descobre** os arquivos `scripts/deploy_server/check-*.sh` em runtime (laço `for spec in "$SPECIALISTS_DIR"/check-*.sh`). Cada specialist é invocado em um **subshell** (`bash "$script" [...]`) com o mesmo `OUTPUT_MODE`:

```
descobrir AVAILABLE = [check-db, check-deps, check-docker, check-env,
                       check-network, check-permissions, check-resources,
                       check-runner, check-stack]
aplicar --only / --except → TO_RUN
para cada nome em TO_RUN:
    bash $SPECIALISTS_DIR/$nome.sh [--quiet|--json|nada]
    capturar exit code + stdout
agregar resumo + renderizar conforme OUTPUT_MODE
exit 0 se nenhum FAIL, 1 se >= 1 FAIL
```

> **Implicação**: adicionar um novo specialist é só criar `scripts/deploy_server/check-novo.sh` (com header `# Summary: ...` para aparecer em `--list`). O doctor o pega no próximo run.

### Modos de saída (human, quiet, json)

| Modo | `OUTPUT_MODE` | Stdout | Stderr | Quando usar |
|---|---|---|---|---|
| `human` (default) | `human` | Pretty-print colorido por specialist: cabeçalho `▸ Specialist: X`, categorias, ✔/✘ por check, resumo final `N/M specialists OK` | Erros de `fail()` apenas | Diagnóstico manual interativo |
| `--quiet` | `quiet` | Apenas linhas `FAIL [<specialist>] <proto>/<port> <target>: <detalhe>` | Progresso `[i/N] nome... ✓/✗` (se TTY) | Cron, monitoramento contínuo |
| `--json` | `json` | Envelope `{summary: {specialists_total, ok, fail}, specialists: [<envelope de cada>]}` | Progresso `[i/N] nome... ✓ ok/total OK` (se TTY) | Integração com ferramenta externa |

Detalhes não-óbvios:

- **Pré-fail (exit 2)**: se um specialist sai com 2 (`.env` ausente, dependência faltando) o doctor:
  - em `human`: imprime marker `✘ <nome> pré-falhou (exit=2) — conta como 1 FAIL no consolidado` para alinhar com o agregado JSON;
  - em `json`: sintetiza um envelope `{summary: {total: 1, ok: 0, fail: 1}, checks: [{category: "Pré-requisito do specialist", ..., detail: "specialist saiu com exit=N sem JSON válido. stderr: <últimos 500 chars>"}]}`. A cauda de stderr é capturada via `STDERR_BUFFER` (`mktemp`) e escapada com `_json_escape` (bash puro, sem depender de `jq` — pois `jq` pode ser exatamente o binário ausente).
- **`--json` exige `jq`** no preflight do doctor (validação dos envelopes individuais). Em `human`/`quiet` o doctor não usa `jq` diretamente — somente os specialists individuais o usam (e cada um faz seu próprio `require_commands jq` se precisar).
- **Progresso no stderr**: habilitado em `--json` e `--quiet` se stderr for TTY. Em CI (stderr não-TTY), permanece desligado para não poluir logs.

### Subconjuntos (--pre-setup, --only, --except)

O cálculo de `TO_RUN` aplica os filtros nessa ordem:

1. Se `--only` definido: roda **apenas** o que está em `--only`.
2. Senão, se `--except` definido (inclui `--pre-setup`, que apenas define `EXCEPT=check-runner,check-stack,check-db`): roda tudo **exceto** o que está em `--except`.
3. Senão: roda todos os specialists descobertos.

A constante `EXCEPT_PRE_SETUP="check-runner,check-stack,check-db"` é fixa no script: esses 3 specialists dependem de etapas do `siscan-server-setup.sh` que ainda não rodaram antes da Fase 5 (runner não instalado, containers não subidos, `.env` final não materializado).

## Specialists disponíveis

Cada specialist é callable standalone (`bash scripts/deploy_server/check-<nome>.sh [--quiet|--json]`) e segue o contrato definido em [`_common.sh`](../../scripts/deploy_server/_common.sh): `print_category_header` → `add_ok`/`add_fail` por check → `render_results` → `finalize_exit`.

### `check-network` — 22 endpoints externos

**O que verifica**: alcançabilidade (firewall liberado) de todos os FQDNs declarados em `scripts/data/network-endpoints.json`, agrupados em 5 categorias:

- **Runner ↔ GitHub Actions** (7 endpoints, HTTPS/443): `github.com`, `api.github.com`, `codeload.github.com`, `pipelines.actions.githubusercontent.com`, `results-receiver.actions.githubusercontent.com`, `productionresultssa0.blob.core.windows.net`, `release-assets.githubusercontent.com`.
- **Self-update do runner** (4 endpoints, HTTPS/443): `objects.githubusercontent.com`, `objects-origin.githubusercontent.com`, `github-releases.githubusercontent.com`, `github-registry-files.githubusercontent.com`.
- **GHCR — pull de imagem** (3 endpoints, HTTPS/443): `ghcr.io`, `pkg-containers.githubusercontent.com`, `npm.pkg.github.com`.
- **Docker Hub** (3 endpoints, HTTPS/443): `registry-1.docker.io`, `auth.docker.io`, `production.cloudflare.docker.com`.
- **OCSP/CRL** (5 endpoints, **TCP/80** — não 443): `crl3.digicert.com`, `crl4.digicert.com`, `ocsp.digicert.com`, `crl.sectigo.com`, `ocsp.sectigo.com`.

**Categoria condicional**: se `SISCAN_PRODUCT` define `siscan_portal_url_default` no manifesto (`rpa`, `full`), adiciona um check do portal SISCAN (URL do `.env` `SISCAN_URL` ou default do manifesto).

**Por que importa**: critério do PDF v2.0 §11.4 — qualquer resposta HTTP (`200`, `301`, `403`, `404`, `405`, …) confirma que **TLS subiu** = firewall liberado. Só `000`/timeout indica bloqueio real. OCSP/CRL roda em HTTP/80 por design do PKIX — esquecer disso é o **erro #1** em whitelist (release de regra apenas para 443 deixa validação intermitente).

**Sintomas que detecta**: chamado interno de firewall de whitelist incompleta; firewall liberando 443 mas não 80; bloqueio de `*.actions.githubusercontent.com` causando runner offline em 14 dias.

> Documentação detalhada de manifesto + critério: [`siscan-server-doctor/scripts/check-network.md`](../siscan-server-doctor/scripts/check-network.md).

### `check-deps` — Docker, Compose, curl, jq, sudo, NTP, OS

**O que verifica** (read-only — não modifica nada):

- **Container runtime**: `docker` (avisa se versão < 24), `docker compose` (plugin v2).
- **Network tools**: `curl`, `jq`, `openssl`.
- **Sistema**: `sudo`, `timeout`, `getent`, `git`.
- **OS**: lê `/etc/os-release` — `ubuntu 24.04` é o alvo; `22.04` aceita com aviso de "Docker/Compose podem estar desatualizados"; distros não-Ubuntu ou `< 22.04` viram FAIL.
- **Sincronização de tempo (NTP)**: `timedatectl status` — clock dessincronizado é registrado como `add_ok` com label `(warn)` (não derruba o gate, mas alerta para `SSL_ERROR_SYSCALL` em TLS). Se `timedatectl` indisponível (WSL, containers), pula com `warn()`.

**Por que importa**: espelha a Fase 1 do `siscan-server-setup.sh` sem duplicar a lógica de correção. Clock fora de sync foi sintoma real relatado em 06/05 no registro interno.

### `check-env` — `.env` preenchido conforme manifesto

**O que verifica** (lê o `.env` como dados, sem `source`/`eval`):

1. **`SISCAN_PRODUCT`** — definido e conhecido em `products.json`. Se ausente, FAIL early + exit.
2. **Variáveis obrigatórias** — `required_env_vars` do manifesto. Cada uma precisa estar não-vazia.
3. **Regras especiais**:
   - `DATABASE_HOST` ≠ `"db"` (valor padrão de dev — banco precisa ser externo em produção).
   - `DATABASE_PASSWORD` ∉ `default_passwords_to_detect` do manifesto (`siscan_rpa`, `siscan_dashboard`).
   - `SESSION_SECRET` ou `SECRET_KEY` (qual depende do produto) com ≥ 32 caracteres.
   - `RPA_DATABASE_URL` no formato `postgresql://user:pass@host:port/db` quando `extras.rpa_database_url_required` (dashboard).
   - `HOST_APP_EXTERNAL_PORT`, `REDIS_PORT`, `DATABASE_PORT` numéricas em `[1, 65535]`.
4. **Diretórios `HOST_*_DIR`** — declarados no `.env` (existência fica para `check-permissions`). Detecta paths Windows (`\` ou `^[A-Z]:`) e marca FAIL.
5. **Avisos** (não impedem boot — `add_ok` com label `(warn)`): `APP_LOG_LEVEL=DEBUG`, `SYNC_INTERVAL_SECONDS` ausente, `SISCAN_URL` ausente.

### `check-docker` — daemon, daemon.json pool, network create

**O que verifica**:

- **Daemon**: `docker info` (acessível) + `systemctl is-active docker` (se systemd presente).
- **Permissões**: `/var/run/docker.sock` presente; **usuário não-root** (uid != 0 — FAIL caso root, porque o runner GitHub Actions recusa rodar como root); usuário no grupo `docker`.
- **Pool de redes (`/etc/docker/daemon.json`)**: parseia `default-address-pools`. **Detecta o problema mais recorrente do servidor parceiro** (visto em duas VMs distintas, 19/03 e 27/03): pool `192.168.4.0/24` com `size: 24` = 1 subnet só, já ocupada pela `bip`, gerando `address pool esgotado` em `docker network create`.
- **Inventário de redes**: `docker network ls` + `docker network inspect` (subnet de cada).
- **Teste real (gold standard)**: `docker network create siscan-check-$$ && docker network rm siscan-check-$$`. Se falhar, o erro real do daemon aparece na linha FAIL.

### `check-runner` — local + API GitHub + regra 30d

**O que verifica** (4 categorias):

1. **Instalação local** (`$RUNNER_DIR`, default `$HOME/actions-runner`): `config.sh` presente, `.runner` (proxy do registro).
2. **Serviço systemd** (`actions.runner.*`): unidade existe e está `active`.
3. **Registro remoto via API GitHub**:
   - Usa `gh api` se autenticado; fallback para `curl` + `GH_TOKEN`.
   - Detecta **auto-removal de 14 dias** (`total_count == 0` → runner removido pelo GitHub).
   - Confere `name == "<hostname>-<runner_name_suffix>"` (suffix do manifesto) e `status == "online"`.
4. **Idade do runner — regra dos 30 dias**:
   - Sinais (em ordem de confiança): `mtime` de `.runner_migrated` (atualizado a cada self-update) → `mtime` do log mais recente em `_diag/Runner_*.log` → `mtime` do `.runner` (proxy de primeiro registro).
   - `< 25 dias`: OK.
   - `[25, 30) dias`: `add_ok` com label `(warn)` — janela preventiva, GitHub ainda envia jobs.
   - `≥ 30 dias`: FAIL — GitHub para de enviar jobs (sintoma confuso: `Waiting for a runner` indefinido, descoberto em 25/05 no chat).

> **Comportamento não-óbvio**: o specialist faz **pre-fail (exit 2)** via `fail()` em `_common.sh` se `gh` CLI ausente **e** `GH_TOKEN` não setado, mas só para o check remoto (que é pulado com `warn()`). Os checks locais/systemd/idade continuam rodando.

### `check-stack` — compose ps + port collision + restart loop

**O que verifica** (todos os parâmetros vêm do manifesto):

1. **Compose file** (`products.json: compose_file`) presente em `$COMPOSE_DIR`. Se ausente, `render_results` + `finalize_exit` early.
2. **`docker compose config`** — valida parse YAML + interpolação. Catch para erros de variáveis ausentes.
3. **Imagem do produto** (`products.json: image`):
   - Cache local (`docker image inspect`) — reporta tamanho via `numfmt --to=iec`.
   - GHCR remoto (`docker manifest inspect`) — detecta `manifest unknown` (tag nunca publicada). `unauthorized`/`denied` é apenas `info()` (pull via CD usa `GITHUB_TOKEN`).
4. **Containers esperados** (`products.json: expected_services`): cada serviço com `State == "running"`.
5. **Restart loop**: `[.[] | select(.State == "restarting")]` — caso real 20/03 (jinja2 ausente em container reiniciando).
6. **Healthcheck**: `[.[] | select(.Health == "unhealthy")]`.
7. **Port collision** (`products.json: expected_external_ports`): `ss -tlnp` (fallback `netstat -tlnp`). Se ocupada pelo Docker → OK; por outro processo → FAIL. Detecta caso 27/03 (porta já em uso por outro serviço da VM).

> **Comportamento não-óbvio**: normaliza `docker compose ps --format json` para suportar tanto Compose v2.21+ (array JSON) quanto v2.20 (linhas separadas) — usa `head -c1 | grep '\['` para detectar.

### `check-permissions` — ownership, safe.directory, UID 1000, RSA keys

**O que verifica** (cobre 5 problemas reais do chat):

1. **`$COMPOSE_DIR`** pertence ao usuário corrente (caso 19/03: criado como root, bind mount falha).
2. **`git safe.directory`** — `git -C "$COMPOSE_DIR" rev-parse` deve funcionar (caso 19/03: `dubious ownership`).
3. **`HOST_*_DIR` do manifesto** — cada um existe + escrevível.
4. **`HOST_SECRETS_DIR` + chaves RSA** (se `extras.rsa_keys_required` ou `host_secrets_dir_optional`): diretório com perms `700`, `rsa_private_key.pem` + `rsa_public_key.pem` presentes (caso 01/04: chaves não persistidas, credenciais SISCAN expirando a cada deploy). Deriva `secrets_dir` de `dirname(HOST_LOG_DIR)/secrets` se não setado (lógica idêntica ao workflow CD).
5. **`HOST_BACKUPS_DIR`** (se `extras.host_backups_dir_optional`): mesma derivação.
6. **`$COMPOSE_DIR/data/.artifacts`** — UID `1000` (do `appuser` no container RPA — caso 01/04: `PermissionError`).
7. **`HOST_CONFIG_DIR/excel_columns_mapping.json`** (se `extras.excel_columns_mapping_required`): arquivo presente (caso 27/03: RPA quebra ao iniciar coleta sem o mapeamento).

### `check-db` — TCP/5432 + pg_isready + versão Postgres

**O que verifica**:

1. **Banco principal** (`DATABASE_HOST:DATABASE_PORT` do `.env`):
   - TCP open via `exec 3<>/dev/tcp/host/port` com `timeout`.
   - `pg_isready -h ... -U ... -d ...` se `pg_isready` instalado (`apt install postgresql-client`).
   - **Versão PostgreSQL** via `psql ... SHOW server_version` se `psql` + `DATABASE_PASSWORD` disponíveis. `≥ 16` OK; `[14, 16)` OK com aviso; `< 14` FAIL.
2. **Banco do RPA visto pelo dashboard** (somente se `extras.rpa_database_url_required`): parseia `RPA_DATABASE_URL` (`postgresql://user:pass@host:port/db`) e repete o ciclo.

**Por que importa**: a §9 do PDF de whitelist (VLAN interna do servidor parceiro) **não é cobertura do `check-network`** — esse specialist é o dedicado. Detecta firewall interno bloqueado, `pg_hba.conf` não aceitando a VM, banco desligado.

### `check-resources` — vCPUs, RAM, disco

**O que verifica** (limites do `DEPLOY_SERVER.md`):

- **vCPUs** (`nproc`) ≥ 4 — Gunicorn workers + scheduler + migrate disputam CPU em picos.
- **RAM** (`free -m`) ≥ 8 GB — Python heap + cache Redis (dashboard) + Playwright (RPA) somam várias centenas de MB cada.
- **Disco livre** (`df -BG --output=avail $COMPOSE_DIR`) ≥ 20 GB — imagens Docker + logs + media (RPA) + backups crescem rápido.

Abaixo do mínimo gera FAIL com motivação operacional (`OOM kills sob carga`, `gargalo em workers`, `risco de disco cheio`).

## Configuração

### Variáveis de ambiente

| Variável | Lida por | Função |
|---|---|---|
| `COMPOSE_DIR` | doctor (via `_common.sh`) e quase todos os specialists | Diretório com o `.env` + compose file. Default: `$PWD`. |
| `OUTPUT_MODE` | `_common.sh` | `human` (default), `quiet` ou `json`. Sobrescrita por `--quiet` / `--json`. |
| `NO_COLOR` | `_common.sh` | Desativa cores ANSI (útil em logs persistidos). |
| `TIMEOUT_SEC` | `check-network` (default 10), `check-db` (default 5) | Timeout por probe. Configurável via `--timeout SEC`. |
| `GH_TOKEN` | `check-runner` | Token com scope `repo` para chamar a API GitHub Actions. Fallback de `gh auth status`. Sem token, o check remoto é pulado com `warn()`. |
| `RUNNER_DIR` | `check-runner` | Default `$HOME/actions-runner`. Configurável via `--runner-dir DIR`. |
| `PRODUCTS_FILE` | Todos os specialists product-aware | Default `$REPO_ROOT/scripts/data/products.json`. |
| `ENV_FILE` | `check-env`, `check-db`, `check-stack`, `check-permissions`, `check-runner`, `check-network` (portal SISCAN) | Default `$COMPOSE_DIR/.env`. Configurável via `--env-file FILE`. |

### Manifesto `products.json`

Fonte de verdade declarativa que diferencia `rpa`, `dashboard` e `full`. Consumida pelos specialists product-aware via helpers de [`_common.sh`](../../scripts/deploy_server/_common.sh):

- `product_validate` — garante `PRODUCTS_FILE` válido, `SISCAN_PRODUCT` setado e conhecido.
- `product_get FIELD [DEFAULT]` — campo string (ex.: `repo`, `image`, `compose_file`).
- `product_get_array FIELD` — array (ex.: `expected_services`, `host_dir_vars`).
- `product_has_extra KEY` — flag boolean (ex.: `rsa_keys_required`).
- `product_extra KEY [DEFAULT]` — valor de `extras.KEY`.

Schema detalhado e adicionar produto novo: [`siscan-server-doctor/products-manifest.md`](../siscan-server-doctor/products-manifest.md).

### Manifesto `network-endpoints.json`

Lista canônica de 22 FQDNs em 5 categorias (runner_actions, runner_self_update, ghcr, docker_hub, ocsp_crl). Cada endpoint declara `fqdn`, `protocol` (`https`|`tcp`), `port`, `purpose`, `expected` (`"<código> — <descrição>"`). Cada categoria carrega `guidance.on_all_ok` / `guidance.on_any_fail` (mensagens emitidas pelo `check-network` via `print_category_guidance`).

Atualizar quando a whitelist mudar (PDF v2.0 §3-7). Detalhes: [`siscan-server-doctor/scripts/check-network.md`](../siscan-server-doctor/scripts/check-network.md).

## Saída JSON (schema)

```json
{
  "summary": {
    "specialists_total": 9,
    "ok": 8,
    "fail": 1
  },
  "specialists": [
    {
      "specialist": "check-network",
      "summary": {"total": 22, "ok": 22, "fail": 0},
      "checks": [
        {
          "category": "Runner ↔ GitHub Actions (HTTPS/443)",
          "target": "github.com",
          "protocol": "https",
          "port": 443,
          "status": "ok",
          "detail": "200 esperado · homepage responde; login e clone funcionam"
        }
      ]
    },
    {
      "specialist": "check-db",
      "summary": {"total": 1, "ok": 0, "fail": 1},
      "checks": [
        {
          "category": "Pré-requisito do specialist",
          "target": "check-db",
          "protocol": "err",
          "port": 0,
          "status": "fail",
          "detail": "specialist saiu com exit=2 sem JSON válido. stderr: ERROR: .env não encontrado: /opt/siscan/assistente-siscan-rpa/.env"
        }
      ]
    }
  ]
}
```

> O envelope sintético do segundo specialist é gerado pelo doctor quando o specialist pré-falha (exit 2 sem JSON válido). A `stderr` é truncada a 500 chars (suficiente para `ERROR:` + ruído de `set -u`/`pipefail`) e escapada via `_json_escape` (bash puro, sem `jq` — porque `jq` pode ser exatamente o binário ausente).

## Solução de problemas

Sintomas observáveis ao usar este utilitário estão catalogados em [`../../TROUBLESHOOTING.md`](../../TROUBLESHOOTING.md) com diagnóstico passo-a-passo e ação corretiva. Cada problema referencia o specialist do doctor que cobre a verificação automatizada. Para sequência operacional do deploy completo, ver [`../../DEPLOY_SERVER.md`](../../DEPLOY_SERVER.md).

## Exit codes

| Code | Doctor | Specialist individual |
|---|---|---|
| `0` | Todos os specialists passaram | Todos os checks OK |
| `1` | Pelo menos um specialist FAIL (`add_fail` em qualquer check ou exit != 0) | Pelo menos um `add_fail` |
| `2` | Uso inválido (`argumento desconhecido`), `--only/--except` vazio, diretório de specialists inexistente | Uso inválido / dependência ausente (`require_commands`) / `.env` ausente / `SISCAN_PRODUCT` inválido |

## Monitoramento contínuo (recomendação 12.8 — PDF whitelist)

Para detectar regressões de firewall ou degradação de stack proativamente, rode o doctor a cada 5 minutos em modo `--quiet` (só FAIL aparece nos logs):

```cron
*/5 * * * * siscan cd /opt/siscan/assistente-siscan-rpa && \
            bash siscan-server-doctor.sh --quiet >> /var/log/siscan-doctor.log 2>&1 || \
            logger -t siscan-doctor "FAIL: $(date)"
```

Qualquer FAIL aparece em `journalctl -t siscan-doctor` e no `/var/log/siscan-doctor.log`. Alternativa mais leve para servidor com whitelist apertada: `--only check-network --quiet` (só revalida endpoints — útil quando a stack já é monitorada por outro mecanismo).

> **Cuidado**: a cada 5 min com `check-network` completo = 22 probes HTTPS/TCP a cada execução = ~6 mil/dia. Para janelas de produção, considere `*/15` ou alternar `--only check-network` (5 min) com diagnóstico completo (`30 * * * *`).

## Estado atual do uso do manifesto (#42)

| Componente | Usa `products.json`? | Status |
|---|---|---|
| `scripts/deploy_server/check-*.sh` (5 specialists product-aware) | ✅ | Concluído na task #45 |
| `siscan-server-doctor.sh` | — | Product-agnostic por design (não precisa) |
| `siscan-server-setup.sh` | ❌ | Pendente (próxima task da feature [#42](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/issues/42)) |

## Veja também

- [`docs/DEPLOY_SERVER.md`](../../DEPLOY_SERVER.md) — guia narrativo do deploy completo (Fases 0-5).
- [`docs/TROUBLESHOOTING.md`](../../TROUBLESHOOTING.md) — sintomas conhecidos e resolução manual + matriz "coberto por <specialist>".
- [`./products-manifest.md`](./products-manifest.md) — schema do `products.json` e checklist para adicionar produto.
- [`./specialists/check-network.md`](./specialists/check-network.md) — referência detalhada do `check-network` + manifesto de endpoints.
- [`../siscan-server-setup.md`](../siscan-server-setup.md) — guia paralelo (instalação inicial — invoca o doctor como gate na Fase 0).
- [`../siscan-runner-recover.md`](../siscan-runner-recover.md) — guia paralelo (recuperação cirúrgica do runner — diagnostica via doctor antes de agir).
- [`scripts/deploy_server/`](../../../scripts/deploy_server/) — código dos specialists + `_common.sh`.
- [`scripts/data/products.json`](../../../scripts/data/products.json) — manifesto declarativo dos produtos.
- [`scripts/data/network-endpoints.json`](../../../scripts/data/network-endpoints.json) — manifesto declarativo dos endpoints externos.
