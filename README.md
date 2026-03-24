# Assistente SISCAN

Scripts de instalação, configuração e operação do [SISCAN RPA](https://github.com/Prisma-Consultoria/siscan-rpa) e do [SISCAN Dashboard](https://github.com/Prisma-Consultoria/siscan-dashboard). Suporta três modos de operação: `rpa` (VM dedicada), `dashboard` (VM dedicada) e `full` (HOST, tudo junto).

---

## Cenários de uso

| Cenário | Script | Sistema |
|---|---|---|
| **Desktop / HOST** — instalação e operação em máquina local | `siscan-assistente.sh` / `siscan-assistente.ps1` | Linux ou Windows |
| **Servidor — Opção 1.A** — deploy automatizado via Imagem Certificada com self-hosted runner | `siscan-server-setup.sh` | Ubuntu Server 22.04+ |

---

## Desktop / HOST — Linux e Windows

Menu interativo para instalar, configurar, atualizar e operar o SISCAN RPA em máquina local com Docker.

Usa `docker-compose.prd.host.yml` — inclui o serviço `db` (PostgreSQL local em container).

### Pré-requisitos

- Docker Engine (Linux) ou Docker Desktop (Windows).
- Docker Compose v2 (plugin integrado ou standalone).
- **Linux:** bash 4+; `jq` opcional (para leitura de `.env.help.json`); `curl` ou `wget`.
- **Windows:** PowerShell 7+ (`pwsh`) recomendado. PowerShell 5.1 suportado via `execute.ps1`.

### Início rápido

```bash
git clone https://github.com/Prisma-Consultoria/assistente-siscan-rpa.git
cd assistente-siscan-rpa
cp .env.host.sample .env
# Edite o .env com os caminhos HOST_* e altere DATABASE_PASSWORD e SECRET_KEY
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

| Opção | Ação | Quando usar |
|---|---|---|
| 1 | **Reiniciar o SISCAN RPA** | O sistema está travado, lento ou parou de responder. É o equivalente a "desligar e ligar" — resolve a maioria dos problemas do dia a dia sem perder dados. |
| 2 | **Atualizar / Instalar o SISCAN RPA** | Primeira instalação ou quando a equipe técnica avisar que há uma nova versão disponível. O assistente baixa e aplica a atualização automaticamente. |
| 3 | **Editar configurações básicas** | Precisa alterar uma pasta, senha ou outra configuração do sistema. Exibe cada configuração com explicação e permite editar o valor. |
| 4 | **Executar tarefas RPA manualmente** | Precisa rodar a coleta de dados agora, sem esperar o horário automático agendado. Útil para testes ou coletas fora do ciclo normal. |
| 5 | **Histórico do Sistema** | Quer verificar se o computador reiniciou sozinho, travou ou desligou inesperadamente. Ajuda a identificar instabilidades no ambiente. |
| 6 | **Atualizar o Assistente** | A equipe técnica orientou a atualizar este menu. Baixa a versão mais recente do assistente e, se algo der errado, desfaz a atualização automaticamente. |
| 7 | **Sair** | Encerra o assistente. O SISCAN RPA continua rodando normalmente em segundo plano. |

### Referência de variáveis — `.env.host.sample`

O `.env.host.sample` cobre o modo HOST (`docker-compose.prd.host.yml`). Copie-o para `.env`, preencha os **caminhos das pastas** e **altere a senha do banco** antes de iniciar o assistente pela primeira vez.

As tabelas abaixo têm quatro colunas de referência:

- **`.env.host.sample`** — o valor que vem escrito no arquivo de exemplo. É o ponto de partida.
- **Default no compose** — valor que o sistema usa se a variável **não** estiver no `.env`. Quando a coluna diz **`sem fallback`**, o sistema não tem valor padrão e o `docker compose up` falha se a variável estiver em branco ou ausente. Essas variáveis são obrigatoriamente preenchidas.
- **Obrigatória?** — indica se a variável precisa ser preenchida antes de subir o sistema.
- **O que é e quando alterar** — explicação em linguagem simples.

> **Credenciais SISCAN** (usuário e senha do portal) são configuradas pela interface web após o primeiro start: `http://localhost:<HOST_APP_EXTERNAL_PORT>/admin/siscan-credentials`

#### Aplicação HTTP

| Variável | `.env.host.sample` | Default no compose | Obrigatória? | O que é e quando alterar |
|---|---|---|---|---|
| `HOST_APP_EXTERNAL_PORT` | `5001` | `:-5001` | Não | Número da porta para acessar o sistema no navegador — URL: `http://localhost:5001`. Altere somente se a porta 5001 já estiver em uso no computador. |
| `APP_LOG_LEVEL` | `INFO` | `:-INFO` | Não | Detalhe dos registros de atividade. Deixe `INFO` no uso normal. Mude para `DEBUG` somente se o suporte técnico solicitar para diagnóstico. |
| `WEB_CONCURRENCY` | `2` | `:-2` | Não | Número de processos internos que atendem as requisições. O valor `2` já é o ideal para PC com ~4 núcleos de CPU — não altere sem orientação técnica. |
| `SECRET_KEY` | *(vazio — gerado pelo assistente)* | sem fallback | **Sim** | Chave de segurança do painel web. O assistente gera automaticamente na primeira execução. Não compartilhe este valor. |

#### Banco de dados

O banco de dados PostgreSQL é gerenciado automaticamente pelo Docker no modo HOST — não é necessário instalar nada separadamente.

| Variável | `.env.host.sample` | Default no compose | Obrigatória? | O que é e quando alterar |
|---|---|---|---|---|
| `DATABASE_NAME` | `siscan_rpa` | `:-siscan_rpa` | Não | Nome interno do banco. Não altere, a menos que haja conflito com outro banco na mesma máquina. |
| `DATABASE_USER` | `siscan_rpa` | `:-siscan_rpa` | Não | Usuário interno do banco. Não altere sem orientação técnica. |
| `DATABASE_PASSWORD` | `siscan_rpa` | `:-siscan_rpa` | Não (**altere antes do primeiro start**) | Senha do banco de dados. O valor padrão `siscan_rpa` é inseguro — **substitua por uma senha própria antes de subir o sistema pela primeira vez**. |
| `DATABASE_PORT` | `5432` | `:-5432` | Não | Porta interna do banco. Não altere. |
| `DATABASE_HOST` | `db` | `:-db` | Não | Endereço interno do banco. No modo HOST o banco roda na mesma stack Docker — **não altere**. |

#### Pool de conexões SQLAlchemy

Controla quantas conexões simultâneas ao banco cada processo mantém abertas. Os valores abaixo são calibrados para PCs com ~4 núcleos e raramente precisam ser alterados.

| Variável | `.env.host.sample` | Default no compose | Obrigatória? | O que é |
|---|---|---|---|---|
| `SQLALCHEMY_POOL_SIZE` | `4` | `:-4` | Não | Conexões permanentes por processo. Deve ser ≥ ao número de núcleos do PC (mínimo 2). |
| `SQLALCHEMY_MAX_OVERFLOW` | `1` | `:-1` | Não | Conexões extras temporárias para absorver picos. Fechadas automaticamente logo após o pico. |
| `SQLALCHEMY_POOL_TIMEOUT` | `30` | `:-30` | Não | Segundos aguardando conexão livre antes de registrar erro. |
| `SQLALCHEMY_POOL_RECYCLE` | `1800` | `:-1800` | Não | Tempo de vida máximo de uma conexão em segundos (30 min). Evita conexões "mortas" por inatividade de rede. |

#### Scheduler batch

| Variável | `.env.host.sample` | Default no compose | Obrigatória? | O que é e quando alterar |
|---|---|---|---|---|
| `CRON_ENABLED` | `true` | `:-true` | Não | Liga (`true`) ou desliga (`false`) as coletas automáticas agendadas. Com `false` o container sobe mas não executa — útil para pausar temporariamente sem desligar o sistema. |
| `CRON_INTERVAL_SECONDS` | `1800` | `:-1800` | Não | Intervalo entre coletas automáticas em segundos. `1800` = a cada 30 minutos. |
| `RPA_MAX_ATTEMPTS` | `3` | `:-3` | Não | Quantas vezes o sistema tenta novamente em caso de falha de rede ou instabilidade do SISCAN antes de desistir. |

#### Pastas no computador — bind mounts

Estas são as pastas do computador onde o sistema guardará os arquivos. **Todas as obrigatórias precisam ser preenchidas** — sem elas o sistema não sobe. O assistente cria as pastas automaticamente se não existirem.

No Windows use barras invertidas (`C:\pasta`); no Linux use barras normais (`/pasta`).

| Variável | `.env.host.sample` | Default no compose | Obrigatória? | O que é |
|---|---|---|---|---|
| `HOST_LOG_DIR` | `C:\siscan-rpa\logs` | sem fallback | **Sim** | Pasta onde ficam os registros de atividade do sistema. Inclua na rotina de backup. |
| `HOST_SISCAN_REPORTS_INPUT_DIR` | `C:\siscan-rpa\media\downloads` | sem fallback | **Sim** | Pasta onde os PDFs baixados do SISCAN são salvos. É a entrada do processamento de laudos. |
| `HOST_REPORTS_OUTPUT_CONSOLIDATED_DIR` | `C:\siscan-rpa\media\reports\mamografia\consolidated` | sem fallback | **Sim** | Pasta dos relatórios consolidados gerados (`.xlsx`, `.parquet`). |
| `HOST_REPORTS_OUTPUT_CONSOLIDATED_PDFS_DIR` | `C:\siscan-rpa\media\reports\mamografia\consolidated\laudos` | sem fallback | **Sim** | Pasta dos PDFs individuais por laudo, organizados em subpastas por status (`liberado/`, `comresultado/`, etc.). |
| `HOST_CONFIG_DIR` | `C:\siscan-rpa\config` | sem fallback | **Sim** | Pasta de configurações externas. Deve conter o arquivo `excel_columns_mapping.json`. |
| `HOST_SCRIPTS_CLIENTS` | `C:\siscan-rpa\scripts\clients` | `:-./scripts/clients` | Não | Pasta com scripts operacionais do operador (ex.: `backup_manager.sh`). |
| `HOST_BACKUPS_DIR` | `C:\siscan-rpa\backups` | `:-./backups` | Não | Pasta de destino dos backups do banco de dados. |

#### Opcional

| Variável | `.env.host.sample` | Default no compose | O que é e quando alterar |
|---|---|---|---|
| `PW_CONTEXT_TIMEZONE` | *(comentado)* | `:-America/Fortaleza` | Fuso horário do agendador e dos registros de log. Altere se o computador operar em fuso diferente de Fortaleza/Brasília. |
| `PW_CONTEXT_STORAGE_STATE_STRICT` | `true` | `:-true` | `true` = reutiliza a sessão de login do SISCAN entre coletas (recomendado). `false` = faz login do zero a cada coleta. |
| `HOST_SHEET_COLUMNS_MAPPING_NAME` | *(comentado)* | `:-excel_columns_mapping.json` | Nome do arquivo JSON de mapeamento de colunas dentro de `HOST_CONFIG_DIR`. Altere somente se usar um arquivo com nome diferente do padrão. |
| `SISCAN_CONSOLIDATED_SHEET_NAME` | *(comentado)* | `:-consolidated_report_results_default.xlsx` | Nome alternativo do relatório consolidado Excel gerado. Normalmente não é necessário alterar. |

#### Variáveis com valor fixo no compose — definir no `.env` não tem efeito

Os composes de produção fixam os valores abaixo como strings literais. Qualquer valor definido no `.env` para essas variáveis é ignorado.

| Variável | Valor fixo | Por que está fixo |
|---|---|---|
| `PW_HEADLESS` | `"true"` | Produção sempre roda sem interface gráfica de navegador. |
| `PW_BROWSER` | `"chromium"` | Browser homologado e testado para o SISCAN. |
| `PW_CONTEXT_STORAGE_STATE` | `"/app/data/.artifacts/auth/storage_state.json"` | Caminho interno fixo para o arquivo de sessão salva. |
| `TAKE_SCREENSHOT` | `"false"` | Capturas de tela de diagnóstico desabilitadas em produção. |
| `PW_RECORD_VIDEO` | `"false"` | Gravação de vídeo desabilitada — consumiria espaço excessivo em produção. |
| `PW_TRACING` | `"false"` | Rastreamento de diagnóstico desabilitado em produção. |
| `SAVE_PAGE_HTML` | `"false"` | Dump de HTML desabilitado em produção. |

---

## Servidor — Deploy via Imagem Certificada (Opção 1.A)

Configura um servidor Linux para receber deploys automáticos do SISCAN RPA via GitHub Actions com self-hosted runner.

Usa `docker-compose.prd.rpa.yml` — sem serviço `db` local; conecta ao PostgreSQL externo definido em `DATABASE_HOST`.

O script executa **uma única vez** por servidor e percorre 8 fases lineares:

| Fase | Descrição | O que acontece |
|---|---|---|
| 1 | Verificação de pré-requisitos | Confirma que Docker, Compose, `curl` e `sudo` estão instalados e nas versões mínimas exigidas. O script para imediatamente se algo estiver faltando, antes de alterar qualquer coisa no servidor. |
| 2 | Criação da estrutura de diretórios | Cria o diretório principal da stack no servidor (`/opt/siscan-rpa` por padrão). É aqui que ficam o arquivo `docker-compose` e o `.env` de produção. |
| 3 | Cópia dos arquivos da stack | Copia `docker-compose.prd.rpa.yml` do repositório para o diretório criado na fase anterior. Este é o arquivo que o GitHub Actions usará em cada deploy automático. |
| 4 | Configuração do `.env` | Se o arquivo `.env` ainda não existe no servidor, cria um a partir do `.env.host.sample`. O script pausa e orienta quais variáveis precisam ser preenchidas antes de continuar. |
| 5 | Criação dos diretórios de dados | Lê as variáveis `HOST_*` do `.env` e cria no servidor as pastas para logs, PDFs do SISCAN, relatórios consolidados e configurações. Sem essas pastas o Docker não sobe. |
| 6 | Download e registro do runner | Baixa o agente do GitHub Actions e o registra no repositório `siscan-rpa` com o token fornecido. É este agente que receberá e executará os deploys automáticos futuros. |
| 7 | Ajuste de permissões Docker | Adiciona o usuário corrente ao grupo `docker` para que o runner possa executar comandos Docker sem `sudo`. Requer logout/login para ter efeito. |
| 8 | Resumo e próximos passos | Exibe um checklist com o que foi feito e o que ainda precisa ser feito manualmente (ex.: preencher credenciais SISCAN, configurar firewall, validar conexão com o banco). |

### Pré-requisitos

- Ubuntu Server 22.04+ (ou distribuição Linux compatível).
- Docker Engine ≥ 24 e Docker Compose v2 (plugin).
- `curl` e `sudo`.
- Token de registro de runner do repositório `siscan-rpa` (GitHub → Settings → Actions → Runners).
- PostgreSQL 16+ externo acessível pelo servidor (hostname/IP em `DATABASE_HOST`).

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

### Referência de variáveis — `.env` (modo servidor)

No modo servidor, o `siscan-server-setup.sh` cria o `.env` a partir do `.env.server-rpa.sample` na fase 4. A tabela abaixo documenta todas as variáveis relevantes para `docker-compose.prd.rpa.yml`.

- **`.env.server-rpa.sample`** — valor sugerido no arquivo de exemplo (caminhos em formato Windows — substitua por caminhos Linux no servidor).
- **Default no compose** — fallback declarado com `${VAR:-default}`. Quando diz **`sem fallback`**, a variável não tem valor padrão: o `docker compose up` falha se estiver ausente ou vazia no `.env`.
- **Obrigatória?** — indica se a variável precisa ser explicitamente definida no `.env`.
- **O que faz / Impacto** — comportamento e consequências arquiteturais.

> **Credenciais SISCAN** são configuradas pela interface web após o primeiro start: `http://<IP-DO-SERVIDOR>:<HOST_APP_EXTERNAL_PORT>/admin/siscan-credentials`

#### Aplicação HTTP

| Variável | `.env.server-rpa.sample` | Default no compose | Obrigatória? | O que faz / Impacto |
|---|---|---|---|---|
| `HOST_APP_EXTERNAL_PORT` | `5001` | `:-5001` | Não | Porta TCP publicada no host. URL de acesso: `http://<IP>:<porta>`. |
| `APP_LOG_LEVEL` | `INFO` | `:-INFO` | Não | Verbosidade dos logs. Use `INFO` em produção; `DEBUG` gera alto volume — somente para diagnóstico. |
| `WEB_CONCURRENCY` | `4` | `:-4` | Não | Workers Gunicorn. 1 worker/vCPU com 4 vCPUs dedicadas. Cada worker = processo OS com pool de conexões próprio. |
| `SECRET_KEY` | *(vazio — preencher)* | sem fallback | **Sim** | Assina cookies de sessão do painel web. A aplicação recusa iniciar sem ela. Gere com `openssl rand -hex 32`. |

#### Banco de dados

| Variável | `.env.server-rpa.sample` | Default no compose | Obrigatória? | O que faz / Impacto |
|---|---|---|---|---|
| `DATABASE_NAME` | `siscan_rpa` | `:-siscan_rpa` | Não | Nome do banco operacional no PostgreSQL externo. |
| `DATABASE_USER` | `siscan_rpa` | `:-siscan_rpa` | Não | Usuário PostgreSQL da aplicação e das migrations. |
| `DATABASE_PASSWORD` | `siscan_rpa` | `:-siscan_rpa` | Não (**altere em produção**) | Senha do banco. O valor padrão é inseguro — substitua antes do primeiro start. |
| `DATABASE_PORT` | `5432` | `:-5432` | Não | Porta TCP do PostgreSQL externo. |
| `DATABASE_HOST` | *(vazio — preencher)* | **sem fallback** | **Sim** | IP ou hostname do PostgreSQL externo. Sem fallback — o container falha no boot se omitido. Exemplo: `192.168.1.10`. |

#### Pool de conexões SQLAlchemy

Cada processo mantém pool próprio. Total de conexões no banco externo com os defaults: `4×(4+2) [app] + 1×(4+2) [rpa-scheduler] = 30 conexões`.

| Variável | `.env.server-rpa.sample` | Default no compose | Obrigatória? | O que faz / Impacto |
|---|---|---|---|---|
| `SQLALCHEMY_POOL_SIZE` | `4` | `:-4` | Não | Conexões permanentes por processo. Deve ser ≥ workers efetivos do `processar_laudos` — com 4 vCPUs: `min(max(4,2), 8) = 4`. |
| `SQLALCHEMY_MAX_OVERFLOW` | `2` | `:-2` | Não | Conexões extras temporárias acima do pool base. Banco externo dedicado suporta pico maior. |
| `SQLALCHEMY_POOL_TIMEOUT` | `30` | `:-30` | Não | Segundos aguardando conexão livre antes de falhar. Timeout recorrente indica saturação — revise a concorrência ou as queries. |
| `SQLALCHEMY_POOL_RECYCLE` | `1800` | `:-1800` | Não | Vida máxima de uma conexão em segundos. Evita reutilizar conexões mortas por NAT, idle-timeout ou balanceadores. |

#### Scheduler batch

| Variável | `.env.server-rpa.sample` | Default no compose | Obrigatória? | O que faz / Impacto |
|---|---|---|---|---|
| `CRON_ENABLED` | `true` | `:-true` | Não | Habilita o container `rpa-scheduler`. `false` = container sobe mas executa `sleep infinity` — útil para desabilitar o batch sem remover o serviço. |
| `CRON_INTERVAL_SECONDS` | `1800` | `:-1800` | Não | Intervalo entre ciclos RPA em segundos. `1800` = a cada 30 minutos. |
| `RPA_MAX_ATTEMPTS` | `3` | `:-3` | Não | Tentativas máximas em falhas transitórias de rede/SISCAN (1 inicial + N−1 repetições). |

#### Persistência no host — bind mounts

Diretórios do servidor montados nos containers. **Sem eles o `docker compose up` falha.** O `siscan-server-setup.sh` cria esses diretórios na fase 5 a partir dos valores definidos no `.env`.

> O `.env.server-rpa.sample` usa caminhos Windows como exemplo. No servidor Linux, defina caminhos absolutos: ex. `/opt/siscan-rpa/logs`.

| Variável | `.env.server-rpa.sample` (exemplo Windows) | Default no compose | Obrigatória? | O que faz |
|---|---|---|---|---|
| `HOST_LOG_DIR` | `C:\siscan-rpa\logs` | sem fallback | **Sim** | Logs da aplicação e do scheduler → `/app/logs` no container. Inclua na rotina de backup. |
| `HOST_SISCAN_REPORTS_INPUT_DIR` | `C:\siscan-rpa\media\downloads` | sem fallback | **Sim** | PDFs baixados do SISCAN → `/app/media/downloads`. Entrada do pipeline `processar_laudos`. |
| `HOST_REPORTS_OUTPUT_CONSOLIDATED_DIR` | `C:\siscan-rpa\media\reports\mamografia\consolidated` | sem fallback | **Sim** | Artefatos consolidados (`.xlsx`, `.parquet`). |
| `HOST_REPORTS_OUTPUT_CONSOLIDATED_PDFS_DIR` | `C:\...\consolidated\laudos` | sem fallback | **Sim** | PDFs individuais por laudo, em subpastas por status (`liberado/`, `comresultado/`, etc.). |
| `HOST_CONFIG_DIR` | `C:\siscan-rpa\config` | sem fallback | **Sim** | Configurações externas → `/app/config`. Deve conter `excel_columns_mapping.json`. |
| `HOST_SCRIPTS_CLIENTS` | `C:\siscan-rpa\scripts\clients` | `:-./scripts/clients` | Não | Scripts do operador → `/app/scripts/clients` (somente leitura). Scripts internos (`cron_loop.sh`) ficam embutidos na imagem. |
| `HOST_BACKUPS_DIR` | `C:\siscan-rpa\backups` | `:-./backups` | Não | Destino dos backups PostgreSQL gerados por `backup_manager.sh`. |

#### Opcional

| Variável | `.env.server-rpa.sample` | Default no compose | O que faz |
|---|---|---|---|
| `PW_CONTEXT_TIMEZONE` | *(comentado)* | `:-America/Fortaleza` | Timezone do scheduler e dos contextos Playwright. Afeta timestamps nos logs e o horário percebido pelo agendador. |
| `PW_CONTEXT_STORAGE_STATE_STRICT` | `true` | `:-true` | `true` = persiste e reutiliza o storage state de autenticação entre execuções (recomendado). `false` = sessão isolada a cada execução. |
| `HOST_SHEET_COLUMNS_MAPPING_NAME` | *(comentado)* | `:-excel_columns_mapping.json` | Nome do JSON de mapeamento de colunas dentro de `HOST_CONFIG_DIR`. |
| `SISCAN_CONSOLIDATED_SHEET_NAME` | *(comentado)* | `:-consolidated_report_results_default.xlsx` | Nome alternativo do XLSX consolidado gerado. Normalmente não é necessário alterar. |

#### Variáveis com valor fixo no compose `prd.external-db.yml`

Valores fixados como strings literais no compose — definir no `.env` não tem efeito.

| Variável | Valor fixo | Motivo |
|---|---|---|
| `PW_HEADLESS` | `"true"` | Produção sempre headless; ambientes de servidor não têm display. |
| `PW_BROWSER` | `"chromium"` | Browser homologado e testado para o SISCAN. |
| `PW_CONTEXT_STORAGE_STATE` | `"/app/data/.artifacts/auth/storage_state.json"` | Caminho interno fixo no volume `siscan-data-artifacts`. |
| `TAKE_SCREENSHOT` | `"false"` | Capturas de diagnóstico desabilitadas em produção. |
| `PW_RECORD_VIDEO` | `"false"` | Gravação desabilitada — esgotaria disco rapidamente. |
| `PW_TRACING` | `"false"` | Tracing desabilitado — gera arquivos grandes de diagnóstico. |
| `SAVE_PAGE_HTML` | `"false"` | Dump de HTML desabilitado em produção. |

---

## Comandos úteis

### Modo HOST (`docker-compose.prd.host.yml`)

```bash
# Subir a stack
docker compose -f docker-compose.prd.host.yml up -d

# Ver logs em tempo real
docker compose -f docker-compose.prd.host.yml logs -f

# Parar a stack
docker compose -f docker-compose.prd.host.yml down

# Ver status dos containers
docker compose -f docker-compose.prd.host.yml ps
```

### Modo servidor (`docker-compose.prd.rpa.yml`)

```bash
docker compose -f docker-compose.prd.rpa.yml up -d
docker compose -f docker-compose.prd.rpa.yml logs -f
docker compose -f docker-compose.prd.rpa.yml down
docker compose -f docker-compose.prd.rpa.yml ps
```

---

## Estrutura do repositório

| Arquivo | Descrição |
|---|---|
| `siscan-assistente.sh` | Assistente interativo — Linux (bash) |
| `siscan-assistente.ps1` | Assistente interativo — Windows (PowerShell 7+) |
| `execute.ps1` | Wrapper de compatibilidade — Windows PowerShell 5.1 |
| `siscan-server-setup.sh` | Bootstrap do servidor — `--product rpa\|dashboard\|full` |
| `docker-compose.prd.host.yml` | Compose modo HOST — RPA + Dashboard + banco local (produto `full`) |
| `docker-compose.prd.rpa.yml` | Compose modo SERVIDOR — RPA com banco externo (produto `rpa`) |
| `docker-compose.prd.dashboard.yml` | Compose modo SERVIDOR — Dashboard com banco externo (produto `dashboard`) |
| `.env.host.sample` | Variáveis de ambiente — modo HOST (produto `full`) |
| `.env.server-rpa.sample` | Variáveis de ambiente — modo Servidor RPA (produto `rpa`) |
| `.env.server-dashboard.sample` | Variáveis de ambiente — modo Servidor Dashboard (produto `dashboard`) |
| `scripts/docker/init-databases.sh` | Init script PostgreSQL — cria banco `siscan_dashboard` no modo HOST |
| `.env.help.json` | Documentação de cada variável (lida pelo assistente) |
| `docs/` | Documentação: [DEPLOY_HOST](docs/DEPLOY_HOST.md), [DEPLOY_SERVER](docs/DEPLOY_SERVER.md), [CHECKLISTS](docs/CHECKLISTS.md), [TROUBLESHOOTING](docs/TROUBLESHOOTING.md) |

---

## Testes

Os testes unitários usam o framework [bats-core](https://github.com/bats-core/bats-core) (Bash Automated Testing System), incluído como submodule git junto com os helpers [bats-support](https://github.com/bats-core/bats-support) e [bats-assert](https://github.com/bats-core/bats-assert).

### Por que submodules?

A alternativa seria instalar o bats via package manager (`apt-get install bats`) ou exigir instalação manual antes de rodar os testes. Optamos por submodules pelos seguintes motivos:

- **Versão fixada**: o repositório aponta para commits específicos dos três projetos bats, garantindo que todos — desenvolvedores e CI — rodem exatamente a mesma versão do framework.
- **Zero dependências externas**: qualquer pessoa que clonar o repositório com `--recurse-submodules` pode rodar `./tests/bats/bin/bats tests/unit/` imediatamente, sem instalar nada no sistema.
- **Reprodutibilidade em CI**: o workflow usa `actions/checkout@v4` com `submodules: recursive`, sem precisar de etapa separada de instalação.

A desvantagem é que o clone inicial é ligeiramente mais pesado e requer o flag `--recurse-submodules`. Esse custo foi considerado aceitável dado que os scripts são em bash e o próprio bats é leve.

### Clonar com submodules

```bash
git clone --recurse-submodules https://github.com/Prisma-Consultoria/assistente-siscan-rpa.git
```

Se já clonou sem `--recurse-submodules`:

```bash
git submodule update --init --recursive
```

### Rodar os testes

```bash
./tests/bats/bin/bats tests/unit/
```

### Estrutura

```
tests/
  bats/                        # submodule — bats-core (runner)
  test_helper/
    bats-support/              # submodule — helpers de output
    bats-assert/               # submodule — asserções
  unit/                        # testes unitários (.bats)
  fixtures/                    # arquivos de apoio aos testes
```

Os testes são executados automaticamente no GitHub Actions a cada pull request para `main` (`.github/workflows/test.yml`).

---

## Documentação adicional

- [DEPLOY — Modo HOST](docs/DEPLOY_HOST.md) — Instalação em PC local (Windows / Linux).
- [DEPLOY — Modo Servidor](docs/DEPLOY_SERVER.md) — Instalação em Ubuntu Server com PostgreSQL externo.
- [TROUBLESHOOTING](docs/TROUBLESHOOTING.md) — Diagnóstico e coleta de artefatos.
- [ERRORS_TABLE](docs/ERRORS_TABLE.md) — Tabela de erros comuns.
- [CHECKLISTS](docs/CHECKLISTS.md) — Procedimentos operacionais e rollback.

Repositório da imagem principal: [Prisma-Consultoria/siscan-rpa](https://github.com/Prisma-Consultoria/siscan-rpa)
