# Guia de Deploy — Modo HOST (PC local)
<a name="deploy-host"></a>

Versão: 2.1
Data: 2026-03-24

Deploy em PC local (Windows ou Linux) com Docker Desktop. O banco de dados PostgreSQL roda em container local junto com as aplicações. No modo HOST, o assistente opera como produto `full` — gerenciando tanto o siscan-rpa quanto o siscan-dashboard em uma única stack.

---

## O que sobe no modo HOST

O sistema SISCAN opera com dois produtos: o **siscan-rpa**, responsável pela coleta automatizada de dados do portal SISCAN via navegador, e o **siscan-dashboard**, um painel analítico que exibe indicadores de câncer de mama a partir dos dados coletados. No modo HOST, ambos rodam em um único PC com Docker Desktop.

O compose `docker-compose.prd.host.yml` cria 8 containers a partir de um único banco PostgreSQL com dois databases. O diagrama a seguir ilustra a arquitetura dos containers, suas dependências de inicialização e as conexões com os bancos de dados.

```mermaid
flowchart TD
    subgraph HOST["🖥️ PC local — docker-compose.prd.host.yml"]

        subgraph DB_LAYER["PostgreSQL (container db)"]
            DB_RPA[("siscan_rpa")]
            DB_DASH[("siscan_dashboard")]
        end

        subgraph RPA["SISCAN RPA"]
            R_MIG["migrate\nalembic (efêmero)"]
            R_APP["app\nporta 5001"]
            R_SCHED["rpa-scheduler\ncoleta SISCAN"]
        end

        subgraph DASHBOARD["SISCAN Dashboard"]
            D_MIG["dashboard-migrate\nalembic (efêmero)"]
            D_APP["dashboard-app\nporta 5000"]
            D_SYNC["dashboard-sync\nsync a cada 30 min"]
            REDIS[("Redis\ncache")]
        end
    end

    DB_RPA -.-|"init-databases.sh\ncria ambos"| DB_DASH

    R_MIG -->|"depends_on\nhealthy"| DB_RPA
    R_APP -->|"depends_on\ncompleted"| R_MIG
    R_SCHED -->|"depends_on\ncompleted"| R_MIG

    D_MIG -->|"depends_on\nhealthy"| DB_DASH
    D_APP -->|"depends_on\ncompleted"| D_MIG
    D_SYNC -->|"depends_on\ncompleted"| D_MIG

    R_APP -->|"lê/escreve"| DB_RPA
    R_SCHED -->|"lê/escreve"| DB_RPA
    D_APP -->|"lê"| DB_DASH
    D_SYNC -->|"lê"| DB_RPA
    D_SYNC -->|"escreve"| DB_DASH
    D_APP --> REDIS
    D_SYNC --> REDIS

    style DB_RPA fill:#336791,color:#fff
    style DB_DASH fill:#336791,color:#fff
    style REDIS fill:#d97706,color:#fff
    linkStyle 9 stroke:#336791,stroke-width:2px
    linkStyle 10 stroke:#336791,stroke-width:2px
    linkStyle 11 stroke:#336791,stroke-width:2px
    linkStyle 12 stroke:#336791,stroke-width:2px
    linkStyle 13 stroke:#336791,stroke-width:2px
    linkStyle 14 stroke:#d97706,stroke-width:2px
    linkStyle 15 stroke:#d97706,stroke-width:2px
```

O diagrama mostra como os containers se organizam e se conectam:

1. O **PostgreSQL** (container `db`) hospeda dois bancos na mesma instância: `siscan_rpa` e `siscan_dashboard`. O script `init-databases.sh` cria o banco do dashboard automaticamente na primeira inicialização — o banco do RPA é criado pelo entrypoint padrão do PostgreSQL.
2. O grupo **SISCAN RPA** tem três containers. O `migrate` executa as migrations do banco do RPA e encerra (efêmero). O `app` (porta 5001) serve o painel administrativo do RPA via Gunicorn. O `rpa-scheduler` executa as coletas automatizadas no portal SISCAN em intervalos configuráveis.
3. O grupo **SISCAN Dashboard** tem quatro containers. O `dashboard-migrate` executa as migrations do banco do dashboard e encerra (efêmero). O `dashboard-app` (porta 5000) serve o painel analítico via Gunicorn. O `dashboard-sync` importa dados do banco do RPA para o banco do dashboard a cada 30 minutos. O **Redis** serve como cache operacional compartilhado entre os workers do Gunicorn e armazena os payloads pré-calculados que aceleram a carga inicial do dashboard.
4. O `dashboard-sync` é o único container que acessa **ambos os bancos**: lê do `siscan_rpa` e escreve no `siscan_dashboard`. Todos os demais acessam apenas seu próprio banco.
5. Os containers de migration só executam uma vez — os serviços `app`, `rpa-scheduler`, `dashboard-app` e `dashboard-sync` só sobem após a conclusão das respectivas migrations.
6. As setas em <span style="color:#336791">**azul**</span> representam conexões com o PostgreSQL. As setas em <span style="color:#d97706">**âmbar**</span> representam conexões com o Redis.
7. Ambas as imagens (`siscan-rpa-rpa:main` e `siscan-dashboard:main`) são baixadas do GHCR via a Opção 2 do menu do assistente.

A tabela a seguir detalha cada container, sua imagem, porta exposta e função.

| Container | Imagem | Porta | Função |
|---|---|---|---|
| `db` | `postgres:17` | — | PostgreSQL com `siscan_rpa` + `siscan_dashboard` (init script cria o segundo banco) |
| `redis` | `redis:7-alpine` | — | Cache operacional e payloads pré-calculados do dashboard |
| `migrate` | `siscan-rpa-rpa:main` | — | Alembic migrations do RPA (efêmero) |
| `app` | `siscan-rpa-rpa:main` | 5001 | Painel web do RPA |
| `rpa-scheduler` | `siscan-rpa-rpa:main` | — | Coleta automática do SISCAN |
| `dashboard-migrate` | `siscan-dashboard:main` | — | Alembic migrations do dashboard (efêmero) |
| `dashboard-app` | `siscan-dashboard:main` | 5000 | Painel analítico |
| `dashboard-sync` | `siscan-dashboard:main` | — | Sync incremental RPA → dashboard (a cada 30 min) |

---

## Pré-requisitos

Antes de prosseguir, verifique os itens da tabela a seguir. Todos os passos são executados no PC que receberá a instalação.

| Passo | O que Fazer | Como Fazer |
|---|---|---|
| 1 | Instalar Docker Desktop | Baixar em docker.com/desktop. Após instalação: abrir e aguardar o ícone estabilizar na bandeja |
| 2 | Confirmar Docker Engine ≥ 24 | `docker version` e `docker info` — ambos sem erros |
| 3 | Confirmar Docker Compose v2 | `docker compose version` — deve retornar `v2.x.x` |
| 4 | Ter `git` instalado | `git --version` |
| 5 | Verificar conectividade com o GHCR | `curl -s -o /dev/null -w "%{http_code}" https://ghcr.io` deve retornar `200` ou `301` |
| 6 | **Windows** — verificar PowerShell | `$PSVersionTable.PSVersion` — PowerShell 7+ recomendado; 5.1 suportado via `execute.ps1` |
| 7 | **Windows** — habilitar execução de scripts | PowerShell (Admin): `Set-ExecutionPolicy RemoteSigned -Scope LocalMachine` |
| 8 | Gerar token GitHub (PAT) com `read:packages` | GitHub → Settings → Developer settings → Personal access tokens → marcar `read:packages` → copiar |

---

## Instalação

No modo HOST, a instalação é feita pelo assistente interativo (`siscan-assistente.sh` ou `siscan-assistente.ps1`), que guia o operador em três etapas: clonar o repositório, configurar as variáveis de ambiente e baixar as imagens Docker do siscan-rpa e do siscan-dashboard. Não é necessário instalar PostgreSQL nem Redis separadamente — ambos sobem como containers gerenciados pelo compose.

### Etapa 1 — Clonar o repositório

Clone o repositório do assistente no PC que receberá a instalação. Esse diretório será o diretório da stack — o compose, o `.env` e os scripts operacionais ficam aqui.

```bash
git clone https://github.com/Prisma-Consultoria/assistente-siscan-rpa.git
cd assistente-siscan-rpa
```

### Etapa 2 — Configurar o `.env`

Copie o sample e preencha os valores obrigatórios antes de executar o assistente pela primeira vez.

```bash
cp .env.host.sample .env
```

Os itens que precisam ser preenchidos nesta etapa são:

1. **`DATABASE_PASSWORD`** — altere a senha padrão `siscan_rpa` para uma senha segura. Essa senha será usada pelo PostgreSQL do container.
2. **`DASHBOARD_ADMIN_PASSWORD`** — defina a senha do usuário administrador do dashboard.
3. **Caminhos `HOST_*`** — preencha os caminhos onde o sistema guardará logs, PDFs, relatórios e configurações. No Windows use barras invertidas (`C:\siscan-rpa\logs`); no Linux use barras normais (`/opt/siscan-rpa/logs`).

A seção [Referência de variáveis](#referência-de-variáveis--env) abaixo documenta todas as variáveis em detalhe.

### Etapa 3 — Executar o assistente

Na primeira execução, o assistente solicita o **usuário GitHub** e o **token PAT** (com permissão `read:packages`) para autenticar no GHCR e baixar as imagens Docker. Essas credenciais são salvas em `credenciais.txt` e reutilizadas nas execuções seguintes.

**Windows — PowerShell 7+:**
```powershell
cd assistente-siscan-rpa
pwsh -File .\siscan-assistente.ps1
```

**Windows — PowerShell 5.1:**
```powershell
cd assistente-siscan-rpa
powershell -File .\execute.ps1
```

**Linux:**
```bash
cd assistente-siscan-rpa
bash ./siscan-assistente.sh
```

> Na primeira execução (Linux), o script define `COMPOSE_DIR` apontando para o diretório onde o repositório foi clonado. Ela é persistida em `/etc/environment` para sessões interativas.

Ao abrir o menu, escolha a **Opção 2 — Atualizar / Instalar** para realizar a primeira instalação. O assistente autentica no GHCR e faz o pull de **três imagens**: `postgres:17`, `redis:7-alpine`, `siscan-rpa-rpa:main` e `siscan-dashboard:main`. Em seguida, sobe a stack completa com todos os containers descritos no diagrama acima.

---

## Menu do Assistente

O menu se adapta ao produto detectado via `SISCAN_PRODUCT` no `.env`. No modo HOST (`SISCAN_PRODUCT=full`), todas as opções estão disponíveis. A tabela a seguir descreve cada opção.

| Opção | O que faz |
|---|---|
| **1 — Reiniciar** | Encerra e reinicia todos os containers (RPA + dashboard). Resolve travamentos sem perda de dados. |
| **2 — Atualizar / Instalar** | Autentica no GHCR, faz pull de ambas as imagens e recria os containers. |
| **3 — Editar configurações** | Editor interativo para variáveis do `.env`. |
| **4 — Executar RPA manualmente** | Força execução imediata do ciclo de coleta, sem esperar o intervalo agendado. |
| **5 — Sync Dashboard manualmente** | Força sincronização full dos dados do RPA para o dashboard. |
| **6 — Histórico do Sistema** | Exibe registros de reinicializações e desligamentos do host. |
| **7 — Atualizar o Assistente** | Baixa a versão mais recente dos scripts com rollback automático. |
| **8 — Sair** | Encerra o assistente. Os containers continuam rodando. |

---

## Referência de variáveis — `.env`

> **As variáveis essenciais são gerenciadas pelo assistente.** Para a maioria das operações — instalação, atualização, reinicialização — o assistente cuida de tudo. Alterar variáveis manualmente é recomendado apenas para técnicos de TI.

O `.env.host.sample` cobre o modo HOST (`docker-compose.prd.host.yml`). As tabelas a seguir usam as colunas:

- **`.env.host.sample`** — valor que vem no arquivo de exemplo.
- **Default no compose** — fallback se a variável não estiver no `.env`. Quando diz **`sem fallback`**, o sistema não sobe sem ela.
- **Obrigatória?** — se precisa ser preenchida antes de subir.
- **O que é** — explicação em linguagem simples.

### Aplicação HTTP (siscan-rpa)

A tabela a seguir descreve as variáveis da aplicação web do siscan-rpa, acessível na porta 5001.

| Variável | `.env.host.sample` | Default no compose | Obrigatória? | O que é |
|---|---|---|---|---|
| `HOST_APP_EXTERNAL_PORT` | `5001` | `:-5001` | Não | Porta do RPA no navegador. |
| `APP_LOG_LEVEL` | `INFO` | `:-INFO` | Não | Detalhe dos logs. `DEBUG` só com orientação técnica. |
| `SECRET_KEY` | *(vazio — gerado pelo assistente)* | sem fallback | **Sim** | Chave de segurança do painel web. Gerada automaticamente. |

### siscan-dashboard

A tabela a seguir descreve as variáveis do siscan-dashboard, acessível na porta 5000.

| Variável | `.env.host.sample` | Default no compose | Obrigatória? | O que é |
|---|---|---|---|---|
| `HOST_DASHBOARD_EXTERNAL_PORT` | `5000` | `:-5000` | Não | Porta do dashboard no navegador. |
| `DASHBOARD_ADMIN_PASSWORD` | *(vazio)* | — | **Sim** (1ª vez) | Senha do admin do dashboard. |
| `DASHBOARD_DATABASE_NAME` | `siscan_dashboard` | `:-siscan_dashboard` | Não | Nome do banco do dashboard. |
| `DASHBOARD_WEB_CONCURRENCY` | `2` | `:-2` | Não | Workers Gunicorn do dashboard. |
| `SYNC_INTERVAL_SECONDS` | `1800` | `:-1800` | Não | Intervalo do sync em segundos (30 min). |
| `HOST_DASHBOARD_LOG_DIR` | `C:\siscan-rpa\logs\dashboard` | `:-./logs/dashboard` | Não | Pasta de logs do dashboard. |
| `CACHE_TIMEOUT` | `300` | `:-300` | Não | TTL do cache operacional em segundos. |
| `CACHE_KEY_PREFIX` | `siscan-dashboard:cache` | `:-siscan-dashboard:cache` | Não | Prefixo das chaves do dashboard no Redis. |

### Banco de dados

O banco PostgreSQL é gerenciado pelo Docker — não é necessário instalar nada separadamente. O init script `scripts/docker/init-databases.sh` cria automaticamente o banco `siscan_dashboard` além do `siscan_rpa`.

| Variável | `.env.host.sample` | Default no compose | Obrigatória? | O que é |
|---|---|---|---|---|
| `DATABASE_NAME` | `siscan_rpa` | `:-siscan_rpa` | Não | Nome do banco do RPA. |
| `DATABASE_USER` | `siscan_rpa` | `:-siscan_rpa` | Não | Usuário do banco. |
| `DATABASE_PASSWORD` | `siscan_rpa` | `:-siscan_rpa` | Não (**altere antes do 1º start**) | Senha do banco. |
| `DATABASE_PORT` | `5432` | `:-5432` | Não | Porta interna do banco. |
| `DATABASE_HOST` | `db` | `:-db` | Não | Endereço do banco no Docker — **não altere**. |

### Scheduler batch (siscan-rpa)

| Variável | `.env.host.sample` | Default no compose | Obrigatória? | O que é |
|---|---|---|---|---|
| `CRON_ENABLED` | `true` | `:-true` | Não | Liga/desliga coletas automáticas. |
| `CRON_INTERVAL_SECONDS` | `1800` | `:-1800` | Não | Intervalo entre coletas (30 min). |

### Pastas no computador — bind mounts

Estas são as pastas onde o sistema guarda arquivos. **Todas as obrigatórias precisam ser preenchidas** — sem elas o sistema não sobe. O assistente cria as pastas automaticamente se não existirem.

| Variável | `.env.host.sample` | Obrigatória? | O que é |
|---|---|---|---|
| `HOST_LOG_DIR` | `C:\siscan-rpa\logs` | **Sim** | Logs do RPA e do scheduler. |
| `HOST_SISCAN_REPORTS_INPUT_DIR` | `C:\siscan-rpa\media\downloads` | **Sim** | PDFs baixados do SISCAN. |
| `HOST_REPORTS_OUTPUT_CONSOLIDATED_DIR` | `C:\siscan-rpa\media\reports\mamografia\consolidated` | **Sim** | Relatórios consolidados. |
| `HOST_REPORTS_OUTPUT_CONSOLIDATED_PDFS_DIR` | `C:\siscan-rpa\media\reports\...\laudos` | **Sim** | PDFs individuais por laudo. |
| `HOST_CONFIG_DIR` | `C:\siscan-rpa\config` | **Sim** | Configurações externas (`excel_columns_mapping.json`). |
| `HOST_BACKUPS_DIR` | `C:\siscan-rpa\backups` | Não | Backups do banco de dados. |
| `HOST_DASHBOARD_LOG_DIR` | `C:\siscan-rpa\logs\dashboard` | Não | Logs do dashboard. |

> **Windows vs Linux:** a estrutura é idêntica — apenas o separador muda (`\` vs `/`). No Windows use `C:\siscan-rpa\`, no Linux o caminho é livre (ex.: `/opt/siscan-rpa/`).

### Opcional e Configurações avançadas

Para variáveis opcionais e avançadas (pool de conexões, timeouts Playwright, workers), consulte [**ENV_REFERENCE.md**](https://github.com/Prisma-Consultoria/siscan-rpa/blob/main/docs/ENV_REFERENCE.md).

---

## Primeiro acesso

Após subir a stack pela primeira vez, acesse as aplicações conforme a tabela a seguir.

| Sistema | URL padrão | Próximo passo |
|---|---|---|
| siscan-rpa | `http://localhost:5001` | Navegar até `/admin/siscan-credentials` e cadastrar usuário/senha do SISCAN |
| siscan-dashboard | `http://localhost:5000` | Login com admin / senha definida em `DASHBOARD_ADMIN_PASSWORD` |

A coleta automática do RPA inicia no próximo ciclo agendado (padrão: 30 minutos). O sync do dashboard roda automaticamente no mesmo intervalo.

---

## Comandos úteis

Os comandos a seguir cobrem as operações mais comuns no modo HOST. Todos usam o compose `docker-compose.prd.host.yml`.

```powershell
# Status dos containers
docker compose -f docker-compose.prd.host.yml ps

# Logs em tempo real (todos os serviços)
docker compose -f docker-compose.prd.host.yml logs -f

# Logs do sync do dashboard
docker compose -f docker-compose.prd.host.yml logs dashboard-sync -f

# Sync manual do dashboard (full refresh)
docker compose -f docker-compose.prd.host.yml exec dashboard-app python -m src.commands.sync_exames --full

# Health do RPA
curl -s http://localhost:5001/health

# Health do dashboard
curl -s http://localhost:5000/health

# Verificar imagens instaladas
docker images | grep -E "siscan-rpa|siscan-dashboard"

# Uso de disco pelo Docker
docker system df
```
