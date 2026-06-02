---
title: Templates de workflows CI/CD — fonte canônica multi-parceiro
type: guide
status: aceita
confidencialidade: público
owner: Time DevOps SISCAN
updated: 2026-05-29
versao: "1.0"
related:
  - docs/guides/workflows/cd-imagem-certificada-selfhosted.md
  - docs/DEPLOY_SERVER.md
  - docs/guides/siscan-server-doctor/index.md
  - docs/guides/siscan-server-setup.md
tags:
  - workflow
  - template
  - cd
  - ci
  - github-actions
  - multi-parceiro
tldr: |
  Templates parametrizados dos workflows CI/CD do SISCAN, reutilizáveis para
  qualquer produto/parceiro que adote o assistente. Encapsulam o padrão
  consolidado pós-F00.05 (pre-deploy/deploy/post-deploy delegando ao
  siscan-server-doctor + check-runner-tls em vez de bash inline). Adoção
  via `cp` + `sed` em ~5 placeholders. Documenta as decisões arquiteturais
  para que evoluções do doctor (specialists novos, advisory-strict)
  propaguem aos workflows sem manutenção paralela.
---

# Templates de workflows CI/CD — fonte canônica multi-parceiro

Esta pasta é a **fonte canônica** do padrão CI/CD do assistente SISCAN. Sempre que um novo produto/parceiro adotar o assistente, comece por estes templates em vez de copiar/colar de um repositório existente.

> **Por que templates?** Auditoria de 2026-05-29 (feature [F00.05 #94](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/issues/94)) revelou ~530 linhas de bash inline duplicadas entre `siscan-rpa` e `siscan-dashboard` reescrevendo dimensões já cobertas pelos 10 specialists do doctor. Templates centralizam o padrão, permitindo que melhorias do ferramental do assistente (novos specialists, `--advisory-strict`, `warning_when_alone`) propaguem automaticamente aos workflows externos.

## Arquivos

| Arquivo | Para que serve |
|---|---|
| [`cd_imagem_certificada_selfhosted.template.yml`](cd_imagem_certificada_selfhosted.template.yml) | Workflow de Continuous Deployment com self-hosted runner — pre-deploy/deploy/post-deploy. |
| [`docker_build.template.yml`](docker_build.template.yml) | Workflow de build + push da imagem certificada no GHCR. |

## Fluxo de adoção (5 passos)

### 1. Copiar para o repositório do produto

```bash
# A partir do clone do assistente
cp docs/guides/workflows/templates/cd_imagem_certificada_selfhosted.template.yml \
   /path/to/PRODUCT_REPO/.github/workflows/cd_imagem_certificada_selfhosted.yml

cp docs/guides/workflows/templates/docker_build.template.yml \
   /path/to/PRODUCT_REPO/.github/workflows/docker_build.yml
```

### 2. Substituir placeholders via `sed`

```bash
cd /path/to/PRODUCT_REPO
sed -i \
  -e 's/{{ PRODUCT_NAME }}/rpa/g' \
  -e 's/{{ RUNNER_LABEL }}/producao-rpa/g' \
  -e 's/{{ COMPOSE_FILE_NAME }}/docker-compose.prd.rpa.yml/g' \
  -e 's/{{ ENV_SAMPLE_NAME }}/.env.server-rpa.sample/g' \
  -e 's/{{ COMPOSE_SERVICES }}/migrate app rpa-scheduler/g' \
  -e 's|{{ STACK_HEALTH_URL }}|http://localhost:5001/health|g' \
  -e 's|{{ DOCKERFILE_PATH }}|Dockerfile|g' \
  -e 's|{{ IMAGE_NAME }}|siscan-rpa-rpa|g' \
  .github/workflows/cd_imagem_certificada_selfhosted.yml \
  .github/workflows/docker_build.yml
```

### 3. Adaptar steps específicos do produto

No `cd_imagem_certificada_selfhosted.yml` (gerado), descomente e ajuste os blocos comentados sob `# ─── Steps específicos do produto ───` em cada job. Exemplos típicos:

- **siscan-rpa**: atualização do `backup_manager.sh`, validação da autenticação SISCAN no post-deploy.
- **siscan-dashboard**: validação do Redis no post-deploy (`redis-cli ping`).

### 4. Validar localmente

```bash
# Sintaxe YAML
yamllint .github/workflows/cd_imagem_certificada_selfhosted.yml

# Estrutura GitHub Actions
actionlint .github/workflows/cd_imagem_certificada_selfhosted.yml
actionlint .github/workflows/docker_build.yml
```

### 5. Commit + PR

Mensagem de commit sugerida:

```text
chore(ci): adotar templates canônicos do assistente (CD + build)

Substitui workflows ad-hoc por templates parametrizados de
assistente-siscan-rpa/docs/guides/workflows/templates/ — pre-deploy
delega ao siscan-server-doctor (-N linhas de bash inline), HOST_*_DIR
derivados pelo setup (TSK00.05.01 #95), runner-TLS validado via
specialist dedicado.
```

## Placeholders de referência

| Placeholder | Tipo | Significado | Exemplos atuais |
|---|---|---|---|
| `{{ PRODUCT_NAME }}` | string | ID do produto no manifesto `scripts/data/products.json` do assistente. | `rpa`, `dashboard`, `full` |
| `{{ RUNNER_LABEL }}` | string | Label do self-hosted runner registrado no GitHub (Fase 7 do setup). | `producao-rpa`, `producao-dashboard` |
| `{{ COMPOSE_FILE_NAME }}` | string | Nome do compose file de produção (mora no repo do produto, sobrescreve a cada deploy — ver [fluxo de propriedade](../../../DEPLOY_SERVER.md#fluxo-do-compose-file-de-produção)). | `docker-compose.prd.rpa.yml` |
| `{{ ENV_SAMPLE_NAME }}` | string | Nome do sample do `.env` (também mora no repo do produto). | `.env.server-rpa.sample` |
| `{{ COMPOSE_SERVICES }}` | string (lista separada por espaço) | Services do compose que devem estar `running` no post-deploy. Idealmente sincronizado com `expected_services` do manifesto. | `migrate app rpa-scheduler`, `app sync redis` |
| `{{ STACK_HEALTH_URL }}` | string | URL do health check da aplicação (validada no post-deploy com timeout de 60s). | `http://localhost:5001/health`, `http://localhost:5000/health` |
| `{{ DOCKERFILE_PATH }}` | string | Caminho do Dockerfile (relativo à raiz do repo do produto). | `Dockerfile`, `docker/Dockerfile.prod` |
| `{{ IMAGE_NAME }}` | string | Nome da imagem no GHCR (sem `ghcr.io/<owner>/` — esse prefixo é montado dinamicamente). | `siscan-rpa-rpa`, `siscan-dashboard` |

## Pré-requisitos do assistente na VM

Antes do primeiro deploy via este workflow, a VM precisa ter:

- [x] `siscan-server-setup.sh --product <PRODUCT_NAME>` executado com sucesso (Fase 10 alcançada).
- [x] Runner registrado com label `<RUNNER_LABEL>` (Fase 7 do setup).
- [x] `COMPOSE_DIR` exportado em `~/actions-runner/.env` (Fase 8 do setup).
- [x] `.env` com `DATABASE_HOST` apontando para o PostgreSQL externo (Fase 5).
- [x] `HOST_*_DIR` declarados no `.env`, incluindo `HOST_SECRETS_DIR` + `HOST_BACKUPS_DIR` derivados pela Fase 5 ([TSK00.05.01 #95](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/issues/95)).
- [x] Doctor passa: `bash siscan-server-doctor.sh` → `10/10 specialists OK`.

## Decisões arquiteturais incorporadas

| Decisão | Origem | Como aparece no template |
|---|---|---|
| Delegar diagnóstico ao `siscan-server-doctor.sh` | Auditoria F00.05 #94 (~530 linhas de duplicação detectadas) | Pre-deploy roda `doctor --quiet --json --pre-setup`; post-deploy roda `doctor --only check-stack`. |
| Validação dedicada de runner TLS | TSK00.04.10 #88 ([PR #93](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/pull/93)) | Pre-deploy step `Validar runner TLS (pré-flight)` chama `check-runner-tls.sh --pre-flight`. |
| Setup deriva HOST_SECRETS_DIR / HOST_BACKUPS_DIR | TSK00.05.01 #95 | Workflow NÃO replica derivação inline; assume `.env` já populado pelo setup. |
| Limpeza de stacks órfãs | Incidente histórico de rename `siscan_rpa-rpa` → `siscan-rpa-rpa` | Step "Parar stacks órfãs" detecta containers com `com.docker.compose.project != siscan-<PRODUCT_NAME>` e os derruba. |
| Artifacts de diagnóstico com retention 14d | Compromisso operacional (registros sobreviventes a debug pós-mortem) | `actions/upload-artifact@v4` com `retention-days: 14` no pre-deploy e post-deploy. |
| `if: always()` em status + cleanup | Lições do CD existente | Steps de status/resumo/cleanup rodam mesmo com falha — preserva logs. |

## Apêndice — como adaptar a outro parceiro

Idêntico ao padrão estabelecido pelo Apêndice A do documento técnico interno de whitelist (registro interno do projeto).

Passos:

1. **Confirmar manifesto**: o produto novo precisa estar em `scripts/data/products.json` do assistente. Se ainda não estiver, adicionar entrada antes de adotar este template — o `siscan-server-doctor.sh` precisa conhecer o produto para validar.
2. **Confirmar registro DNS / firewall**: o GitHub Actions precisa conseguir entregar jobs ao runner self-hosted da VM do parceiro. Validação prévia: `bash scripts/deploy_server/check-network.sh` (specialist dedicado, cobre os 22 endpoints incluindo Actions, GHCR, OCSP/CRL).
3. **Provisionar VM**: `siscan-server-setup.sh --product <PRODUCT_NAME>` na VM (registra runner, configura `.env`, deriva HOST_*_DIR).
4. **Substituir placeholders**: passo 2 deste guia (sed/editor).
5. **Validar localmente**: `actionlint` + `yamllint`.
6. **Push + acionar primeiro deploy**: `workflow_dispatch` na UI do GitHub (mais seguro que aguardar primeiro merge — facilita debug).
7. **Observar artifacts**: o pre-deploy publica `pre-deploy-diag.json` mesmo em caso de falha — primeira linha de diagnóstico se o doctor reprovar.

## Ver também

- [`../cd-imagem-certificada-selfhosted.md`](../cd-imagem-certificada-selfhosted.md) — guia em prosa do workflow CD (referência para operadores das VMs).
- [`../../../DEPLOY_SERVER.md`](../../../DEPLOY_SERVER.md) — guia narrativo do deploy em modo servidor (3 VMs, fluxo do compose, runner self-hosted).
- [`../../siscan-server-doctor/index.md`](../../siscan-server-doctor/index.md) — entry point dos 10 specialists do doctor (cada um delegável dos workflows).
- [`../../siscan-server-setup.md`](../../siscan-server-setup.md) — guia operacional do setup (Fase 5 derivação de HOST_*_DIR).
- [Feature F00.05 #94](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/issues/94) — coordenação cross-repo dos refactors externos.
