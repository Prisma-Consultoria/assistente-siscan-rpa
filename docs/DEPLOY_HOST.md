# Guia de Deploy — Modo HOST (PC local)
<a name="deploy-host"></a>

Versão: 2.0
Data: 2026-03-23

Deploy em PC local (Windows ou Linux) com Docker Desktop. O banco de dados PostgreSQL roda em container local junto com as aplicações. No modo HOST, o assistente opera como produto `full` — gerenciando tanto o siscan-rpa quanto o siscan-dashboard em uma única stack.

---

## O que sobe no modo HOST

No modo HOST, o compose `docker-compose.prd.host.yml` cria 7 containers a partir de um único banco PostgreSQL com dois databases. A tabela a seguir descreve cada serviço e sua função.

| Container | Imagem | Porta | Função |
|---|---|---|---|
| `db` | `postgres:17` | — | PostgreSQL com `siscan_rpa` + `siscan_dashboard` (init script cria o segundo banco) |
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

A instalação consiste em clonar o repositório do assistente, configurar o `.env` e executar o assistente para baixar as imagens Docker.

### Clonar o repositório

```bash
git clone https://github.com/Prisma-Consultoria/assistente-siscan-rpa.git
cd assistente-siscan-rpa
```

### Configurar o `.env`

```bash
cp .env.host.sample .env
```

Preencha os caminhos das pastas, a senha do banco e a senha do admin do dashboard antes de iniciar o assistente pela primeira vez. A seção [Referência de variáveis](#referência-de-variáveis--env) abaixo documenta todas as variáveis.

### Executar o assistente

Na primeira execução, o assistente solicita o **usuário GitHub** e o **token PAT** para autenticar no GHCR. Essas credenciais são salvas em `credenciais.txt` e reutilizadas nas execuções seguintes.

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

Escolha a **Opção 2 — Atualizar / Instalar** no menu para realizar a primeira instalação. O assistente faz o pull de **duas imagens**: `siscan-rpa-rpa:main` e `siscan-dashboard:main`.

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

### Aplicação HTTP (RPA)

A tabela a seguir descreve as variáveis da aplicação web do RPA, acessível na porta 5001.

| Variável | `.env.host.sample` | Default no compose | Obrigatória? | O que é |
|---|---|---|---|---|
| `HOST_APP_EXTERNAL_PORT` | `5001` | `:-5001` | Não | Porta do RPA no navegador. |
| `APP_LOG_LEVEL` | `INFO` | `:-INFO` | Não | Detalhe dos logs. `DEBUG` só com orientação técnica. |
| `SECRET_KEY` | *(vazio — gerado pelo assistente)* | sem fallback | **Sim** | Chave de segurança do painel web. Gerada automaticamente. |

### Dashboard

A tabela a seguir descreve as variáveis da aplicação dashboard, acessível na porta 5000.

| Variável | `.env.host.sample` | Default no compose | Obrigatória? | O que é |
|---|---|---|---|---|
| `HOST_DASHBOARD_EXTERNAL_PORT` | `5000` | `:-5000` | Não | Porta do dashboard no navegador. |
| `DASHBOARD_ADMIN_PASSWORD` | *(vazio)* | — | **Sim** (1ª vez) | Senha do admin do dashboard. |
| `DASHBOARD_DATABASE_NAME` | `siscan_dashboard` | `:-siscan_dashboard` | Não | Nome do banco do dashboard. |
| `DASHBOARD_WEB_CONCURRENCY` | `2` | `:-2` | Não | Workers Gunicorn do dashboard. |
| `SYNC_INTERVAL_SECONDS` | `1800` | `:-1800` | Não | Intervalo do sync em segundos (30 min). |
| `HOST_DASHBOARD_LOG_DIR` | `C:\siscan-rpa\logs\dashboard` | `:-./logs/dashboard` | Não | Pasta de logs do dashboard. |

### Banco de dados

O banco PostgreSQL é gerenciado pelo Docker — não é necessário instalar nada separadamente. O init script `scripts/docker/init-databases.sh` cria automaticamente o banco `siscan_dashboard` além do `siscan_rpa`.

| Variável | `.env.host.sample` | Default no compose | Obrigatória? | O que é |
|---|---|---|---|---|
| `DATABASE_NAME` | `siscan_rpa` | `:-siscan_rpa` | Não | Nome do banco do RPA. |
| `DATABASE_USER` | `siscan_rpa` | `:-siscan_rpa` | Não | Usuário do banco. |
| `DATABASE_PASSWORD` | `siscan_rpa` | `:-siscan_rpa` | Não (**altere antes do 1º start**) | Senha do banco. |
| `DATABASE_PORT` | `5432` | `:-5432` | Não | Porta interna do banco. |
| `DATABASE_HOST` | `db` | `:-db` | Não | Endereço do banco no Docker — **não altere**. |

### Scheduler batch (RPA)

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

| Aplicação | URL padrão | Próximo passo |
|---|---|---|
| RPA | `http://localhost:5001` | Navegar até `/admin/siscan-credentials` e cadastrar usuário/senha do SISCAN |
| Dashboard | `http://localhost:5000` | Login com admin / senha definida em `DASHBOARD_ADMIN_PASSWORD` |

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
