# `siscan-runner-recover.sh` — Recuperação cirúrgica do runner

Recupera o GitHub Actions self-hosted runner em **dois cenários** descobertos no incidente do ICI (15/04 → 25/05/2026):

## Cenário A — Auto-removal após 14 dias offline

GitHub remove runners offline há > 14 dias. Diagnóstico:
```
gh api repos/<owner>/<repo>/actions/runners → total_count: 0
```
Resolução: re-registrar (precisa token novo).

## Cenário B — Regra dos 30 dias de auto-update

Runner online + serviço ativo, mas GitHub recusa jobs porque o runner ficou > 30 dias sem atualizar sua versão.
[GitHub docs](https://docs.github.com/en/actions/reference/runners/self-hosted-runners#runner-software-updates-on-self-hosted-runners):

> "If you do not perform a software update within 30 days, the GitHub Actions service will not queue jobs to your runner."

Resolução: `sudo -u siscan ./run.sh --check` (**não** precisa token).

## Sinopse

```bash
bash siscan-runner-recover.sh                       # detecta produto via .env
bash siscan-runner-recover.sh --product rpa         # explícito
bash siscan-runner-recover.sh --product dashboard
bash siscan-runner-recover.sh --skip-doctor         # pula pré-flight (debug)
bash siscan-runner-recover.sh --help
```

## Como o script decide o que fazer

Diagnóstico em 4 passos:

1. **Estado local** — mtime de `.runner_migrated` (preferência) ou `.runner` → idade do runner em dias
2. **Estado remoto** via GitHub API:
   - Sem `gh auth status` nem `GH_TOKEN` → diagnóstico só por idade (detecta B, não A)
   - Com auth → `gh api repos/<owner>/<repo>/actions/runners`
3. **Cruza** os dois pra decidir o cenário
4. **Executa** a ação correspondente

| Estado da API | Idade local | Cenário | Ação |
|---|---|---|---|
| `total_count: 0` | qualquer | **A** Auto-removed | Re-registrar (pede token) |
| Runner ausente do nome esperado | qualquer | **A'** Nome mismatch | Re-registrar |
| Runner presente, `offline` | qualquer | **A'** Offline | Re-registrar |
| Runner presente, `online`, ≥ 30d | ≥ 30d | **B** Regra dos 30d | `run.sh --check` |
| Runner presente, `online`, 25-29d | 25-29d | **WARN** | `run.sh --check` (preventivo) |
| Runner presente, `online`, < 25d | < 25d | **OK** | Nada — exit 0 |
| `~/actions-runner/` ausente | — | **N/A** | Orienta `siscan-server-setup.sh` |

## Pré-flight: doctor é invocado primeiro

Antes de tocar no runner, invoca:
```bash
bash siscan-server-doctor.sh --quiet \
    --only check-network,check-deps,check-docker,check-permissions
```

Por que esses 4 e não `check-runner`? Porque `check-runner` é o que vamos **consertar** — não faz sentido falhar nele antes de tentar. Mas se a rede está fora, o daemon caiu, ou as permissões mudaram, o recovery vai falhar do mesmo jeito — vale abortar cedo.

Use `--skip-doctor` pra pular o pré-flight em cenários de debug onde você sabe o que está fazendo.

## Manifesto: `products.json` define repo + nome

O script lê de `scripts/data/products.json`:
- `repo` (`owner/name`) → URL do `config.sh --url`
- `runner_name_suffix` → nome esperado (`<hostname>-<suffix>`)
- `runner_label` → label do `config.sh --labels`

Adicionar um produto novo é só editar o manifesto — o recovery descobre automaticamente.

## Pós-recovery: validação

Depois da ação, espera 5s e roda `bash scripts/deploy_server/check-runner.sh --quiet`. Se OK → exit 0 + mensagem de sucesso. Se ainda FAIL → exit 1 + orientação pra diagnose detalhada.

## Exit codes

| Code | Significa |
|---|---|
| `0` | Runner saudável (nada a fazer) **OU** recovery bem-sucedido |
| `1` | Falha em alguma etapa do recovery (token inválido, svc.sh falhou, etc.) |
| `2` | Pré-condição não atendida: produto indefinido, runner nunca instalado, doctor reportou problemas em outras dimensões |

## Comportamento

- **Idempotente**: rodar duas vezes seguidas — a segunda detecta runner OK e sai com exit 0
- **Não é instalação**: assume `~/actions-runner/` existe. Para VM nova, use `siscan-server-setup.sh`
- **Reusa identidade**: mantém nome + label do runner conforme manifesto
- **Cenário B não pede token**: economiza ida ao GitHub UI quando só falta auto-update

## Exemplo — incidente real do ICI (25/05/2026)

Cenário: VM `VMPRDAPP-RPADASHBOARD` estava 40 dias sem deploy. Firewall foi reaberto, mas jobs ficavam em `Waiting for a runner`.

Diagnóstico pelo doctor:
- `check-network`: 22/22 OK (firewall liberado)
- `check-runner`: ✘ `total_count: 0` na API (auto-removed após 14d offline)

Comando único pra recuperar:
```bash
cd /app/assistente-siscan-rpa
bash siscan-runner-recover.sh --product dashboard
```

O script detecta cenário A, pede token (gerado em
`https://github.com/Prisma-Consultoria/siscan-dashboard/settings/actions/runners/new`),
faz `svc.sh stop/uninstall + config.sh remove + config.sh register + svc.sh install/start`,
e valida com `check-runner` no final.

## Ver também

- [`../index.md`](../index.md) — overview do doctor + lista de specialists
- [`check-network.md`](check-network.md) — primeiro specialist invocado no pré-flight
- [`../../TROUBLESHOOTING.md`](../../TROUBLESHOOTING.md) — sintomas e diagnóstico manual
- [Self-hosted runners reference (GitHub docs)](https://docs.github.com/en/actions/reference/runners/self-hosted-runners)
- [Task #31](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/issues/31)
