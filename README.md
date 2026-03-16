# Assistente SISCAN RPA

Scripts de instalação, configuração e operação do [SISCAN RPA](https://github.com/Prisma-Consultoria/siscan-rpa).

---

## Cenários de uso

| Cenário | Script | Sistema |
|---|---|---|
| **Desktop** — instalação e operação em máquina local | `siscan-assistente.sh` / `siscan-assistente.ps1` | Linux ou Windows |
| **Servidor — Opção 1.A** — deploy automatizado via Imagem Certificada com self-hosted runner | `siscan-server-setup.sh` | Ubuntu Server 22.04+ |

---

## Desktop — Linux e Windows

Menu interativo para instalar, configurar, atualizar e operar o SISCAN RPA em máquina local com Docker.

### Pré-requisitos

- Docker Engine (Linux) ou Docker Desktop (Windows).
- Docker Compose v2 (plugin integrado ou standalone).
- **Linux:** bash 4+; `jq` opcional (para leitura de `.env.help.json`); `curl` ou `wget`.
- **Windows:** PowerShell 7+ (`pwsh`) recomendado. PowerShell 5.1 suportado via `execute.ps1`.

### Início rápido

```bash
git clone https://github.com/Prisma-Consultoria/assistente-siscan-rpa.git
cd assistente-siscan-rpa
cp .env.sample .env
```

**Linux:**
```bash
bash ./siscan-assistente.sh
```

**Windows (PowerShell 7+):**
```powershell
pwsh -File .\siscan-assistente.ps1
```

**Windows (PowerShell 5.1):**
```powershell
powershell -File .\execute.ps1
```

### Menu do Assistente

Ao iniciar, ambos os scripts apresentam o mesmo menu interativo:

| Opção | Ação |
|---|---|
| 1 | **Reiniciar o SISCAN RPA** — fecha e reinicia o serviço (problemas simples) |
| 2 | **Atualizar / Instalar o SISCAN RPA** — baixa e aplica a versão mais recente |
| 3 | **Editar configurações básicas** — ajusta caminhos e variáveis essenciais do `.env` |
| 4 | **Executar tarefas RPA manualmente** — força execução imediata do extrator |
| 5 | **Histórico do Sistema** — exibe desligamentos, travamentos e reinicializações |
| 6 | **Atualizar o Assistente** — baixa nova versão do assistente com rollback automático |
| 7 | **Sair** |

---

## Servidor — Deploy via Imagem Certificada (Opção 1.A)

Configura um servidor Linux para receber deploys automáticos do SISCAN RPA via GitHub Actions com self-hosted runner.

O script executa **uma única vez** por servidor e percorre 8 fases lineares:

| Fase | Descrição |
|---|---|
| 1 | Verificação de pré-requisitos (Docker ≥ 24, Compose v2, curl, sudo) |
| 2 | Criação da estrutura de diretórios da stack (`/opt/siscan-rpa` por padrão) |
| 3 | Cópia dos arquivos da stack (`docker-compose.prd.yml`) |
| 4 | Configuração do `.env` (criado a partir do `.env.sample` se ausente) |
| 5 | Criação dos diretórios HOST_* definidos no `.env` |
| 6 | Download e registro do GitHub Actions runner |
| 7 | Ajuste de permissões Docker (adiciona usuário ao grupo `docker`) |
| 8 | Resumo e próximos passos |

### Pré-requisitos

- Ubuntu Server 22.04+ (ou distribuição Linux compatível).
- Docker Engine ≥ 24 e Docker Compose v2 (plugin).
- `curl` e `sudo`.
- Token de registro de runner do repositório `siscan-rpa` (GitHub → Settings → Actions → Runners).

### Início rápido

```bash
git clone https://github.com/Prisma-Consultoria/assistente-siscan-rpa.git
cd assistente-siscan-rpa
bash ./siscan-server-setup.sh
```

Variáveis de ambiente opcionais para sobrescrever os padrões:

```bash
COMPOSE_DIR=/opt/siscan-rpa \
RUNNER_DIR=~/actions-runner \
RUNNER_LABEL=producao-cliente \
bash ./siscan-server-setup.sh
```

Referência: [docs/DEPLOY_AUTOMATICO.md](https://github.com/Prisma-Consultoria/siscan-rpa/blob/main/docs/DEPLOY_AUTOMATICO.md) — Opção 1.A Self-hosted Runner.

---

## Configuração (`.env`)

Copie o arquivo de exemplo e ajuste conforme necessário:

```bash
cp .env.sample .env
```

| Variável | Padrão | Obrigatório | Descrição |
|---|---|---|---|
| `HOST_APP_EXTERNAL_PORT` | `5001` | não | Porta externa da aplicação web |
| `APP_LOG_LEVEL` | `INFO` | não | Nível de log (`DEBUG`, `INFO`, `WARNING`, `ERROR`) |
| `WEB_CONCURRENCY` | `1` | não | Workers HTTP do Gunicorn |
| `DATABASE_NAME` | `siscan_rpa` | não | Nome do banco PostgreSQL |
| `DATABASE_USER` | `siscan_rpa` | não | Usuário do banco PostgreSQL |
| `DATABASE_PASSWORD` | `siscan_rpa` | **sim** | Senha do banco — altere antes do primeiro start |
| `VOLUME_DB` | `siscan-db` | não | Volume Docker para dados do PostgreSQL |
| `VOLUME_DATA` | `siscan-data` | não | Volume Docker para autenticação Playwright |
| `VOLUME_MEDIA` | `siscan-media` | não | Volume Docker para downloads e relatórios |
| `VOLUME_LOGS` | `siscan-logs` | não | Volume Docker para logs operacionais |
| `VOLUME_CONFIG` | `siscan-config` | não | Volume Docker para arquivo de mapeamento de colunas |
| `CRON_INTERVAL_SECONDS` | `1800` | não | Intervalo entre execuções agendadas (segundos) |
| `RPA_MAX_ATTEMPTS` | `3` | não | Tentativas máximas em caso de falha |
| `SECRET_KEY` | gerada auto. | **sim** | Chave de assinatura de sessão — gerada pelo assistente se vazia |

> **Credenciais SISCAN** (usuário/senha do portal) são configuradas pela interface administrativa após o primeiro start:
> `http://localhost:<HOST_APP_EXTERNAL_PORT>/admin/siscan-credentials`

---

## Comandos úteis

```bash
# Subir a stack
docker compose up -d

# Ver logs em tempo real
docker compose logs -f

# Parar a stack
docker compose down

# Ver status dos containers
docker compose ps
```

---

## Estrutura do repositório

| Arquivo | Descrição |
|---|---|
| `siscan-assistente.sh` | Assistente interativo — Linux (bash) |
| `siscan-assistente.ps1` | Assistente interativo — Windows (PowerShell 7+) |
| `execute.ps1` | Wrapper de compatibilidade — Windows PowerShell 5.1 |
| `siscan-server-setup.sh` | Bootstrap do servidor — Opção 1.A self-hosted runner |
| `docker-compose.yml` | Orquestração Docker da stack SISCAN RPA |
| `.env.sample` | Exemplo de variáveis de ambiente |
| `.env.help.json` | Documentação de cada variável (lida pelo assistente) |
| `docs/` | Documentação adicional (deploy, troubleshooting, checklists) |

---

## Documentação adicional

- [DEPLOY](docs/DEPLOY.md) — Manual de deploy: requisitos e passo a passo.
- [TROUBLESHOOTING](docs/TROUBLESHOOTING.md) — Diagnóstico e coleta de artefatos.
- [ERRORS_TABLE](docs/ERRORS_TABLE.md) — Tabela de erros comuns.
- [CHECKLISTS](docs/CHECKLISTS.md) — Procedimentos operacionais e rollback.

Repositório da imagem principal: [Prisma-Consultoria/siscan-rpa](https://github.com/Prisma-Consultoria/siscan-rpa)
