# Guia de Deploy — Modo Servidor (Ubuntu Server)
<a name="deploy-server"></a>

Versão: 2.0
Data: 2026-03-23

Deploy em Ubuntu Server com PostgreSQL externo. O deploy de novas versões é automático via GitHub Actions com self-hosted runner. O assistente suporta dois produtos (`rpa` e `dashboard`), cada um instalado em sua própria VM.

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
        PG[("PostgreSQL\nsiscan_rpa + siscan_dashboard")]
    end

    subgraph VM3["🖥️ VM 3 — siscan-dashboard"]
        R2["Runner producao-dashboard"]
        R2 --> R2A["docker pull + compose up"]
        subgraph DASH_CONTAINERS["Containers"]
            DA["app (5000)"]
            DS["sync (loop 30min)"]
            REDIS[("Redis\ncache")]
        end
    end

    E1 -->|"HTTPS"| R1
    E2 -->|"HTTPS"| R2
    RA -->|"TCP 5432"| PG
    RS -->|"TCP 5432"| PG
    DA -->|"TCP 5432"| PG
    DS -->|"lê siscan_rpa\nescreve siscan_dashboard"| PG
    DA --> REDIS
    DS --> REDIS

    style PG fill:#336791,color:#fff
    style REDIS fill:#d97706,color:#fff
    linkStyle 10 stroke:#336791,stroke-width:2px
    linkStyle 11 stroke:#336791,stroke-width:2px
    linkStyle 12 stroke:#336791,stroke-width:2px
    linkStyle 13 stroke:#336791,stroke-width:2px
    linkStyle 14 stroke:#d97706,stroke-width:2px
    linkStyle 15 stroke:#d97706,stroke-width:2px
```

O fluxo de deploy e a infraestrutura funcionam assim:

1. Quando um desenvolvedor faz merge na branch `main` de qualquer um dos repositórios (siscan-rpa ou siscan-dashboard), o GitHub Actions inicia automaticamente o pipeline de CI/CD. O pipeline compila a imagem Docker do produto alterado e publica no GitHub Container Registry (GHCR).
2. Em seguida, o pipeline dispara um job de deploy direcionado ao runner self-hosted da VM correspondente. Cada VM de aplicação possui seu próprio runner registrado no GitHub — o merge no siscan-rpa aciona apenas o runner da VM 1, e o merge no siscan-dashboard aciona apenas o runner da VM 3. Os deploys são independentes.
3. A **VM 1 (siscan-rpa)** hospeda o produto de coleta automatizada. O container `app` (porta 5001) oferece o painel administrativo do RPA, e o `rpa-scheduler` executa as coletas no portal SISCAN em intervalos configuráveis. Ambos conectam ao PostgreSQL na VM 2.
4. A **VM 2 (Banco de dados)** é um PostgreSQL dedicado que hospeda dois bancos: `siscan_rpa` (dados da coleta) e `siscan_dashboard` (dados analíticos). Essa VM não tem runner nem assistente — é gerenciada separadamente.
5. A **VM 3 (siscan-dashboard)** hospeda o painel analítico. O container `app` (porta 5000) serve a interface web via Gunicorn, e o `sync` importa dados do banco do RPA para o banco do dashboard a cada 30 minutos. O Redis roda como container local nessa mesma VM, servindo como cache operacional compartilhado entre os workers do Gunicorn e como armazenamento dos payloads pré-calculados que aceleram a carga inicial do dashboard.
6. As setas em <span style="color:#336791">**azul**</span> representam conexões com o PostgreSQL (TCP 5432). As setas em <span style="color:#d97706">**âmbar**</span> representam conexões com o Redis (cache local na VM 3).

---

## Pré-requisitos

Antes de executar o setup, verifique os pré-requisitos em cada VM conforme a tabela a seguir.

### VM de aplicação (RPA ou Dashboard)

| Requisito | Mínimo | Verificação |
|---|---|---|
| Sistema operacional | Ubuntu 24.04 LTS | `lsb_release -a` |
| vCPUs | 4 | `nproc` |
| Memória RAM | 8 GB | `free -h` |
| Docker Engine | ≥ 28.x | `docker version` |
| Docker Compose | ≥ 2.37 | `docker compose version` |
| git | qualquer versão | `git --version` |
| Conectividade HTTPS | `github.com` e `ghcr.io` porta 443 | `curl -Iv https://github.com` |

### VM do banco de dados

| Requisito | Mínimo |
|---|---|
| PostgreSQL | ≥ 16 |
| Bancos criados | `siscan_rpa` + `siscan_dashboard` |
| Conectividade TCP | Porta 5432 acessível por ambas as VMs de aplicação |

Verificar conectividade antes de prosseguir:

```bash
psql -h <DATABASE_HOST> -U siscan_rpa -c "SELECT version();"
```

### Token de registro do runner

Cada VM precisa de um token de registro gerado no repositório correspondente ao produto:

| Produto | Onde gerar o token |
|---|---|
| `rpa` | [siscan-rpa → Settings → Actions → Runners → New](https://github.com/Prisma-Consultoria/siscan-rpa/settings/actions/runners/new) |
| `dashboard` | [siscan-dashboard → Settings → Actions → Runners → New](https://github.com/Prisma-Consultoria/siscan-dashboard/settings/actions/runners/new) |

>  ⚠️  O token expira em poucos minutos. Gere-o imediatamente antes de executar o script.

---

## Instalação (`siscan-server-setup.sh`)

O script executa **uma única vez** de forma interativa em cada VM. O flag `--product` seleciona qual aplicação será instalada. Em uma infraestrutura com 3 VMs, execute o script uma vez em cada VM com o produto correspondente.

```bash
git clone https://github.com/Prisma-Consultoria/assistente-siscan-rpa.git
cd assistente-siscan-rpa

# VM do RPA:
bash ./siscan-server-setup.sh --product rpa

# VM do Dashboard:
bash ./siscan-server-setup.sh --product dashboard

# Sem --product: o script pergunta interativamente.
```

A tabela a seguir descreve o que cada produto configura automaticamente.

| Aspecto | `--product rpa` | `--product dashboard` |
|---|---|---|
| Compose file | `docker-compose.prd.rpa.yml` | `docker-compose.prd.dashboard.yml` |
| .env sample | `.env.server-rpa.sample` | `.env.server-dashboard.sample` |
| Runner label | `producao-rpa` | `producao-dashboard` |
| Runner name | `<hostname>-siscan-rpa` | `<hostname>-siscan-dashboard` |
| Diretório da stack | Diretório onde o assistente foi clonado (`COMPOSE_DIR`) | Idem |
| Repo URL padrão | `Prisma-Consultoria/siscan-rpa` | `Prisma-Consultoria/siscan-dashboard` |
| Chave de sessão | `SECRET_KEY` (auto-gerada) | `SESSION_SECRET` (auto-gerada) |
| Variável extra | — | `RPA_DATABASE_URL` (conexão ao banco do RPA) |
| Diretórios HOST_* | 5 (logs, downloads, consolidated, PDFs, config) | 1 (logs) |

### Respostas esperadas — produto RPA

A tabela a seguir lista as perguntas interativas do script para o produto RPA e os valores esperados.

| Fase | Pergunta | Valor esperado |
|---|---|---|
| 5 | `DATABASE_HOST` | IP ou hostname do PostgreSQL externo (ex.: `192.168.1.10`) |
| 5 | `DATABASE_PASSWORD` | Senha do banco PostgreSQL |
| 5 | `HOST_LOG_DIR` | `/opt/siscan-rpa/logs` |
| 5 | `HOST_SISCAN_REPORTS_INPUT_DIR` | `/opt/siscan-rpa/media/downloads` |
| 5 | `HOST_REPORTS_OUTPUT_CONSOLIDATED_DIR` | `/opt/siscan-rpa/media/reports/mamografia/consolidated` |
| 5 | `HOST_REPORTS_OUTPUT_CONSOLIDATED_PDFS_DIR` | `/opt/siscan-rpa/media/reports/mamografia/consolidated/laudos` |
| 5 | `HOST_CONFIG_DIR` | `/opt/siscan-rpa/config` |
| 7 | `URL do repositório` | Enter para aceitar `https://github.com/Prisma-Consultoria/siscan-rpa` |
| 7 | `Token de registro` | Token copiado da tela do GitHub |

> `SECRET_KEY` é gerada automaticamente — não pergunta.

### Respostas esperadas — produto Dashboard

A tabela a seguir lista as perguntas interativas para o produto dashboard. A principal diferença é a variável `RPA_DATABASE_URL` que permite ao sync conectar no banco do RPA.

| Fase | Pergunta | Valor esperado |
|---|---|---|
| 5 | `DATABASE_HOST` | IP ou hostname do PostgreSQL (ex.: `192.168.1.10`) |
| 5 | `DATABASE_PASSWORD` | Senha do banco do dashboard |
| 5 | `RPA_DATABASE_URL` | `postgresql://siscan_rpa:senha@192.168.1.10:5432/siscan_rpa` |
| 5 | `HOST_LOG_DIR` | `/opt/siscan-dashboard/logs` |
| 7 | `URL do repositório` | Enter para aceitar `https://github.com/Prisma-Consultoria/siscan-dashboard` |
| 7 | `Token de registro` | Token copiado da tela do GitHub |

> `SESSION_SECRET` é gerada automaticamente — não pergunta.

---

## Fases do script

O script percorre 9 fases em sequência. Algumas fases se adaptam ao produto selecionado, conforme indicado.

### Fase 1 — Verificação de pré-requisitos

Verifica Docker Engine, Docker Compose v2, curl e sudo. O script não prossegue se algum estiver ausente. Comportamento idêntico para ambos os produtos.

---

### Fase 2 — Usuário dedicado para o runner

Se executado como root, cria o usuário `siscan`, adiciona ao grupo `docker` e re-executa o script como esse usuário (propagando o `--product`). Se executado como não-root, confirma o usuário e prossegue.

---

### Fase 3 — Estrutura de diretórios da stack

O diretório da stack é o próprio diretório onde o assistente foi clonado (`SCRIPT_DIR`). Os arquivos da stack (compose, `.env`, config) ficam nesse diretório. Não é necessário criar um diretório separado — o script ajusta as permissões do diretório atual para o usuário que executa.

---

### Fase 4 — Arquivos da stack

Copia o compose file e o diretório `config/` para o diretório da stack. O compose file copiado varia conforme o produto selecionado.

| Produto | Compose file |
|---|---|
| `rpa` | `docker-compose.prd.rpa.yml` |
| `dashboard` | `docker-compose.prd.dashboard.yml` |

---

### Fase 5 — Configuração do `.env`

Cria o `.env` a partir do sample correspondente ao produto e solicita interativamente os valores obrigatórios. A tabela a seguir resume as diferenças.

| Variável | Produto RPA | Produto Dashboard |
|---|---|---|
| Chave de sessão | `SECRET_KEY` (auto-gerada) | `SESSION_SECRET` (auto-gerada) |
| `DATABASE_HOST` | Pergunta (obrigatório) | Pergunta (obrigatório) |
| `DATABASE_PASSWORD` | Pergunta | Pergunta |
| `RPA_DATABASE_URL` | — | Pergunta (obrigatório para o sync) |
| Diretórios `HOST_*` | 5 caminhos | 1 caminho (`HOST_LOG_DIR`) |

O produto é persistido no `.env` via `SISCAN_PRODUCT=rpa` ou `SISCAN_PRODUCT=dashboard`, permitindo que o assistente (`siscan-assistente.sh`) detecte automaticamente qual produto gerenciar.

---

### Fase 6 — Criação dos diretórios `HOST_*`

Lê os caminhos definidos nas variáveis `HOST_*` do `.env` e executa `mkdir -p` para cada um. O número de diretórios criados varia: 5 para RPA, 1 para dashboard.

---

### Fase 7 — GitHub Actions Runner

Baixa, registra e instala o runner como serviço systemd. A label e o nome do runner são definidos pelo produto conforme a tabela a seguir.

| Aspecto | Produto RPA | Produto Dashboard |
|---|---|---|
| Label | `producao-rpa` | `producao-dashboard` |
| Nome | `<hostname>-siscan-rpa` | `<hostname>-siscan-dashboard` |
| URL padrão do repo | `Prisma-Consultoria/siscan-rpa` | `Prisma-Consultoria/siscan-dashboard` |

O script sugere a URL padrão — basta pressionar Enter para aceitar. O token de registro deve ser gerado no repositório correspondente (ver [pré-requisitos](#token-de-registro-do-runner)).

---

### Fase 8 — Persistir `COMPOSE_DIR` no ambiente do runner

O runner roda como serviço systemd e não carrega `~/.bashrc` nem `/etc/environment`. O script grava `COMPOSE_DIR` (diretório do assistente) no `~/actions-runner/.env` — o único mecanismo para injetar variáveis nos jobs do GitHub Actions. Também persiste em `/etc/environment` para sessões interativas.

Ambos os workflows de CD (siscan-rpa e siscan-dashboard) usam `${COMPOSE_DIR}` para localizar o compose file e o `.env` no servidor.

---

### Fase 9 — Permissões Docker

Verifica se o usuário atual pertence ao grupo `docker` e adiciona se necessário. Comportamento idêntico para ambos os produtos.

---

### Fase 10 — Resumo e próximos passos

Exibe o que foi configurado (produto, diretório, compose, runner) e os próximos passos:

1. Revisar o `.env` no diretório da stack.
2. Confirmar que o runner aparece como **Idle** em GitHub → Settings → Actions → Runners.
3. O próximo merge para `main` no repositório correspondente acionará o deploy automaticamente.

---

## Referência de variáveis — `.env`

As variáveis do `.env` são específicas de cada produto. As seções a seguir documentam as variáveis do produto **RPA** (`docker-compose.prd.rpa.yml`). Para as variáveis do produto **Dashboard** (`docker-compose.prd.dashboard.yml`), consulte o `.env.server-dashboard.sample` que acompanha o assistente.

### Aplicação HTTP (RPA)

| Variável | `.env.server-rpa.sample` | Default no compose | Obrigatória? | O que faz / Impacto |
|---|---|---|---|---|
| `HOST_APP_EXTERNAL_PORT` | `5001` | `:-5001` | Não | Porta TCP publicada no host. URL de acesso: `http://<IP>:<porta>`. |
| `APP_LOG_LEVEL` | `INFO` | `:-INFO` | Não | Verbosidade dos logs. Use `INFO` em produção; `DEBUG` gera alto volume. |
| `SECRET_KEY` | *(vazio — preencher)* | sem fallback | **Sim** | Assina cookies de sessão do painel web. Gere com `openssl rand -hex 32`. |

### Banco de dados (RPA)

| Variável | `.env.server-rpa.sample` | Default no compose | Obrigatória? | O que faz / Impacto |
|---|---|---|---|---|
| `DATABASE_NAME` | `siscan_rpa` | `:-siscan_rpa` | Não | Nome do banco operacional no PostgreSQL externo. |
| `DATABASE_USER` | `siscan_rpa` | `:-siscan_rpa` | Não | Usuário PostgreSQL da aplicação e das migrations. |
| `DATABASE_PASSWORD` | `siscan_rpa` | `:-siscan_rpa` | Não (**altere em produção**) | Senha do banco. Substitua antes do primeiro start. |
| `DATABASE_PORT` | `5432` | `:-5432` | Não | Porta TCP do PostgreSQL externo. |
| `DATABASE_HOST` | *(vazio — preencher)* | **sem fallback** | **Sim** | IP ou hostname do PostgreSQL externo. |

### Variáveis específicas do Dashboard

A tabela a seguir lista variáveis que existem apenas no `.env.server-dashboard.sample` e não se aplicam ao produto RPA.

| Variável | `.env.server-dashboard.sample` | Obrigatória? | O que faz |
|---|---|---|---|
| `SESSION_SECRET` | *(vazio)* | **Sim** | Chave de sessão Flask. Auto-gerada pelo setup. |
| `RPA_DATABASE_URL` | *(vazio)* | **Sim** | Conexão ao banco do RPA para o sync. Formato: `postgresql://user:pass@host:port/db` |
| `SYNC_INTERVAL_SECONDS` | `1800` | Não | Intervalo do sync automático em segundos. |
| `ADMIN_PASSWORD` | *(vazio)* | Sim (1ª exec.) | Senha do admin do dashboard. |
| `HOST_DASHBOARD_EXTERNAL_PORT` | `5000` | Não | Porta TCP do dashboard. |
| `REDIS_HOST` | `redis` | Não | Host do Redis. Default `redis` (serviço local no compose). |
| `REDIS_PORT` | `6379` | Não | Porta TCP do Redis. |
| `CACHE_TIMEOUT` | `300` | Não | TTL do cache operacional em segundos. |
| `CACHE_KEY_PREFIX` | `siscan-dashboard:cache` | Não | Prefixo das chaves do dashboard no Redis. |

---

## Primeiro acesso

Após o primeiro deploy, acesse a aplicação conforme o produto instalado na VM.

| Produto | URL padrão | Próximo passo |
|---|---|---|
| RPA | `http://<IP>:5001` | Navegar até `/admin/siscan-credentials` e cadastrar usuário/senha do SISCAN |
| Dashboard | `http://<IP>:5000` | Login com admin / senha definida em `ADMIN_PASSWORD` |

O runner registrado na fase 7 receberá automaticamente os próximos deploys via GitHub Actions.

---

## Comandos úteis

Os comandos a seguir cobrem as operações mais comuns. Substitua o compose file e a porta conforme o produto instalado na VM.

### Produto RPA

```bash
# Status dos containers
docker compose -f docker-compose.prd.rpa.yml ps

# Logs em tempo real
docker compose -f docker-compose.prd.rpa.yml logs -f

# Testar health endpoint
curl -s http://localhost:5001/health | python3 -m json.tool

# Status do runner
sudo ~/actions-runner/svc.sh status
```

### Produto Dashboard

```bash
# Status dos containers
docker compose -f docker-compose.prd.dashboard.yml ps

# Logs em tempo real
docker compose -f docker-compose.prd.dashboard.yml logs -f

# Testar health endpoint
curl -s http://localhost:5000/health | python3 -m json.tool

# Sync manual (full refresh)
docker compose -f docker-compose.prd.dashboard.yml exec app \
  python -m src.commands.sync_exames --full

# Status do runner
sudo ~/actions-runner/svc.sh status
```
