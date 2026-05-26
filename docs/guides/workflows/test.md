---
title: "test.yml — Workflow de testes unitários do assistente"
type: guide
status: aceita
confidencialidade: público
owner: Time DevOps SISCAN
updated: 2026-05-26
versao: "1.0"
related:
  - docs/guides/workflows/cd-imagem-certificada-selfhosted.md
  - docs/DEPLOY_SERVER.md
tags:
  - workflow
  - ci
  - github-actions
  - testing
  - bats
tldr: |
  Guia de referência do `test.yml` — workflow simples de Continuous
  Integration do próprio assistente. Executa a suite de testes unitários
  em `bats` (`tests/unit/`) em cada Pull Request e cada push para `main`.
  Roda em GitHub-hosted runner padrão (`ubuntu-latest`) — não usa
  self-hosted runner, porque o assistente é um conjunto de scripts shell
  testáveis em qualquer Ubuntu sem dependência de infra do servidor
  parceiro.
---

# `test.yml` — Workflow de testes unitários do assistente

Workflow simples de **Continuous Integration** do assistente. Dispara a suite `bats` de testes unitários a cada Pull Request e a cada push em `main`. Garante que mudanças em scripts shell e nos specialists do doctor não introduzem regressões nas funções utilitárias.

> **Onde aparece**: `.github/workflows/test.yml` em `Prisma-Consultoria/assistente-siscan-rpa` (repositório público).
> **Quem dispara**: `pull_request` para `main`; `push` para `main`.
> **Onde executa**: GitHub-hosted runner padrão (`ubuntu-latest`) — não usa self-hosted runner.

## Por que GitHub-hosted (não self-hosted)?

Diferente do [workflow CD dos produtos](./cd-imagem-certificada-selfhosted.md), os testes do assistente são **independentes de infra de produção**:

- A suite `bats` testa funções shell isoladas (parsing de `.env`, validação de paths, helpers de saída)
- Não precisa de Docker, runner registrado, banco PostgreSQL ou rede pra `ghcr.io`
- Só precisa de `bash`, `jq` e o framework `bats` (que já vem no repo como submódulo)

Por isso o `runs-on: ubuntu-latest` resolve — mais rápido (~30s do início ao fim), sem disputar fila do runner self-hosted, executa em paralelo a outros workflows sem bloquear.

## Estrutura do workflow

| Aspecto | Valor |
|---|---|
| Nome | `Tests` |
| Triggers | `pull_request` para `main`, `push` para `main` |
| Job | `bats` — único job, sem `needs:` |
| Runner | `ubuntu-latest` (GitHub-hosted) |
| Permissões | default (read-only no repo) |
| Tempo médio de execução | ~30-60 segundos |

## Steps do job `bats`

| # | Step | O que faz |
|---|---|---|
| 1 | Checkout | `actions/checkout@v5` com `submodules: recursive`. Necessário para trazer `tests/test_helper/bats-support/` e `tests/test_helper/bats-assert/` (submódulos `bats-core`). |
| 2 | Install jq | `sudo apt-get install -y jq`. O `bats` em si já vem versionado no repo (`tests/bats/`), mas `jq` é usado pelos próprios specialists (e por alguns testes que validam saída JSON do doctor). |
| 3 | Run tests | `./tests/bats/bin/bats --formatter tap tests/unit/`. Roda todos os arquivos `*.bats` na pasta `tests/unit/` em modo TAP (Test Anything Protocol), que o GitHub Actions consegue parsear pra mostrar no UI. |

## O que está coberto pelos testes

Os testes em `tests/unit/` exercitam funções extraídas dos scripts principais:

- `test_check_env_configured.bats` — leitura e validação do `.env`
- `test_ensure_host_paths.bats` — criação dos diretórios `HOST_*`
- `test_env_contracts.bats` — contratos entre variáveis (ex.: `DATABASE_HOST=db` rejeitado em modo servidor)
- `test_generate_secret.bats` — geração de `SECRET_KEY` / `SESSION_SECRET`
- `test_get_expected_service_names.bats` — leitura de `expected_services` do `products.json`
- `test_load_env_help_json.bats` — parsing do `env_help.json` (descrições das variáveis)
- `test_server_setup_*.bats` — funções específicas do `siscan-server-setup.sh`

**Não cobre** (intencional):
- Testes E2E (deploy real) — esses ficam no workflow CD self-hosted
- Specialists do doctor que dependem de Docker daemon — esses são exercitados em VM real, não em CI
- Integração com GitHub API (registro de runner, etc.)

## Resultado e UX

- ✅ **Verde**: todos os assertions passaram; o PR pode ser mergeado conforme branch protection (se ativada)
- ❌ **Vermelho**: pelo menos um teste falhou; o output TAP mostra qual `.bats` e qual linha; obrigatório investigar antes do merge
- O workflow não posta comentários no PR — o status aparece apenas no widget "Checks" do GitHub UI

## Como rodar localmente (debug)

Antes de abrir o PR, vale rodar os mesmos testes na sua máquina:

```bash
# Garantir submódulos do bats
git submodule update --init --recursive

# Instalar jq (Debian/Ubuntu)
sudo apt-get install -y jq

# Rodar a suite inteira
./tests/bats/bin/bats tests/unit/

# Ou um arquivo específico
./tests/bats/bin/bats tests/unit/test_generate_secret.bats
```

A saída local não é TAP por padrão (mostra pretty output colorido). Para reproduzir exatamente o que o CI gera:

```bash
./tests/bats/bin/bats --formatter tap tests/unit/
```

## Diferenças vs CD dos produtos

| Aspecto | `test.yml` (assistente) | `cd_imagem_certificada_selfhosted.yml` (produtos) |
|---|---|---|
| Repo | `assistente-siscan-rpa` (público) | `siscan-rpa` / `siscan-dashboard` (privados) |
| Runner | `ubuntu-latest` (GitHub-hosted) | `self-hosted, producao-<produto>` (na VM) |
| Dispara em | PR + push `main` | `workflow_dispatch` + push `main` |
| Jobs | 1 (`bats`) | 3 (`pre-deploy` → `deploy` → `post-deploy`) |
| Tempo médio | ~30s | ~3-5 minutos |
| Acessa infra externa | Não | Sim (GHCR, banco externo, runner registrado) |
| Pode rodar em paralelo | Sim (GitHub gerencia fila) | Não (1 deploy por vez por VM) |

## Veja também

- [`./cd-imagem-certificada-selfhosted.md`](./cd-imagem-certificada-selfhosted.md) — workflow de deploy dos produtos (em repos privados)
- [`../../DEPLOY_SERVER.md`](../../DEPLOY_SERVER.md) — playbook operacional onde o workflow `test.yml` é mencionado como gate de PR
- [bats-core (docs oficiais)](https://bats-core.readthedocs.io/) — framework usado pelos testes
