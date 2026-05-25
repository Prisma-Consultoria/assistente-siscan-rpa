# `check-network` — Specialist de Diagnóstico

Specialist do `siscan-server-doctor.sh` responsável por validar a conectividade de saída de uma VM com todos os endpoints externos exigidos pelos runners self-hosted do GitHub Actions, pelo pull de imagens (GHCR), pelo pull do Redis (Docker Hub) e pela validação OCSP/CRL dos certificados.

Para entender **quando** rodar diagnósticos no ciclo de vida de uma VM, consulte o guia narrativo em [`../../DEPLOY_SERVER.md`](../../DEPLOY_SERVER.md). Este documento é a referência precisa do specialist `check-network`: opções, exit codes, formato de entrada e saída.

## Histórico de mudanças

| Versão | Data | Mudança |
|---|---|---|
| 1.2 | 2026-05-25 | Movido para `scripts/deploy_server/diagnostics/check-network.sh` (subpasta dedicada a specialists de diagnóstico — abre espaço pra outros tipos de scripts em `scripts/deploy_server/` no futuro). UX: header explicativo de escopo (validação de firewall) + reescrita por linha como "código esperado · porquê". |
| 1.1 | 2026-05-25 | Refatorado para usar `_common.sh` (cores, helpers, renderização compartilhados entre specialists). Mesma cobertura (22 endpoints). |
| 1.0 | 2026-05-25 | Versão inicial — 22 endpoints (req ICI 753315 v2.0 + GitHub docs *self-hosted-runners#communication*). Automatiza o item *Conectividade HTTPS* da tabela de pré-requisitos do `DEPLOY_SERVER.md`, que antes era um `curl -Iv https://github.com` manual. |

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
bash scripts/deploy_server/diagnostics/check-network.sh [--quiet | --json] [--timeout SEC] [--endpoints-file FILE]
bash scripts/deploy_server/diagnostics/check-network.sh --help

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
| `1` | Pelo menos um FAIL | Consulte [`../../TROUBLESHOOTING.md`](../../TROUBLESHOOTING.md#problema-d--falha-no-pull-por-rede-instável--firewall) ou abra requisição de reabertura de firewall (para VMs do ICI, referenciar requisição **753315**) |
| `2` | Uso inválido, dependência ausente ou JSON inválido | Verificar mensagem de erro no stderr |

## Critério de aceitação

Conforme seção 11.4 do PDF *Reativação de whitelist v2.0* (req ICI 753315):

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

1. Documento **Reativação de whitelist — VMs siscan-dashboard e siscan-rpa v2.0** (requisição ICI 753315), seções 3 a 7.
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
bash scripts/deploy_server/diagnostics/check-network.sh && echo "Rede OK, posso rodar siscan-server-setup.sh"
```

### Diagnóstico amplo via doctor

```bash
bash siscan-server-doctor.sh                       # roda todos os specialists, incluindo este
bash siscan-server-doctor.sh --only check-network  # roda apenas este
```

### Cron de monitoramento contínuo

Conforme recomendação 12.8 do PDF. Em `/etc/cron.d/siscan-network-check`:

```
*/5 * * * * siscan cd /opt/siscan/assistente-siscan-rpa && \
            bash scripts/deploy_server/diagnostics/check-network.sh --quiet >> /var/log/siscan-network-check.log 2>&1 || \
            logger -t siscan-network-check "FAIL: $(date)"
```

A primeira execução com FAIL aparece em `journalctl -t siscan-network-check`; o detalhe vai pro log.

### Integração com ferramenta externa via JSON

```bash
bash scripts/deploy_server/diagnostics/check-network.sh --json | jq '.checks[] | select(.status == "fail")'
```

### Lista customizada para teste

```bash
bash scripts/deploy_server/diagnostics/check-network.sh \
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
- [`../../../scripts/deploy_server/diagnostics/_common.sh`](../../../scripts/deploy_server/diagnostics/_common.sh) — biblioteca compartilhada (cores, helpers, renderização)
