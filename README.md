# Assistente SISCAN

Scripts de instalação, configuração e operação do [SISCAN RPA](https://github.com/Prisma-Consultoria/siscan-rpa) e do [SISCAN Dashboard](https://github.com/Prisma-Consultoria/siscan-dashboard). Suporta três modos de operação conforme o cenário de deploy.

---

## Modos de operação

O assistente suporta três produtos, selecionados durante a instalação. Cada produto determina quais compose files, .env samples e serviços são gerenciados.

| Produto | Cenário | Compose | Serviços |
|---|---|---|---|
| `rpa` | VM dedicada ao RPA | `docker-compose.prd.rpa.yml` | migrate, app, rpa-scheduler |
| `dashboard` | VM dedicada ao Dashboard | `docker-compose.prd.dashboard.yml` | migrate, app, sync |
| `full` | HOST (PC local, tudo junto) | `docker-compose.prd.host.yml` | db + todos acima (7 containers) |

---

## Início rápido

### Modo HOST (PC local)

```bash
git clone https://github.com/Prisma-Consultoria/assistente-siscan-rpa.git
cd assistente-siscan-rpa
cp .env.host.sample .env
# Editar .env: DATABASE_PASSWORD, DASHBOARD_ADMIN_PASSWORD, caminhos HOST_*

# Windows:
pwsh -File .\siscan-assistente.ps1

# Linux:
bash ./siscan-assistente.sh
```

Escolha a **Opção 2 — Atualizar / Instalar** no menu. Guia completo: [docs/DEPLOY_HOST.md](docs/DEPLOY_HOST.md).

### Modo Servidor (VM dedicada)

```bash
git clone https://github.com/Prisma-Consultoria/assistente-siscan-rpa.git
cd assistente-siscan-rpa

# VM do RPA:
bash ./siscan-server-setup.sh --product rpa

# VM do Dashboard:
bash ./siscan-server-setup.sh --product dashboard
```

O script configura tudo interativamente (`.env`, diretórios, runner GitHub Actions). Guia completo: [docs/DEPLOY_SERVER.md](docs/DEPLOY_SERVER.md).

---

## Menu do assistente

O menu se adapta ao produto detectado via `SISCAN_PRODUCT` no `.env`. No modo `full`, todas as opções estão disponíveis.

| Opção | Descrição | Produtos |
|---|---|---|
| 1 — Reiniciar | Para e sobe os containers | Todos |
| 2 — Atualizar / Instalar | Pull das imagens + recria containers | Todos |
| 3 — Editar configurações | Editor interativo do `.env` | Todos |
| 4 — Executar RPA manualmente | Força ciclo de coleta do SISCAN | `rpa`, `full` |
| 5 — Sync Dashboard | Sincroniza dados do RPA para o dashboard | `dashboard`, `full` |
| 6 — Histórico do Sistema | Reinicializações e desligamentos do host | Todos |
| 7 — Atualizar o Assistente | Baixa versão mais recente dos scripts | Todos |
| 8 — Sair | Encerra o assistente | Todos |

---

## Estrutura do repositório

| Arquivo | Descrição |
|---|---|
| `siscan-assistente.sh` | Assistente interativo — Linux (bash) |
| `siscan-assistente.ps1` | Assistente interativo — Windows (PowerShell 7+) |
| `execute.ps1` | Wrapper de compatibilidade — Windows PowerShell 5.1 |
| `siscan-server-setup.sh` | Bootstrap do servidor — `--product rpa\|dashboard\|full` |
| `docker-compose.prd.host.yml` | Compose HOST — RPA + Dashboard + banco local |
| `docker-compose.prd.rpa.yml` | Compose Servidor — RPA com banco externo |
| `docker-compose.prd.dashboard.yml` | Compose Servidor — Dashboard com banco externo |
| `.env.host.sample` | Variáveis — modo HOST (produto `full`) |
| `.env.server-rpa.sample` | Variáveis — modo Servidor RPA |
| `.env.server-dashboard.sample` | Variáveis — modo Servidor Dashboard |
| `scripts/docker/init-databases.sh` | Init script PostgreSQL — cria segundo banco no modo HOST |
| `.env.help.json` | Metadados das variáveis (lidos pelo assistente) |

---

## Documentação

| Documento | Conteúdo |
|---|---|
| [DEPLOY_HOST.md](docs/DEPLOY_HOST.md) | Guia completo do modo HOST: pré-requisitos, instalação, menu, variáveis, primeiro acesso |
| [DEPLOY_SERVER.md](docs/DEPLOY_SERVER.md) | Guia do modo Servidor: arquitetura 3 VMs, `--product`, fases do setup, variáveis por produto |
| [CHECKLISTS.md](docs/CHECKLISTS.md) | Checklists operacionais por produto: antes do deploy, após instalação, rollback |
| [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Problemas comuns: GHCR, `.env`, Docker, sync do dashboard |

---

## Testes

```bash
# Instalar bats (se necessário)
sudo apt install bats

# Executar testes
bats tests/
```
