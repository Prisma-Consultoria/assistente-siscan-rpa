# `siscan-runner-recover.sh` — Recuperação idempotente do runner

Recupera o GitHub Actions self-hosted runner em **9 cenários auto-resolvíveis** (OK, N/A, 1, 2, C, A, A2, B, WARN) + 1 estado inconclusivo (UNKNOWN, que orienta passos manuais) — desde "serviço systemd ausente" até "bootstrap do zero". A lógica de download/registro/instalação é compartilhada com `siscan-server-setup.sh` via o módulo `scripts/deploy_server/_runner.sh` (issue #51).

Os 2 cenários originais (A e B) foram descobertos no incidente no servidor parceiro (15/04 → 25/05/2026); o cenário C foi descoberto na VMPRDAPP-RPADASHBOARD em 26/05/2026.

## Cenários cobertos (matriz rápida)

| Cenário | Trigger | Token? | Re-registra? | Instala systemd? |
|---|---|---|---|---|
| **OK** | tudo online + idade <25d | não | não | não |
| **N/A** | `~/actions-runner/` não existe | **sim** | sim (bootstrap) | sim |
| **1** | dir existe mas binários ausentes | **sim** | sim (bootstrap incremental) | sim |
| **2** | binários OK, `.runner` ausente | **sim** | sim | sim |
| **C** | `.runner` OK, systemd unit ausente | **não** | não | sim (cirúrgico) |
| **A** | API `total_count=0` (auto-removed >14d) | **sim** | sim (uninstall + remove + register) | sim |
| **A2** | API: runner `offline` ou nome mismatch | **sim** | sim (idem A) | sim |
| **B** | idade ≥30d | não | não | não (só `run.sh --check` + start) |
| **WARN** | idade 25-29d | não | não | preventivo (idem B) |
| **UNKNOWN** | sem gh/`GH_TOKEN`/`--token` + estado inconclusivo | — | — | — (orienta) |

### Cenário A — Auto-removal após 14 dias offline

GitHub remove runners offline há > 14 dias. Diagnóstico:
```
gh api repos/<owner>/<repo>/actions/runners → total_count: 0
```
Resolução: re-registrar (precisa token novo).

### Cenário B — Regra dos 30 dias de auto-update

Runner online + serviço ativo, mas GitHub recusa jobs porque o runner ficou > 30 dias sem atualizar sua versão.
[GitHub docs](https://docs.github.com/en/actions/reference/runners/self-hosted-runners#runner-software-updates-on-self-hosted-runners):

> "If you do not perform a software update within 30 days, the GitHub Actions service will not queue jobs to your runner."

Resolução: `sudo -u siscan ./run.sh --check` (**não** precisa token).

### Cenário C — Serviço systemd ausente (novo em #51)

`.runner` continua válido remotamente, mas o systemd unit `actions.runner.*.service` foi desinstalado ou nunca instalado. Detecção é 100% local — não precisa de gh/`GH_TOKEN`. Resolução: `svc.sh install $USER` + `svc.sh start`. **Não pede token** porque o `.runner` ainda é aceito pelo GitHub.

Descoberto na VMPRDAPP-RPADASHBOARD em 26/05/2026: alguém rodou `svc.sh uninstall` (intencional ou não), o `.runner` ficou válido localmente, mas o serviço sumiu do systemd.

### Cenários N/A, 1, 2 — Bootstrap incremental (novos em #51)

Antes de #51, o recover abortava se `~/actions-runner/` não existisse. Após #51, o recover faz o que for necessário pra alcançar estado 4:
- **N/A**: cria dir + baixa tarball + registra + instala + inicia
- **1**: baixa + registra + instala + inicia (dir existia mas binários sumiram — limpeza parcial rara)
- **2**: registra + instala + inicia (binários OK, mas `.runner` foi removido)

Todos os 3 requerem token. Use `--token TOKEN` na CLI ou aguarde o prompt interativo.

## Sinopse

```bash
bash siscan-runner-recover.sh                              # detecta produto via $COMPOSE_DIR/.env (SISCAN_PRODUCT)
bash siscan-runner-recover.sh --product rpa                # explícito (sem .env ou .env sem SISCAN_PRODUCT)
bash siscan-runner-recover.sh --product dashboard
bash siscan-runner-recover.sh --product full               # VM que hospeda RPA + Dashboard
bash siscan-runner-recover.sh --env-file /path/to/.env     # apontar pra um .env em outro caminho
bash siscan-runner-recover.sh --skip-doctor                # pula pré-flight (debug)
bash siscan-runner-recover.sh --token ghr_xxx...           # token via CLI (sobrescreve prompt interativo)
bash siscan-runner-recover.sh --help
```

### Flag `--token`

Quando fornecida, sobrescreve o prompt interativo `read -srp "Token: "` dos cenários que precisam de token (N/A, 1, 2, A, A2). Útil para:
- **Automação** (CI/scripts sem TTY interativo)
- **UNKNOWN defensivo**: se `gh`/`GH_TOKEN` ausentes e estado local OK + idade <30d, fornecer `--token` força o cenário **A2** (re-registro defensivo, assumindo que o GitHub pode ter auto-removido o runner sem possibilidade de detectar via API)

Sem `--token`, o comportamento histórico do prompt interativo é preservado.

> **Pré-requisito**: o script precisa saber o produto antes de qualquer ação. Resolução em ordem:
> 1. `--product VALOR` explícito vence sempre.
> 2. Senão, lê `SISCAN_PRODUCT` do **`ENV_FILE` efetivo**:
>    - default: `$COMPOSE_DIR/.env` (ou `$PWD/.env` se `COMPOSE_DIR` não estiver exportada)
>    - override: `--env-file /caminho/para/.env` na CLI
> 3. Se nenhum dos dois resolveu, aborta com `ERRO: SISCAN_PRODUCT não definido. Use --product rpa|dashboard|full ou preencha .env.`
>
> Operacionalmente isso significa que **na VM você pode rodar sem flag** (o `.env` já vem do `siscan-server-setup.sh`); fora da VM (ex.: testes locais, debug em dev box) você usa `--product` ou `--env-file` apontando pra um `.env` válido.

## Detecção de SISCAN_PRODUCT a partir do `.env`

Quando você roda sem `--product`, o script tenta inferir o produto do `.env` da VM. **Não há "magia": é grep simples sobre arquivo de dados.**

```bash
# COMPOSE_DIR cai pra $(pwd) se não exportado;
# --env-file VALOR no CLI sobrescreve este default (ver --help do script).
ENV_FILE="${COMPOSE_DIR}/.env"

_read_env_var() {
    # Pipeline em uma linha — copy-paste seguro (sem trailing spaces após \).
    # 1. grep   → linhas começando com 'SISCAN_PRODUCT='
    # 2. tail   → última atribuição vence (override permitido)
    # 3. cut    → pega tudo após o primeiro '='
    # 4. sed    → remove aspas envolventes ("..." ou '...')
    grep -E "^SISCAN_PRODUCT=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | sed 's/^["'\'']\(.*\)["'\'']$/\1/'
}
```

Características desse mecanismo:

- **Lê como dados, não como código**: NÃO usa `source .env` nem `eval`. Isso evita que chars especiais no valor (`$`, `` ` ``, aspas mal-fechadas) sejam interpretados como bash — proteção contra command injection.
- **Última atribuição vence** (`tail -1`): se o `.env` tiver `SISCAN_PRODUCT=` duas vezes, prevalece a de baixo (consistente com o comportamento de `docker compose` e `dotenv`).
- **Aspas envolventes são strippadas**: aceita `SISCAN_PRODUCT=rpa`, `SISCAN_PRODUCT="rpa"` ou `SISCAN_PRODUCT='rpa'` indistintamente.
- **Mesmo padrão dos demais specialists**: `check-env`, `check-permissions`, `check-db`, `check-runner` usam função idêntica — qualquer mudança aqui precisa ser propagada (ou extraída pra `_common.sh`).

**Pré-requisitos pra detecção via `.env` funcionar:**

1. `ENV_FILE` aponta pra um caminho legível. Default = `$COMPOSE_DIR/.env` (ou `$PWD/.env` se `COMPOSE_DIR` não estiver exportada); pode ser sobrescrito por `--env-file VALOR` na CLI.
2. O arquivo apontado por `ENV_FILE` existe e é legível pelo usuário corrente.
3. Esse arquivo tem uma linha `SISCAN_PRODUCT=<rpa|dashboard|full>`.

Se qualquer um dos 3 falhar, a saída é o erro documentado em "Pré-requisito" acima — soluções: passar `--product VALOR` na CLI, `--env-file /caminho/.env` apontando pra um `.env` válido em outro lugar, ou ajustar o `.env` do default.

## Como o script decide o que fazer

Diagnóstico em 4 passos:

1. **Estado local** — mtime de `.runner_migrated` (preferência) ou `.runner` → idade do runner em dias
2. **Estado remoto** via GitHub API:
   - Sem `gh auth status` nem `GH_TOKEN` → diagnóstico só por idade (detecta B, não A)
   - Com auth → `gh api repos/<owner>/<repo>/actions/runners`
3. **Cruza** os dois pra decidir o cenário
4. **Executa** a ação correspondente

Detecção é feita por `runner_diagnose` (em `scripts/deploy_server/_runner.sh`), que combina estado local (via `runner_get_state`) e remoto (via `runner_query_api`). Ordem de precedência:

| Estado local | Estado remoto | Idade | Cenário | Ação |
|---|---|---|---|---|
| dir ausente | — | — | **N/A** | Bootstrap completo (pede token) |
| dir OK, binários ausentes | — | — | **1** | Bootstrap incremental (pede token) |
| binários OK, `.runner` ausente | — | — | **2** | Register + install + start (pede token) |
| binários + `.runner` OK, systemd unit ausente | — | — | **C** | Install + start (sem token) |
| tudo local OK | `total_count: 0` | qualquer | **A** | Uninstall + remove + re-register + install + start |
| tudo local OK | runner offline ou nome mismatch | qualquer | **A2** | Idem A |
| tudo local OK | runner online | ≥ 30d | **B** | `run.sh --check` + start |
| tudo local OK | runner online | 25-29d | **WARN** | Idem B (preventivo) |
| tudo local OK | runner online | < 25d | **OK** | Nada — exit 0 |
| tudo local OK | API indisponível | < 30d, `--token` setado | **A2** (defensivo) | Idem A |
| tudo local OK | API indisponível | < 30d, sem `--token` | **UNKNOWN** | Orienta `--token` ou `gh` |

## Ações por cenário (o que o script faz na VM)

A tabela abaixo lista a sequência de comandos que o script executa internamente, na ordem exata, com idempotência e necessidade de sudo. **Não é um runbook copy/paste** — as variáveis (`$TOKEN`, `$REPO`, etc.) são resolvidas pelo próprio script via prompt + `products.json`; mostradas aqui pra você entender o blast radius antes de rodar — especialmente porque o Cenário A consome um token de admin que expira rapidamente (o script avisa "expira em ~5 min" ao pedir o token).

### Cenário A / A' (Auto-removal, Offline, ou Nome mismatch) — re-registro completo

Todos rodam em `~/actions-runner/`. As variáveis no comando vêm do script:

- `$TOKEN` — pedido interativamente quando o script roda
- `$REPO` — `https://github.com/<owner>/<repo>` derivado de `products.json[<product>].repo`
- `$EXPECTED_NAME` — `<hostname>-<runner_name_suffix>` (sufixo do manifesto)
- `$RUNNER_LABEL` — `products.json[<product>].runner_label`
- `$CURRENT_USER` — saída de `whoami`

| # | Comando | Idempotente? | Sudo? |
|---|---|---|---|
| 1 | `./svc.sh stop` | sim — `warn` se já parado | sim |
| 2 | `./svc.sh uninstall` | sim — `warn` se já desinstalado | sim |
| 3 | `./config.sh remove --token "$TOKEN"` | sim — `warn` se 404 (esperado quando o GitHub já auto-removeu) | não |
| 4 | `./config.sh --url $REPO --token $TOKEN --name $EXPECTED_NAME --labels $RUNNER_LABEL --unattended --replace` | sim — `--replace` sobrescreve registro existente | não |
| 5 | `./svc.sh install $CURRENT_USER` | recria | sim |
| 6 | `./svc.sh start` | recria | sim |

Estado da VM após sucesso:

- `~/actions-runner/.runner`: regerado com `id` novo (vindo do GitHub) e timestamp atual.
- `~/actions-runner/.credentials*`: regerado (chaves de autenticação do runner).
- `/etc/systemd/system/actions.runner.<owner>-<repo>.<host>-<suffix>.service`: arquivo da unit instalado.
- Serviço `systemctl is-active actions.runner.*`: `active (running)`.

Cobre o caso `.runner` presente + serviço systemd ausente (passos 2 e 5 fazem o ciclo uninstall→install) — exatamente o padrão visto na VMPRDAPP-RPADASHBOARD em 25/05/2026.

### Cenário B / WARN (Regra dos 30 dias) — só auto-update

Não pede token — força o runner a baixar versão nova e reinicia.

| # | Comando | Idempotente? | Sudo? |
|---|---|---|---|
| 1 | `./svc.sh stop` | sim — `warn` se já parado | sim |
| 2 | `./run.sh --check` (executado como `$CURRENT_USER` via `sudo -u`) | repetível — só dispara o auto-update; em runner já atualizado, é noop | sim (apenas pra `sudo -u`) |
| 3 | `./svc.sh start` | recria | sim |

Estado da VM após sucesso:

- `~/actions-runner/bin/`: binários atualizados pra versão upstream mais recente.
- `~/actions-runner/.runner_migrated`: mtime renovado (próxima janela de 30d resetada).
- Serviço continua com o mesmo registro (`.runner` e `.credentials*` intactos).

### Cenário OK — exit 0, nada a fazer

Runner saudável (`online`, idade < 25d). O script não toca em nada e retorna `0`.

### Cenário N/A — `~/actions-runner/` ausente

`fail`: o script orienta `bash siscan-server-setup.sh --product $SISCAN_PRODUCT` (instalação do zero) e sai com `2`. Recovery não cobre instalação inicial — é um script cirúrgico, não setup.

> **Pré-requisito de sudo**: o operador precisa ter `sudo` configurado pro usuário corrente (em VMs do siscan-server-setup, isso já está garantido). Se exigir senha, o script vai pausar pedindo password nos passos 1, 2, 5, 6 do A (ou 1, 2, 3 do B) — sem perder estado.

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
- **Cobre instalação do zero** (a partir de #51): cenários N/A, 1 e 2 fazem bootstrap incremental usando as funções do módulo `_runner.sh`. Não é mais necessário chamar `siscan-server-setup.sh` separadamente apenas para o runner.
- **Reusa identidade**: mantém nome + label do runner conforme manifesto
- **Cenário B/WARN/C não pedem token**: economiza ida ao GitHub UI quando só falta auto-update ou só o systemd unit
- **`--token` sobrescreve prompt**: util para automação e para forçar A2 defensivo quando API não está consultável

## Relação com `siscan-server-setup.sh`

A Fase 7 do setup e o recover compartilham as **mesmas funções** do módulo `scripts/deploy_server/_runner.sh`:

```
runner_download_binaries  → baixa tarball (estado 1→2)
runner_register           → config.sh --token (estado 2→3)
runner_install_service    → svc.sh install (estado 3→4)
runner_start_service      → svc.sh start
runner_stop_service       → svc.sh stop (idempotente)
runner_uninstall_service  → svc.sh uninstall (idempotente)
runner_remove_registration → config.sh remove (idempotente)
runner_get_state          → echo N/A|1|2|3|4
runner_diagnose           → echo OK|N/A|1|2|C|A|A2|B|WARN|UNKNOWN
```

Por isso, bugs ou melhorias na lógica de runner se propagam automaticamente para ambos os scripts.

## Exemplo — incidente real no servidor parceiro (25/05/2026)

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
- [Task #31](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/issues/31) — entrega original (cenários A e B)
- [Task #51](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/issues/51) — refatoração `_runner.sh` + cenários C/N/A/1/2 + flag `--token`
