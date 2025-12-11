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
- PowerShell 7+ (`pwsh`) recomendado; existe um wrapper para PowerShell 5.1 (`execute.ps1`).
- Acesso à rede para puxar imagens ou acesso a registry privado com token.

## Instalação rápida

Recomendação (mais seguro): clonar o repositório e executar localmente:

```bash
git clone https://github.com/Prisma-Consultoria/assistente-siscan-rpa.git
cd assistente-siscan-rpa

# PowerShell Core (recomendado)
pwsh -File ./siscan-assistente.ps1

# Windows PowerShell (compatibilidade através do wrapper)
powershell -File .\\execute.ps1
```

Se for baixar o script direto do GitHub, sempre revise antes de executar:

```powershell
Invoke-WebRequest 'https://raw.githubusercontent.com/Prisma-Consultoria/assistente-siscan-rpa/main/siscan-assistente.ps1' -OutFile siscan-assistente.ps1
# revisar o arquivo localmente antes de executar
pwsh -NoProfile -ExecutionPolicy Bypass -File .\\siscan-assistente.ps1
```

## Configuração (`.env`)

1. Copie o exemplo:

```bash
cp .env.sample .env
```

1. Preencha os campos obrigatórios, por exemplo:

- `SISCAN_USER` / `SISCAN_PASSWORD` — credenciais do SISCAN (OBRIGATÓRIO).
- `HOST_CONSOLIDATED_EXCEL_DIR_PATH` — diretório onde o Excel consolidado será salvo (recomendado definir explicitamente).
- `HOST_EXCEL_COLUMNS_MAPPING_DIR` — diretório de configuração (recomendado definir explicitamente).

**Importante sobre caminhos:**
- O instalador converte automaticamente `\` para `/` (formato Docker).
- Você pode digitar `Z:\media\reports` que será convertido para `Z:/media/reports`.
- Observação: em ambientes WSL o caminho pode ser `/mnt/c/...` dependendo da configuração do Docker.

## Comandos úteis

- Iniciar serviços no diretório com `docker-compose.yml`:

```bash
docker compose up -d
```

- Ver logs:

```bash
docker compose logs -f
```

## Estrutura do repositório

- `siscan-assistente.ps1` — script principal (PowerShell Core) com menu interativo.
- `execute.ps1` — wrapper para compatibilidade com Windows PowerShell 5.1.
- `docker-compose.yml` — arquivo de orquestração (gerado/atualizado pelo instalador).
- `.env.sample` — exemplo de variáveis de ambiente.
- `docs/` — documentação adicional (deploy, troubleshooting, checklists).

## Como funciona (resumo)

- O bootstrap solicita credenciais e parâmetros, monta/atualiza `.env` e executa `docker compose` para criar/atualizar serviços.
- Operações de pull/restart são executadas via Docker Compose; credenciais de registro são utilizadas quando necessário.

## Solução de problemas básica

- `docker` não encontrado: instale Docker Desktop ou Docker Engine.
- `docker compose` não encontrado: instale Compose ou use a versão integrada ao Docker Desktop.
- `docker login` falha: verifique token/usuário e permissões no registry.
- Problemas de encoding em Windows PowerShell: prefira `pwsh` ou salve scripts com BOM para compatibilidade.
- **Caminhos Windows com caracteres especiais** (`&`, `%`, `!`): Docker não monta volumes corretamente. **Solução**: use mapeamento de unidade de rede (`net use Z: \\servidor\share`) ou renomeie pastas. Ver [Problema 8 no TROUBLESHOOTING](docs/TROUBLESHOOTING.md#problema-8--caminhos-windowsunc-com-caracteres-especiais).

### Caminhos UNC (compartilhamentos de rede)

**IMPORTANTE:** O instalador converte automaticamente barras invertidas (`\`) para barras normais (`/`).

Se usar caminhos UNC no `.env`:
```powershell
# ❌ ERRO - Docker não consegue montar:
HOST_MEDIA_ROOT=\\172.19.222.100\siscan_laudos&\media

# ✅ SOLUÇÃO - Mapear unidade primeiro:
net use Z: \\172.19.222.100\siscan_laudos /persistent:yes

# Pode digitar com \ ou / - será convertido automaticamente:
HOST_MEDIA_ROOT=Z:\media  (convertido para Z:/media)
# ou
HOST_MEDIA_ROOT=Z:/media
```

Referência: repositório da imagem principal — [Prisma-Consultoria/siscan-rpa](https://github.com/Prisma-Consultoria/siscan-rpa)

Outros problemas e diagnósticos estão disponíveis em: [TROUBLESHOOTING](docs/TROUBLESHOOTING.md#troubleshooting)

## Documentação de Deploy e Operação

Os documentos completos estão em `docs/`.

- [DEPLOY](docs/DEPLOY.md#deploy) — Manual de Deploy: requisitos e passo a passo.
- [TROUBLESHOOTING](docs/TROUBLESHOOTING.md#troubleshooting) — Diagnóstico e coleta de artefatos.
- [ERRORS_TABLE](docs/ERRORS_TABLE.md#errors) — Tabela de erros comuns.
- [CHECKLISTS](docs/CHECKLISTS.md#checklists) — Procedimentos operacionais e rollback.
