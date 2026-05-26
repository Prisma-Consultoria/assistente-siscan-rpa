# siscan-assistente.sh — Assistente interativo (modo HOST/PC local)

`siscan-assistente.sh` (Linux/macOS) e `siscan-assistente.ps1` (Windows) são o **menu único** de operação do SISCAN no modo HOST — o cenário em que o RPA e o Dashboard rodam **juntos em um PC local** via Docker Desktop. O assistente cuida do ciclo completo: instalar, configurar, iniciar/reiniciar, coletar, sincronizar, atualizar e diagnosticar.

> **Issue de origem**: [#58](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/issues/58).
> **Modo coberto**: HOST (`SISCAN_PRODUCT=full`) com `docker-compose.prd.host.yml`.
> **Para modo SERVIDOR** (Ubuntu + PostgreSQL externo), veja `./siscan-server-setup.md` (em elaboração) e `../DEPLOY_SERVER.md`.

## Quando usar

- O computador é um **PC local** (notebook ou desktop) com Docker Desktop instalado.
- Você precisa **operar o sistema diariamente** — não fazer DevOps. O assistente é o ponto único de contato.
- O usuário-alvo é **operacional** (analista, gestor, equipe de coleta) e não precisa lembrar comandos `docker compose`.

Para detalhes técnicos do deploy HOST (arquitetura dos 8 containers, bancos, healthchecks), consulte `../DEPLOY_HOST.md`.

## Pré-requisitos

| Item | Linux/macOS | Windows |
|---|---|---|
| Docker | Docker Engine + `docker compose` (plugin v2) | Docker Desktop 4.x ou superior |
| Shell | Bash 4+ (para arrays associativos) | PowerShell 5.1+ ou pwsh 7+ |
| Ferramentas | `curl` **ou** `wget` (atualização do próprio assistente) | Já incluídas no Windows 10/11 |
| Opcional | `jq` (lê `.env.help.json` para textos de ajuda das variáveis), `openssl` (geração de `SECRET_KEY`), `nc` (diagnóstico de conectividade) | `Invoke-WebRequest` + `curl.exe` |
| Imagens GHCR | Token PAT do GitHub com escopo `read:packages` (ver `credenciais.txt` adiante) | idem |

Se a versão preferida (`openssl`) não estiver disponível, o assistente cai para `python3` e, em último recurso, lê 64 caracteres hexadecimais de `/dev/urandom`.

## Uso rápido

### Linux/macOS

```bash
cd /opt/siscan-rpa            # ou onde você clonou o repo
chmod +x siscan-assistente.sh # primeira vez
./siscan-assistente.sh
```

Na primeira execução o assistente:

1. Exporta `DIR_SISCAN_ASSISTENTE` apontando para a raiz do script.
2. Persiste essa variável em `./env` (do compose) e em `/etc/environment` (com `sudo`, melhor esforço).
3. Detecta o produto via `SISCAN_PRODUCT` no `.env` (default: `full`).
4. Carrega textos de ajuda de `.env.help.json` se `jq` estiver instalado.

### Windows

```powershell
cd C:\siscan-rpa
.\siscan-assistente.ps1
```

> Se aparecer erro de **ExecutionPolicy**, use o wrapper `execute.ps1` que invoca o assistente com a política liberada:
>
> ```powershell
> powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\execute.ps1
> ```
>
> O wrapper apenas redireciona para `siscan-assistente.ps1` — foi mantido por compatibilidade com instalações antigas (havia um arquivo `execute.ps1` original; agora ele só delega).

## Menu interativo

```
========================================
   Assistente SISCAN RPA + Dashboard
========================================

 1) Reiniciar
    - Fecha e inicia os serviços (útil para problemas simples)
 2) Atualizar / Instalar
    - Baixa a versão mais recente das imagens
 3) Editar configurações básicas
    - Ajuste caminhos e opções essenciais (.env)
 4) Executar tarefas RPA manualmente
    - Força execução do script de download/processamento (dia anterior)
 5) Sync Dashboard manualmente
    - Sincroniza dados do RPA para o dashboard (full refresh)
 6) Histórico do Sistema
    - Visualiza desligamentos, crashes e reinicializações
 7) Atualizar o Assistente
    - Baixa a versão mais recente do assistente com rollback automático
 8) Sair

----------------------------------------
Escolha uma opção (1-8):
```

As opções **4** e **5** aparecem condicionalmente — só são exibidas quando o produto detectado as suporta (`rpa` ou `full` mostra a 4; `dashboard` ou `full` mostra a 5). No modo `full` (HOST) **as duas** ficam disponíveis.

### Opção 1 — Reiniciar / iniciar a stack

Lógica:

- Se já existem containers `extrator-siscan-rpa`, `siscan-rpa-*` ou `siscan` rodando, executa `docker compose down && up -d`.
- Se nada está rodando, lista os serviços esperados (`get_expected_service_names` faz o parse do compose), garante os diretórios de bind mount (`ensure_host_paths`) e executa `docker compose up -d`.
- Antes de subir, valida que `.env` existe **e** contém `SECRET_KEY` mais todas as variáveis `HOST_*` obrigatórias. Se faltar algo, mostra a lista do que falta e orienta a usar a opção 3.

### Opção 2 — Atualizar / Instalar (imagens)

Esta é a opção usada na **primeira instalação** e em qualquer atualização posterior.

Fluxo:

1. Solicita usuário GitHub e token PAT (`read:packages`) — não persistidos em disco por padrão.
2. Tenta `docker login ghcr.io` via `--password-stdin`.
3. Executa `docker pull ghcr.io/prisma-consultoria/siscan-rpa-rpa:main` com spinner ASCII animado.
4. No modo `full`, também baixa `ghcr.io/prisma-consultoria/siscan-dashboard:main`.
5. Se o pull falhar, tenta credenciais salvas (`credenciais.txt`), pede novas credenciais, e por fim cai para `docker compose pull` como último recurso.
6. Após o pull, valida se `.env` está completo. Se não estiver, oferece abrir o editor (opção 3) e só depois sobe os containers (`docker compose down && up -d`).
7. No final, exibe a URL para acesso: `http://localhost:5001` (RPA) — o Dashboard fica em `http://localhost:5000`.

### Opção 3 — Editar configurações (.env)

Editor interativo, variável por variável.

Comportamento:

- Se `.env` não existe, copia de um template (busca em ordem: `.env.host.sample`, `.env.example`, `.env.template`, `.env.dist`) ou cria vazio.
- Para cada `KEY=VALUE` do arquivo:
  - Mostra o valor atual (oculto se for secret).
  - Mostra o **texto de ajuda**, **exemplo** e marca **obrigatório** quando esse metadado existe em `.env.help.json`.
  - Pede o novo valor. Enter mantém o atual.
- **Detecção automática de secrets** por nome (`PASSWORD`, `TOKEN`, `SECRET`, `KEY`) ou explicitamente via `secret: true` no JSON de ajuda — entrada lida sem eco.
- **Geração automática de `SECRET_KEY`** quando vazia (chaves marcadas como `type: generated_secret`).
- **Validação de paths**: variáveis com nome terminando em `_PATH`/`_DIR`/`_ROOT` (ou contendo `MEDIA`/`CONFIG`) detectam formato Windows em ambiente Linux (`C:\…`, `\\servidor\share`, backslash) e avisam antes de salvar.
- No final, se a stack já estava rodando, oferece reiniciar para aplicar as mudanças. Se nada está rodando, lembra que basta usar a opção 1 depois.

### Opção 4 — Coleta manual (tarefas RPA)

Visível apenas para `SISCAN_PRODUCT=rpa` ou `full`.

Executa **manualmente** o pipeline noturno dentro do container, com **data de referência = dia anterior**:

1. Baixar exames requisitados (status R).
2. Baixar exames com laudos (status C).
3. Baixar exames com laudo requisitado (status L).
4. Processar laudos de mamografia (gerar XLSX/CSV consolidados).

Comando executado: `docker exec <container> sh /app/scripts/nightly_rpa_runner.sh`.

Pré-requisitos:

- O serviço precisa estar rodando (`check_service`).
- Container localizado por filtro `name=extrator-siscan-rpa` ou `name=siscan`.

A operação pode levar **vários minutos** — a saída do RPA é exibida em tempo real. Em caso de erro, o assistente mostra os comandos `docker logs` para inspeção.

### Opção 5 — Sync do Dashboard

Visível apenas para `SISCAN_PRODUCT=dashboard` ou `full`.

Força uma sincronização **full refresh** dos dados do RPA para o dashboard. Comando equivalente:

```bash
docker compose -f docker-compose.prd.host.yml exec dashboard-app \
    python -m src.commands.sync_exames --full
```

O assistente tenta primeiro no serviço `dashboard-app`; se não existir (compose mais antigo), tenta no serviço `app`. Útil quando o sync incremental automático (a cada 30 min via `CRON_INTERVAL_SECONDS`) ficou para trás ou os indicadores não bateram com o RPA.

### Opção 6 — Histórico do sistema

Coleta eventos do SO nos últimos 30 dias para diagnóstico de **estabilidade do hospedeiro** (não dos containers — para isso, use `docker logs` ou os scripts do `siscan-server-doctor/`).

No Linux:

- `last reboot` / `last -x shutdown` — inicializações e desligamentos.
- `journalctl -k --since "30 days ago"` — kernel panics, BUGs, OOM kills.
- `journalctl --list-boots` — lista de boots indexados.

No Windows o equivalente (`Get-WinEvent`) coleta eventos do `System` log com IDs 41 (kernel power), 1074 (shutdown), 6005/6006/6008 (Event Log start/clean/dirty), 41 + 6008 (crash).

O assistente exibe um resumo (contagem de boots, shutdowns, panics, OOM) e oferece **exportar relatório completo** para `relatorio-sistema-YYYYMMDD-HHMMSS.txt` no diretório do script.

### Opção 7 — Atualizar o Assistente (auto-update)

Atualiza o próprio script `siscan-assistente.sh` (ou `.ps1`) com **rollback automático em 5 passos**:

1. **Backup** — copia o script atual para `siscan-assistente.sh.backup.YYYYMMDD_HHMMSS`.
2. **Download** — tenta `curl -fsSL` e cai para `wget -q` (PowerShell: `Invoke-WebRequest` com fallback `curl.exe`). URL fixa: `https://raw.githubusercontent.com/Prisma-Consultoria/assistente-siscan-rpa/main/siscan-assistente.sh`.
3. **Validação** — verifica que o arquivo baixado tem ≥ 1000 bytes e contém o shebang `#!/usr/bin/env bash`.
4. **Aplicação** — sobrescreve o script e refaz `chmod +x`.
5. **Sintaxe** — roda `bash -n` para validar parse. Se houver erro, pergunta se deve restaurar o backup.

Após sucesso, o assistente **encerra** — você precisa relançá-lo para usar a nova versão.

### Opção 8 — Sair

Retorna ao shell sem desligar containers. A stack permanece como está (rodando se estava rodando).

## Modo Windows vs Linux — diferenças relevantes

| Aspecto | `siscan-assistente.sh` (Linux) | `siscan-assistente.ps1` (Windows) |
|---|---|---|
| Menu (1–8) | Idêntico | Idêntico |
| Login GHCR | Uma estratégia: `--password-stdin` via pipe | **Três estratégias em fallback**: arquivo temporário, `.NET Process`, console stdin — Windows tem mais idiossincrasias com `docker login` |
| Histórico do sistema | `last`, `journalctl`, `utmpdump` | `Get-WinEvent` no log `System` (IDs 41/1074/6005/6006/6008) |
| Geração de `SECRET_KEY` | `openssl rand -hex 32` → `python3 secrets` → `/dev/urandom` | `[System.Security.Cryptography.RandomNumberGenerator]` |
| Validação de paths | Avisa quando `C:\`, `\\servidor`, ou `\` aparecem em ambiente Linux | Avisa caracteres problemáticos em paths Windows (`?`, `*`, etc.); sugere usar `/` ou mapeamento de unidade de rede |
| Wrapper de execução | Direto: `./siscan-assistente.sh` | `execute.ps1` (compatibilidade) + bypass de ExecutionPolicy |
| Auto-update (opção 7) | `curl`/`wget` | `Invoke-WebRequest` em job para barra de progresso + fallback `curl.exe` |

A **lógica e o comportamento são equivalentes** — a versão `.ps1` é simplesmente o port nativo para Windows.

## Configuração

### Variáveis HOST_*

Os bind mounts apontam diretórios reais do sistema operacional. Estrutura sugerida (Windows):

```
C:\siscan-rpa\
├── logs\                          ← HOST_LOG_DIR
├── config\                        ← HOST_CONFIG_DIR
├── media\downloads\               ← HOST_SISCAN_REPORTS_INPUT_DIR
├── media\reports\…\consolidated\  ← HOST_REPORTS_OUTPUT_CONSOLIDATED_DIR
├── media\reports\…\laudos\        ← HOST_REPORTS_OUTPUT_CONSOLIDATED_PDFS_DIR
├── scripts\clients\               ← HOST_SCRIPTS_CLIENTS
└── backups\                       ← HOST_BACKUPS_DIR
```

No Linux, substitua `C:\siscan-rpa\` por `/opt/siscan-rpa/` e `\` por `/`.

**Obrigatórias** (`check_env_configured` falha sem elas):

- `HOST_LOG_DIR`
- `HOST_SISCAN_REPORTS_INPUT_DIR`
- `HOST_REPORTS_OUTPUT_CONSOLIDATED_DIR`
- `HOST_REPORTS_OUTPUT_CONSOLIDATED_PDFS_DIR`
- `HOST_CONFIG_DIR`

**Opcionais** (criadas se preenchidas): `HOST_SCRIPTS_CLIENTS`, `HOST_BACKUPS_DIR`.

Antes de qualquer `docker compose up`, `ensure_host_paths` cria os diretórios que ainda não existem.

A lista completa de variáveis (banco, scheduler, pool SQLAlchemy, dashboard) está documentada no template `.env.host.sample` na raiz do repositório.

### `SECRET_KEY`

Chave de assinatura de sessão web. Gerada **automaticamente** na primeira passada pela opção 3, com 256 bits em hex. Para regenerar manualmente: o editor pergunta antes — note que **invalida sessões ativas**.

### Token GHCR (`read:packages`)

Para baixar as imagens privadas:

1. Acesse https://github.com/settings/tokens/new
2. Selecione o escopo **`read:packages`** (e nada mais — princípio do menor privilégio).
3. Cole o token quando a opção 2 solicitar — entrada oculta.

O token **não é persistido em disco** por padrão. O assistente apenas mantém em memória durante a sessão.

### `credenciais.txt` (cache opcional)

Se você criar manualmente um arquivo `credenciais.txt` na raiz do projeto com o formato abaixo, o assistente o usará como fallback **antes** de pedir credenciais novas:

```
usuario=seu-usuario-github
token=ghp_XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
```

⚠️ **Cuidado**: esse arquivo expõe um token em texto plano. Não comite no Git, não compartilhe, e considere `chmod 600 credenciais.txt`. A opção 2 (`ensure_credentials`) **apaga** esse arquivo se ele existir antes de pedir novas credenciais — comportamento intencional para forçar rotação.

## Solução de problemas

| Sintoma | Causa provável | Ação |
|---|---|---|
| "Arquivo de configuração não encontrado: docker-compose.prd.host.yml" | Você não está no diretório certo, ou o `git pull` falhou | `cd` para a raiz do repo e confira `ls docker-compose.prd.host.yml` |
| "CONFIGURAÇÃO INCOMPLETA" listando `HOST_LOG_DIR` etc. | Variáveis obrigatórias vazias no `.env` | Use a opção 3 e preencha; o assistente lista exatamente o que falta |
| "DOCKER NÃO ESTÁ FUNCIONANDO" | Docker Desktop não iniciou; serviço Docker parado no Linux | Abra o Docker Desktop ou `sudo systemctl start docker`; teste com `docker ps` |
| "FALHA NO LOGIN" no GHCR | Token vencido, sem `read:packages`, ou usuário errado (e-mail em vez do username) | Gere novo PAT e teste manual: `echo $TOKEN \| docker login ghcr.io -u $USER --password-stdin` |
| Pull falha com timeout | Proxy corporativo bloqueando `ghcr.io:443` | Configure proxy no Docker Desktop; teste `curl -I https://ghcr.io` |
| Path Windows num assistente Linux (`C:\...`) | `.env` veio de instalação anterior em outro SO | Use a opção 3 — a validação detecta e oferece o caminho equivalente em Linux |
| Opção 7 falha após download | Arquivo baixado corrompido ou shebang ausente | O backup é restaurado automaticamente; verifique conectividade com `raw.githubusercontent.com` |
| Opção 4 diz "container não encontrado" | A stack não está rodando | Use a opção 1 primeiro; depois confira `docker ps` |
| `jq: command not found` (warning silencioso) | `jq` não instalado | `apt install jq` (Debian/Ubuntu) ou `brew install jq` (macOS). Sem `jq`, os textos de ajuda do `.env` ficam reduzidos aos defaults embutidos. |

Para problemas mais profundos (rede, runner, banco), consulte `../TROUBLESHOOTING.md` e o checklist em `../CHECKLISTS.md`.

## Exit codes

O assistente é interativo e geralmente retorna `0`. As funções internas usam os seguintes códigos:

| Código | Significado |
|---|---|
| 0 | Operação concluída com sucesso |
| 1 | Falha genérica (Docker indisponível, login falhou, .env incompleto, pull falhou, sintaxe inválida após auto-update) |

O script **não usa `set -e`** intencionalmente — funções como `check_service` retornam `1` como controle de fluxo normal (sem container rodando) e cada call site trata o resultado.

## Veja também

- `../DEPLOY_HOST.md` — Deploy completo do modo HOST (arquitetura, 8 containers, healthchecks, primeira instalação passo a passo).
- `../TROUBLESHOOTING.md` — Catálogo de problemas observados em campo (12+ entradas) com diagnóstico e ação.
- `../CHECKLISTS.md` — Checklists operacionais (pré-deploy, pós-deploy, validação periódica).
- `../ERRORS_TABLE.md` — Erros conhecidos do RPA com causa e remediação.
- `./siscan-server-doctor/` — Suite de diagnóstico para o **modo SERVIDOR** (Ubuntu + runner self-hosted). Contraste: o assistente é para HOST/PC local; o doctor/runner-recover é para servidor de produção.
- `.env.host.sample` (raiz do repositório) — Template anotado de todas as variáveis disponíveis no modo HOST.
