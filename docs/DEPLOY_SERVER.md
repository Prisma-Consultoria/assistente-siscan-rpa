# Guia de Deploy — Modo Servidor (Ubuntu Server)
<a name="deploy-server"></a>

Versão: 2.2
Data: 2026-03-27

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
    linkStyle 11 stroke:#336791,stroke-width:2px
    linkStyle 12 stroke:#336791,stroke-width:2px
    linkStyle 13 stroke:#336791,stroke-width:2px
    linkStyle 14 stroke:#336791,stroke-width:2px
    linkStyle 15 stroke:#d97706,stroke-width:2px
    linkStyle 16 stroke:#d97706,stroke-width:2px
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
| Docker network pool | Pool com subnets disponíveis | `docker network create teste && docker network rm teste` |

> **Docker daemon.json:** se a equipe de infraestrutura configurou `/etc/docker/daemon.json` com `default-address-pools` restrito (ex: uma única subnet `/24`), o Docker não conseguirá criar redes para os compose projects. Verifique com `cat /etc/docker/daemon.json` e consulte o [Problema 1 do Troubleshooting](TROUBLESHOOTING.md#problema-1--pool-de-endereços-docker-esgotado-ao-criar-rede) para a solução.

### VM do banco de dados

| Requisito | Mínimo |
|---|---|
| PostgreSQL | ≥ 16 |
| Bancos criados | `siscan_rpa` + `siscan_dashboard` |
| Conectividade TCP | Porta 5432 acessível por ambas as VMs de aplicação |
| Senhas sem caracteres especiais | Evitar `@`, `%`, `/`, `#`, `:`, `\` nas senhas dos bancos |

> **Senhas do banco:** o Docker Compose monta a `DATABASE_URL` por interpolação de variáveis. Caracteres como `@` na senha quebram o parsing da URL (o `@` é o separador entre credenciais e host). Use senhas alfanuméricas com símbolos seguros (`_`, `-`, `!`, `^`).

Verificar conectividade antes de prosseguir:

```bash
psql -h <DATABASE_HOST> -U siscan_rpa -c "SELECT version();"
```

### Token de registro do runner

Cada VM precisa de um token de registro gerado no repositório correspondente ao produto:

| Sistema | Onde gerar o token |
|---|---|
| siscan-rpa | [siscan-rpa → Settings → Actions → Runners → New](https://github.com/Prisma-Consultoria/siscan-rpa/settings/actions/runners/new) |
| `dashboard` | [siscan-dashboard → Settings → Actions → Runners → New](https://github.com/Prisma-Consultoria/siscan-dashboard/settings/actions/runners/new) |

>  ⚠️  O token expira em poucos minutos. Gere-o imediatamente antes de executar o script.

---

## Instalação (`siscan-server-setup.sh`)

O script `siscan-server-setup.sh` é o ponto de entrada para instalar o siscan-rpa e/ou o siscan-dashboard em servidores Ubuntu. Ele é executado **uma única vez** de forma interativa em cada VM. O flag `--product` seleciona qual aplicação será instalada naquela VM. O mesmo script e o mesmo repositório do assistente são usados para instalar qualquer um dos dois produtos — a diferença está no argumento passado.

Em uma infraestrutura com 3 VMs (conforme o diagrama de arquitetura acima), o processo de instalação é:

1. **Na VM do RPA (VM 1):** clone o assistente e execute com `--product rpa`. O script configura o compose do RPA, gera a chave de sessão, solicita as credenciais do banco externo e os caminhos de dados, instala o runner do GitHub Actions e registra no repositório `siscan-rpa`.
2. **Na VM do Dashboard (VM 3):** clone o assistente novamente (ou copie) e execute com `--product dashboard`. O script configura o compose do dashboard (que inclui o Redis), gera a chave de sessão, solicita as credenciais do banco externo, a connection string do banco do RPA para o sync, e o caminho de logs, instala o runner e registra no repositório `siscan-dashboard`.
3. **A VM do banco de dados (VM 2)** não precisa do assistente — é um PostgreSQL dedicado que deve estar acessível por ambas as VMs antes de executar o script.

Cada VM é independente — não é necessário instalar uma antes da outra. A única dependência é que o PostgreSQL (VM 2) esteja acessível no momento em que os containers subirem pela primeira vez.

### Instalação do siscan-rpa (VM 1)

Na VM dedicada ao RPA, clone o assistente e execute o script com `--product rpa`:

```bash
git clone https://github.com/Prisma-Consultoria/assistente-siscan-rpa.git
cd assistente-siscan-rpa
bash ./siscan-server-setup.sh --product rpa
```

O script configura automaticamente:

| Aspecto | Valor |
|---|---|
| Compose file | `docker-compose.prd.rpa.yml` |
| .env sample | `.env.server-rpa.sample` |
| Runner label | `producao-rpa` |
| Runner name | `<hostname>-siscan-rpa` |
| Repo URL padrão | `Prisma-Consultoria/siscan-rpa` |
| Chave de sessão | `SECRET_KEY` (auto-gerada) |
| Diretórios HOST_* | 5 (logs, downloads, consolidated, PDFs, config) |

Durante a execução, o script solicita interativamente os seguintes valores:

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

### Instalação do siscan-dashboard (VM 3)

Na VM dedicada ao dashboard, clone o assistente e execute o script com `--product dashboard`:

```bash
git clone https://github.com/Prisma-Consultoria/assistente-siscan-rpa.git
cd assistente-siscan-rpa
bash ./siscan-server-setup.sh --product dashboard
```

O script configura automaticamente:

| Aspecto | Valor |
|---|---|
| Compose file | `docker-compose.prd.dashboard.yml` |
| .env sample | `.env.server-dashboard.sample` |
| Runner label | `producao-dashboard` |
| Runner name | `<hostname>-siscan-dashboard` |
| Repo URL padrão | `Prisma-Consultoria/siscan-dashboard` |
| Chave de sessão | `SESSION_SECRET` (auto-gerada) |
| Diretórios HOST_* | 1 (logs) |
| Serviço extra | Redis (cache operacional, criado automaticamente pelo compose) |

A principal diferença em relação ao RPA é a variável `RPA_DATABASE_URL`, que permite ao serviço `sync` conectar no banco do RPA para importar os dados de exames. Sem essa variável, o dashboard sobe mas o sync não funciona.

Durante a execução, o script solicita interativamente os seguintes valores:

| Fase | Pergunta | Valor esperado |
|---|---|---|
| 5 | `DATABASE_HOST` | IP ou hostname do PostgreSQL (ex.: `192.168.1.10`) |
| 5 | `DATABASE_PASSWORD` | Senha do banco do dashboard |
| 5 | `ADMIN_PASSWORD` | Senha do administrador do dashboard |
| 5 | `RPA_DATABASE_URL` | `postgresql://siscan_rpa:senha@192.168.1.10:5432/siscan_rpa` |
| 5 | `HOST_LOG_DIR` | `/opt/siscan-dashboard/logs` |
| 7 | `URL do repositório` | Enter para aceitar `https://github.com/Prisma-Consultoria/siscan-dashboard` |
| 7 | `Token de registro` | Token copiado da tela do GitHub |

> `SESSION_SECRET` é gerada automaticamente — não pergunta.

---

## Fases do script

O script `siscan-server-setup.sh` executa 10 fases em sequência. Cada fase exibe um banner com o número e o nome da etapa, seguido de verificações e ações. Se alguma fase falhar, o script interrompe com uma mensagem de erro indicando o problema e a ação corretiva. Algumas fases se adaptam ao produto selecionado (`rpa` ou `dashboard`), conforme indicado.

Antes de iniciar as fases, o script exibe um banner com o produto selecionado, o compose file que será usado, o diretório da stack, o diretório do runner e o usuário atual. Essas informações permitem ao operador confirmar visualmente que os parâmetros estão corretos antes de prosseguir.

### Fase 1 — Verificação de pré-requisitos

O script verifica se as ferramentas necessárias estão instaladas e acessíveis: Docker Engine (>= 24.x recomendado), Docker Compose v2 (plugin), curl e sudo. Para cada ferramenta encontrada, exibe a versão detectada. Se alguma estiver ausente, o script interrompe com a instrução de instalação.

No caso do Docker, se o daemon não estiver acessível, o script diagnostica a causa provável: serviço inativo (`systemctl`), usuário fora do grupo `docker`, ou socket `/var/run/docker.sock` inexistente. Essa verificação é idêntica para ambos os produtos.

---

### Fase 2 — Usuário dedicado para o runner

O GitHub Actions runner recusa execução como root. Se o script detectar que está rodando como root, ele cria o usuário `siscan` (solicita que o operador defina uma senha), adiciona ao grupo `docker`, transfere a propriedade do diretório do assistente para esse usuário e re-executa o script inteiro como `siscan`, propagando o `--product` selecionado. Se o script já estiver rodando como não-root, apenas confirma o usuário e prossegue.

---

### Fase 3 — Estrutura de diretórios da stack

O diretório da stack é o próprio diretório onde o assistente foi clonado. Os arquivos da stack (compose file, `.env`, diretório `config/`) ficam nesse mesmo local — não é criado um diretório separado. O script verifica se o diretório existe e se o usuário atual é o dono. Se necessário, ajusta as permissões via `sudo chown`.

---

### Fase 4 — Arquivos da stack

O script verifica se o compose file correspondente ao produto está presente no diretório da stack. Se não estiver, tenta copiar do diretório de origem do script (caso tenham sido distribuídos juntos). Se o arquivo não for encontrado em nenhum dos dois locais, o script interrompe com a instrução para o operador colocar o arquivo manualmente.

| Sistema | Compose file |
|---|---|
| siscan-rpa | `docker-compose.prd.rpa.yml` |
| siscan-dashboard | `docker-compose.prd.dashboard.yml` |

Além do compose, o script verifica o diretório `config/` e a presença do arquivo `excel_columns_mapping.json` (necessário para o RPA). Se o `config/` não existir, tenta copiar do diretório de origem ou cria vazio com aviso.

---

### Fase 5 — Configuração do `.env`

Esta é a fase interativa principal. O script cria o `.env` a partir do sample correspondente ao produto (`.env.server-rpa.sample` ou `.env.server-dashboard.sample`) e solicita os valores obrigatórios ao operador.

O fluxo de perguntas segue esta ordem:

1. **Chave de sessão** — gerada automaticamente sem intervenção do operador. Para o RPA, gera `SECRET_KEY`; para o dashboard, gera `SESSION_SECRET`. Ambas são chaves hexadecimais de 256 bits produzidas via `openssl rand -hex 32`.
2. **`DATABASE_HOST`** — o script pergunta o IP ou hostname do PostgreSQL externo. Se o valor atual for `db` (padrão de desenvolvimento), avisa que é inválido para banco externo e solicita correção.
3. **`DATABASE_PASSWORD`** — o script pergunta a senha do banco. Se detectar a senha padrão `siscan_rpa`, exibe aviso para alteração. A entrada é ocultada (não ecoa no terminal).
4. **`ADMIN_PASSWORD`** (apenas para o siscan-dashboard) — o script solicita a senha do usuário administrador do dashboard. Se deixada vazia, o dashboard gera uma senha temporária nos logs na primeira execução.
5. **`RPA_DATABASE_URL`** (apenas para o siscan-dashboard) — o script solicita a connection string completa para o banco do RPA, exibindo o formato e um exemplo. Essa variável é obrigatória para que o `sync_exames` consiga ler os dados do RPA.
6. **Diretórios `HOST_*`** — o script percorre cada variável de caminho, exibindo o valor atual e uma descrição. Se o valor atual parecer um caminho Windows (letra de drive, barras invertidas, UNC), exibe um aviso e sugere o equivalente Linux. O operador pode manter o valor atual pressionando Enter ou informar um novo caminho.

| Variável | siscan-rpa | siscan-dashboard |
|---|---|---|
| Chave de sessão | `SECRET_KEY` (auto-gerada) | `SESSION_SECRET` (auto-gerada) |
| `DATABASE_HOST` | Pergunta (obrigatório) | Pergunta (obrigatório) |
| `DATABASE_PASSWORD` | Pergunta | Pergunta |
| `ADMIN_PASSWORD` | — | Pergunta (senha do admin do dashboard) |
| `RPA_DATABASE_URL` | — | Pergunta (obrigatório para o sync) |
| Diretórios `HOST_*` | 5 caminhos | 1 caminho (`HOST_LOG_DIR`) |

Ao final, o produto é persistido no `.env` via `SISCAN_PRODUCT=rpa` ou `SISCAN_PRODUCT=dashboard`, permitindo que o assistente (`siscan-assistente.sh`) detecte automaticamente qual produto gerenciar em operações futuras.

---

### Fase 6 — Criação dos diretórios `HOST_*`

O script lê os caminhos definidos nas variáveis `HOST_*_DIR` do `.env` e executa `mkdir -p` para cada um, criando toda a estrutura de diretórios necessária para os bind mounts dos containers. Para cada diretório criado com sucesso, exibe uma confirmação. Se a criação falhar (por exemplo, por falta de permissão), exibe um aviso — mas não interrompe o script. O número de diretórios criados varia: 5 para RPA (logs, downloads, consolidados, PDFs, config), 1 para dashboard (logs).

---

### Fase 7 — GitHub Actions Runner

Esta fase instala e registra o GitHub Actions runner que receberá os deploys automáticos via CI/CD. O script é **idempotente** — detecta o estado atual da instalação e retoma de onde parou. São 3 sub-etapas independentes (download, registro, serviço), cada uma verificada individualmente:

| Indicador | Significa | Sub-etapa pulada |
|---|---|---|
| `config.sh` presente | Binários extraídos | Download |
| `.runner` presente | Runner registrado no GitHub | Download + Registro |
| Serviço systemd ativo | Instalação completa | Download + Registro + Serviço |

Isso permite re-executar o script com segurança após falhas parciais (ex: token expirado, erro de rede no registro). O script retoma da sub-etapa que faltou, sem repetir o que já foi feito.

Se o runner não estiver instalado, o fluxo completo é:

1. **Detecta a arquitetura** do servidor (x86_64 ou aarch64) para baixar o binário correto.
2. **Consulta a versão mais recente** do runner via API do GitHub (`actions/runner/releases/latest`).
3. **Baixa e extrai** o tarball no diretório `~/actions-runner`.
4. **Solicita a URL do repositório** — sugere a URL padrão conforme o produto; o operador pode aceitar com Enter ou informar outra.
5. **Solicita o token de registro** — o operador deve copiar o token gerado na tela de Settings → Actions → Runners → New do repositório correspondente. O token expira em poucos minutos.
6. **Registra o runner** com a label e o nome definidos pelo produto, usando `--unattended --replace`.
7. **Instala como serviço systemd** e inicia o serviço. O runner passa a rodar em background e sobrevive a reinicializações do servidor.

| Aspecto | siscan-rpa | siscan-dashboard |
|---|---|---|
| Label | `producao-rpa` | `producao-dashboard` |
| Nome | `<hostname>-siscan-rpa` | `<hostname>-siscan-dashboard` |
| URL padrão do repo | `Prisma-Consultoria/siscan-rpa` | `Prisma-Consultoria/siscan-dashboard` |

---

### Fase 8 — Persistir `COMPOSE_DIR` no ambiente do runner

O runner roda como serviço systemd e não carrega `~/.bashrc` nem `/etc/environment`. Para que os workflows de CD consigam localizar o compose file e o `.env` no servidor, o script grava a variável `COMPOSE_DIR` (diretório do assistente) em dois locais:

1. **`~/actions-runner/.env`** — é o único mecanismo para injetar variáveis de ambiente nos jobs executados pelo runner. Ambos os workflows de CD (siscan-rpa e siscan-dashboard) usam `${COMPOSE_DIR}` para navegar até o diretório correto antes de executar `docker compose`.
2. **`/etc/environment`** — disponibiliza a variável para sessões interativas (SSH), permitindo que o operador use `cd $COMPOSE_DIR` para acessar rapidamente o diretório da stack.

Como o runner foi instalado e iniciado na fase 7 — antes do `COMPOSE_DIR` ser gravado — o script **reinicia o serviço do runner** ao final desta fase para que ele carregue o `.env` atualizado. Isso garante que o primeiro deploy via workflow já encontre o `COMPOSE_DIR` disponível.

---

### Fase 9 — Permissões Docker

O script verifica se o usuário atual pertence ao grupo `docker`. Se não pertencer, executa `sudo usermod -aG docker` e avisa que é necessário logout/login para que a mudança tenha efeito na sessão do terminal. O serviço do runner, por reiniciar via systemd, já terá o grupo automaticamente. Comportamento idêntico para ambos os produtos.

---

### Fase 10 — Resumo e próximos passos

O script exibe um resumo completo do que foi configurado: produto, diretório da stack, compose file, `.env`, diretório do runner e label. Em seguida, lista os próximos passos que o operador deve executar:

1. Revisar o `.env` no diretório da stack para confirmar que todos os valores estão corretos.
2. Confirmar que o runner aparece como **Idle** em GitHub → Settings → Actions → Runners do repositório correspondente.
3. Verificar o status do serviço do runner via `sudo ~/actions-runner/svc.sh status`.
4. O próximo merge para `main` no repositório correspondente acionará o deploy automaticamente. Para acionar manualmente, usar Actions → CD → Run workflow.
5. Acompanhar os logs do runner via `journalctl -u actions.runner.*.service -f`.
6. Acompanhar os logs da stack após o primeiro deploy via `docker compose -f <compose-file> logs -f`.

---

## Referência de variáveis — `.env`

As variáveis do `.env` são específicas de cada sistema. As seções a seguir documentam as variáveis do **siscan-rpa** (`docker-compose.prd.rpa.yml`). Para as variáveis do **siscan-dashboard** (`docker-compose.prd.dashboard.yml`), consulte o `.env.server-dashboard.sample` que acompanha o assistente.

### Aplicação HTTP (siscan-rpa)

| Variável | `.env.server-rpa.sample` | Default no compose | Obrigatória? | O que faz / Impacto |
|---|---|---|---|---|
| `HOST_APP_EXTERNAL_PORT` | `5001` | `:-5001` | Não | Porta TCP publicada no host. URL de acesso: `http://<IP>:<porta>`. |
| `APP_LOG_LEVEL` | `INFO` | `:-INFO` | Não | Verbosidade dos logs. Use `INFO` em produção; `DEBUG` gera alto volume. |
| `SECRET_KEY` | *(vazio — preencher)* | sem fallback | **Sim** | Assina cookies de sessão do painel web. Gere com `openssl rand -hex 32`. |

### Banco de dados (siscan-rpa)

| Variável | `.env.server-rpa.sample` | Default no compose | Obrigatória? | O que faz / Impacto |
|---|---|---|---|---|
| `DATABASE_NAME` | `siscan_rpa` | `:-siscan_rpa` | Não | Nome do banco operacional no PostgreSQL externo. |
| `DATABASE_USER` | `siscan_rpa` | `:-siscan_rpa` | Não | Usuário PostgreSQL da aplicação e das migrations. |
| `DATABASE_PASSWORD` | `siscan_rpa` | `:-siscan_rpa` | Não (**altere em produção**) | Senha do banco. Substitua antes do primeiro start. |
| `DATABASE_PORT` | `5432` | `:-5432` | Não | Porta TCP do PostgreSQL externo. |
| `DATABASE_HOST` | *(vazio — preencher)* | **sem fallback** | **Sim** | IP ou hostname do PostgreSQL externo. |

### Variáveis específicas do siscan-dashboard

A tabela a seguir lista variáveis que existem apenas no `.env.server-dashboard.sample` e não se aplicam ao siscan-rpa.

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

| Sistema | URL padrão | Próximo passo |
|---|---|---|
| siscan-rpa | `http://<IP>:5001` | Navegar até `/admin/siscan-credentials` e cadastrar usuário/senha do SISCAN |
| siscan-dashboard | `http://<IP>:5000` | Login com admin / senha definida em `ADMIN_PASSWORD` |

O runner registrado na fase 7 receberá automaticamente os próximos deploys via GitHub Actions.

---

## Atualização do assistente

Após a instalação inicial, o assistente não se atualiza sozinho. No entanto, os deploys automáticos via GitHub Actions já mantêm atualizados os arquivos mais importantes a cada deploy:

- **Imagens Docker** — o workflow faz pull da imagem mais recente do GHCR.
- **Compose file** (`docker-compose.prd.*.yml`) — o workflow baixa a versão mais recente da branch `main` do assistente e sobrescreve o arquivo local no `COMPOSE_DIR`.
- **`.env` sample** (`.env.server-*.sample`) — o workflow baixa o sample atualizado para o `COMPOSE_DIR`, servindo como referência para identificar novas variáveis.

Isso significa que, **no modo SERVER, o `git pull` é opcional**. Os arquivos operacionais (compose e imagens) já são atualizados automaticamente pelo CD. O `git pull` seria útil apenas para atualizar scripts do assistente (`siscan-server-setup.sh`) e documentação (`docs/`), que raramente mudam após a instalação.

Se ainda assim quiser atualizar o repositório completo:

```bash
cd /app/assistente-siscan-rpa   # ajuste conforme o caminho da sua instalação
git pull origin main
```

### Novas variáveis de ambiente

Quando uma nova versão do assistente introduz variáveis de ambiente novas (como foi o caso da adição do Redis com `REDIS_HOST`, `REDIS_PORT`, `CACHE_TIMEOUT`), o `.env` sample atualizado já estará disponível no servidor após o próximo deploy automático. Para identificar as variáveis novas, compare o sample com o `.env` em uso:

```bash
# Ver variáveis que existem no sample mas não no .env atual
diff <(grep -E '^[A-Z_]+=' .env.server-rpa.sample | cut -d= -f1 | sort) \
     <(grep -E '^[A-Z_]+=' .env | cut -d= -f1 | sort)
```

Adicione as variáveis faltantes manualmente ao `.env` e reinicie a stack para aplicar:

```bash
# siscan-rpa (VM 1):
docker compose -f docker-compose.prd.rpa.yml down
docker compose -f docker-compose.prd.rpa.yml up -d --wait

# siscan-dashboard (VM 3):
docker compose -f docker-compose.prd.dashboard.yml down
docker compose -f docker-compose.prd.dashboard.yml up -d --wait
```

> No modo HOST (PC local), o assistente oferece a **Opção 7 — Atualizar o Assistente** no menu interativo, que baixa a versão mais recente do script automaticamente. A **Opção 3 — Editar configurações** permite revisar e completar variáveis novas interativamente.

### Compose file e `git pull` — por que não há conflito

Os workflows de CD sobrescrevem o compose file e o `.env` sample no servidor a cada deploy, baixando a versão mais recente da branch `main` do assistente via `curl`. Como o conteúdo baixado é idêntico ao que está na `main` do repositório remoto, o `git pull` subsequente não detecta diferença e executa normalmente (fast-forward).

O único cenário que causaria conflito é se o operador **modificar manualmente** o compose file ou o sample no servidor. Nesse caso, o `git pull` recusaria o merge por haver alterações locais não commitadas. Para resolver, descarte as alterações locais antes do pull:

```bash
git checkout -- docker-compose.prd.rpa.yml docker-compose.prd.dashboard.yml
git checkout -- .env.server-rpa.sample .env.server-dashboard.sample
git pull origin main
```

> **Recomendação:** nunca edite os compose files nem os `.env` samples diretamente no servidor. Alterações devem ser feitas no repositório do assistente e propagadas automaticamente pelo workflow de CD.

---

## Comandos úteis

Os comandos a seguir cobrem as operações mais comuns. Substitua o compose file e a porta conforme o sistema instalado na VM.

### siscan-rpa

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

### siscan-dashboard

```bash
# Status dos containers
docker compose -f docker-compose.prd.dashboard.yml ps

# Logs em tempo real
docker compose -f docker-compose.prd.dashboard.yml logs -f

# Testar health endpoint
curl -s http://localhost:5000/health | python3 -m json.tool

# Sync full (re-importa todos os registros do RPA)
docker compose -f docker-compose.prd.dashboard.yml exec app \
  python -m src.commands.sync_exames --full

# Sync incremental (apenas registros novos desde o último sync)
docker compose -f docker-compose.prd.dashboard.yml exec app \
  python -m src.commands.sync_exames

# Status do runner
sudo ~/actions-runner/svc.sh status
```

---

## Backup e restauração

O script `backup_manager.sh` oferece um menu interativo para backup e restauração do banco PostgreSQL. O workflow de CD do siscan-rpa copia automaticamente o script para `${COMPOSE_DIR}/scripts/backup_manager.sh` a cada deploy.

### Executar backup/restauração (menu interativo)

Na VM do RPA (VM 1):

```bash
cd /app/assistente-siscan-rpa
bash scripts/clients/backup_manager.sh
```

O menu lista as opções disponíveis (backup, restauração, listar backups). Os dumps são salvos em `backups/` no diretório da stack.

### Restauração manual (sem menu)

Se preferir restaurar diretamente, copie o dump para `backups/` e execute:

```bash
docker compose -f docker-compose.prd.rpa.yml exec -T app \
  pg_restore -h <IP-VM2> -U siscan_rpa -d siscan_rpa --clean --if-exists --no-owner \
  < backups/<nome_do_dump>.dump
```

### Sincronizar dashboard após restauração

Após restaurar o banco do RPA, o dashboard precisa ser re-sincronizado para refletir os dados atualizados. Na VM do dashboard (VM 3):

```bash
# Sync full — re-importa todos os registros do banco do RPA
docker compose -f docker-compose.prd.dashboard.yml exec app \
  python -m src.commands.sync_exames --full
```

O sync incremental (sem `--full`) roda automaticamente a cada 30 minutos via container `sync`. O `--full` é necessário após restauração de backup porque o `sync_control` pode ter timestamps inconsistentes com os dados restaurados.
