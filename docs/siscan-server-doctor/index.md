# `siscan-server-doctor.sh` — Diagnóstico amplo da VM

Entry point recomendado para o operador validar a saúde da VM antes/depois de deploys, troubleshooting, ou em cron de monitoramento contínuo.

**Scripts relacionados** (todos no root do repositório):
- [`siscan-server-setup.sh`](../../siscan-server-setup.sh) — instalação inicial; invoca o doctor como gate (Fase 0)
- [`siscan-runner-recover.sh`](scripts/siscan-runner-recover.md) — recuperação cirúrgica do runner (auto-removal 14d, regra dos 30d)

```bash
bash siscan-server-doctor.sh                          # roda todos os specialists
bash siscan-server-doctor.sh --only check-network     # subset
bash siscan-server-doctor.sh --except check-db        # tudo exceto
bash siscan-server-doctor.sh --quiet                  # só FAIL (cron)
bash siscan-server-doctor.sh --json                   # envelope consolidado
bash siscan-server-doctor.sh --list                   # lista specialists disponíveis
```

## O que o doctor faz

Descobre os specialists em `scripts/deploy_server/check-*.sh` e os executa sequencialmente, com **3 modos de saída**:

| Modo | Quando usar | Comportamento |
|---|---|---|
| `human` (default) | Diagnóstico manual | Pretty-print colorido, com categoria + verdict + ação por specialist |
| `--quiet` | Cron de monitoramento | Apenas linhas FAIL; exit code 0/1/2 |
| `--json` | Integração com ferramentas | Envelope `{summary, specialists: [...]}` agregando o JSON de cada specialist |

## Specialists disponíveis

Cada specialist é responsável por uma dimensão da saúde da VM. Todos podem ser invocados standalone (`bash scripts/deploy_server/check-<nome>.sh`) ou via doctor.

| Specialist | Dimensão | Referência |
|---|---|---|
| `check-network` | 22 endpoints externos (runner GitHub Actions, GHCR, Docker Hub, OCSP/CRL) — validação de firewall | [scripts/check-network.md](scripts/check-network.md) |
| `check-deps` | Binários locais (docker, compose, curl, jq, sudo, git) + sincronização NTP + OS (Ubuntu 24.04) | (a documentar) |
| `check-resources` | vCPUs (≥4), RAM (≥8GB), disco livre (≥20GB) em `$COMPOSE_DIR` conforme DEPLOY_SERVER.md | (a documentar) |
| `check-env` | `.env` preenchido conforme manifesto, formato de `RPA_DATABASE_URL`, defaults de senha, port validity | (a documentar) |
| `check-docker` | Docker daemon ativo, grupo, daemon.json pool, teste real de network create | (a documentar) |
| `check-stack` | Compose file + parse OK, imagem local + GHCR remoto, containers running sem restart loop, port collision | (a documentar) |
| `check-permissions` | Ownership do COMPOSE_DIR, git safe.directory, HOST_*_DIR escrevíveis, chaves RSA, UID 1000 em data/.artifacts | (a documentar) |
| `check-runner` | Runner GitHub Actions: instalação local + serviço systemd + registro remoto + regra dos 30 dias | (a documentar) |
| `check-db` | TCP/5432 + pg_isready + versão PostgreSQL (≥16) para DATABASE_HOST e RPA_DATABASE_URL (dashboard) | (a documentar) |

## Manifesto de produtos

A diferenciação entre os produtos (rpa, dashboard, full) é declarativa via [`scripts/data/products.json`](../../scripts/data/products.json). Cada specialist lê do manifesto em vez de `case "$SISCAN_PRODUCT"` hardcoded. Schema completo em [products-manifest.md](products-manifest.md).

## Exit codes (doctor + specialists)

| Code | Doctor | Specialist |
|---|---|---|
| `0` | Todos os specialists OK | Todos os checks OK |
| `1` | Pelo menos um specialist falhou | Pelo menos um check falhou |
| `2` | Uso inválido / `products.json` ausente | Uso inválido / dependência ausente / `.env` ausente |

## Cron de monitoramento (recomendação)

Em `/etc/cron.d/siscan-doctor`:

```
*/15 * * * * siscan cd /opt/siscan/assistente-siscan-rpa && \
             bash siscan-server-doctor.sh --quiet >> /var/log/siscan-doctor.log 2>&1 || \
             logger -t siscan-doctor "FAIL: $(date)"
```

A cada 15 minutos, qualquer FAIL aparece em `journalctl -t siscan-doctor`.

## Estado atual do uso do manifesto (#42)

| Componente | Usa products.json? | Status |
|---|---|---|
| `scripts/deploy_server/check-*.sh` (5 specialists product-aware) | ✅ | Concluído na task #45 |
| `siscan-server-doctor.sh` | — | Product-agnostic por design (não precisa) |
| `siscan-server-setup.sh` | ❌ | Pendente (próxima task da feature [#42](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/issues/42)) |

## Ver também

- [`../DEPLOY_SERVER.md`](../DEPLOY_SERVER.md) — guia narrativo do deploy completo
- [`../TROUBLESHOOTING.md`](../TROUBLESHOOTING.md) — sintomas conhecidos e resolução manual
- [`products-manifest.md`](products-manifest.md) — schema do manifesto que governa cada produto
- [`../../scripts/deploy_server/`](../../scripts/deploy_server/) — código dos specialists
- [`../../scripts/data/products.json`](../../scripts/data/products.json) — fonte de verdade dos produtos
- [`../../scripts/data/network-endpoints.json`](../../scripts/data/network-endpoints.json) — fonte de verdade dos FQDNs externos do check-network
