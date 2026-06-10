# Guia de Deploy — Modo Servidor (Ubuntu Server)
<a name="deploy-server"></a>

Versão: 2.5
Data: 2026-05-26

Deploy em Ubuntu Server com PostgreSQL externo. O deploy de novas versões é automático via GitHub Actions com self-hosted runner. O assistente suporta dois produtos (`rpa` e `dashboard`), cada um instalado em sua própria VM.

> Este documento é um **playbook narrativo de alto nível**: arquitetura, operação cotidiana e conteúdo único do modo servidor. Para a referência operacional detalhada de cada script (flags, fases internas, exit codes, schema), consulte os guias em [`docs/guides/`](guides/) — linkados ao longo do texto.

---

## Arquitetura — infraestrutura com 3 VMs

O sistema SISCAN opera com dois produtos distintos: o **siscan-rpa**, responsável pela coleta automatizada de dados do portal SISCAN via navegador, e o **siscan-dashboard**, um painel analítico que exibe indicadores de câncer de mama a partir dos dados coletados. Em produção, esses produtos rodam em VMs separadas, conectados por um banco de dados PostgreSQL central.

O diagrama a seguir ilustra a topologia de produção com 3 VMs e o fluxo de deploy automatizado.

```mermaid
flowchart TD
    subgraph GITHUB["☁️ GitHub"]
        A["merge → main"] --> B["GitHub Actions CI/CD"]
        B --> C1["Build siscan-rpa-rpa:main"]
        B --> C2["Build siscan-dashboard:main"]
        C1 --> D["Push → GHCR"]
        C2 --> D
        B --> E1["Job deploy → runner producao-rpa"]
        B --> E2["Job deploy → runner producao-dashboard"]
    end

    subgraph VM1["🖥️ VM 1 — siscan-rpa"]
        R1["Runner producao-rpa"]
        R1 --> R1A["docker pull + compose up"]
        subgraph RPA_CONTAINERS["Containers"]
            RA["app (5001)"]
            RS["rpa-scheduler"]
        end
    end

    subgraph VM2["🗄️ VM 2 — Banco de dados"]
        PG[("PostgreSQL<br/>siscan_rpa + siscan_dashboard")]
    end

    subgraph VM3["🖥️ VM 3 — siscan-dashboard"]
        R2["Runner producao-dashboard"]
        R2 --> R2A["docker pull + compose up"]
        subgraph DASH_CONTAINERS["Containers"]
            DA["app (5000)"]
            DS["sync (loop 30min)"]
            REDIS[("Redis<br/>cache")]
        end
    end

    E1 -->|"HTTPS"| R1
    E2 -->|"HTTPS"| R2
    RA -->|"TCP 5432"| PG
    RS -->|"TCP 5432"| PG
    DA -->|"TCP 5432"| PG
    DS -->|"lê siscan_rpa<br/>escreve siscan_dashboard"| PG
    DA --> REDIS
    DS --> REDIS

    style PG fill:#336791,color:#fff
    style REDIS fill:#d97706,color:#fff
    linkStyle 11 stroke:#336791,stroke-width:2px
    linkStyle 12 stroke:#336791,stroke-width:2px
    linkStyle 13 stroke:#336791,stroke-width:2px
    linkStyle 14 stroke:#336791,stroke-width:2px
    linkStyle 15 stroke:#d97706,stroke-width:2px
    linkStyle 16 stroke:#d97706,stroke-width:2px
```

O fluxo de deploy e a infraestrutura funcionam assim:

1. Quando um desenvolvedor faz merge na branch `main` de qualquer um dos repositórios (siscan-rpa ou siscan-dashboard), o GitHub Actions inicia automaticamente o pipeline de CI/CD. O pipeline compila a imagem Docker do produto alterado e publica no GitHub Container Registry (GHCR).
2. Em seguida, o pipeline dispara o workflow `cd_imagem_certificada_selfhosted.yml` direcionado ao runner self-hosted da VM correspondente. Cada VM de aplicação possui seu próprio runner registrado no GitHub — o merge no siscan-rpa aciona apenas o runner da VM 1, e o merge no siscan-dashboard aciona apenas o runner da VM 3. Os deploys são independentes.
3. A **VM 1 (siscan-rpa)** hospeda o produto de coleta automatizada. O container `app` (porta 5001) oferece o painel administrativo do RPA, e o `rpa-scheduler` executa as coletas no portal SISCAN em intervalos configuráveis. Ambos conectam ao PostgreSQL na VM 2.
4. A **VM 2 (Banco de dados)** é um PostgreSQL dedicado que hospeda dois bancos: `siscan_rpa` (dados da coleta) e `siscan_dashboard` (dados analíticos). Essa VM não tem runner nem assistente — é gerenciada separadamente.
5. A **VM 3 (siscan-dashboard)** hospeda o painel analítico. O container `app` (porta 5000) serve a interface web via Gunicorn, e o `sync` importa dados do banco do RPA para o banco do dashboard a cada 30 minutos. O Redis roda como container local nessa mesma VM, servindo como cache operacional compartilhado entre os workers do Gunicorn e como armazenamento dos payloads pré-calculados que aceleram a carga inicial do dashboard.
6. As setas em <span style="color:#336791">**azul**</span> representam conexões com o PostgreSQL (TCP 5432). As setas em <span style="color:#d97706">**âmbar**</span> representam conexões com o Redis (cache local na VM 3).

### Workflows GitHub Actions envolvidos

Como os repositórios `siscan-rpa` e `siscan-dashboard` são **privados**, operadores externos não conseguem inspecionar os arquivos `.github/workflows/*.yml` diretamente. Os guias abaixo descrevem em prosa o que cada workflow faz:

| Workflow | Repositório | Visibilidade | Guia de referência |
|---|---|---|---|
| `cd_imagem_certificada_selfhosted.yml` | `siscan-rpa` e `siscan-dashboard` | privado | [`guides/workflows/cd-imagem-certificada-selfhosted.md`](guides/workflows/cd-imagem-certificada-selfhosted.md) — 3 jobs (pre-deploy → deploy → post-deploy) com ~12-19 steps |
| `test.yml` | `assistente-siscan-rpa` (este repo) | **público** | [`guides/workflows/test.md`](guides/workflows/test.md) — CI dos testes `bats` do próprio assistente |

O workflow de CD nos produtos consome `siscan-server-doctor.sh` como gate em **pre-deploy** (validação pré) e **post-deploy** (validação pós) — espelhando o gate da Fase 0 do `siscan-server-setup.sh`.

---

## Pré-requisitos

Antes de provisionar a VM e executar o setup, garanta que ela atende aos requisitos mínimos abaixo. O doctor (próxima seção) valida automaticamente todos eles, mas dimensionamento de hardware/SO precisa ser combinado com a equipe de infraestrutura antes.

Os limiares de recursos (vCPUs, RAM, disco) e de versão (Docker, Compose, Ubuntu, PostgreSQL) verificados pelos specialists têm como fonte única o manifesto `scripts/data/products.json` (`.defaults.resources` e `.defaults.host_requirements`) — esta tabela é a contraparte humana desses valores e deve ser mantida coerente com ele.

### VM de aplicação (RPA ou Dashboard)

| Requisito | Mínimo | Validado por |
|---|---|---|
| Sistema operacional | Ubuntu 24.04 LTS | `check-deps` |
| vCPUs | 4 | `check-resources` |
| Memória RAM | recomendado 8 GB · piso 7 GB (7–8 GB = aviso, não bloqueia) | `check-resources` |
| Disco livre em `$COMPOSE_DIR` | 20 GB | `check-resources` |
| Docker Engine | ≥ 24 (recomendado 28+) | `check-deps` + `check-docker` |
| Docker Compose | ≥ 2.37 | `check-deps` |
| git, jq, openssl, curl, sudo, timeout | qualquer versão | `check-deps` |
| Conectividade HTTPS | 22 endpoints (GitHub Actions, GHCR, Docker Hub, OCSP/CRL) | `check-network` |
| Docker network pool com subnets disponíveis | — | `check-docker` (teste real `network create`) |
| Usuário corrente não-root + no grupo `docker` | — | `check-docker` |
| Stack dir com ownership correto + git `safe.directory` | — | `check-permissions` |
| Chaves RSA em `HOST_SECRETS_DIR` (RPA) | persistidas | `check-permissions` |
| `.env` preenchido com formato correto | — | `check-env` |

> **Docker `daemon.json`:** se a equipe de infraestrutura configurou `/etc/docker/daemon.json` com `default-address-pools` restrito (ex: uma única subnet `/24`), o Docker não conseguirá criar redes para os compose projects. O `check-docker` detecta isso automaticamente; consulte o [Problema 1 do Troubleshooting](TROUBLESHOOTING.md#problema-1--pool-de-endereços-docker-esgotado-ao-criar-rede) para a solução.

### VM do banco de dados

| Requisito | Mínimo | Validado por |
|---|---|---|
| PostgreSQL | ≥ 16 | `check-db` (`SHOW server_version`) |
| Bancos criados | `siscan_rpa` + `siscan_dashboard` | (operacional, não verificado) |
| Conectividade TCP | Porta 5432 acessível por ambas as VMs de aplicação | `check-db` (TCP + `pg_isready`) |
| Senhas sem caracteres especiais | Evitar `@`, `%`, `/`, `#`, `:`, `\` | `check-env` (regex de `RPA_DATABASE_URL`) |

> **Senhas do banco:** o Docker Compose monta a `DATABASE_URL` por interpolação de variáveis. Caracteres como `@` na senha quebram o parsing da URL (o `@` é o separador entre credenciais e host). Use senhas alfanuméricas com símbolos seguros (`_`, `-`, `!`, `^`).

> O `check-db` só roda depois que o `.env` tem `DATABASE_HOST` preenchido (após Fase 5 do setup). Use `bash siscan-server-doctor.sh --only check-db` para validá-lo pontualmente após o setup.

### Pré-flight automatizado

Com a VM provisionada, valide todos os requisitos acima de uma vez:

```bash
git clone https://github.com/Prisma-Consultoria/assistente-siscan-rpa.git
cd assistente-siscan-rpa
bash siscan-server-doctor.sh --pre-setup
```

Saída esperada: `7/7 specialists OK` em `--pre-setup` (3 specialists — `check-runner`, `check-stack`, `check-db` — só fazem sentido depois do setup completar; `check-runner-tls` em modo `--pre-flight` roda sempre, mesmo pré-setup). Cada FAIL traz mensagem com ação corretiva específica. Referência completa de cada specialist (o que verifica, exit codes, schema JSON) em [`guides/siscan-server-doctor/`](guides/siscan-server-doctor/index.md).

> O próprio `siscan-server-setup.sh` invoca o doctor como **Fase 0** (gate pré-flight) antes de executar qualquer ação destrutiva. Use `--skip-doctor` no setup só em cenários de debugging.

### Token de registro do runner

Cada VM precisa de um token de registro gerado no repositório correspondente ao produto:

| Sistema | Onde gerar o token |
|---|---|
| siscan-rpa | [siscan-rpa → Settings → Actions → Runners → New](https://github.com/Prisma-Consultoria/siscan-rpa/settings/actions/runners/new) |
| siscan-dashboard | [siscan-dashboard → Settings → Actions → Runners → New](https://github.com/Prisma-Consultoria/siscan-dashboard/settings/actions/runners/new) |

> ⚠️ O token expira em poucos minutos. Gere-o imediatamente antes de executar o script.

---

## Instalação

O script `siscan-server-setup.sh` é o ponto de entrada para instalar o siscan-rpa e/ou o siscan-dashboard em servidores Ubuntu. Ele roda **uma única vez** de forma interativa em cada VM. O flag `--product` seleciona qual aplicação será instalada — o mesmo script e o mesmo repositório do assistente funcionam para ambos.

Em uma infraestrutura com 3 VMs (conforme o diagrama de arquitetura acima):

1. **Na VM do RPA (VM 1):** clone o assistente e execute com `--product rpa`. O script configura o compose do RPA, gera a chave de sessão, solicita as credenciais do banco externo e os caminhos de dados, instala o runner do GitHub Actions e registra no repositório `siscan-rpa`.
2. **Na VM do Dashboard (VM 3):** clone o assistente novamente e execute com `--product dashboard`. O script configura o compose do dashboard (que inclui o Redis), gera a chave de sessão, solicita credenciais e a connection string do banco do RPA para o sync, instala o runner e registra no repositório `siscan-dashboard`.
3. **A VM do banco de dados (VM 2)** não precisa do assistente — é um PostgreSQL dedicado que deve estar acessível por ambas as VMs antes do primeiro `compose up`.

Cada VM é independente — não há ordem obrigatória entre RPA e Dashboard. A única dependência é que o PostgreSQL (VM 2) esteja acessível no momento em que os containers subirem pela primeira vez.

O script executa 11 fases idempotentes (`0` a `10`) que cobrem pré-flight via doctor, criação do usuário dedicado `siscan`, estrutura de diretórios, geração do `.env`, instalação do runner (via cenários `N/A → 1 → 2 → 3 → 4`) e persistência de `COMPOSE_DIR`. Detalhe de cada fase, flags, variáveis de ambiente reconhecidas e exit codes em [`guides/siscan-server-setup.md`](guides/siscan-server-setup.md).

### Instalação do siscan-rpa (VM 1)

Na VM dedicada ao RPA:

```bash
git clone https://github.com/Prisma-Consultoria/assistente-siscan-rpa.git
cd assistente-siscan-rpa
bash ./siscan-server-setup.sh --product rpa
```

O script configura automaticamente:

| Aspecto | Valor |
|---|---|
| Compose file | `docker-compose.prd.rpa.yml` |
| .env sample | `.env.server-rpa.sample` |
| Runner label | `producao-rpa` |
| Runner name | `<hostname>-siscan-rpa` |
| Repo URL padrão | `Prisma-Consultoria/siscan-rpa` |
| Chave de sessão | `SECRET_KEY` (auto-gerada) |
| Diretórios HOST_* | 5 (logs, downloads, consolidated, PDFs, config) |

Durante a execução, o script solicita interativamente os seguintes valores:

| Fase | Pergunta | Valor esperado |
|---|---|---|
| 5 | `DATABASE_HOST` | IP ou hostname do PostgreSQL externo (ex.: `192.168.1.10`) |
| 5 | `DATABASE_PASSWORD` | Senha do banco PostgreSQL |
| 5 | `HOST_LOG_DIR` | `/opt/siscan-rpa/logs` |
| 5 | `HOST_SISCAN_REPORTS_INPUT_DIR` | `/opt/siscan-rpa/media/downloads` |
| 5 | `HOST_REPORTS_OUTPUT_CONSOLIDATED_DIR` | `/opt/siscan-rpa/media/reports/mamografia/consolidated` |
| 5 | `HOST_REPORTS_OUTPUT_CONSOLIDATED_PDFS_DIR` | `/opt/siscan-rpa/media/reports/mamografia/consolidated/laudos` |
| 5 | `HOST_CONFIG_DIR` | `/opt/siscan-rpa/config` |
| 7 | URL do repositório | Enter para aceitar `https://github.com/Prisma-Consultoria/siscan-rpa` |
| 7 | Token de registro | Token copiado da tela do GitHub |

> `SECRET_KEY` é gerada automaticamente via `openssl rand -hex 32` — não pergunta.

### Instalação do siscan-dashboard (VM 3)

Na VM dedicada ao dashboard:

```bash
git clone https://github.com/Prisma-Consultoria/assistente-siscan-rpa.git
cd assistente-siscan-rpa
bash ./siscan-server-setup.sh --product dashboard
```

O script configura automaticamente:

| Aspecto | Valor |
|---|---|
| Compose file | `docker-compose.prd.dashboard.yml` |
| .env sample | `.env.server-dashboard.sample` |
| Runner label | `producao-dashboard` |
| Runner name | `<hostname>-siscan-dashboard` |
| Repo URL padrão | `Prisma-Consultoria/siscan-dashboard` |
| Chave de sessão | `SESSION_SECRET` (auto-gerada) |
| Diretórios HOST_* | 1 (logs) |
| Serviço extra | Redis (cache, criado automaticamente pelo compose) |

A principal diferença em relação ao RPA é a variável `RPA_DATABASE_URL`, que permite ao serviço `sync` ler o banco do RPA. Sem ela, o dashboard sobe mas o sync não funciona.

Durante a execução, o script solicita interativamente os seguintes valores:

| Fase | Pergunta | Valor esperado |
|---|---|---|
| 5 | `DATABASE_HOST` | IP ou hostname do PostgreSQL (ex.: `192.168.1.10`) |
| 5 | `DATABASE_PASSWORD` | Senha do banco do dashboard |
| 5 | `ADMIN_PASSWORD` | Senha do administrador do dashboard |
| 5 | `RPA_DATABASE_URL` | `postgresql://siscan_rpa:senha@192.168.1.10:5432/siscan_rpa` |
| 5 | `HOST_LOG_DIR` | `/opt/siscan-dashboard/logs` |
| 7 | URL do repositório | Enter para aceitar `https://github.com/Prisma-Consultoria/siscan-dashboard` |
| 7 | Token de registro | Token copiado da tela do GitHub |

> `SESSION_SECRET` é gerada automaticamente via `openssl rand -hex 32` — não pergunta.

---

## Validação de saúde (`siscan-server-doctor.sh`)

Antes de prosseguir com a instalação — e sempre que o deploy quebrar — rode o doctor para um diagnóstico amplo da VM:

```bash
bash ./siscan-server-doctor.sh
```

O doctor orquestra **10 specialists** em `scripts/deploy_server/check-*.sh`, cada um cobrindo uma dimensão da saúde da VM:

| Specialist | Cobre |
|---|---|
| `check-network` | 22 FQDNs base + 12 variantes regionais advisory + 3 endpoints opcionais advisory (LFS, Dependabot) |
| `check-deps` | Docker, Compose, curl, sudo, jq, NTP |
| `check-env` | `.env` preenchido, formato de `RPA_DATABASE_URL`, `APP_LOG_LEVEL` |
| `check-docker` | Daemon ativo, pool de redes (`daemon.json`), grupo docker |
| `check-runner` | `.runner` local, GitHub API, regra dos 30 dias |
| `check-runner-tls` | Diagnóstico TLS proativo (proxy env, CAs custom, DNS) — também invocado em modo `--reactive` por `runner_register` em falha (TSK00.04.10) |
| `check-stack` | `docker compose ps`, port collision, restart loop |
| `check-permissions` | Ownership do stack dir, git `safe.directory`, UID 1000 |
| `check-db` | TCP/5432 + `pg_isready` para `DATABASE_HOST` (e `RPA_DATABASE_URL`) |
| `check-resources` | vCPUs, RAM, disco em `$COMPOSE_DIR` |

Saída `N/N specialists OK` libera o próximo passo. Saída com `FAIL` em algum specialist aponta a causa-raiz — consulte [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) para a ação corretiva associada.

Para rodar um specialist isoladamente:

```bash
bash siscan-server-doctor.sh --only check-network       # via doctor
bash scripts/deploy_server/check-network.sh             # standalone
```

Modos de saída (`--quiet`, `--json`, `--list`), subconjuntos (`--only`, `--except`, `--pre-setup`), exit codes consumíveis por gates de CI ou cron, schema do envelope JSON e detalhe de cada specialist em [`guides/siscan-server-doctor/`](guides/siscan-server-doctor/index.md).

> **Monitoramento contínuo (recomendação 12.8 do PDF de whitelist):** programe `siscan-server-doctor.sh --quiet` em cron a cada 5 minutos. Exit != 0 dispara alerta. Isso evita que uma nova expiração de regra de firewall — ou outras regressões — passem despercebidas por semanas, como aconteceu em 15/04/2026.

---

## Primeiro acesso

Após o primeiro deploy, acesse a aplicação conforme o produto instalado na VM.

| Sistema | URL padrão | Próximo passo |
|---|---|---|
| siscan-rpa | `http://<IP>:5001` | Navegar até `/admin/siscan-credentials` e cadastrar usuário/senha do SISCAN |
| siscan-dashboard | `http://<IP>:5000` | Login com admin / senha definida em `ADMIN_PASSWORD` |

O runner registrado na Fase 7 do setup receberá automaticamente os próximos deploys via GitHub Actions.

---

## Atualização do assistente

Após a instalação inicial, o assistente não se atualiza sozinho. Há **dois mecanismos paralelos** de atualização:

| Mecanismo | O que atualiza | Quando |
|---|---|---|
| **Workflow CD** (automático) | `docker-compose.prd.*.yml`, `.env.server-*.sample`, imagens Docker do GHCR | A cada merge em `main` dos repos `siscan-rpa` / `siscan-dashboard` |
| **`git pull` manual** | Tudo o resto: `siscan-server-setup.sh`, `siscan-server-doctor.sh`, `siscan-runner-recover.sh`, `scripts/deploy_server/check-*.sh`, `scripts/data/*.json`, `docs/` | Quando o assistente ganha novas funcionalidades (specialists novos, manifesto, fixes etc.) |

> **Importante:** o `git pull` **não é opcional** quando o repo do assistente ganha novos scripts. O workflow CD só sincroniza compose + sample, não o resto do repo.

### Procedimento padrão

```bash
cd $COMPOSE_DIR   # tipicamente /app/assistente-siscan-rpa
git pull origin main
bash siscan-server-doctor.sh --pre-setup
```

A última linha valida que o ambiente continua íntegro após o pull. Saída esperada: `7/7 specialists OK` (modo `--pre-setup` inclui `check-runner-tls` pre-flight + 6 prévios).

### Autoatualização agendada (cron) — `siscan-assistente-autoupdate.sh`

Para eliminar o `git pull` manual repetido, agende a atualização do clone via cron. O `siscan-assistente-autoupdate.sh` faz `git pull --ff-only origin main`, grava um **estado auditável** (commit, timestamp, resultado) fora do repo e expõe esse estado no `pre-deploy-diag.json` de todo deploy (chave `assistant_update`). Política de árvore suja fixada: se houver modificação em arquivos **rastreados**, o `run` grava `outcome: failed` e **não** toca no repo (nunca stasha silenciosamente).

```bash
cd $COMPOSE_DIR   # tipicamente /app/assistente-siscan-rpa

# Agendar (diário às 03:00, ou a cada N dias; sem args entra em prompt interativo)
bash siscan-assistente-autoupdate.sh schedule --daily --at 03:00
bash siscan-assistente-autoupdate.sh schedule --every-days 3 --at 04:30

# Conferir o estado da última atualização
bash siscan-assistente-autoupdate.sh status

# Rodar uma atualização agora (mesmo alvo do cron)
bash siscan-assistente-autoupdate.sh run

# Remover o agendamento (preserva o resto do crontab)
bash siscan-assistente-autoupdate.sh unschedule
```

"A cada N dias" usa guarda de intervalo: o cron dispara diariamente e o `run` decide o ciclo comparando `last_success_utc` com `interval_days`. Detalhe dos subcomandos, esquema do estado e troubleshooting: [`guides/siscan-assistente-autoupdate.md`](guides/siscan-assistente-autoupdate.md).

### Cenários complexos (runner offline, auto-removed, primeira atualização ampla)

Para recuperação cirúrgica do runner — auto-removido após 14 dias offline, regra dos 30 dias de auto-update, bootstrap em VM nova, serviço systemd ausente, entre outros — use `siscan-runner-recover.sh`. O script detecta automaticamente um entre **9 cenários auto-resolvíveis** (`OK`, `N/A`, `1`, `2`, `C`, `A`, `A2`, `B`, `WARN`) + 1 inconclusivo (`UNKNOWN`), compartilha a lógica de download/registro/instalação com `siscan-server-setup.sh` e valida ao final via `check-runner`. Detalhe de cada cenário, flags (`--token`, `--pat`, `--env-file`, `--product`), resolução do `ENV_FILE` e geração do PAT classic: [`guides/siscan-runner-recover.md`](guides/siscan-runner-recover.md).

```bash
# Na VM (detecta produto via .env)
bash siscan-runner-recover.sh

# Sem .env / testes locais
bash siscan-runner-recover.sh --product rpa
bash siscan-runner-recover.sh --product dashboard
bash siscan-runner-recover.sh --product full
```

### Quando há novas variáveis de ambiente

Quando uma nova versão do assistente introduz variáveis novas (como a adição do Redis com `REDIS_HOST`, `REDIS_PORT`, `CACHE_TIMEOUT`), o `.env` sample atualizado já estará disponível no servidor após o próximo deploy automático. Para identificar o que falta:

```bash
# Ver variáveis que existem no sample mas não no .env atual
diff <(grep -E '^[A-Z_]+=' .env.server-rpa.sample | cut -d= -f1 | sort) \
     <(grep -E '^[A-Z_]+=' .env | cut -d= -f1 | sort)
```

Adicione as variáveis faltantes manualmente ao `.env` e reinicie a stack para aplicar:

```bash
# siscan-rpa (VM 1):
docker compose -f docker-compose.prd.rpa.yml down
docker compose -f docker-compose.prd.rpa.yml up -d --wait

# siscan-dashboard (VM 3):
docker compose -f docker-compose.prd.dashboard.yml down
docker compose -f docker-compose.prd.dashboard.yml up -d --wait
```

---

## Variáveis de ambiente principais

A tabela a seguir lista apenas as variáveis **obrigatórias** por produto — todas as demais variáveis (defaults do compose, opcionais como `APP_LOG_LEVEL`, `SYNC_INTERVAL_SECONDS`, `CACHE_TIMEOUT`, `REDIS_HOST` etc.) e o detalhamento completo do `.env` estão em [`guides/siscan-server-setup.md`](guides/siscan-server-setup.md) e no manifesto declarativo `scripts/data/products.json` (schema em [`guides/siscan-server-doctor/products-manifest.md`](guides/siscan-server-doctor/products-manifest.md)).

| Variável | Produtos | Origem | O que faz |
|---|---|---|---|
| `SISCAN_PRODUCT` | todos | Auto (Fase 5) | Persiste o produto (`rpa`/`dashboard`/`full`) para detecção automática pelos scripts. |
| `SECRET_KEY` | `rpa`, `full` | Auto-gerada | Assina cookies de sessão do painel web (64 hex chars). |
| `SESSION_SECRET` | `dashboard` | Auto-gerada | Chave de sessão Flask do dashboard. |
| `DATABASE_HOST` | todos | Interativo | IP/hostname do PostgreSQL externo. Rejeita literal `db`. |
| `DATABASE_PASSWORD` | todos | Interativo | Senha do banco. Evite caracteres `@`, `%`, `/`, `#`, `:`, `\` (quebram parsing da `RPA_DATABASE_URL`). |
| `ADMIN_PASSWORD` | `dashboard` | Interativo | Senha do admin do painel. Vazio = senha temporária nos logs. |
| `RPA_DATABASE_URL` | `dashboard` | Interativo | Conexão ao banco do RPA para o sync. Formato: `postgresql://user:pass@host:port/db` |
| `HOST_*_DIR` | varia | Interativo | Caminhos POSIX para bind mounts (logs, downloads, reports etc.). |

---

## Fluxo do compose file de produção

> **Auditoria de 2026-05-29 (F00.05 #94):** documenta o **fluxo de propriedade** do compose file (`docker-compose.prd.{rpa,dashboard}.yml`) ao longo do ciclo de vida — quem coloca, quem sobrescreve, quando o operador NÃO deve editar manualmente.

O compose file de produção tem **2 fontes-de-verdade** ao longo do tempo, sincronizadas com o repositório do produto (siscan-rpa ou siscan-dashboard) como fonte canônica:

1. **Setup inicial** (`siscan-server-setup.sh` Fase 4): copia o compose do diretório do assistente para `${COMPOSE_DIR}/` na VM. Bootstrap único.
2. **Cada deploy** (`cd_imagem_certificada_selfhosted.yml` job `deploy`): sobrescreve o compose com `cp docker-compose.prd.X.yml ${COMPOSE_DIR}/...` a partir do **checkout do repositório do produto** (siscan-rpa ou siscan-dashboard).

Não é bug — é **design intencional**: o repo do produto é a fonte canônica em uso, garantindo coerência entre versão de imagem e versão de compose. Mas se o operador editar `${COMPOSE_DIR}/docker-compose.prd.X.yml` manualmente para um quick-fix, o próximo deploy **sobrescreve silenciosamente** essa edição.

### Diagrama de propriedade

```
┌────────────────────────────────────────────────────────────────────┐
│  Repositório do produto (siscan-rpa OU siscan-dashboard)           │
│  → fonte canônica do compose                                       │
└──────────────────────────────┬─────────────────────────────────────┘
                               │
                ┌──────────────┴────────────────┐
                │                               │
                ▼                               ▼
   ┌──────────────────────┐         ┌──────────────────────────┐
   │ Setup inicial        │         │ Cada CD via runner       │
   │ Fase 4 do            │         │ Step "Atualizar          │
   │ siscan-server-       │         │ docker-compose.*.yml"    │
   │ setup.sh             │         │ — cp do checkout         │
   └──────────┬───────────┘         └───────────┬──────────────┘
              │                                 │
              └───────────────┬─────────────────┘
                              ▼
   ┌─────────────────────────────────────────────────────┐
   │ ${COMPOSE_DIR}/docker-compose.prd.<rpa|dashboard>.yml │
   │ ⚠ NÃO EDITAR MANUALMENTE — será sobrescrito          │
   │   silenciosamente no próximo deploy                  │
   └─────────────────────────────────────────────────────┘
```

### Tabela "quem possui o quê"

| Artefato | Fonte canônica | Propagação | Edição manual permitida? |
|---|---|---|---|
| `docker-compose.prd.<id>.yml` | Repo do produto, branch `main` | Setup (1×) + Deploy (cada push) | ❌ Não — sobrescrita silenciosa no próximo CD |
| `.env` | Operador (Fase 5 do setup) | Setup (1× + idempotente) | ✅ Sim — `.env` NUNCA é sobrescrito pelo CD |
| `.env.server-<id>.sample` | Repo do produto | Setup + Deploy | ❌ Sample é referência — edição manual revertida |
| Bind mounts (`HOST_*`) | Operador (Fase 5) | Setup | ✅ Sim — operador tem total controle |
| `HOST_SECRETS_DIR`, `HOST_BACKUPS_DIR` | Setup Fase 5 deriva do parent de `HOST_LOG_DIR` (TSK00.05.01 #95) | Setup (idempotente) | ✅ Sim — declaração no `.env` preservada se operador customizar |

### Cenários comuns

**Preciso mudar o compose temporariamente para investigar um problema em produção.**

| Cenário | Como fazer |
|---|---|
| Quick fix permanente | Editar no repo do produto + cherry-pick para deploy emergencial (workflow_dispatch com tag específica). Após o merge, a alteração propaga ao próximo CD normal. |
| Override permanente local na VM | Usar arquivo `docker-compose.override.yml` ao lado do compose principal (compose merge automático, e este arquivo **não é sobrescrito** pelo deploy). |
| Debug temporário | Editar `${COMPOSE_DIR}/docker-compose.prd.X.yml` na VM com plena consciência de que o próximo push à `main` reverte. Anote a edição em um issue para não esquecer. |

### Compose file e `git pull` — por que (geralmente) não há conflito

O step "Atualizar `docker-compose.prd.X.yml`" do job `deploy` faz `cp` direto sobre o arquivo. Como `${COMPOSE_DIR}` tipicamente também é repositório git do assistente (para `git pull` dos scripts), uma edição manual ao compose **gera diff local** que pode bloquear o próximo `git pull origin main` do assistente. Nesse caso, descarte as alterações locais antes do pull:

```bash
git checkout -- docker-compose.prd.rpa.yml docker-compose.prd.dashboard.yml
git checkout -- .env.server-rpa.sample .env.server-dashboard.sample
git pull origin main
```

> **Recomendação consolidada:** nunca edite compose files ou `.env` samples diretamente na VM. Alterações de compose devem ir no repositório do produto; alterações de scripts/diagnóstico do assistente, neste repositório.

---

## Operações cotidianas

Esta seção lista apenas as operações **manuais** que o operador realmente executa no dia a dia — para tudo o mais (status de containers, logs, health endpoint, debug profundo), use o doctor e a seção [Coleta de artefatos](TROUBLESHOOTING.md#coleta-de-artefatos-para-suporte-avançado) do TROUBLESHOOTING.

### Diagnóstico geral da VM

```bash
bash siscan-server-doctor.sh                    # validação completa (10/10 OK esperado)
bash siscan-server-doctor.sh --only check-stack # só containers + healthcheck
bash siscan-server-doctor.sh --json             # saída estruturada (cron / integração)
```

Detalhes de cada specialist, modos de saída e schema JSON em [`guides/siscan-server-doctor/`](guides/siscan-server-doctor/index.md).

### Status do runner (debug rápido sem rodar o doctor inteiro)

```bash
sudo ~/actions-runner/svc.sh status
```

Para recuperação cirúrgica do runner (auto-removed, regra dos 30 dias, serviço ausente etc.), ver [`guides/siscan-runner-recover.md`](guides/siscan-runner-recover.md).

### Sync manual do dashboard (caso operacional real)

O serviço `sync` do dashboard roda a cada 30 minutos automaticamente. Manual só é necessário em **2 cenários**:

- **Pós-restore de backup**: o `sync_control` ficou com timestamps inconsistentes; um `--full` re-importa do zero
- **Re-sincronização forçada**: depuração de divergência entre RPA e Dashboard

```bash
# Sync full — re-importa todos os registros do RPA
docker compose -f docker-compose.prd.dashboard.yml exec app \
  python -m src.commands.sync_exames --full

# Sync incremental — só registros novos desde o último sync
docker compose -f docker-compose.prd.dashboard.yml exec app \
  python -m src.commands.sync_exames
```

> Para coleta de logs, status de containers e debug profundo, ver [TROUBLESHOOTING.md — Coleta de artefatos](TROUBLESHOOTING.md#coleta-de-artefatos-para-suporte-avançado).

---

## Backup e restauração

O script `backup_manager.sh` oferece um menu interativo para backup e restauração do banco PostgreSQL. O workflow de CD do siscan-rpa copia automaticamente o script para `${COMPOSE_DIR}/scripts/backup_manager.sh` a cada deploy.

### Executar backup/restauração (menu interativo)

Na VM do RPA (VM 1):

```bash
cd /app/assistente-siscan-rpa
bash scripts/clients/backup_manager.sh
```

O menu lista as opções disponíveis (backup, restauração, listar backups). Os dumps são salvos em `backups/` no diretório da stack.

### Restauração manual (sem menu)

Se preferir restaurar diretamente, copie o dump para `backups/` e execute:

```bash
docker compose -f docker-compose.prd.rpa.yml exec -T app \
  pg_restore -h <IP-VM2> -U siscan_rpa -d siscan_rpa --clean --if-exists --no-owner \
  < backups/<nome_do_dump>.dump
```

### Sincronizar dashboard após restauração

Após restaurar o banco do RPA, o dashboard precisa ser re-sincronizado para refletir os dados atualizados. Na VM do dashboard (VM 3):

```bash
# Sync full — re-importa todos os registros do banco do RPA
docker compose -f docker-compose.prd.dashboard.yml exec app \
  python -m src.commands.sync_exames --full
```

O sync incremental (sem `--full`) roda automaticamente a cada 30 minutos via container `sync`. O `--full` é necessário após restauração de backup porque o `sync_control` pode ter timestamps inconsistentes com os dados restaurados.

---

## Veja também

- [`guides/siscan-server-setup.md`](guides/siscan-server-setup.md) — referência operacional completa do `siscan-server-setup.sh` (11 fases, flags, exit codes, manifesto `products.json`).
- [`guides/siscan-server-doctor/`](guides/siscan-server-doctor/index.md) — referência completa do doctor + de cada specialist (opções, exit codes, schema JSON, exemplos).
- [`guides/siscan-runner-recover.md`](guides/siscan-runner-recover.md) — recuperação cirúrgica do runner em 9 cenários auto-resolvíveis + UNKNOWN.
- [`guides/workflows/cd-imagem-certificada-selfhosted.md`](guides/workflows/cd-imagem-certificada-selfhosted.md) — workflow de deploy contínuo (3 jobs, ~12-19 steps) executado pelo runner self-hosted dos repos privados de cada produto.
- [`guides/workflows/test.md`](guides/workflows/test.md) — workflow de CI dos testes `bats` do próprio assistente (repo público).
- [`CHECKLISTS.md`](CHECKLISTS.md) — checklist operacional pós-setup.
- [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) — sintomas observados em campo, com a coluna "Coberto por" indicando qual script automatiza cada caso.
- [`ERRORS_TABLE.md`](ERRORS_TABLE.md) — incidentes históricos observados em deploys reais.
