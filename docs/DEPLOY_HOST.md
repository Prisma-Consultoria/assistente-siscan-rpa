# Guia de Deploy — Modo HOST (PC local)
<a name="deploy-host"></a>

Versão: 1.0
Data: 2026-03-18

Deploy em PC local (Windows ou Linux) com Docker Desktop. O banco de dados PostgreSQL roda em container local junto com a aplicação.

---

## Pré-requisitos

| Passo | O que Fazer | Como Fazer |
|---|---|---|
| 1 | Confirmar Docker Engine ≥ 24 instalado | `docker version` e `docker info` — ambos sem erros |
| 2 | Confirmar Docker Compose v2 | `docker compose version` — deve retornar `v2.x.x` |
| 3 | Ter `git` instalado | `git --version` |
| 4 | Verificar conectividade com o GHCR | `curl -s -o /dev/null -w "%{http_code}" https://ghcr.io` deve retornar `200` ou `301`. No Windows: `Test-NetConnection ghcr.io -Port 443` |
| 5 | Instalar Docker Desktop | Baixar em docker.com/desktop. Após instalação: abrir e aguardar o ícone estabilizar na bandeja |
| 6 | **Windows** — verificar PowerShell | `$PSVersionTable.PSVersion` — PowerShell 7+ recomendado; 5.1 suportado via `execute.ps1` |
| 7 | **Windows** — habilitar execução de scripts | PowerShell (Admin): `Set-ExecutionPolicy RemoteSigned -Scope LocalMachine`. Se houver GPO restritiva, use `execute.ps1` |
| 8 | Gerar token GitHub (PAT) com `read:packages` | GitHub → Settings → Developer settings → Personal access tokens → marcar `read:packages` → copiar imediatamente |

---

## Instalação

### Clonar o repositório

```bash
git clone https://github.com/Prisma-Consultoria/assistente-siscan-rpa.git
cd assistente-siscan-rpa
```

### Configurar o `.env`

```bash
cp .env.host.sample .env
```

Preencha os caminhos das pastas e altere a senha do banco antes de iniciar o assistente pela primeira vez. A seção [Referência de variáveis](#referência-de-variáveis--env) abaixo documenta todas as variáveis.

### Executar o assistente

Na primeira execução, o assistente solicita o **usuário GitHub** e o **token PAT** para autenticar no GHCR. Essas credenciais são salvas em `credenciais.txt` (na mesma pasta dos scripts) e reutilizadas nas execuções seguintes — não entram no `.env`.

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

Para resetar as credenciais (ex.: token expirou):

```powershell
# Windows
Remove-Item .\credenciais.txt -Force
```
```bash
# Linux
rm -f ./credenciais.txt
```

Escolha a **Opção 2 — Atualizar / Instalar** no menu para realizar a primeira instalação.

---

## Menu do Assistente — cada opção

O menu interativo apresenta 7 opções. O assistente valida o ambiente antes de executar cada ação.

### Opção 1 — Reiniciar o SISCAN RPA

Encerra todos os containers da stack e os sobe novamente (`docker compose down` + `docker compose up -d`). Resolve travamentos e falhas transitórias sem perda de dados.

| Mensagem de erro | Causa | Solução |
|---|---|---|
| `port is already allocated` | Porta do host em uso | `netstat -ano | findstr :5001` (Windows) ou `ss -ltnp | grep 5001` (Linux); encerrar o processo ou alterar `HOST_APP_EXTERNAL_PORT` |
| `container is unhealthy` | Healthcheck falhou | `docker compose -f docker-compose.prd.host.yml logs app --tail=50` |

### Opção 2 — Atualizar / Instalar o SISCAN RPA

Autentica no GHCR, faz `docker pull ghcr.io/prisma-consultoria/siscan-rpa-rpa:main` e recria os containers. Use na primeira instalação e quando o time técnico indicar nova versão.

| Mensagem de erro | Causa | Solução |
|---|---|---|
| `unauthorized` / `pull access denied` | Token PAT expirado ou sem `read:packages` | Apagar `credenciais.txt`; na próxima execução o assistente pedirá novas credenciais |
| `Cannot connect to ghcr.io` | Sem acesso à internet ou porta 443 bloqueada | Verificar rede; solicitar liberação ao TI. Ver [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — Problema A |

### Opção 3 — Editar configurações básicas

Editor interativo para variáveis do `.env`. Exibe descrição e exemplo de cada campo (lidos do `.env.help.json`). Variáveis `secret` têm o valor atual mascarado. Após salvar, oferece reiniciar os containers.

### Opção 4 — Executar tarefas RPA manualmente

Força execução imediata do ciclo de coleta no container `rpa-scheduler`, sem esperar o intervalo agendado (`CRON_INTERVAL_SECONDS`).

### Opção 5 — Histórico do Sistema

Exibe registros de reinicializações, travamentos e desligamentos inesperados do host. Útil para identificar quedas de energia ou instabilidades.

### Opção 6 — Atualizar o Assistente

Baixa a versão mais recente dos scripts via `git pull`. Se a atualização falhar, restaura a versão anterior automaticamente (rollback).

### Opção 7 — Sair

Encerra o assistente. Os containers continuam rodando em segundo plano.

---

## Referência de variáveis — `.env`

> ⚠️ **As variáveis essenciais do `.env` são gerenciadas pelo assistente (`siscan-assistente.sh` / `siscan-assistente.ps1`).** Para a maioria das operações do dia a dia — instalação, atualização, reinicialização e execução manual de coletas — o assistente cuida de tudo sem que o operador precise editar o arquivo diretamente.
>
> **Alterar variáveis manualmente no `.env` é recomendado apenas para técnicos de TI familiarizados com o sistema.** Uma alteração incorreta pode:
> - Impedir que os containers subam (ex.: caminho de pasta inválido ou variável obrigatória vazia);
> - Derrubar a comunicação entre a aplicação e o banco de dados (ex.: `DATABASE_HOST`, `DATABASE_PASSWORD` incorretos);
> - Interromper completamente a coleta de dados (ex.: `CRON_ENABLED=false` esquecido);
> - Causar esgotamento de disco (ex.: habilitar `TAKE_SCREENSHOT`, `PW_RECORD_VIDEO` ou `PW_TRACING`);
> - Tornar o painel web inacessível (ex.: `SECRET_KEY` alterada invalida todas as sessões ativas, `HOST_APP_EXTERNAL_PORT` conflitante bloqueia a porta).
>
> Em caso de dúvida, acione o suporte técnico da Prisma antes de editar.

O `.env.host.sample` cobre o modo HOST (`docker-compose.prd.host.yml`). As tabelas de configuração do dia a dia têm as colunas:

- **`.env.host.sample`** — valor que vem no arquivo de exemplo.
- **Default no compose** — valor usado se a variável **não** estiver no `.env`. Quando diz **`sem fallback`**, não há valor padrão e o `docker compose up` falha se a variável estiver ausente ou vazia.
- **Obrigatória?** — indica se precisa ser preenchida antes de subir o sistema.
- **O que é e quando alterar** — explicação em linguagem simples.

Variáveis que raramente precisam de ajuste (pool de conexões, timeouts, workers, scripts externos e variáveis fixas no compose) estão agrupadas em [Configurações avançadas](#configurações-avançadas).

> **Credenciais SISCAN** (usuário e senha do portal) são configuradas pela interface web após o primeiro start: `http://localhost:<HOST_APP_EXTERNAL_PORT>/admin/siscan-credentials`

### Aplicação HTTP

| Variável | `.env.host.sample` | Default no compose | Obrigatória? | O que é e quando alterar |
|---|---|---|---|---|
| `HOST_APP_EXTERNAL_PORT` | `5001` | `:-5001` | Não | Número da porta para acessar o sistema no navegador. Altere somente se a porta 5001 já estiver em uso no computador. |
| `APP_LOG_LEVEL` | `INFO` | `:-INFO` | Não | Detalhe dos registros de atividade. Deixe `INFO` no uso normal. Mude para `DEBUG` somente se o suporte técnico solicitar. |
| `SECRET_KEY` | *(vazio — gerado pelo assistente)* | sem fallback | **Sim** | Chave de segurança do painel web. O assistente gera automaticamente na primeira execução. Não compartilhe este valor. |

### Banco de dados

O banco PostgreSQL é gerenciado automaticamente pelo Docker no modo HOST — não é necessário instalar nada separadamente.

| Variável | `.env.host.sample` | Default no compose | Obrigatória? | O que é e quando alterar |
|---|---|---|---|---|
| `DATABASE_NAME` | `siscan_rpa` | `:-siscan_rpa` | Não | Nome interno do banco. Não altere, a menos que haja conflito com outro banco na mesma máquina. |
| `DATABASE_USER` | `siscan_rpa` | `:-siscan_rpa` | Não | Usuário interno do banco. Não altere sem orientação técnica. |
| `DATABASE_PASSWORD` | `siscan_rpa` | `:-siscan_rpa` | Não (**altere antes do primeiro start**) | Senha do banco. O valor padrão `siscan_rpa` é inseguro — **substitua por uma senha própria antes de subir o sistema pela primeira vez**. |
| `DATABASE_PORT` | `5432` | `:-5432` | Não | Porta interna do banco. Não altere. |
| `DATABASE_HOST` | `db` | `:-db` | Não | Endereço interno do banco. No modo HOST o banco roda na mesma stack Docker — **não altere**. |

### Scheduler batch

| Variável | `.env.host.sample` | Default no compose | Obrigatória? | O que é e quando alterar |
|---|---|---|---|---|
| `CRON_ENABLED` | `true` | `:-true` | Não | Liga (`true`) ou desliga (`false`) as coletas automáticas. Com `false` o container sobe executando apenas `sleep infinity` — útil para pausar temporariamente. |
| `CRON_INTERVAL_SECONDS` | `1800` | `:-1800` | Não | Intervalo entre coletas automáticas em segundos. `1800` = a cada 30 minutos. |

> ⚠️ **`CRON_ENABLED=false` paralisa completamente o processamento:** nenhum PDF é baixado do SISCAN e nenhum dado é extraído ou persistido no banco. O container `rpa-scheduler` fica ativo mas executa apenas `sleep infinity`. Use `false` somente para manutenção pontual e retorne para `true` imediatamente após.

Para `RPA_MAX_ATTEMPTS` e `RPA_BACKOFF_SECONDS` (retentativas e backoff exponencial), consulte [Configurações avançadas](#configurações-avançadas).

### Pastas no computador — bind mounts

Estas são as pastas do computador onde o sistema guardará os arquivos. **Todas as obrigatórias precisam ser preenchidas** — sem elas o sistema não sobe. O assistente cria as pastas automaticamente se não existirem.

No Windows use barras invertidas (`C:\pasta`); no Linux use barras normais (`/pasta`).

| Variável | `.env.host.sample` | Default no compose | Obrigatória? | O que é |
|---|---|---|---|---|
| `HOST_LOG_DIR` | `C:\siscan-rpa\logs` | sem fallback | **Sim** | Pasta onde ficam os registros de atividade do sistema. Inclua na rotina de backup. |
| `HOST_SISCAN_REPORTS_INPUT_DIR` | `C:\siscan-rpa\media\downloads` | sem fallback | **Sim** | Pasta onde os PDFs baixados do SISCAN são salvos. É a entrada do processamento de laudos. |
| `HOST_REPORTS_OUTPUT_CONSOLIDATED_DIR` | `C:\siscan-rpa\media\reports\mamografia\consolidated` | sem fallback | **Sim** | Pasta dos relatórios consolidados gerados (`.xlsx`, `.parquet`). |
| `HOST_REPORTS_OUTPUT_CONSOLIDATED_PDFS_DIR` | `C:\siscan-rpa\media\reports\mamografia\consolidated\laudos` | sem fallback | **Sim** | Pasta dos PDFs individuais por laudo, organizados em subpastas por status (`liberado/`, `comresultado/`, etc.). |
| `HOST_CONFIG_DIR` | `C:\siscan-rpa\config` | sem fallback | **Sim** | Pasta de configurações externas. Deve conter o arquivo `excel_columns_mapping.json`. |
| `HOST_BACKUPS_DIR` | `C:\siscan-rpa\backups` | `:-./backups` | Não | Pasta de destino dos backups do banco de dados. |

Estrutura de diretórios resultante no computador:

**Windows** (padrão sugerido em `C:\siscan-rpa\`):

```
C:\siscan-rpa\
├── logs\                                                 ← HOST_LOG_DIR
├── config\                                               ← HOST_CONFIG_DIR
│   └── excel_columns_mapping.json
├── media\
│   ├── downloads\                                        ← HOST_SISCAN_REPORTS_INPUT_DIR
│   └── reports\
│       └── mamografia\
│           └── consolidated\                             ← HOST_REPORTS_OUTPUT_CONSOLIDATED_DIR
│               ├── laudos\                               ← HOST_REPORTS_OUTPUT_CONSOLIDATED_PDFS_DIR
│               │   ├── liberado\
│               │   ├── comresultado\
│               │   └── ...
│               └── *.xlsx / *.parquet
├── scripts\
│   └── clients\                                          ← HOST_SCRIPTS_CLIENTS
└── backups\                                              ← HOST_BACKUPS_DIR
```

**Linux** (padrão sugerido em `/opt/siscan-rpa/`):

```
/opt/siscan-rpa/
├── logs/                                                 ← HOST_LOG_DIR
├── config/                                               ← HOST_CONFIG_DIR
│   └── excel_columns_mapping.json
├── media/
│   ├── downloads/                                        ← HOST_SISCAN_REPORTS_INPUT_DIR
│   └── reports/
│       └── mamografia/
│           └── consolidated/                             ← HOST_REPORTS_OUTPUT_CONSOLIDATED_DIR
│               ├── laudos/                               ← HOST_REPORTS_OUTPUT_CONSOLIDATED_PDFS_DIR
│               │   ├── liberado/
│               │   ├── comresultado/
│               │   └── ...
│               └── *.xlsx / *.parquet
├── scripts/
│   └── clients/                                          ← HOST_SCRIPTS_CLIENTS
└── backups/                                              ← HOST_BACKUPS_DIR
```

> **Windows vs Linux:** a estrutura de pastas é idêntica — apenas o separador muda (`\` no Windows, `/` no Linux) e a raiz (`C:\siscan-rpa\` vs `/opt/siscan-rpa/`). No `.env`, use o formato correspondente ao sistema operacional onde o Docker Desktop está rodando. Caminhos Windows com espaços ou caracteres especiais (`&`, `%`, `#`) podem causar erros no Docker — prefira caminhos simples como `C:\siscan-rpa\`.

### Opcional

Consulte o documento de referência: [**ENV_REFERENCE.md — Opcional**](https://github.com/Prisma-Consultoria/siscan-rpa/blob/main/docs/ENV_REFERENCE.md#opcional).

### Configurações avançadas

Variáveis que raramente precisam de ajuste em produção normal (concorrência de workers, pool de conexões SQLAlchemy, timeouts Playwright, scripts externos e variáveis com valor fixo no compose). Consulte o documento de referência: [**ENV_REFERENCE.md — Configurações avançadas**](https://github.com/Prisma-Consultoria/siscan-rpa/blob/main/docs/ENV_REFERENCE.md#configurações-avançadas).

---

## Primeiro acesso

1. Abrir o navegador em `http://localhost:<HOST_APP_EXTERNAL_PORT>` (padrão: `http://localhost:5001`).
2. Navegar até `/admin/siscan-credentials` e cadastrar usuário/senha do portal SISCAN.
3. A coleta automática iniciará no próximo ciclo agendado (padrão: 30 minutos).

---

## Comandos úteis

```powershell
# Status dos containers
docker compose -f docker-compose.prd.host.yml ps

# Logs em tempo real
docker compose -f docker-compose.prd.host.yml logs -f

# Logs das últimas 10 minutos
docker compose -f docker-compose.prd.host.yml logs --since 10m

# Testar health endpoint
Invoke-WebRequest http://localhost:5001/health -UseBasicParsing | Select-Object StatusCode, Content

# Verificar imagem instalada
docker images ghcr.io/prisma-consultoria/siscan-rpa-rpa

# Uso de disco pelo Docker
docker system df
```
