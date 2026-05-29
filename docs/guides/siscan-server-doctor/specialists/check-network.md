# `check-network` — Specialist de Diagnóstico

Specialist do `siscan-server-doctor.sh` responsável por validar a conectividade de saída de uma VM com todos os endpoints externos exigidos pelos runners self-hosted do GitHub Actions, pelo pull de imagens (GHCR), pelo pull do Redis (Docker Hub) e pela validação OCSP/CRL dos certificados.

Para entender **quando** rodar diagnósticos no ciclo de vida de uma VM, consulte o guia narrativo em [`../../DEPLOY_SERVER.md`](../../DEPLOY_SERVER.md). Este documento é a referência precisa do specialist `check-network`: opções, exit codes, formato de entrada e saída.

## Histórico de mudanças

| Versão | Data | Mudança |
|---|---|---|
| 1.4 | 2026-05-28 | Nova categoria `runner_actions_regional_variants` no `network-endpoints.json` (12 variantes regionais conhecidas: `pipelinesghub<region>*`, `results-receiverghub<region>*`, `productionresultssa<N>`) com flag `"advisory": true`. Specialist tratou advisory como `SKIPPED` em vez de `FAIL`: variantes bloqueadas NÃO contam no exit code do specialist (não quebram pre-flight) — saída fica visível como insumo para solicitação ÚNICA e COMPLETA ao time de segurança em vez de rodadas iterativas. Refatoração mínima em `check-network.sh`: `_check_https`/`_check_tcp` ganham 5º arg opcional `advisory`; loop principal lê `categories[i].advisory` e propaga. Ver [issue #88](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/issues/88). Subseção operacional "*Mapeamento de variantes regionais para solicitação de firewall*" adicionada abaixo. **Decisão arquitetural**: single source of truth em `network-endpoints.json` (evita arquivo paralelo que pode envelhecer); categoria advisory cria a separação de comportamento sem fragmentar o catálogo. |
| 1.3 | 2026-05-28 | `guidance.on_any_fail` da categoria *Runner ↔ GitHub Actions* explicita **wildcard `*.actions.githubusercontent.com`** como recomendação primária no pedido à TI. Motivação: lab 2026-05-28 revelou que `pipelinesghubeus6.actions.githubusercontent.com` (variante regional) ficou bloqueada mesmo com o endpoint base `pipelines.actions.githubusercontent.com` já liberado — o backend do GitHub Actions roteia dinamicamente para variantes regionais (`pipelinesghub<region>*`, `results-receiverghub<region>*`) que não são cobertas por whitelist literal do base. Ver [ERRORS_TABLE F38](../../../../docs/ERRORS_TABLE.md) e [issue #84](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/issues/84). Mesma cobertura de teste (22 endpoints) — só guidance e documentação. Diagnóstico **reativo** complementar via `runner_diagnose_tls_failure` em [issue #82](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/issues/82) (extrai URL específico do `_diag/` log quando recover falha). |
| 1.2 | 2026-05-25 | UX: header explicativo de escopo (validação de firewall) + reescrita por linha como "código esperado · porquê" + guidance por categoria com próximo passo concreto. |
| 1.1 | 2026-05-25 | Refatorado para usar `_common.sh` (cores, helpers, renderização compartilhados entre specialists). Mesma cobertura (22 endpoints). |
| 1.0 | 2026-05-25 | Versão inicial — 22 endpoints (<chamado-firewall> v2.0 + GitHub docs *self-hosted-runners#communication*). Automatiza o item *Conectividade HTTPS* da tabela de pré-requisitos do `DEPLOY_SERVER.md`, que antes era um `curl -Iv https://github.com` manual. |

## Origem e relação com outros scripts

Este specialist **não é uma refatoração de código** do `siscan-server-setup.sh` — nenhuma das 10 fases do setup tinha verificação de rede. O que se migrou foi o item *Conectividade HTTPS* da **tabela de pré-requisitos** em [`../../DEPLOY_SERVER.md`](../../DEPLOY_SERVER.md), que era um comando manual (`curl -Iv https://github.com`, cobrindo 1 endpoint) — agora se torna um specialist automatizado cobrindo 22 endpoints, categorizados por finalidade, com saída estruturada e exit codes para uso em cron.

A relação com os outros scripts da feature [#28](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/issues/28) é de **complementaridade**, não de extração:

| Script | Quando entra | Relação com check-network |
|---|---|---|
| `siscan-server-doctor.sh` (orquestrador) | Sempre, como entry point de diagnóstico | Invoca este specialist como parte do diagnóstico amplo |
| `siscan-server-setup.sh` | Instalação inicial de uma VM | A Fase 1 atual valida binários locais mas **não** testa rede. O issue [#30](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/issues/30) prevê que a Fase 1 passe a invocar o doctor (incluindo este specialist). |
| `siscan-runner-recover.sh` | Recuperação de runner auto-removido ou >30 dias offline | Vai chamar este specialist como pré-condição antes de tentar re-registrar (issue [#31](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/issues/31)). |

## Sinopse

```bash
# Standalone
bash scripts/deploy_server/check-network.sh [--quiet | --json] [--timeout SEC] [--endpoints-file FILE]
bash scripts/deploy_server/check-network.sh --help

# Via orquestrador (recomendado para diagnóstico amplo)
bash siscan-server-doctor.sh --only check-network
```

## Opções

| Opção | Padrão | Descrição |
|---|---|---|
| `--quiet` | — | Suprime a saída legível e imprime somente linhas `FAIL`. Útil em cron de monitoramento. |
| `--json` | — | Saída estruturada em JSON. Útil para integração com ferramentas. |
| `--timeout SEC` | `10` | Timeout (em segundos) por check individual. Aumente em redes lentas. |
| `--endpoints-file FILE` | `scripts/data/network-endpoints.json` | Override do arquivo de endpoints. Permite testar listas customizadas. |
| `-h`, `--help` | — | Exibe ajuda e sai com `0`. |

## Exit codes

| Código | Significado | Ação sugerida |
|---|---|---|
| `0` | Todos os endpoints alcançáveis | Prosseguir com setup / deploy |
| `1` | Pelo menos um FAIL | Consulte [`../../TROUBLESHOOTING.md`](../../TROUBLESHOOTING.md#problema-d--falha-no-pull-por-rede-instável--firewall) ou abra requisição de reabertura de firewall (para VMs do servidor parceiro, referenciar requisição **753315**) |
| `2` | Uso inválido, dependência ausente ou JSON inválido | Verificar mensagem de erro no stderr |

## Critério de aceitação

Conforme seção 11.4 do PDF *Reativação de whitelist v2.0* (<chamado-firewall>):

> **Qualquer resposta HTTP do servidor (200, 301, 302, 400, 403, 404, 405, ...) indica que o TLS subiu** — esse é o critério de sucesso para os checks HTTPS/443.

Apenas `000` (sem resposta — curl não conseguiu sequer abrir o socket TLS ou foi cortado pela rede) ou timeout indicam bloqueio de firewall.

Para os checks TCP/80 (OCSP/CRL), basta o socket abrir; nenhum byte é trocado.

## Dependências

| Ferramenta | Por quê | Instalação |
|---|---|---|
| `curl` | Checks HTTPS | `sudo apt install -y curl` |
| `jq` | Parsing do `network-endpoints.json` | `sudo apt install -y jq` |
| `bash` ≥ 4 | Redirecionamento `/dev/tcp` para checks TCP | já presente no Ubuntu |
| `timeout` | Limita o tempo de cada check TCP | já presente (coreutils) |

Não exige root.

## Fonte de verdade dos FQDNs

A lista verificada vive em [`../../../scripts/data/network-endpoints.json`](../../../scripts/data/network-endpoints.json) e combina duas fontes:

1. Documento **Reativação de whitelist — VMs siscan-dashboard e siscan-rpa v2.0** (chamado interno de firewall), seções 3 a 7.
2. [Referência oficial atual do GitHub](https://docs.github.com/en/actions/reference/runners/self-hosted-runners#communication) — seção *Communication*.

Para atualizar a lista, edite o JSON diretamente. O schema é:

```json
{
  "version": "1.0",
  "sources": [...],
  "categories": [
    {
      "id": "runner_actions",
      "label": "Runner ↔ GitHub Actions (HTTPS/443)",
      "pdf_sections": ["3.1", "3.2"],
      "endpoints": [
        { "fqdn": "github.com", "protocol": "https", "port": 443, "purpose": "..." },
        { "fqdn": "pipelines.actions.githubusercontent.com", "protocol": "https", "port": 443,
          "purpose": "...", "wildcard_for": "*.actions.githubusercontent.com" }
      ]
    }
  ]
}
```

Cada `endpoint` requer `fqdn`, `protocol` (`https` ou `tcp`) e `port`. O campo `purpose` é informativo (não consumido pelo script, mas exibido em renderização de docs). O campo opcional `wildcard_for` documenta quando um FQDN concreto está sendo testado como representante de um wildcard liberado no firewall.

### Cobertura atual (22 endpoints)

| Categoria | HTTPS/443 | TCP/80 | Total |
|---|---:|---:|---:|
| Runner ↔ GitHub Actions | 7 | — | 7 |
| Self-update do runner | 4 | — | 4 |
| GHCR (pull de imagem) | 3 | — | 3 |
| Docker Hub (pull do Redis) | 3 | — | 3 |
| OCSP/CRL (DigiCert + Sectigo) | — | 5 | 5 |
| **Total** | **17** | **5** | **22** |

### Wildcards substituídos

| Wildcard do firewall | FQDN concreto testado |
|---|---|
| `*.actions.githubusercontent.com` | `pipelines.actions.githubusercontent.com` |
| `*.blob.core.windows.net` | `productionresultssa0.blob.core.windows.net` |
| `*.pkg.github.com` | `npm.pkg.github.com` |

Se o firewall liberou o wildcard inteiro, qualquer subdomínio responde. Se liberou apenas FQDNs literais, o teste denuncia o gap corretamente.

### Fora de escopo

A seção 8 do PDF (SMTP e Keycloak/OIDC) e a seção 9 (Postgres 5432 via VLAN interna) **não são verificadas** por este specialist:

- Seção 8: depende de features opt-in via `.env` (`EMAIL_ENABLED=true`, OIDC reativado) — escopo do `check-env` specialist.
- Seção 9: tráfego interno de VLAN — escopo do `check-db` specialist (TCP/5432 + `pg_isready`).

## Exemplos

### Validação pré-deploy

```bash
bash scripts/deploy_server/check-network.sh && echo "Rede OK, posso rodar siscan-server-setup.sh"
```

### Mapeamento de variantes regionais para solicitação de firewall

**Quando aparece**: o pre-flight regular passa as 22 obrigatórias mas o `runner_register` falha com `The SSL connection could not be established`. Sintoma característico de **variante regional bloqueada**: o whitelist do firewall corporativo cobre o endpoint base (`pipelines.actions.githubusercontent.com`) mas não as variantes regionais (`pipelinesghub<region>*.actions.githubusercontent.com`, `results-receiverghub<region>*`, etc.) que o backend do GitHub Actions roteia dinamicamente.

A v1.4 do specialist trouxe a categoria `runner_actions_regional_variants` ao `network-endpoints.json` com flag `"advisory": true` — uma execução normal do `check-network` JÁ inclui o mapeamento dessas variantes na saída, **sem afetar** o exit code:

```bash
bash scripts/deploy_server/check-network.sh
```

Saída típica em VM com whitelist estreita (somente endpoint base liberado):

```
=== Variantes regionais — mapeamento para solicitação de firewall (advisory) ===
  ⊘  pipelinesghubeus6.actions.githubusercontent.com        firewall bloqueou — advisory
  ✔  pipelinesghubwestus.actions.githubusercontent.com      400 esperado
  ...
=== Resumo (check-network) ===
  29/34 OK · 5 SKIPPED
```

`SKIPPED` (em vez de `FAIL`) na categoria advisory garante que essas falhas **não bloqueiam** o pre-flight do doctor — são informativas para construção do pedido à TI. Variantes que voltarem como `SKIPPED` (HTTP=000) devem ser todas listadas na solicitação ao time de segurança; idealmente pedir **wildcard** `*.actions.githubusercontent.com` (e `*.blob.core.windows.net` se Azure Blob estiver bloqueado) numa única rodada.

Origem operacional: [TSK00.04.09 #88](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/issues/88), motivada pelo lab #259 (28/05/2026) onde `pipelinesghubeus6.actions.githubusercontent.com` ficou bloqueada mesmo após a base liberada (req 767679, 26/05). Decisão arquitetural: usar categoria advisory dentro do `network-endpoints.json` (single source of truth) em vez de arquivo paralelo, evitando risco de drift entre catálogos.

### v1.5 — flag `--advisory-strict` + `warning_when_alone` + alinhamento doc oficial GitHub

**TSK00.04.11 ([#90](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/issues/90))** complementa a v1.4 adicionando:

1. **Flag opt-in `--advisory-strict`** — categorias advisory contam como `FAIL` (bloqueante, exit 1) em vez de `SKIPPED` (não-bloqueante). Útil em CI/CD ou pipeline de provisionamento que **requer** wildcard liberado antes de prosseguir.

   ```bash
   # Default (TSK00.04.09 mantida): advisory = warning, exit 0 mesmo com SKIPPEDs
   bash check-network.sh

   # Strict opt-in (TSK00.04.11): advisory = bloqueante, exit 1 se variantes regionais falharem
   bash check-network.sh --advisory-strict
   ```

   **Variante A da decisão #90** — sem prompt interativo (operador ignora prompt e perde o teste); flag CLI com default seguro (warning). Setup/recover **não passam** `--advisory-strict` por padrão (mantêm compat com TSK00.04.09). Veja [#90 issuecomment-decisão](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/issues/90) para o trade-off.

2. **Campo `warning_when_alone`** no schema do JSON, anotado nos 3 endpoints com `wildcard_for` (`pipelines.actions.githubusercontent.com`, `productionresultssa0.blob.core.windows.net`, `npm.pkg.github.com`). Quando o endpoint passa o teste, o specialist emite aviso pós-OK orientando o operador a pedir wildcard ao firewall na próxima Req — não bloqueia, mas educa.

   ```
   ✔  pipelines.actions.githubusercontent.com                404 esperado · ...
        ⚠ NÃO solicitar este FQDN literal ao firewall corporativo sem o wildcard
          *.actions.githubusercontent.com — liberação literal sozinha causa
          falhas regionais recorrentes. Lab #259 (2026-05-28) confirmou ...
   ```

3. **Nova categoria advisory `runner_actions_optional_features`** — endpoints da doc oficial GitHub que só são acessados se features específicas estiverem ativas no projeto: `github-cloud.githubusercontent.com` + `github-cloud.s3.amazonaws.com` (Git LFS), `dependabot-actions.githubapp.com` (Dependabot Updates). Verificar `.github/dependabot.yml` e `git lfs install` antes de pedir liberação ao firewall.

4. **Alinhamento explícito com doc oficial GitHub** em `guidance.on_any_fail` da categoria principal — não é só achado empírico nosso; a doc oficial recomenda wildcards na seção *Communication > Accessible domains by function*.

**Versão atual do JSON**: `1.2` (consultar campo `.version` em `network-endpoints.json`).

### Diagnóstico amplo via doctor

```bash
bash siscan-server-doctor.sh                       # roda todos os specialists, incluindo este
bash siscan-server-doctor.sh --only check-network  # roda apenas este
```

### Cron de monitoramento contínuo

Conforme recomendação 12.8 do PDF. Em `/etc/cron.d/siscan-network-check`:

```
*/5 * * * * siscan cd /opt/siscan/assistente-siscan-rpa && \
            bash scripts/deploy_server/check-network.sh --quiet >> /var/log/siscan-network-check.log 2>&1 || \
            logger -t siscan-network-check "FAIL: $(date)"
```

A primeira execução com FAIL aparece em `journalctl -t siscan-network-check`; o detalhe vai pro log.

### Integração com ferramenta externa via JSON

```bash
bash scripts/deploy_server/check-network.sh --json | jq '.checks[] | select(.status == "fail")'
```

### Lista customizada para teste

```bash
bash scripts/deploy_server/check-network.sh \
    --endpoints-file /tmp/extra-endpoints.json \
    --timeout 20
```

## Saídas — formatos

### Modo `human` (padrão)

```
=== Runner ↔ GitHub Actions (HTTPS/443) ===
  ✔  github.com                                             200
  ✔  api.github.com                                         200
  ...

=== Resumo (check-network) ===
  22/22 OK
```

### Modo `--quiet`

```
(silêncio em caso de sucesso)
FAIL [check-network] https/443 objects-origin.githubusercontent.com: timeout/conexão recusada
```

### Modo `--json`

```json
{
  "specialist": "check-network",
  "summary": {"total": 22, "ok": 22, "fail": 0},
  "checks": [
    {"category": "Runner ↔ GitHub Actions (HTTPS/443)", "target": "github.com",
     "protocol": "https", "port": 443, "status": "ok", "detail": "200"},
    ...
  ]
}
```

## Ver também

- [`../../DEPLOY_SERVER.md`](../../DEPLOY_SERVER.md) — guia narrativo de deploy completo
- [`../../TROUBLESHOOTING.md`](../../TROUBLESHOOTING.md) — Problema D (rede / firewall)
- [`../../../scripts/data/network-endpoints.json`](../../../scripts/data/network-endpoints.json) — fonte de verdade dos FQDNs
- [`../../../scripts/deploy_server/_common.sh`](../../../scripts/deploy_server/_common.sh) — biblioteca compartilhada (cores, helpers, renderização)
