# Assistente SISCan RPA

Assistente SISCan RPA — instalador remoto (PowerShell + Bash) para instalar, atualizar e gerenciar o serviço "Assistente SISCan RPA".

Conteúdo deste README

- Visão geral
- Pré-requisitos
- Instalação rápida
- Configuração (`.env`)
- Comandos úteis
- Estrutura do repositório
- Como funciona
- Resolução de problemas básica
- Documentação de deploy e operação

## Visão geral

O instalador solicita as informações necessárias (token para registry, credenciais SISCAN, caminhos de diretórios) e cria/atualiza os serviços Docker via `docker compose`.

Usuários não técnicos: forneça os caminhos e credenciais solicitadas; o instalador fará o restante.

## Pré-requisitos

- Docker Desktop (Windows) ou Docker Engine (Linux/macOS).
- Docker Compose (v2 integrado ao Docker Desktop ou `docker-compose`).
- Acesso à rede para baixar imagens ou acesso ao registry privado com token.

## Instalação rápida

Windows (PowerShell):

```powershell
irm "https://raw.githubusercontent.com/Prisma-Consultoria/assistente-siscan-rpa/main/install.ps1" | iex
```

Linux / macOS (Bash):

```bash
curl -sSL https://raw.githubusercontent.com/Prisma-Consultoria/assistente-siscan-rpa/main/install.sh | bash
```

Se preferir inspecionar os scripts, clone este repositório e execute `install.ps1` / `install.sh` localmente.

## Configuração (`.env`)

1. Copie o exemplo:

```bash
cp .env.sample .env
```

2. Preencha os campos obrigatórios, por exemplo:

- `SISCAN_USER` / `SISCAN_PASSWORD` — credenciais do SISCAN.
- `HOST_MEDIA_ROOT` — pasta onde screenshots e downloads serão salvos (ex.: `C:\siscan\media`).
- `HOST_DOWNLOAD_DIR` — pasta de downloads do Playwright.
- `HOST_SISCAN_REPORTS_INPUT_DIR` / `HOST_SISCAN_REPORTS_OUTPUT_DIR` — entradas e saídas de relatórios.

Observação: em ambientes WSL o caminho pode ser `/mnt/c/...` dependendo da configuração do Docker.

## Comandos úteis

- Iniciar serviços (diretório com `docker-compose.yml`):

```bash
docker compose up -d
```

- Ver logs:

```bash
docker compose logs -f
```

## Estrutura do repositório

- `install.ps1` / `install.sh` — bootstrap que interage com o usuário e baixa módulos.
- `scripts/modules/` — módulos que executam tarefas (docker, siscan, etc.).
- `docker-compose.yml` — gerado pelo instalador quando necessário.
- `.env.sample` — exemplo de variáveis de ambiente.

## Como funciona (resumo)

- O bootstrap baixa módulos em `scripts/modules/` e executa o fluxo.
- Módulos são cacheados localmente para execução offline/recuperação.
- Credenciais e tokens são solicitados via entrada segura; não são gravados em texto puro nos logs.

## Troubleshooting básico

- Erro: `docker` não encontrado — instale Docker Desktop (Windows) ou Docker Engine (Linux).
- Erro: `docker compose` não encontrado — instale a versão compatível do Compose.
- Erro no `docker login` — verifique token/usuário e permissões do registry.
- Permissões em pastas (Windows): execute o PowerShell como Administrador ou ajuste permissões NTFS.

---

Referência: repositório da imagem principal — [Prisma-Consultoria/siscan-rpa](https://github.com/Prisma-Consultoria/siscan-rpa)

## Documentação de Deploy e Operação

Os documentos completos estão em `docs/`.

- [DEPLOY](docs/DEPLOY.md#deploy) — Manual de Deploy: requisitos, arquitetura, passo a passo completo.
- [TROUBLESHOOTING](docs/TROUBLESHOOTING.md#troubleshooting) — Diagnóstico, coleta de artefatos e árvores de decisão.
- [ERRORS_TABLE](docs/ERRORS_TABLE.md#errors) — Tabela com 40+ erros comuns e soluções.
- [CHECKLISTS](docs/CHECKLISTS.md#checklists) — Checklists operacionais e procedimentos de rollback.

Como usar: comece por `docs/DEPLOY.md`; em caso de falha, siga `docs/TROUBLESHOOTING.md` e consulte `docs/ERRORS_TABLE.md`; antes de mudanças críticas, use `docs/CHECKLISTS.md`.

Se quiser, posso gerar um `docs/docker-compose.example.yml` anotado ou versões PDF desses documentos.
# Assistente SISCan RPA

**Assistente SISCan RPA — Instalador remoto**

Este repositório contém um instalador remoto modular (PowerShell + Bash) para instalar, atualizar e gerenciar o serviço "Assistente SISCan RPA".

Resumo

- Objetivo: fornecer um instalador simples para usuários finais (técnicos e não técnicos).

Conteúdo deste README

- Visão geral
- Pré-requisitos
- Instalação rápida
- Configuração (`.env`)
- Estrutura do repositório
- Como funciona
- Resolução de problemas (troubleshooting)

## Visão geral

O instalador solicita as informações necessárias (token para registry, credenciais SISCAN, caminhos de diretórios) e cria/atualiza os serviços Docker via `docker-compose`.

Para operadores não técnicos: você só precisa fornecer algumas informações básicas e criar pastas no Windows quando solicitado. O instalador trata do restante das operações.

- O que contém: introdução ao produto, requisitos mínimos, arquitetura do deploy, componentes (Docker, GHCR, scripts), pré-requisitos detalhados (Docker, Docker Compose, Windows, rede e permissões) e o passo a passo completo do deploy (download, posicionamento dos arquivos, criação do `.env`, autenticação no GHCR, pull da imagem, `docker compose up -d`, validação e exemplos de checagem).

- [`TROUBLESHOOTING`](docs/TROUBLESHOOTING.md#troubleshooting) — Guia de Troubleshooting.

- O que contém: comandos de coleta rápida, diagnóstico e correções para problemas com Docker (daemon/WSL2), Docker Compose, GHCR, Windows (políticas/Defender/NTFS) e rede; árvores de decisão e procedimentos para coleta de artefatos antes do escalonamento.

- [`ERRORS_TABLE`](docs/ERRORS_TABLE.md#errors) — Tabela de Erros Comuns (busca rápida).

- O que contém: 40+ erros frequentes com a mensagem típica, causa provável e solução prática (rede, Docker, compose, permissões, GHCR, WSL2, etc.). Use este arquivo para localizar rapidamente a provável causa e o passo de remediação.

- [`CHECKLISTS`](docs/CHECKLISTS.md#checklists) — Checklists Operacionais.

- O que contém: checklists para executar antes do deploy (staging), após o deploy, antes de atualizar/upgrade e procedimentos rápidos de rollback/emergência com comandos úteis.

Como usar: comece por `docs/DEPLOY.md` para realizar o deploy; se ocorrerem falhas, siga `docs/TROUBLESHOOTING.md` e procure mensagens no `docs/ERRORS_TABLE.md`; antes de mudanças críticas, consulte `docs/CHECKLISTS.md`.

Se desejar, posso também:

- Gerar um `docs/docker-compose.example.yml` anotado com comentários e caminhos recomendados.
- Produzir versões PDF/print-ready desses documentos.

# Assistente SISCan RPA

**Assistente SISCan RPA — Instalador remoto**

Este repositório contém um instalador remoto modular (PowerShell + Bash) para instalar, atualizar e gerenciar o serviço "Assistente SISCan RPA".

Resumo

- Objetivo: fornecer um instalador simples para usuários finais (técnicos e não técnicos).

Conteúdo deste README

- Visão geral
- Pré-requisitos
- Instalação rápida
- Configuração (`.env`)
- Estrutura do repositório
- Como funciona
- Resolução de problemas (troubleshooting)

Visão geral

O instalador solicita as informações necessárias (token para registry, credenciais SISCAN, caminhos de diretórios) e cria/atualiza os serviços Docker via `docker-compose`.

Para operadores não técnicos: você só precisa fornecer algumas informações básicas e criar pastas no Windows quando solicitado. O instalador trata do restante das operações.

Pré-requisitos

- Docker Desktop (Windows) ou Docker Engine (Linux/macOS).
- Docker Compose (v2 integrado ao Docker Desktop ou `docker-compose`).
- Acesso à internet para baixar imagens e módulos, ou acesso ao registry privado com token.

Instalação rápida

Windows (PowerShell):

```powershell
irm "https://raw.githubusercontent.com/Prisma-Consultoria/assistente-siscan-rpa/main/install.ps1" | iex
```

Linux / macOS (Bash):

```bash
curl -sSL https://raw.githubusercontent.com/Prisma-Consultoria/assistente-siscan-rpa/main/install.sh | bash
```

Se preferir inspecionar os scripts antes de executar, clone este repositório e execute `install.ps1` / `install.sh` localmente.

Configuração (`.env`)
