---
title: siscan-server-setup.sh — Setup automatizado do servidor SISCAN
type: guide
status: aceita
confidencialidade: interno
owner: Time DevOps SISCAN
updated: 2026-05-26
versao: "1.1"
related:
  - docs/DEPLOY_SERVER.md
  - docs/TROUBLESHOOTING.md
  - docs/CHECKLISTS.md
  - docs/guides/siscan-server-doctor/index.md
  - docs/guides/siscan-runner-recover.md
  - docs/guides/siscan-server-doctor/products-manifest.md
tags:
  - deploy
  - server-setup
  - github-actions
  - self-hosted-runner
  - docker-compose
tldr: |
  Guia operacional de `siscan-server-setup.sh` — script de provisionamento
  do servidor SISCAN (RPA, Dashboard ou Host full). Executa 11 fases
  idempotentes (0–10): pré-flight via doctor, verificação de pré-requisitos,
  criação de usuário dedicado `siscan`, estrutura de diretórios, geração do
  `.env`, instalação do GitHub Actions self-hosted runner por estados
  (N/A → 1 → 2 → 3 → 4) e persistência de `COMPOSE_DIR`. Suporta os 3
  produtos do manifesto `scripts/data/products.json`. Roda como root, mas
  re-executa como `siscan` no momento certo.
---

# siscan-server-setup.sh — Setup automatizado do servidor SISCAN

`siscan-server-setup.sh` provisiona uma VM Linux para receber deploys automáticos do SISCAN (RPA, Dashboard ou Host completo) via GitHub Actions self-hosted runner. Roda em 11 fases sequenciais idempotentes (`0` a `10`), cada uma demarcada por um banner ANSI no console. É o **ponto de entrada** do fluxo de provisionamento — todos os deploys subsequentes saem dele.

> **Issue de origem**: [#55](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/issues/55).
> **Refatorações recentes**: [#52](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/pull/52) — Fase 7 delegada para `scripts/deploy_server/_runner.sh` (cenários N/A → 4).
> **Pré-flight**: [#32](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/pull/32) — Fase 0 invoca `siscan-server-doctor.sh --pre-setup`.

## Pré-requisitos

- **Linux** (Ubuntu 22.04+ recomendado).
- **Docker Engine >= 24** e **Docker Compose v2** (plugin) — o script aborta se ausentes.
- **`curl`** disponível em `PATH`.
- **`sudo`** disponível — usado para criar `COMPOSE_DIR`, instalar o runner como serviço systemd e gravar `/etc/environment`.
- **Acesso de rede** a `github.com` e `api.github.com` (download do runner) e ao banco PostgreSQL externo.
- **Token de registro do runner** obtido em `Settings → Actions → Runners → New self-hosted runner` no repositório do produto. **Tokens expiram em poucos minutos** — gere logo antes de chegar na Fase 7.
- **Arquivos auxiliares no mesmo diretório do script** (caso não sejam encontrados em `COMPOSE_DIR`):
  - `docker-compose.prd.<produto>.yml`
  - `.env.server-<produto>.sample` (ou `.env.host.sample` para `full`)
  - `config/excel_columns_mapping.json` (para `rpa` e `full`).

## Invocações suportadas

Catálogo de formas sintáticas aceitas pelo script. Para a sequência operacional onde cada invocação é usada, ver [`../DEPLOY_SERVER.md`](../DEPLOY_SERVER.md).

```bash
# Produto explícito via --product
bash ./siscan-server-setup.sh --product rpa
bash ./siscan-server-setup.sh --product dashboard
bash ./siscan-server-setup.sh --product full

# Forma equivalente com '='
bash ./siscan-server-setup.sh --product=rpa

# Sem --product → abre menu interativo
bash ./siscan-server-setup.sh

# Pular o gate doctor da Fase 0
bash ./siscan-server-setup.sh --product rpa --skip-doctor

# Via variável de ambiente equivalente a --product
SISCAN_PRODUCT=rpa bash ./siscan-server-setup.sh
```

Argumentos desconhecidos são silenciosamente ignorados (loop com `*) shift ;;`).

## Flags

| Flag | Tipo | Default | Descrição |
|---|---|---|---|
| `--product <p>` | string | — | Produto a instalar. Valores aceitos: `rpa`, `dashboard`, `full`. Se omitido, o script abre menu interativo. |
| `--product=<p>` | string | — | Forma equivalente com `=`. |
| `--skip-doctor` | flag | `false` | Pula o gate `siscan-server-doctor --pre-setup` da Fase 0. **Não recomendado em produção** — só usar em debugging de ambientes anômalos. |

Argumentos desconhecidos são silenciosamente ignorados (loop com `*) shift ;;`).

### Variáveis de ambiente reconhecidas

| Variável | Default | Descrição |
|---|---|---|
| `RUNNER_DIR` | `${HOME}/actions-runner` | Onde o tarball do GitHub Actions runner será extraído. |
| `COMPOSE_DIR` | `${SCRIPT_DIR}` | Diretório onde mora o `docker-compose.prd.*.yml` e o `.env`. Persistido em `/etc/environment` na Fase 8. |
| `SISCAN_PRODUCT` | — | Equivalente a `--product`. Repassado automaticamente na re-execução da Fase 2. |

## Funcionamento técnico

### Fase 0 — Pré-flight via doctor

Gate diagnóstico **antes de qualquer ação destrutiva**. Invoca `siscan-server-doctor.sh --quiet --pre-setup`, que roda um subconjunto dos specialists em `scripts/deploy_server/check-*.sh` para detectar problemas pré-setup (Docker/Compose/curl/jq ausentes, OS incompatível, recursos sub-dimensionados, firewall fechado).

São **excluídos** 3 specialists que só fazem sentido depois do setup:

- `check-runner` — runner ainda não foi instalado.
- `check-stack` — stack ainda não foi subida.
- `check-db` — `.env` final com `DATABASE_HOST` só sai na Fase 5.

Comportamento:

- Se o doctor passar: `ok "Doctor aprovou: VM atende aos pré-requisitos pré-setup"`.
- Se o doctor falhar: o script aborta com **exit 2** e instrui o operador a rodar o doctor em modo legível (`bash siscan-server-doctor.sh`).
- Se `siscan-server-doctor.sh` estiver ausente: warn e prossegue.
- Se `--skip-doctor`: warn e prossegue.

### Fase 1 — Verificação de pré-requisitos

Checagens diretas dos binários:

- `docker` no `PATH` → `fail` se ausente.
- `docker info` conecta ao daemon → se falhar, diagnostica causa específica:
  - Serviço inativo: sugere `sudo systemctl start docker`.
  - Usuário fora do grupo `docker`: sugere `sudo usermod -aG docker $USER`.
  - Socket ausente: avisa que o daemon não subiu.
- Versão do Docker >= 24.x (warn se inferior).
- `docker compose version` (plugin v2) → `fail` se ausente.
- `curl` e `sudo` presentes.

### Fase 2 — Usuário dedicado para o runner

O binário do GitHub Actions runner **recusa execução como root**. Comportamento:

- Se `id -u == 0`:
  1. Cria o usuário `siscan` via `useradd -m -s /bin/bash siscan` (se não existir).
  2. Pede senha interativa via `passwd siscan`.
  3. Adiciona ao grupo `docker`.
  4. Transfere ownership de `SCRIPT_DIR` para `siscan:siscan` (evita `Permission denied` no `.git` quando o repo foi clonado como root).
  5. **Re-executa o script via `exec sudo -u siscan ...`**, repassando `SISCAN_PRODUCT`, `COMPOSE_DIR`, `RUNNER_DIR` e `--product`. A execução atual termina aqui.
- Se já estiver rodando como não-root: apenas reporta `ok` e prossegue.

### Fase 3 — Estrutura de diretórios da stack

- Cria `COMPOSE_DIR` via `sudo mkdir -p` se não existir.
- Garante que o dono é o `CURRENT_USER` (ajusta via `sudo chown` se necessário).

### Fase 4 — Arquivos da stack

Procura e/ou copia para `COMPOSE_DIR` os arquivos obrigatórios:

| Arquivo | Origem fallback | Ação se ausente |
|---|---|---|
| `docker-compose.prd.<produto>.yml` | `SCRIPT_DIR` | `fail` — instrui a colocar manualmente. |
| `config/` (diretório) | `SCRIPT_DIR/config/` | Cria vazio + warn. |
| `config/excel_columns_mapping.json` | — | Warn (não é fatal nesta fase). |

### Fase 5 — Configuração do .env (interativa)

1. **Bootstrap**: se `${COMPOSE_DIR}/.env` não existe, copia do sample correspondente (`.env.server-rpa.sample`, `.env.server-dashboard.sample` ou `.env.host.sample`), procurando primeiro em `COMPOSE_DIR` e depois em `SCRIPT_DIR`. Se nenhum sample for encontrado, cria vazio.
2. **Persistência de produto**: grava `SISCAN_PRODUCT=<p>` no `.env`.
3. **Geração de segredo**:
   - Para `dashboard`: gera `SESSION_SECRET` (64 hex chars) se ausente.
   - Para `rpa` e `full`: gera `SECRET_KEY`.
   - Função `_generate_secret` usa `openssl rand -hex 32` (fallback `python3` ou `/dev/urandom`).
4. **Prompt interativo** para variáveis-chave (cada uma só pergunta se faltar ou estiver com valor inválido). As perguntas e validações específicas variam por produto — a lista canônica por produto (`DATABASE_HOST`, `DATABASE_PASSWORD`, `ADMIN_PASSWORD`, `RPA_DATABASE_URL` etc.) está em [`../DEPLOY_SERVER.md`](../DEPLOY_SERVER.md) (seção *Instalação*). Em geral o script:
   - Rejeita valores-padrão de dev (ex.: `DATABASE_HOST=db`).
   - Lê senhas silenciosamente (`read -rs`).
   - Detecta passwords default declaradas no manifesto (`default_passwords_to_detect`) e dispara warn.
   - Valida formato de URLs declaradas como obrigatórias (ex.: regex `^postgresql://[^@]+@[^/]+/.+`).
5. **Variáveis `HOST_*`** — caminhos que viram bind mounts. A lista por produto vem do campo `host_dir_vars` do manifesto `products.json`. Os valores típicos sugeridos para cada produto estão tabulados em [`../DEPLOY_SERVER.md`](../DEPLOY_SERVER.md) (seção *Instalação*). Para cada variável declarada no manifesto, o script mostra o valor atual e oferece manter (`Enter`) ou substituir. **Caminhos no formato Windows** (drive letter `C:\`, UNC `\\server\share`, ou backslash como separador) disparam warn da função `_validate_linux_path`, e o operador precisa confirmar explicitamente (`S/N`) para gravá-los assim mesmo.

### Fase 6 — Criação dos diretórios HOST_*

Itera as variáveis configuradas na Fase 5 e roda `mkdir -p` em cada uma. Falhas geram warn mas não abortam — útil quando o operador define caminhos em volumes montados depois.

### Fase 7 — GitHub Actions Runner (estados 1 → 2 → 3 → 4)

A lógica do runner foi extraída para `scripts/deploy_server/_runner.sh` no [PR #52](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/pull/52). É a **mesma single-source-of-truth** consumida por `siscan-runner-recover.sh`, garantindo coerência entre setup inicial e recovery.

Estados detectados por `runner_get_state RUNNER_DIR`:

| Estado | Significado | Ação tomada |
|---|---|---|
| `N/A` | `$RUNNER_DIR` não existe | Cria, baixa, registra, instala, start |
| `1` | dir existe, binários (`config.sh`/`svc.sh`) ausentes | Baixa, registra, instala, start |
| `2` | binários OK, `.runner` ausente (registro não feito) | Registra, instala, start |
| `3` | `.runner` OK, systemd unit ausente | Instala, start |
| `4` | tudo presente | Garante que está em `active` (idempotente) |

A detecção de "systemd unit instalada" usa o marker `${RUNNER_DIR}/.service` (escrito por `svc.sh install`), que vincula o `RUNNER_DIR` à sua unit específica em hosts com múltiplos runners.

Quando atinge o estado `2`, o script solicita interativamente:

- **URL do repositório** — default derivado de `products.json[<product>].repo`. A URL específica por produto (`siscan-rpa`, `siscan-dashboard` etc.) está em [`../DEPLOY_SERVER.md`](../DEPLOY_SERVER.md) (seção *Instalação*).
- **Token de registro** (`read -rs` — não ecoa). Gerado em `Settings → Actions → Runners → New self-hosted runner`. **Expira em ~5 min**.

O registro chama `./config.sh --url <URL> --token <TOKEN> --labels <LABEL> --name <NAME> --unattended --replace`. `LABEL` vem do campo `runner_label` do manifesto e `NAME` é montado como `<hostname>-<runner_name_suffix>`. Os valores por produto estão em [`../DEPLOY_SERVER.md`](../DEPLOY_SERVER.md).

O download (`runner_download_binaries`) detecta arquitetura automaticamente (`x86_64` → `x64`, `aarch64` → `arm64`; outras arches abortam) e consulta `api.github.com/repos/actions/runner/releases/latest` para baixar a versão mais recente.

### Fase 8 — Persistir COMPOSE_DIR no ambiente do runner

O runner roda como serviço systemd e **não carrega** `~/.bashrc` nem `/etc/environment`. A única forma de injetar variáveis nos jobs é via arquivo `.env` dentro de `RUNNER_DIR`. Esta fase:

1. Cria/atualiza `${RUNNER_DIR}/.env` com `COMPOSE_DIR=<valor>`.
2. **Reinicia o runner** (`sudo svc.sh stop && sudo svc.sh start`) — necessário porque ele subiu na Fase 7 *antes* de o `.env` existir.
3. Persiste também em `/etc/environment` (para sessões interativas SSH).

### Fase 9 — Permissões Docker

Adiciona `CURRENT_USER` ao grupo `docker` via `sudo usermod -aG docker`. Avisa que **logout/login é necessário** para a mudança ter efeito em terminais existentes — mas o serviço do runner, ao reiniciar via systemd, já assume o novo grupo.

### Fase 10 — Resumo e próximos passos

Imprime tabela com produto, paths e label do runner, mais 6 instruções para o operador (revisar `.env`, conferir runner no GitHub, status do serviço, gatilho de deploy, logs do runner e da stack).

## Configuração

### Variáveis de ambiente do `.env`

A lista completa de variáveis obrigatórias por produto está no manifesto declarativo `scripts/data/products.json`. Resumo das mais relevantes:

| Variável | Produtos | Origem | Notas |
|---|---|---|---|
| `SISCAN_PRODUCT` | todos | Auto (Fase 5) | Persistido pelo próprio script. |
| `SECRET_KEY` | `rpa`, `full` | Gerado (Fase 5) | 64 hex chars. |
| `SESSION_SECRET` | `dashboard` | Gerado (Fase 5) | 64 hex chars. |
| `DATABASE_HOST` | todos | Interativo | Rejeita literal `db`. |
| `DATABASE_USER`, `DATABASE_NAME` | todos | Sample | Editar manualmente se necessário. |
| `DATABASE_PASSWORD` | todos | Interativo | Hidden input. Detecta default `siscan_rpa`. |
| `ADMIN_PASSWORD` | `dashboard` | Interativo | Opcional — fallback gera no log. |
| `RPA_DATABASE_URL` | `dashboard` | Interativo | Validada por regex Postgres. |
| `HOST_*_DIR` | varia (Fase 5) | Interativo | Detecta paths Windows. |

### Manifesto `products.json`

`scripts/data/products.json` é a **fonte declarativa** consumida pelos specialists (`scripts/deploy_server/check-*.sh`) — substitui hardcoding `case "$SISCAN_PRODUCT"` em cada script. Para o setup, define:

| Chave | Uso pelo setup |
|---|---|
| `compose_file` | Arquivo procurado/copiado na Fase 4. |
| `env_sample` | Sample copiado na Fase 5. |
| `runner_label` | Label passada ao `config.sh` na Fase 7. |
| `runner_name_suffix` | Sufixo do `RUNNER_NAME` (`<hostname>-<suffix>`). |
| `session_secret_var` | `SECRET_KEY` (rpa/full) vs `SESSION_SECRET` (dashboard). |
| `host_dir_vars` | Lista de `HOST_*` solicitadas na Fase 5. |
| `required_env_vars` | Validadas pelo doctor (check-env) pós-setup. |
| `default_passwords_to_detect` | Valores que disparam warn na Fase 5. |

Schema completo: [`docs/guides/siscan-server-doctor/products-manifest.md`](./siscan-server-doctor/products-manifest.md).

> Importante: o setup **não** lê o manifesto diretamente — ele tem seus próprios `case "${SISCAN_PRODUCT}"` em `siscan-server-setup.sh`. O manifesto é consumido pelos specialists do doctor. Em divergências entre os dois, o manifesto é a fonte canônica; ajustes no setup ficam para refactor futuro.

## Solução de problemas

Sintomas observáveis ao usar este utilitário estão catalogados em [`../TROUBLESHOOTING.md`](../TROUBLESHOOTING.md) com diagnóstico passo-a-passo e ação corretiva. Cada problema referencia o specialist do doctor que cobre a verificação automatizada. Para sequência operacional do deploy completo, ver [`../DEPLOY_SERVER.md`](../DEPLOY_SERVER.md).

## Exit codes

| Código | Causa |
|---|---|
| `0` | Setup concluído com sucesso (Fase 10 alcançada). |
| `1` | Falha em pré-requisito de Fase 1, Fase 4 (compose ausente), Fase 7 (registro/install/start do runner) ou outras chamadas explícitas a `fail()`. |
| `2` | Doctor reprovou na Fase 0 (gate pré-setup). |

O script **não** usa `set -e` (errexit) intencionalmente — comandos como `read` e `grep` retornam não-zero em fluxo normal. Erros são tratados explicitamente via `fail()`.

## Veja também

- [`docs/DEPLOY_SERVER.md`](../DEPLOY_SERVER.md) — playbook completo de deploy do servidor (contexto onde o setup é uma etapa).
- [`docs/TROUBLESHOOTING.md`](../TROUBLESHOOTING.md) — sintomas observados em campo, com a coluna "Coberto por" indicando qual script automatiza cada caso.
- [`docs/CHECKLISTS.md`](../CHECKLISTS.md) — checklist operacional pós-setup.
- [`./siscan-server-doctor/index.md`](./siscan-server-doctor/index.md) — diagnóstico automatizado (gate da Fase 0 e validação pós-deploy).
- [`./siscan-runner-recover.md`](./siscan-runner-recover.md) — recovery do runner (compartilha `_runner.sh` com a Fase 7).
- [`docs/guides/siscan-server-doctor/products-manifest.md`](./siscan-server-doctor/products-manifest.md) — schema do manifesto `products.json`.
