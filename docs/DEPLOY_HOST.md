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

| Variável | `.env.host.sample` | Default no compose | O que é e quando alterar |
|---|---|---|---|
| `PW_CONTEXT_TIMEZONE` | *(comentado)* | `:-America/Fortaleza` | Fuso horário do agendador e dos registros de log. Altere se o computador operar em fuso diferente de Fortaleza/Brasília. |
| `PW_CONTEXT_STORAGE_STATE_STRICT` | `true` | `:-true` | `true` = reutiliza a sessão de login do SISCAN entre coletas (recomendado). `false` = faz login do zero a cada coleta. |
| `HOST_SHEET_COLUMNS_MAPPING_NAME` | *(comentado)* | `:-excel_columns_mapping.json` | Nome do arquivo JSON de mapeamento de colunas dentro de `HOST_CONFIG_DIR`. Altere somente se usar um arquivo com nome diferente do padrão. |
| `SISCAN_CONSOLIDATED_SHEET_NAME` | *(comentado)* | `:-consolidated_report_results_default.xlsx` | Nome alternativo do relatório consolidado Excel gerado. Normalmente não é necessário alterar. |

### Configurações avançadas

Variáveis que raramente precisam de ajuste em produção normal. Revise-as apenas quando o suporte técnico indicar ou quando houver mudança significativa no hardware do computador.

#### Concorrência e workers

| Variável | `.env.host.sample` | Default no compose | Obrigatória? | O que faz | Impacto se alterado |
|---|---|---|---|---|---|
| `WEB_CONCURRENCY` | `2` | `:-2` | Não | Número de processos Gunicorn que atendem requisições HTTP. O valor `2` é calibrado para PC com ~4 núcleos — preserva memória para o Chromium do `rpa-scheduler`. | Aumentar sem memória suficiente causa OOM; reduzir limita o throughput do painel web. |
| `RPA_MAX_ATTEMPTS` | `3` | `:-3` | Não | Tentativas máximas por subperíodo em falhas transitórias do SISCAN. Ver nota abaixo. | Aumentar prolonga o tempo total do ciclo; reduzir abaixo de 2 elimina toda margem de retry. |
| `RPA_BACKOFF_SECONDS` | `5` | `:-5` | Não | Base do backoff exponencial entre tentativas em segundos. Padrão: 5 s → 10 s → 20 s. | Valores muito baixos sobrecarregam o SISCAN; valores muito altos prolongam o ciclo de coleta. |

**Sobre `WEB_CONCURRENCY`:**

Cada worker é um processo OS independente executando a aplicação FastAPI/Gunicorn, com seu próprio pool de conexões ao banco de dados. A quantidade ideal depende de dois fatores: **disponibilidade de RAM** e **núcleos de CPU**.

No modo HOST, o `rpa-scheduler` executa o browser Chromium na mesma máquina — consumindo 400–800 MB de RAM durante as coletas. Com `WEB_CONCURRENCY=2` e `POOL_SIZE=4`, o orçamento total estimado é: 2 workers (~150 MB cada) + Chromium (~600 MB) + PostgreSQL local + SO ≈ 1,5–2 GB, confortavelmente dentro dos 8 GB recomendados. Aumentar para 4 workers ainda cabe, mas deixa margem de segurança menor para picos de memória do Chromium.

**Quando considerar alterar:** se o computador for atualizado para 8+ núcleos com 16+ GB de RAM, `WEB_CONCURRENCY=4` passa a ser razoável — mas ajuste também `SQLALCHEMY_POOL_SIZE` e verifique `max_connections` no PostgreSQL.

**Sobre `RPA_MAX_ATTEMPTS` e o mecanismo de retry:**

O retry acontece **por subperíodo** (uma combinação de estabelecimento + período de coleta), não para toda a execução. A cada tentativa falha, o sistema aguarda `RPA_BACKOFF_SECONDS × 2^(tentativa−1)` — com o padrão de 5 s: 5 s → 10 s → 20 s.

- **Erros transitórios** (retentáveis): `asyncio.TimeoutError`, `SiscanMenuNotFoundError`, `SiscanLoginError` e variantes de timeout ou "menu não encontrado" em mensagens de exceção. O contador de tentativas é consumido nesses casos.
- **Erros não transitórios**: fecham imediatamente o contexto do browser e lançam `RuntimeError` — `RPA_MAX_ATTEMPTS` não tem efeito, a tentativa não é recontada.
- **Após esgotar as tentativas:** o subperíodo é marcado com erro e o processamento **continua** para o próximo — a execução não é abortada por completo.

**Quando considerar aumentar `RPA_MAX_ATTEMPTS`:** se os logs mostrarem `SiscanMenuNotFoundError`, `SiscanLoginError` ou timeouts recorrentes. O valor `5` é razoável para ambientes com SISCAN instável.

**Sobre `RPA_BACKOFF_SECONDS`:**

Define a base da fórmula de backoff exponencial: `espera = RPA_BACKOFF_SECONDS × 2^(tentativa−1)`. Com o padrão de 5 s:

- Tentativa 1 falha → aguarda **5 s** antes da próxima
- Tentativa 2 falha → aguarda **10 s** antes da próxima
- Tentativa 3 falha → aguarda **20 s** e registra erro (com `RPA_MAX_ATTEMPTS=3`)

Tempo extra total por subperíodo com 3 falhas consecutivas: 5 + 10 + 20 = **35 s**. Valores muito baixos (ex.: 1 s) podem sobrecarregar um SISCAN já instável antes que ele se recupere; valores muito altos (ex.: 30 s) somam até 210 s de espera por subperíodo. Ajuste sempre em conjunto com `RPA_MAX_ATTEMPTS`.

#### Pool de conexões SQLAlchemy

> **Recomendado: não altere esses valores sem necessidade.** Estão calibrados para PCs com ~4 núcleos. Revise apenas se o número de núcleos do computador aumentar significativamente.

Total de conexões abertas no PostgreSQL com os valores padrão do HOST: `WEB_CONCURRENCY × (POOL_SIZE + MAX_OVERFLOW) = 2 × (4 + 1) = 10 conexões`.

| Variável | `.env.host.sample` | Default no compose | Obrigatória? | O que faz | Impacto se alterado |
|---|---|---|---|---|---|
| `SQLALCHEMY_POOL_SIZE` | `4` | `:-4` | Não | Conexões permanentes por processo. Deve ser ≥ `WEB_CONCURRENCY`. Com `WEB_CONCURRENCY=2` e `POOL_SIZE=4` já há folga. | Muito baixo causa pool starvation; muito alto desperdiça conexões no PostgreSQL. |
| `SQLALCHEMY_MAX_OVERFLOW` | `1` | `:-1` | Não | Conexões extras temporárias para absorver picos. Fechadas automaticamente após o pico. | Muito alto pode estourar `max_connections` do PostgreSQL durante picos. |
| `SQLALCHEMY_POOL_TIMEOUT` | `30` | `:-30` | Não | Segundos aguardando conexão livre antes de registrar erro. | Muito baixo gera timeouts espúrios; alto demais oculta saturação real do pool. |
| `SQLALCHEMY_POOL_RECYCLE` | `1800` | `:-1800` | Não | Tempo de vida máximo de uma conexão em segundos (30 min). Evita conexões "mortas" por inatividade de rede. | Muito baixo gera recriação frequente de conexões; não reduzir sem motivo claro. |

**Quando considerar ajuste:**

- **Erro `QueuePool limit of size X overflow Y reached`** nos logs → pool saturado. Aumente `SQLALCHEMY_MAX_OVERFLOW` em 1–2 unidades.
- **`SQLALCHEMY_POOL_TIMEOUT` recorrente** → saturação ou queries lentas. Investigue as queries antes de aumentar o pool.
- **PC com mais núcleos** (ex.: upgrade para 8 núcleos): recomendado ajustar `WEB_CONCURRENCY=4`, `POOL_SIZE=4`, `MAX_OVERFLOW=2` → `4 × (4+2) = 24 conexões`. Garanta que o PostgreSQL aceite ao menos esse número (`max_connections` no `postgresql.conf`).

**O que não ajuda:** aumentar `POOL_SIZE` além de `WEB_CONCURRENCY` sem aumentar os workers — os slots extras ficam ociosos.

**Sobre `SQLALCHEMY_POOL_SIZE`:**

Define o número de conexões mantidas abertas e prontas por processo. Essas conexões são criadas na inicialização e reaproveitadas entre requisições, sem custo de estabelecimento por chamada. Com `WEB_CONCURRENCY=2` workers + 1 `rpa-scheduler`, o total de conexões permanentes no PostgreSQL é `(2 + 1) × 4 = 12`. O `rpa-scheduler` usa conexões para queries de controle e para persistir resultados do processamento paralelo de laudos — cada worker de `processar_laudos` consome uma conexão do pool simultaneamente.

**Sobre `SQLALCHEMY_MAX_OVERFLOW`:**

Cria conexões extras além do `POOL_SIZE` quando todos os slots estão ocupados. Diferente das conexões do pool: são criadas sob demanda e **descartadas** ao serem devolvidas, sem retornar ao pool permanente. Úteis para absorver picos curtos (ex.: flush de checkpoint com muitas escritas simultâneas). O número máximo de conexões simultâneas por processo é `POOL_SIZE + MAX_OVERFLOW`.

**Sobre `SQLALCHEMY_POOL_TIMEOUT`:**

Quando todos os `POOL_SIZE + MAX_OVERFLOW` slots estão em uso e uma nova requisição chega, ela aguarda até `POOL_TIMEOUT` segundos por uma conexão livre. Se o tempo expirar, a aplicação lança `TimeoutError: QueuePool limit of size X overflow Y reached, connection timed out after Z sec`. A causa mais comum não é pool pequeno demais, mas **queries lentas segurando conexões por tempo excessivo**. Antes de aumentar este valor, inspecione `pg_stat_activity` no PostgreSQL para identificar queries de longa duração.

**Sobre `SQLALCHEMY_POOL_RECYCLE`:**

Após `POOL_RECYCLE` segundos de vida, uma conexão é descartada ao ser devolvida ao pool e substituída por uma nova na próxima utilização. Isso evita reutilizar conexões TCP que foram silenciosamente encerradas pela infraestrutura de rede (NAT, firewalls) durante períodos de inatividade. O valor padrão de 1800 s (30 min) é conservador. Reduza apenas se a rede ou o PostgreSQL tiver `idle_timeout` inferior a 30 min — verificável com `SHOW tcp_keepalives_idle;` no PostgreSQL.

#### Timeouts e tentativas Playwright

> ⚠️ **Estas variáveis NÃO estão declaradas nos composes de produção.** Para ativá-las, acrescente cada uma ao bloco `x-app-common-env` do compose antes de definir no `.env`:
> ```yaml
> PW_SEARCH_TIMEOUT_MS: ${PW_SEARCH_TIMEOUT_MS:-60000}
> ```
> Sem essa declaração no compose, o valor do `.env` não chega ao container — a aplicação usa o padrão interno listado abaixo.

| Variável | Padrão interno | O que faz | Impacto se alterado |
|---|---|---|---|
| `PW_NAVIGATION_TIMEOUT_MS` | `20000` | Timeout (ms) para carregamento de página ou transação de rede extensa. | Muito baixo gera falsos timeouts em páginas lentas do SISCAN; muito alto atrasa detecção de travamento. |
| `PW_ACTION_TIMEOUT_MS` | `15000` | Timeout (ms) para interagir com um elemento DOM (click, fill, etc.). | Muito baixo falha em elementos lentos a aparecer; muito alto atrasa retry em elementos ausentes. |
| `PW_SEARCH_TIMEOUT_MS` | `60000` | Timeout (ms) aguardando resposta do SISCAN após clicar em "Pesquisar" (AJAX). O SISCAN pode demorar mais de 15 s com muitos registros. | Aumentar se logs mostrarem timeout na etapa de pesquisa; reduzir apenas se o SISCAN for consistentemente rápido. |
| `PW_SEARCH_FIRST_ATTEMPT_TIMEOUT_MS` | `8000` | Timeout (ms) da primeira tentativa de pesquisa. O SISCAN (RichFaces) frequentemente ignora silenciosamente o primeiro clique — timeout curto detecta isso e repete. | Muito baixo gera retentativa desnecessária; muito alto desperdiça tempo antes de repetir o clique. |
| `TARGET_DOWNLOAD_TIMEOUT_MS` | `900000` | Timeout (ms) para conclusão de download de PDF (padrão: 15 min). | Reduzir somente se downloads nunca ultrapassam o novo limite. Aumentar se logs mostrarem timeout em downloads legítimos. |
| `PW_RETRIES` | `3` | Tentativas internas do Playwright em ações de alto nível (ex.: `click_button`). | Aumentar se ações falharem por timing inconsistente no SISCAN; reduzir para ciclos mais rápidos em ambientes estáveis. |
| `PW_CONTEXT_SLOW_MO_MS` | `100` | Delay (ms) entre cada operação do Playwright (slow-motion). Valor `0` desabilita. | Reduzir para maior velocidade; aumentar para diagnóstico manual. Zerar pode causar race conditions em páginas com AJAX pesado. |

**Sobre `PW_NAVIGATION_TIMEOUT_MS`:**

Aplicado às chamadas de navegação completa de página: `page.goto()`, `page.reload()`, `page.wait_for_load_state()`. O SISCAN usa JSF/RichFaces, que em algumas transições de menu realiza recarregamentos completos de página. Em condições normais de rede, o SISCAN responde em menos de 5 s — o padrão de 20 s dá margem ampla. Aumente apenas se o link entre o computador e o SISCAN for consistentemente lento (ex.: acesso via VPN congestionada ou link de baixa qualidade).

**Sobre `PW_ACTION_TIMEOUT_MS`:**

Aplicado a interações individuais com elementos DOM: `click()`, `fill()`, `select_option()`, `wait_for_selector()`. O Playwright aguarda o elemento estar visível, habilitado e estável antes de agir — o timeout cobre todo esse período de espera. Se o elemento não aparecer em 15 s, a ação falha. Aumente se o SISCAN demora para renderizar elementos após transições de estado AJAX; reduza para detectar estados quebrados mais rapidamente e liberar a tentativa seguinte.

**Sobre `PW_SEARCH_TIMEOUT_MS`:**

Aplicado especificamente à espera pelos resultados da pesquisa após clicar em "Pesquisar". A busca no SISCAN é uma chamada AJAX que consulta o banco de dados do SISCAN — com períodos contendo muitos registros ou sob carga elevada, pode demorar 30–60 s para retornar. O padrão de 60 s cobre a maioria dos casos. Aumente se os logs mostrarem `TimeoutError` na etapa de pesquisa em períodos com grande volume de dados.

**Sobre `PW_SEARCH_FIRST_ATTEMPT_TIMEOUT_MS`:**

O SISCAN (RichFaces) frequentemente ignora silenciosamente o primeiro clique em "Pesquisar" — o AJAX é disparado mas o resultado nunca chega. Em vez de aguardar 60 s para detectar isso, o sistema usa este timeout menor (padrão 8 s) na **primeira tentativa**. Se o resultado não aparecer em 8 s, o código repete o clique e então aguarda o `PW_SEARCH_TIMEOUT_MS` completo. Isso reduz significativamente o tempo perdido com o comportamento silencioso do RichFaces — que é a causa mais frequente de lentidão nas coletas.

**Sobre `TARGET_DOWNLOAD_TIMEOUT_MS`:**

Aplicado ao `page.expect_download()` — o tempo máximo que o Playwright aguarda pela conclusão do download do arquivo PDF. O SISCAN gera o PDF no servidor antes de enviá-lo; para períodos com milhares de registros, a geração pode levar vários minutos. O padrão de 900000 ms (15 min) é conservador — na prática, a maioria dos downloads completa em menos de 2 min. Reduza para falhar mais rápido em downloads travados; aumente se os logs mostrarem timeout em downloads legítimos de períodos com muitos registros.

**Sobre `PW_RETRIES`:**

Distinto de `RPA_MAX_ATTEMPTS`: enquanto `RPA_MAX_ATTEMPTS` opera no nível do subperíodo inteiro (reiniciando o browser e retomando do início), `PW_RETRIES` opera no nível de **ações individuais de alto nível** (ex.: `click_button`, `fill_form`). Com `PW_RETRIES=3`, uma chamada a `click_button` faz até 3 tentativas internas antes de propagar a exceção. Os dois mecanismos atuam em camadas diferentes e se complementam: `PW_RETRIES` lida com instabilidades momentâneas de elementos; `RPA_MAX_ATTEMPTS` lida com falhas maiores que encerram o contexto do browser.

**Sobre `PW_CONTEXT_SLOW_MO_MS`:**

Adiciona um delay fixo entre cada operação do Playwright (clique, preenchimento, navegação). O padrão de 100 ms dá ao framework RichFaces do SISCAN tempo para processar cada ação antes da próxima — sem esse delay, ações sequenciais rápidas podem confundir a máquina de estado AJAX e resultar em cliques ignorados ou estados inconsistentes. Aumente para diagnóstico manual (facilita acompanhar o browser visualmente). Zerar (`0`) remove o delay, mas aumenta o risco de race conditions em páginas com AJAX intenso como o SISCAN.

#### Scripts externos

| Variável | `.env.host.sample` | Default no compose | Obrigatória? | O que faz | Impacto se alterado |
|---|---|---|---|---|---|
| `HOST_SCRIPTS_CLIENTS` | `C:\siscan-rpa\scripts\clients` | `:-./scripts/clients` | Não | Pasta do host com scripts operacionais do operador (ex.: `backup_manager.sh`). Montado em `/app/scripts/clients` no container (somente leitura). Scripts internos (`cron_loop.sh`) ficam embutidos na imagem e não precisam ser montados aqui. | Apontar para pasta inexistente impede a stack de subir. Se não houver scripts externos, garanta que a pasta padrão `./scripts/clients` exista. |

**Sobre `HOST_SCRIPTS_CLIENTS`:**

O diretório é montado como **somente leitura** em `/app/scripts/clients` dentro de cada container. Os scripts internos do sistema (`cron_loop.sh`, `nightly_rpa_runner.sh`) ficam embutidos na imagem Docker — não precisam ser montados externamente e não devem ser copiados para esta pasta. Este mount é exclusivamente para scripts **do operador**: rotinas customizadas como `backup_manager.sh`, exportações periódicas ou integrações específicas do cliente.

Se o diretório apontado não existir no host no momento em que o Docker Compose sobe, a stack falha com `bind source path does not exist`. O fallback padrão `:-./scripts/clients` é relativo ao diretório onde o docker-compose é executado (a pasta do repositório no caso do modo HOST). Garanta que a pasta exista mesmo que esteja vazia — o Docker não a cria automaticamente.

#### Variáveis com valor fixo no compose

> ⚠️ Os composes de produção fixam os valores abaixo como strings literais diretamente no YAML. Qualquer valor definido no `.env` para essas variáveis é **ignorado pelo Docker Compose**. Só altere editando diretamente o arquivo compose — e apenas com orientação técnica da Prisma.

| Variável | Valor fixo | Por que está fixo | Impacto se alterado |
|---|---|---|---|
| `PW_HEADLESS` | `"true"` | Produção sempre roda sem interface gráfica. | `false` tenta abrir janela de browser; falha em ambientes sem display e interrompe a coleta. |
| `PW_BROWSER` | `"chromium"` | Browser homologado e testado para o SISCAN. | Outro browser pode não ter os seletores validados — coleta falha ou produz resultados incorretos. |
| `PW_CONTEXT_STORAGE_STATE` | `"/app/data/.artifacts/auth/storage_state.json"` | Caminho interno fixo para o arquivo de sessão salva. | Caminho diferente impede reutilização do login — o sistema faz login do zero a cada coleta. |
| `TAKE_SCREENSHOT` | `"false"` | Diagnóstico desabilitado em produção. | `true` gera um arquivo de imagem por ciclo — acumula e esgota o disco progressivamente. |
| `PW_RECORD_VIDEO` | `"false"` | Gravação de vídeo desabilitada. | `true` grava vídeo de cada sessão de browser — esgota disco rapidamente. |
| `PW_TRACING` | `"false"` | Rastreamento de diagnóstico desabilitado. | `true` gera arquivos de trace grandes a cada execução. |
| `SAVE_PAGE_HTML` | `"false"` | Dump de HTML desabilitado em produção. | `true` salva HTML de cada página navegada — volume expressivo em disco por ciclo. |

**Sobre `PW_HEADLESS`:**

O modo headless executa o Chromium sem renderizar interface gráfica — apenas o motor de navegação opera. Containers Docker não têm display físico ou servidor X11/Wayland disponível; `headless=false` tentaria abrir uma janela de browser e falharia imediatamente. O modo headless é obrigatório em qualquer ambiente de produção containerizado, independentemente do sistema operacional do host.

**Sobre `PW_BROWSER`:**

O Chromium é o único browser validado e homologado para o SISCAN RPA. O SISCAN usa JavaServer Faces com RichFaces — um framework de componentes AJAX com comportamentos específicos por browser. Toda a suite de testes do projeto cobre exclusivamente o Chromium. Alterar para Firefox ou WebKit pode resultar em falhas silenciosas de renderização, seletores XPath que não encontram elementos, ou timing diferente nos eventos AJAX, sem qualquer garantia de compatibilidade.

**Sobre `PW_CONTEXT_STORAGE_STATE`:**

Após um login bem-sucedido no SISCAN, o Playwright salva cookies de sessão, localStorage e outros dados de autenticação neste arquivo JSON. Nas execuções seguintes, o sistema carrega o storage state e pula a etapa de login — tornando cada ciclo mais rápido e menos sujeito a falhas de autenticação. O caminho `/app/data/.artifacts/auth/storage_state.json` está dentro do volume Docker `siscan-data-artifacts`, garantindo persistência entre reinicializações do container. O comportamento de reutilização depende também de `PW_CONTEXT_STORAGE_STATE_STRICT=true` (seção Opcional).

**Sobre `TAKE_SCREENSHOT`:**

Quando `true`, o RPA captura imagens PNG da tela do browser em pontos-chave da execução. Extremamente útil para diagnóstico de falhas visuais — mas com ciclos a cada 30 min, cada execução pode gerar dezenas de arquivos. Em 6 meses de operação isso resulta em milhares de arquivos acumulados, consumindo disco progressivamente. Por isso está fixado em `"false"` em produção.

**Sobre `PW_RECORD_VIDEO`:**

Quando `true`, o Playwright grava um vídeo MP4 de toda a sessão do browser. Muito útil para depurar comportamentos difíceis de reproduzir — mas cada sessão completa pode ocupar centenas de MB. Em produção com execuções frequentes, o disco se esgota em poucas horas. Por isso está fixado em `"false"`.

**Sobre `PW_TRACING`:**

O tracing do Playwright gera arquivos `.zip` com capturas de tela em cada passo, timeline de eventos de rede e logs detalhados de cada operação — abríveis no Playwright Trace Viewer para depuração aprofundada. Em produção, cada arquivo de trace pode ter dezenas de MB e o overhead de geração impacta a performance da coleta. Por isso está fixado em `"false"`.

**Sobre `SAVE_PAGE_HTML`:**

Quando `true`, o RPA salva o HTML completo de cada página navegada no SISCAN. Útil para inspecionar o DOM e depurar seletores XPath. O SISCAN tem páginas com centenas de KB de HTML — salvar uma por ação resulta em muitos MB por ciclo de coleta. Por isso está fixado em `"false"` em produção.

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
