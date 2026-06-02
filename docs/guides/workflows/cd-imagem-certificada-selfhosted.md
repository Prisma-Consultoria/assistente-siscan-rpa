---
title: "cd_imagem_certificada_selfhosted.yml — Workflow de deploy contínuo"
type: guide
status: aceita
confidencialidade: público
owner: Time DevOps SISCAN
updated: 2026-05-31
versao: "1.1"
related:
  - docs/DEPLOY_SERVER.md
  - docs/guides/siscan-server-setup.md
  - docs/guides/siscan-server-doctor/index.md
  - docs/guides/siscan-runner-recover.md
  - docs/guides/workflows/test.md
tags:
  - workflow
  - cd
  - github-actions
  - self-hosted-runner
  - deploy
tldr: |
  Guia de referência do workflow `cd_imagem_certificada_selfhosted.yml` —
  o pipeline de Continuous Deployment do SISCAN, executado pelos GitHub
  Actions self-hosted runners das VMs de produção dos produtos
  `siscan-rpa` e `siscan-dashboard`. Composto por 3 jobs sequenciais
  (`pre-deploy`, `deploy`, `post-deploy`) que orquestram diagnóstico,
  pull de imagem, recriação da stack via `docker compose` e validação
  de carga. Os arquivos YAML moram nos repositórios privados de cada
  produto; este guia descreve a sequência em prosa para que operadores
  do servidor parceiro (que vêem apenas a saída no GitHub UI) saibam
  o que esperar passo a passo.
---

# `cd_imagem_certificada_selfhosted.yml` — Workflow de deploy contínuo

Pipeline de **Continuous Deployment** do SISCAN. Cada vez que um merge entra em `main` (ou um `workflow_dispatch` manual é acionado), o GitHub Actions dispara este workflow para o **self-hosted runner** da VM correspondente ao produto. O runner puxa a imagem certificada do GHCR e recria a stack Docker em produção.

Este guia é **referência narrativa** dos jobs e steps do pipeline para que operadores do servidor parceiro entendam o que acontece quando disparam o deploy via UI do GitHub. Os arquivos YAML vivem nos repositórios privados dos produtos (`siscan-rpa`, `siscan-dashboard`); aqui descrevemos a sequência sem expor o YAML literal.

> **Onde aparece**: `.github/workflows/cd_imagem_certificada_selfhosted.yml` nos repositórios `Prisma-Consultoria/siscan-rpa` e `Prisma-Consultoria/siscan-dashboard` (ambos privados).
> **Quem dispara**: merge em `main` (automático) ou **Actions → CD → Run workflow** (manual).
> **Onde executa**: na VM de produção correspondente ao produto, via runner self-hosted com label `producao-rpa` ou `producao-dashboard`.

## Visão geral — fluxo dos 3 jobs

```
┌─────────────────────┐    ┌─────────────────────┐    ┌─────────────────────┐
│   pre-deploy        │───▶│      deploy         │───▶│   post-deploy       │
│                     │    │                     │    │                     │
│ • doctor pré-flight │    │ • pull GHCR         │    │ • aguarda containers│
│ • publica artifact  │    │ • atualiza compose  │    │ • doctor pós-deploy │
│   de diagnóstico    │    │ • sobe stack        │    │ • valida carga      │
│                     │    │ • limpa imagens     │    │ • publica relatório │
└─────────────────────┘    └─────────────────────┘    └─────────────────────┘
   `needs: nada`             `needs: pre-deploy`        `needs: deploy`
   se falhar → para           se falhar → post-deploy    relatório roda
                              ainda roda (limpeza)        mesmo com falha
```

Cada job declara `runs-on: [self-hosted, producao-<produto>]` — esse par de labels é o que casa o job com o runner correto. Se o runner estiver offline ou auto-removido, o job fica indefinidamente em `Waiting for a runner` (catalogado em [`../../TROUBLESHOOTING.md`](../../TROUBLESHOOTING.md) — Problemas 6 e 7).

## Job 1 — `pre-deploy`

**Propósito**: validar a saúde da VM **antes** de tocar em qualquer coisa destrutiva. Se a VM não passar no diagnóstico, o deploy aborta sem mudar nada.

> **Padrão pós-F00.05 (mai/2026):** o pre-deploy delega 100% do diagnóstico ao `siscan-server-doctor.sh` + `check-runner-tls.sh` em vez de replicar ~190 linhas de bash inline (estado anterior do `siscan-rpa`). Toda evolução do doctor (specialists novos, `--advisory-strict`, `warning_when_alone`) propaga automaticamente — sem manutenção paralela. Referência canônica em [`templates/cd_imagem_certificada_selfhosted.template.yml`](templates/cd_imagem_certificada_selfhosted.template.yml).

| # | Step | O que faz |
|---|---|---|
| 1 | Coletar diagnóstico pré-deploy | Roda `bash siscan-server-doctor.sh --quiet --json --pre-setup > pre-deploy-diag.json`. O modo `--pre-setup` exclui specialists que dependem de estado pós-instalação (`check-runner` é o próprio runner que está rodando o workflow; `check-stack` validaria a stack atual mas vamos substituí-la; `check-db` precisa do `.env` finalizado). Saída esperada: `7/7 specialists OK`. |
| 2 | Coletar diagnóstico TLS do runner (`--pre-flight`) | Roda `bash scripts/deploy_server/check-runner-tls.sh --pre-flight` (step adicionado pós-F00.05). Em modo human (default), o specialist imprime no log do Actions: variáveis de proxy detectadas (com redação de credenciais), CAs custom em `/usr/local/share/ca-certificates/` e resolução DNS de `api.github.com`. **Coleta best-effort** — não bloqueia o deploy; serve para acelerar diagnóstico humano se um step posterior (`docker login ghcr.io` / `docker pull`) falhar por TLS. Introduzido em [TSK00.04.10](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/pull/93); para diagnóstico completo pós-falha de registro, ver o modo `--reactive` do specialist. |
| 3 | Publicar relatório como artifact | Sempre executa (`if: always()`), mesmo se os steps anteriores falharam. Sobe o JSON de diagnóstico como artifact do workflow run para auditoria (`retention-days: 14`). Disponível em "Actions → run → Summary → Artifacts". |

**Resultado**:
- Se o doctor passar e o TLS pre-flight passar, o job termina com sucesso e libera o `deploy`
- Se algum step falhar, o job termina com erro; o `deploy` não executa (depende de `pre-deploy` via `needs:`); o artifact ainda é publicado para diagnóstico humano

## Job 2 — `deploy`

**Propósito**: executar o deploy propriamente dito — atualizar arquivos de configuração, puxar a nova imagem do GHCR e recriar a stack via `docker compose up -d`.

| # | Step | O que faz |
|---|---|---|
| 1 | Validar `COMPOSE_DIR` | Verifica se a variável `COMPOSE_DIR` está exportada no ambiente do runner (gravada pela Fase 8 do `siscan-server-setup.sh` em `~/actions-runner/.env`). Sem isso, o runner não sabe onde está a stack. |
| 2 | Checkout do repositório | `actions/checkout` busca o código mais recente do repositório do produto (acessa apenas o repositório do próprio produto onde o workflow vive). |
| 3 | Autenticar no GHCR | `docker login ghcr.io` usando o `GITHUB_TOKEN` injetado automaticamente pelo Actions. Necessário para o `docker pull` baixar a imagem certificada. |
| 4 | Atualizar `docker-compose.prd.<produto>.yml` | Copia a versão mais recente do compose file do checkout para o `$COMPOSE_DIR`. Resolve o cenário "operador editou o compose manualmente" — o workflow sempre prevalece. Detalhes do fluxo de propriedade (1 fonte canônica, 2 propagações) em [`../../DEPLOY_SERVER.md`](../../DEPLOY_SERVER.md#fluxo-do-compose-file-de-produção). |
| 5 | Atualizar `.env.server-<produto>.sample` | Mesma lógica do step 4 para o sample. **Não toca no `.env` real** — esse permanece com os valores que o operador preencheu na Fase 5 do setup. |
| 6 | _(siscan-rpa apenas)_ Atualizar `backup_manager.sh` | Copia o script `scripts/clients/backup_manager.sh` para o `$COMPOSE_DIR/scripts/`. Disponibiliza a versão mais recente da ferramenta de backup. |
| 7 | ~~_(siscan-rpa apenas)_ Garantir `HOST_SECRETS_DIR` e `HOST_BACKUPS_DIR`~~ **REMOVIDO** | **Removido pós-F00.05** (TSK00.05.01 [#95](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/issues/95)): a derivação foi movida para `siscan-server-setup.sh` Fase 5 via schema v2.0 do `products.json` (`host_dir_vars[]` aceita objetos com `derived_from`/`derivation`/`default_mode`/`auto_create`). Workflows agora **confiam** que o `.env` já tem essas variáveis populadas. Workflows antigos do siscan-rpa removem esse step na T1 do refactor cross-repo ([#694](https://github.com/Prisma-Consultoria/siscan-rpa/issues/694)). |
| 8 | Pull das novas imagens | `docker compose -f docker-compose.prd.<produto>.yml pull` baixa as imagens declaradas no compose. A imagem certificada do GHCR já está em cache local após o primeiro deploy; daí em diante o pull verifica apenas digest novo. |
| 9 | Parar stacks órfãs com nome de projeto diferente | Detecta containers com label `com.docker.compose.project=<produto-antigo>` (resíduo de renomeações como `siscan_rpa-rpa` → `siscan-rpa-rpa`) e os derruba via `docker compose down`. Evita conflito de portas e bind mounts. |
| 10 | Subir stack atualizada | `docker compose -f docker-compose.prd.<produto>.yml up -d --remove-orphans`. Recria containers que tiveram imagem nova; mantém volumes; remove containers que não estão mais no compose. |
| 11 | Status da stack (`if: always()`) | Imprime `docker compose ps` no log do step. Roda mesmo se o `up -d` falhou — ajuda a entender o estado pós-mortem. |
| 12 | Resumo do deploy (`if: always()`) | Monta um sumário Markdown no `$GITHUB_STEP_SUMMARY` com versão da imagem, hash do commit, tempo de execução. |
| 13 | Limpar imagens Docker antigas (`if: always()`) | `docker image prune -f` para liberar disco. Não toca em imagens em uso (containers running). |

**Resultado**:
- ✅ Se tudo passar, o job termina com sucesso e libera o `post-deploy`
- ❌ Se algum step falhar antes de "Status da stack", os steps marcados `if: always()` ainda rodam (status + resumo + limpeza), garantindo logs para diagnóstico. O `post-deploy` ainda assim é tentado (depende apenas de `deploy` ter rodado, não de ter sucedido)

## Job 3 — `post-deploy`

**Propósito**: validar que a stack subiu saudável e fazer ajustes finais que dependem do banco já estar acessível (migrations aplicadas, dados de bootstrap).

> **Padrão pós-F00.05 (mai/2026):** o post-deploy delega o gate principal (`check-stack`) ao doctor em vez de replicar lógica de polling/healthcheck em bash inline (~150 linhas a menos por consumer). Os steps específicos por produto (SISCAN auth no RPA; bootstrap admin + verificação MVP no dashboard) permanecem — são lógica de aplicação, não diagnóstico.

| # | Step | O que faz |
|---|---|---|
| 1 | Aguardar estabilização dos containers | Polling curto pelos services declarados em `COMPOSE_SERVICES` (template TSK00.05.03) com timeout de ~90s. Dá tempo das migrations rodarem, dos workers do Gunicorn subirem e dos containers reportarem `running`. |
| 2 | Diagnóstico pós-deploy (`--only check-stack`) | Roda `bash siscan-server-doctor.sh --quiet --json --only check-stack > post-deploy-stack.json`. Delegação reduz o post-deploy de ~150 linhas inline para uma chamada. Para diagnóstico completo (10/10 specialists), o operador pode rodar manualmente `bash siscan-server-doctor.sh` na VM — útil para troubleshooting pós-mortem. |
| 3 | _(siscan-rpa)_ Verificar carga inicial (`if: always()`) | Bate em `http://localhost:5001/health` e valida `schema_status: current`. Confirma que as migrations Alembic rodaram. |
| 4 | _(siscan-dashboard)_ Aplicar CPF + senha do `system_admin` via secrets (`if: always()`) | Lê CPF e senha de [GitHub secrets do repositório](https://docs.github.com/actions/security-guides/encrypted-secrets) e cria/atualiza o usuário admin via comando da aplicação. Necessário para o primeiro acesso ao dashboard com identidade real (substitui o `ADMIN_PASSWORD` literal do `.env` que era temporário). |
| 5 | _(siscan-dashboard, temporário)_ Verificação MVP gestão de usuários (`if: always()`) | Step transitório validando o fluxo de gestão de usuários (mvp em construção). Será removido quando a feature estabilizar. |
| 6 | _(siscan-dashboard, temporário)_ Mirror relatório no `STEP_SUMMARY` (`if: always()`) | Espelha o relatório do step 5 no sumário do run para visibilidade no GitHub UI. |
| 7 | _(siscan-dashboard, temporário)_ Comentário no commit em caso de warning ou falha (`if: always()`) | Posta um comentário no commit que disparou o workflow, alertando o autor caso a verificação MVP tenha encontrado problemas. |
| 8 | Publicar relatório pós-deploy (`if: always()`) | Sobe o JSON de diagnóstico pós-deploy como artifact. Comparação com o artifact pré-deploy ajuda a detectar regressões introduzidas pelo deploy. |

**Resultado**:
- ✅ Se todos os checks passarem, deploy é considerado bem-sucedido. O ciclo termina.
- ⚠️ Se `check-resources` falhar (RAM < 8 GB), o run aparece como ✅ funcionalmente mas com warn — não bloqueia o sucesso operacional.
- ❌ Se `check-stack` ou `check-db` falharem (stack não subiu, banco inacessível), o run termina como falha e o operador precisa investigar com base nos artifacts publicados.

## Variáveis e secrets consumidos

| Tipo | Nome | Função |
|---|---|---|
| Env (`COMPOSE_DIR`) | exportada pelo `~/actions-runner/.env` | Local da stack do produto na VM |
| Secret (Actions) | `GITHUB_TOKEN` | Auto-injetado pelo Actions; usado no `docker login ghcr.io` |
| _(dashboard)_ Secret | `SYSTEM_ADMIN_CPF` | CPF do admin operacional do dashboard |
| _(dashboard)_ Secret | `SYSTEM_ADMIN_PASSWORD` | Senha do admin operacional do dashboard |

Variáveis lidas do `.env` da VM (não do workflow):
- `DATABASE_HOST`, `DATABASE_PASSWORD`, `RPA_DATABASE_URL`, `HOST_*_DIR`, `REDIS_HOST`, `REDIS_PORT`, etc.

## Diferenças entre RPA e Dashboard

| Aspecto | siscan-rpa | siscan-dashboard |
|---|---|---|
| Label do runner | `producao-rpa` | `producao-dashboard` |
| Compose file atualizado | `docker-compose.prd.rpa.yml` | `docker-compose.prd.dashboard.yml` |
| Sample atualizado | `.env.server-rpa.sample` | `.env.server-dashboard.sample` |
| Scripts auxiliares | `backup_manager.sh` copiado | — |
| Diretórios garantidos | ~~`HOST_SECRETS_DIR`, `HOST_BACKUPS_DIR`~~ — derivados pelo setup Fase 5 (TSK00.05.01) | — |
| Carga inicial verificada | `http://localhost:5001/health` (`schema_status`) | Via gestão MVP de usuários (step temporário) |
| Secrets adicionais | — | `SYSTEM_ADMIN_CPF`, `SYSTEM_ADMIN_PASSWORD` |

## Como o operador interage com o workflow

O operador do servidor parceiro **não edita o YAML** (está em repo privado). Os pontos de contato são:

1. **Disparar manualmente**: `Actions → CD → Run workflow` no GitHub UI do produto
2. **Acompanhar a execução**: clicar no run em curso para ver os steps em tempo real
3. **Baixar artifacts**: ao final de cada run, os relatórios de diagnóstico pré e pós-deploy ficam disponíveis em "Artifacts"
4. **Tratar falhas**: cada step falho tem log; o operador copia o output e consulta [`../../TROUBLESHOOTING.md`](../../TROUBLESHOOTING.md) ou compartilha com o time de DevOps

## Como o assistente está envolvido no workflow

Tudo o que o workflow precisa ter na VM antes do primeiro run é provisionado pelo `siscan-server-setup.sh` (ver [`../siscan-server-setup.md`](../siscan-server-setup.md)):

- O **runner** (Fase 7) — quem efetivamente executa os steps
- `$COMPOSE_DIR` exportado em `~/actions-runner/.env` (Fase 8) — onde a stack mora
- Diretórios `HOST_*` criados (Fase 6) — bind mounts dos containers
- `.env` da VM preenchido (Fase 5) — variáveis runtime

Os 3 jobs do workflow consomem `siscan-server-doctor.sh` (`pre-deploy` step 1 e `post-deploy` step 2) como **gate de qualidade**, espelhando o gate da Fase 0 do setup. O `pre-deploy` também consome `check-runner-tls.sh` (step 2) — único specialist do doctor com modo `--pre-flight` específico.

> **Estado dos workflows externos (em 2026-05-31):** este guia descreve o **padrão alvo pós-F00.05**. Os workflows reais em `Prisma-Consultoria/siscan-rpa` (refactor em [#693](https://github.com/Prisma-Consultoria/siscan-rpa/issues/693)) e `Prisma-Consultoria/siscan-dashboard` (refactor em [#524](https://github.com/Prisma-Consultoria/siscan-dashboard/issues/524)) estão sendo migrados em PRs separados; até o merge, podem ainda usar bash inline. A fonte canônica do **padrão consolidado** é o template em [`templates/cd_imagem_certificada_selfhosted.template.yml`](templates/cd_imagem_certificada_selfhosted.template.yml). Quando T1/T2 dos consumers forem mergeados, este guia será revisado para refletir status final.

## Solução de problemas

Sintomas observáveis durante o workflow estão catalogados em [`../../TROUBLESHOOTING.md`](../../TROUBLESHOOTING.md):

- **Job preso em `Waiting for a runner` indefinidamente** → Problemas 6 e 7 (runner offline ou auto-removed); ação: [`../siscan-runner-recover.md`](../siscan-runner-recover.md)
- **Step "Autenticar no GHCR" falha** → Problema A (token vencido); regenerar PAT
- **Step "Subir stack atualizada" falha com `bind: address already in use`** → Problema 11 (porta em uso)
- **Step "Pull das novas imagens" falha com timeout** → Problema D (rede instável)
- **Container em restart loop após `post-deploy`** → registro interno (jinja2 ausente, `RPA_DATABASE_URL` malformada — ver `ERRORS_TABLE.md`)

Para sequência operacional do deploy completo (do clone à primeira execução do workflow), ver [`../../DEPLOY_SERVER.md`](../../DEPLOY_SERVER.md).

## Adoção em produto novo — templates canônicos

> **Adicionado em 2026-05-29 (TSK00.05.03 [#97](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/issues/97)):** quando um parceiro novo adotar o assistente, o workflow CD não deve ser copiado/colado de um repo existente — use os **templates parametrizados** em [`templates/`](templates/README.md). Eles são a **fonte canônica** do padrão consolidado pós-F00.05 (delegação ao doctor + check-runner-tls, HOST_*_DIR derivados pelo setup), com placeholders explícitos para customização.

Fluxo resumido:

```bash
cp docs/guides/workflows/templates/cd_imagem_certificada_selfhosted.template.yml \
   /path/to/PRODUCT_REPO/.github/workflows/cd_imagem_certificada_selfhosted.yml
# substituir 6 placeholders via sed (PRODUCT_NAME, RUNNER_LABEL, ...)
```

Guia completo: [`templates/README.md`](templates/README.md) — placeholders, decisões arquiteturais incorporadas, Apêndice "como adaptar a outro parceiro".

## Veja também

- [`./test.md`](./test.md) — workflow de testes unitários do próprio assistente (`test.yml`, repo público)
- [`./templates/README.md`](./templates/README.md) — **fonte canônica** dos workflows parametrizados (adoção em produto novo)
- [`../siscan-server-setup.md`](../siscan-server-setup.md) — provisionamento inicial da VM
- [`../siscan-server-doctor/index.md`](../siscan-server-doctor/index.md) — diagnóstico usado pelo `pre-deploy` e `post-deploy`
- [`../siscan-runner-recover.md`](../siscan-runner-recover.md) — recuperação do runner quando o workflow trava
- [`../../DEPLOY_SERVER.md`](../../DEPLOY_SERVER.md) — playbook operacional do deploy
- [`../../TROUBLESHOOTING.md`](../../TROUBLESHOOTING.md) — sintomas observados em workflows reais
- [`../../ERRORS_TABLE.md`](../../ERRORS_TABLE.md) — incidentes históricos durante deploys
- [GitHub Actions self-hosted runners (docs oficiais)](https://docs.github.com/actions/hosting-your-own-runners/managing-self-hosted-runners/about-self-hosted-runners)
