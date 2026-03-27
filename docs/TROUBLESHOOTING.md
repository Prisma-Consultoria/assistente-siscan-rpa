# Guia de Troubleshooting — Assistente SISCAN
<a name="troubleshooting"></a>

Versão: 4.2
Data: 2026-03-27

Os problemas estão organizados em três grupos:
- **Problemas comuns** — ocorrem em qualquer modo (HOST ou Servidor).
- **Específicos — Modo HOST** — exclusivos de Windows/Docker Desktop/PowerShell.
- **Específicos — Modo Servidor** — exclusivos de Ubuntu/PostgreSQL externo/runner.

---

## Regra de Ouro — Antes de agir

| Passo | O que Fazer | Como Fazer |
|---|---|---|
| 1 | Registrar o incidente | Anotar data, hora, usuário e passos executados antes do erro |
| 2 | Coletar evidências antes de alterar qualquer configuração | `docker info`, `docker compose ps`, logs do serviço afetado |
| 3 | Executar diagnósticos com privilégios adequados | **Windows:** PowerShell como Administrador. **Linux:** `sudo` quando indicado |

---

## Problemas comuns — ambos os modos

### Problema A — Falha de autenticação no GHCR

Sintomas:
- `Error response from daemon: Get "https://ghcr.io/v2/": denied: denied`
- `unauthorized: access to the requested resource is not authorized`
- `pull access denied for ghcr.io/prisma-consultoria/...`

#### Diagnóstico

| Passo | O que Fazer | Como Fazer |
|---|---|---|
| 1 | Verificar formato do token | Token válido começa com `ghp_` (classic PAT), `gho_` (OAuth) ou `ghs_` (server) e tem 40+ caracteres |
| 2 | Confirmar scope do token | Token deve ter `read:packages`. GitHub → Settings → Developer settings → Personal access tokens → verificar scopes |
| 3 | Verificar expiração | GitHub → Settings → Developer settings → Personal access tokens → coluna "Expires" |
| 4 | Testar login manualmente | `echo SEU_TOKEN \| docker login ghcr.io -u SEU_USERNAME --password-stdin` — deve retornar `Login Succeeded` |
| 5 | Limpar cache de credenciais | **Windows:** Painel de Controle → Credential Manager → Windows Credentials → remover entradas `ghcr.io`. **Linux:** `docker logout ghcr.io` |

#### Gerar novo token (quando necessário)

1. Acessar: GitHub → Settings → Developer settings → Personal access tokens → Generate new token.
2. **Note:** `SISCAN RPA - Read Packages`
3. **Expiration:** 90 days (ou conforme política da organização).
4. **Scopes:** marcar `read:packages`.
5. Clicar em **Generate token** → **copiar imediatamente** (aparece só uma vez).

No modo HOST: apagar `credenciais.txt` e executar novamente o assistente — ele pedirá as novas credenciais.

#### Checklist rápido de validação de token

- [ ] Token começa com `ghp_`, `gho_` ou `ghs_`
- [ ] Token tem 40+ caracteres
- [ ] Token não está expirado
- [ ] Token tem scope `read:packages`
- [ ] Username é o correto (não email)
- [ ] Você tem acesso ao repositório `siscan-rpa` no GitHub

---

### Problema B — `.env` vazio ou variáveis obrigatórias não preenchidas

Sintoma: containers sobem mas falham com erros de configuração; logs indicam variável vazia ou caminho inválido.

| Passo | O que Fazer | Como Fazer |
|---|---|---|
| 1 | Verificar variáveis vazias | **Windows:** `Select-String -Path .env -Pattern '^[A-Z0-9_]+=\s*$'`. **Linux:** `grep -E '^[A-Z0-9_]+=$' .env` — qualquer saída indica variável obrigatória vazia |
| 2 | Recriar `.env` a partir do sample | **HOST Windows:** `Copy-Item .env.host.sample .env -Force`. **HOST Linux:** `cp .env.host.sample .env`. **Servidor:** `cp .env.server-rpa.sample .env` |
| 3 | Editar variáveis obrigatórias | Preencher `DATABASE_PASSWORD`, `SECRET_KEY` e todos os `HOST_*` |
| 4 | Reiniciar após corrigir | Opção 1 do menu (HOST) ou `docker compose -f docker-compose.prd.rpa.yml restart` (Servidor) |

---

### Problema C — `APP_LOG_LEVEL=DEBUG` deixado em produção

Contexto: alto volume de logs após diagnóstico temporário.

| Passo | O que Fazer | Como Fazer |
|---|---|---|
| 1 | Verificar o nível atual | **Windows:** `Select-String -Path .env -Pattern '^APP_LOG_LEVEL'`. **Linux:** `grep APP_LOG_LEVEL .env` |
| 2 | Corrigir via Opção 3 do menu | Selecionar `APP_LOG_LEVEL` → definir `INFO` (modo HOST) |
| 3 | Ou editar diretamente | **Windows:** `(Get-Content .env) -replace '^APP_LOG_LEVEL=.*','APP_LOG_LEVEL=INFO' | Set-Content .env`. **Linux:** `sed -i 's/^APP_LOG_LEVEL=.*/APP_LOG_LEVEL=INFO/' .env` |
| 4 | Reiniciar para aplicar | Opção 1 do menu (HOST) ou `docker compose restart app rpa-scheduler` (Servidor) |

---

### Problema D — Falha no pull por rede instável / firewall

Sintoma: `docker pull` falha intermitentemente, timeout ou conexões TLS interceptadas.

| Passo | O que Fazer | Como Fazer |
|---|---|---|
| 1 | Diagnóstico básico de rede | **Windows:** `Test-NetConnection ghcr.io -Port 443 -InformationLevel Detailed`. **Linux:** `curl -v https://ghcr.io/v2/` |
| 2 | Traceroute para identificar hops problemáticos | **Windows:** `tracert ghcr.io`. **Linux:** `traceroute ghcr.io` |
| 3 | Retry manual | **Windows:** `for ($i=0; $i -lt 3; $i++) { docker pull ghcr.io/prisma-consultoria/siscan-rpa-rpa:main; if ($?) { break }; Start-Sleep 30 }`. **Linux:** tentativas manuais com `docker pull` |
| 4 | Se houver proxy corporativo | Configurar proxy no Docker: editar `~/.docker/config.json` com `"proxies"` ou via Docker Desktop → Settings → Resources → Proxies |
| 5 | Envolver TI da prefeitura | Fornecer saída do `tracert`/`traceroute` e `curl -v` solicitando liberação de `ghcr.io` porta 443 |

---

### Problema E — Stack não está rodando / containers ausentes

Sintoma: assistente ou comandos `docker compose` indicam containers inexistentes ou parados.

> **Nota:** o SISCAN RPA roda inteiramente em containers Docker — não existe serviço Windows (`Get-Service`) associado.

| Passo | O que Fazer | Como Fazer |
|---|---|---|
| 1 | Verificar status real | **HOST:** `docker compose -f docker-compose.prd.host.yml ps`. **Servidor:** `docker compose -f docker-compose.prd.rpa.yml ps` |
| 2 | Docker está rodando? | **Windows:** ícone do Docker na bandeja deve estar estável. **Linux:** `systemctl status docker` |
| 3 | Subir a stack manualmente | **HOST:** `docker compose -f docker-compose.prd.host.yml up -d`. **Servidor:** `docker compose -f docker-compose.prd.rpa.yml up -d` |
| 4 | Verificar se `.env` está preenchido | Se `up` falhar, verificar Problema B acima |
| 5 | Logs de inicialização | `docker compose logs --tail=50` (acrescente `-f` para o arquivo correto) |

---

## Problemas específicos — Modo HOST

### Problema 1 — ExecutionPolicy bloqueando scripts (Windows)

Mensagem: `.\siscan-assistente.ps1 : não pode ser carregado porque a execução de scripts foi desabilitada neste sistema.`

| Passo | O que Fazer | Como Fazer |
|---|---|---|
| 1 | Diagnosticar a política ativa | PowerShell (Admin): `Get-ExecutionPolicy -List` — verificar por escopo |
| 2 | Liberar para a sessão atual | `Set-ExecutionPolicy RemoteSigned -Scope Process -Force` |
| 3 | Liberar permanentemente (se permitido) | PowerShell (Admin): `Set-ExecutionPolicy RemoteSigned -Scope LocalMachine` |
| 4 | Verificar GPO restritiva | `gpresult /h C:\temp\gpresult.html` — procurar configurações de ExecutionPolicy. Se houver, solicitar exceção ao admin de domínio |
| 5 | Alternativa sem mudar GPO | Usar `execute.ps1` (incluso no repositório) — contorna a restrição via wrapper |

---

### Problema 2 — Erro de permissão em volumes montados (Docker Desktop / WSL2)

Sintomas:
- `PermissionError: [Errno 13] Permission denied: '/app/media/reports/mamografia/laudos'`
- Container falha ao iniciar e fica reiniciando
- Logs mostram erro em `Path(_dir).mkdir(parents=True, exist_ok=True)`

**Causa:** no Docker Desktop Windows/WSL2, volumes bind-mounted herdam permissões do Windows. O usuário dentro do container não tem permissão para criar subdiretórios nesses volumes.

#### Diagnóstico e solução

| Passo | O que Fazer | Como Fazer |
|---|---|---|
| 1 | Identificar o diretório que falhou | `docker compose -f docker-compose.prd.host.yml logs app --tail=50` — procurar `PermissionError` |
| 2 | Criar a estrutura de diretórios no Windows | PowerShell (Admin): `New-Item -ItemType Directory -Force -Path "C:\siscan-rpa\media\reports\mamografia\laudos"` e demais subpastas necessárias |
| 3 | Verificar variáveis `HOST_*` no `.env` | Confirmar que todos os caminhos obrigatórios estão preenchidos |
| 4 | Recriar containers | `docker compose -f docker-compose.prd.host.yml down` seguido de `docker compose -f docker-compose.prd.host.yml up -d` |

#### Checklist de validação de estrutura de diretórios

Antes de subir os containers pela primeira vez (substitua pelos caminhos do seu `.env`):

- [ ] `HOST_LOG_DIR` existe no Windows
- [ ] `HOST_SISCAN_REPORTS_INPUT_DIR` existe
- [ ] `HOST_REPORTS_OUTPUT_CONSOLIDATED_DIR` existe
- [ ] `HOST_REPORTS_OUTPUT_CONSOLIDATED_PDFS_DIR` existe
- [ ] `HOST_CONFIG_DIR` existe e contém `excel_columns_mapping.json`
- [ ] `.env` usa caminhos absolutos (sem variáveis de ambiente do shell)

#### Problema 2B — Variável `HOST_*` apontando para pasta já coberta por outra variável

Sintoma: conflito de permissão ou dado não aparece onde esperado.

| Passo | O que Fazer | Como Fazer |
|---|---|---|
| 1 | Revisar a seção `x-app-common-volumes` no `docker-compose.prd.host.yml` | Confirmar os caminhos de cada bind mount |
| 2 | Verificar sobreposição de caminhos | Ex.: `HOST_REPORTS_OUTPUT_CONSOLIDATED_DIR` e `HOST_REPORTS_OUTPUT_CONSOLIDATED_PDFS_DIR` devem ser pastas distintas não sobrepostas pelo compose |
| 3 | Configuração correta | `HOST_REPORTS_OUTPUT_CONSOLIDATED_DIR=C:\siscan-rpa\media\consolidated` e `HOST_REPORTS_OUTPUT_CONSOLIDATED_PDFS_DIR=C:\siscan-rpa\media\consolidated\laudos` |
| 4 | Aplicar | `docker compose -f docker-compose.prd.host.yml down` → corrigir `.env` → `docker compose -f docker-compose.prd.host.yml up -d` |

---

### Problema 3 — Caminhos Windows/UNC com caracteres especiais

Sintomas:
- `\\172.19.222.100\siscan_laudos&\Config is not valid windows path`
- `Error response from daemon: invalid mount config`

**Causa:** Docker Desktop no Windows não monta volumes com caminhos contendo `&`, `%`, `!`, `$`, `` ` ``, `"` ou `'`.

#### Solução A — Mapear unidade de rede (recomendado para UNC)

```powershell
# Mapear o compartilhamento com letra de unidade
net use Z: \\172.19.222.100\siscan_laudos /persistent:yes

# Atualizar .env
# Antes: HOST_CONFIG_DIR=\\172.19.222.100\siscan_laudos&\Config
# Depois: HOST_CONFIG_DIR=Z:\Config
```

#### Solução B — Renomear a pasta (recomendado para caminhos locais)

```powershell
docker compose -f docker-compose.prd.host.yml down
# Renomear no Explorer: siscan_laudos& → siscan_laudos
# Atualizar .env com o novo caminho
docker compose -f docker-compose.prd.host.yml up -d
```

#### Solução C — Usar barras normais (compatibilidade mista)

Docker aceita `/` mesmo no Windows. Não resolve caracteres especiais, mas melhora compatibilidade geral:

```
# No .env:
HOST_LOG_DIR=C:/siscan-rpa/logs
```

#### Checklist de resolução

- [ ] Identificou a variável `HOST_*` com o caminho problemático
- [ ] Escolheu solução A, B ou C conforme o contexto
- [ ] Parou containers (`docker compose -f docker-compose.prd.host.yml down`)
- [ ] Aplicou correção e atualizou `.env`
- [ ] Testou com `docker compose -f docker-compose.prd.host.yml up -d`
- [ ] Verificou que container iniciou sem erros

---

## Problemas específicos — Modo Servidor

### Problema 1 — Pool de endereços Docker esgotado ao criar rede

Sintoma: deploy falha com:
```
failed to create network siscan-rpa_default: Error response from daemon: all predefined address pools have been fully subnetted
```

O Docker esgotou os blocos de IP disponíveis para redes bridge. Há duas causas possíveis:

#### Causa A — Redes antigas acumuladas

Redes de deploys anteriores que não foram removidas. Solução rápida:

```bash
docker network prune -f
```

#### Causa B — `daemon.json` com pool restrito (mais comum em infra corporativa)

A equipe de infraestrutura pode ter configurado `/etc/docker/daemon.json` com um pool de endereços muito pequeno. Exemplo de configuração problemática:

```json
{
    "bip": "192.168.4.1/24",
    "default-address-pools": [
        { "base": "192.168.4.0/24", "size": 24 }
    ]
}
```

Nesse exemplo, o pool tem **apenas 1 subnet** (`/24` com size 24), que já está ocupada pela bridge padrão (`bip`). Resultado: zero subnets disponíveis para novas redes.

**Diagnóstico:**

```bash
# Ver configuração atual
cat /etc/docker/daemon.json

# Ver subnets em uso
docker network inspect $(docker network ls -q) 2>/dev/null | grep -A2 "Subnet"

# Testar criação de rede
docker network create teste && docker network rm teste && echo "OK" || echo "FALHOU"
```

**Solução:** expandir o pool para o range `172.16.0.0/12` (privado, sem conflito com `192.168.x.x`):

```bash
sudo tee /etc/docker/daemon.json <<'EOF'
{
    "bip": "192.168.4.1/24",
    "default-address-pools": [
        { "base": "172.16.0.0/12", "size": 24 }
    ],
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "100m",
        "max-file": "7"
    }
}
EOF
sudo systemctl restart docker
```

> Ajuste o `bip` conforme o valor original do `daemon.json` da VM. Se não havia `daemon.json`, omita o `bip` (o Docker usará o default `172.17.0.1/16`).

Após corrigir, acione o deploy manualmente:
**GitHub → repositório → Actions → CD — Deploy Produção → Run workflow**

---

### Problema 2 — Falha de conexão com o banco de dados externo

Sintoma: container `migrate` falha no boot; logs mostram `could not connect to server` ou `connection refused`.

| Passo | O que Fazer | Como Fazer |
|---|---|---|
| 1 | Confirmar `DATABASE_HOST` no `.env` | `grep DATABASE_HOST .env` — deve ter o IP/hostname do PostgreSQL externo, não `db` |
| 2 | Testar conectividade TCP com o banco | `nc -zv $DATABASE_HOST $DATABASE_PORT` ou `telnet $DATABASE_HOST $DATABASE_PORT` |
| 3 | Testar autenticação | `psql -h $DATABASE_HOST -U $DATABASE_USER -d $DATABASE_NAME -c "SELECT 1"` |
| 4 | Verificar firewall entre servidores | O servidor de app precisa de acesso à porta TCP 5432 do servidor do banco. Verificar regras de firewall / security group |
| 5 | Verificar `pg_hba.conf` no PostgreSQL | O PostgreSQL externo precisa ter regra `host` permitindo o IP do servidor de app |

#### Problema 2B — Senha com caracteres especiais quebra a DATABASE_URL

Sintoma: `migrate` falha com `could not translate host name "P@172.x.x.x"` ou similar — parte da senha é interpretada como hostname.

**Causa:** o compose monta a `DATABASE_URL` por interpolação: `postgresql://${DATABASE_USER}:${DATABASE_PASSWORD}@${DATABASE_HOST}:...`. Se a senha contém `@`, o SQLAlchemy interpreta o `@` da senha como separador entre credenciais e host.

**Diagnóstico:**

```bash
# Ver como o compose resolve a URL
cd /app/assistente-siscan-rpa
docker compose -f docker-compose.prd.dashboard.yml config 2>&1 | grep DATABASE_URL
```

Se a URL mostrar algo como `...senha@P@172.19...`, a senha tem `@`.

**Solução:** trocar a senha no PostgreSQL para uma sem caracteres especiais (`@`, `%`, `/`, `#`, `:`):

```bash
# Na VM do banco (PostgreSQL):
sudo -u postgres psql -c "ALTER USER siscan_dashboard PASSWORD 'NovaSenhaSegura123';"

# Na VM da aplicação:
sed -i "s/^DATABASE_PASSWORD=.*/DATABASE_PASSWORD=NovaSenhaSegura123/" /app/assistente-siscan-rpa/.env
```

> **Prevenção:** ao criar senhas para o banco, evite os caracteres `@`, `%`, `/`, `#`, `:` e `\`. Esses caracteres têm significado especial em URLs PostgreSQL e causam problemas quando interpolados pelo Docker Compose.

---

### Problema 2 — Runner do GitHub Actions offline ou sem receber jobs

Sintoma: deploys via GitHub Actions ficam aguardando runner; GitHub mostra runner como `Offline` ou jobs ficam `queued` indefinidamente.

#### 2A — Runner offline

| Passo | O que Fazer | Como Fazer |
|---|---|---|
| 1 | Verificar status do runner | `sudo ~/actions-runner/svc.sh status` |
| 2 | Verificar logs recentes | `journalctl -u actions.runner.* --since "1h ago" --no-pager` |
| 3 | Se aparecer `SSL connection could not be established` | O runner perdeu conectividade SSL. Reiniciar o serviço: `sudo ~/actions-runner/svc.sh stop && sudo ~/actions-runner/svc.sh start` |
| 4 | Se `start` não resolver SSL | Testar conectividade da VM: `curl -Iv https://github.com`. Se falhar, é problema de rede/firewall — envolver infra |
| 5 | Verificar conectividade com GitHub | `curl -s https://api.github.com` deve retornar JSON |
| 6 | Re-registrar o runner (token expirado) | Obter novo token de registro no GitHub → Settings → Actions → Runners → `./config.sh` com o novo token |

> O runner pode mostrar `Active (running)` no systemd mas estar desconectado do GitHub (loop de erro SSL). Nesse caso, `svc.sh status` mostra ativo mas o GitHub mostra Offline. A solução é `stop` + `start` para forçar reconexão.

#### 2B — Jobs queued mas runner está Idle

Se o runner aparece como **Idle** no GitHub mas os jobs ficam **queued**, o problema é **labels incompatíveis**. O workflow espera labels que o runner não tem.

| Passo | O que Fazer | Como Fazer |
|---|---|---|
| 1 | Verificar labels do runner | GitHub → repo → Settings → Actions → Runners → clicar no runner |
| 2 | Verificar labels do workflow | No arquivo `.github/workflows/cd_*.yml`, procurar `runs-on:` |
| 3 | Comparar | O runner deve ter **todas** as labels listadas no `runs-on` |
| 4 | Adicionar label via UI | Na página do runner no GitHub, clicar em "Add label" |

Labels esperadas por produto:

| Produto | Label no workflow | Label no runner |
|---|---|---|
| siscan-rpa | `producao-rpa` | `producao-rpa` |
| siscan-dashboard | `producao-dashboard` | `producao-dashboard` |

---

### Problema 3 — Falha TLS ao conectar ao GitHub (handshake interrompido)

Sintoma: `curl -Iv https://github.com` conecta na porta 443 mas o handshake TLS falha:

```
* Connected to github.com (x.x.x.x) port 443
* TLSv1.3 (OUT), TLS handshake, Client hello (1):
* OpenSSL SSL_connect: SSL_ERROR_SYSCALL in connection to github.com:443
curl: (35) OpenSSL SSL_connect: SSL_ERROR_SYSCALL in connection to github.com:443
```

A conexão TCP é estabelecida com sucesso, mas o servidor (ou um intermediário) encerra o handshake TLS abruptamente antes de responder.

#### Interpretação técnica

| Diagnóstico | Resultado |
|---|---|
| DNS resolve `github.com` | ✔ |
| TCP conecta na porta 443 | ✔ |
| Cliente envia `ClientHello` TLS | ✔ |
| Servidor responde ao handshake | ❌ |

#### Causas mais prováveis (em ordem de probabilidade)

| # | Causa | Indicador |
|---|---|---|
| 1 | Firewall ou WAF da rede bloqueando/interceptando TLS para `github.com` | Ocorre apenas de dentro da rede do parceiro |
| 2 | Proxy corporativo obrigatório não configurado na VM | VM tenta conexão direta, que é bloqueada |
| 3 | Inspeção SSL por proxy sem certificado confiável instalado | Proxy injeta certificado próprio não reconhecido pelo `ca-certificates` do sistema |
| 4 | Bloqueio seletivo por IP de `github.com` | Outros domínios HTTPS funcionam normalmente |

#### Diagnóstico

```bash
# Testar se outros domínios HTTPS funcionam
curl -Iv https://google.com

# Verificar se há proxy configurado no sistema
env | grep -i proxy

# Testar com proxy explícito (se houver)
curl -Iv --proxy http://<PROXY_HOST>:<PORTA> https://github.com

# Verificar política de firewall de saída
sudo iptables -L OUTPUT -n | grep -E "443|DROP|REJECT"
```

#### Solução

A resolução depende da infraestrutura do parceiro:

- **Proxy corporativo**: configurar `https_proxy` e `http_proxy` na sessão e/ou no serviço do runner
- **Firewall bloqueando `github.com`**: solicitar liberação das saídas HTTPS para `github.com` e `ghcr.io` (porta 443)
- **Inspeção SSL**: instalar o certificado da CA corporativa no sistema (`update-ca-certificates`)

> ⚠️ O runner e o `docker pull` do GHCR precisam de acesso HTTPS de saída para `github.com` e `ghcr.io`. Sem isso, o setup e os deploys automáticos não funcionam.

---

### Problema 4 — Permissões Linux nos diretórios `HOST_*`

Sintoma: `PermissionError` nos logs; container não consegue escrever nos diretórios bind-montados.

| Passo | O que Fazer | Como Fazer |
|---|---|---|
| 1 | Verificar dono dos diretórios | `ls -la /opt/siscan-rpa/logs` (ou o caminho do `HOST_LOG_DIR`) |
| 2 | Verificar o UID do processo dentro do container | `docker compose exec app id` |
| 3 | Ajustar permissões | `sudo chown -R <UID>:<GID> /opt/siscan-rpa/logs` — ou usar permissões mais abertas: `sudo chmod -R 777 /opt/siscan-rpa/logs` (somente se não houver política de segurança contrária) |
| 4 | Criar diretórios ausentes | O `siscan-server-setup.sh` cria os diretórios na fase 5. Se foram criados manualmente com root, ajustar dono conforme passo 3 |

---

## Coleta de artefatos para suporte avançado

Sempre coletar antes de abrir chamado. Substituir `<PASTA_LOGS>` pelo valor de `HOST_LOG_DIR` no `.env`.

### Comuns — ambos os modos

```bash
# Logs dos containers (últimas 1h)
docker compose logs --no-log-prefix --since 1h

# Info e versão do Docker
docker info
docker version

# Status dos containers
docker compose ps
```

### Modo HOST — PowerShell

```powershell
# Logs
docker compose -f docker-compose.prd.host.yml logs --no-log-prefix --since 1h > "$env:TEMP\compose-logs.txt"

# Docker info
docker info > "$env:TEMP\docker-info.txt"

# Teste de rede GHCR
Test-NetConnection ghcr.io -Port 443 -InformationLevel Detailed > "$env:TEMP\nettest-ghcr.txt"

# Política de execução
Get-ExecutionPolicy -List > "$env:TEMP\executionpolicy.txt"

# Imagem instalada
docker images ghcr.io/prisma-consultoria/siscan-rpa-rpa > "$env:TEMP\images.txt"

# Status dos containers
docker compose -f docker-compose.prd.host.yml ps > "$env:TEMP\compose-ps.txt"

# Chaves do .env (sem valores)
Get-Content .env | Select-String -Pattern '^[^#]' | ForEach-Object { ($_ -split '=')[0] } > "$env:TEMP\env-keys.txt"
```

### Modo Servidor — bash

```bash
# Logs
docker compose -f docker-compose.prd.rpa.yml logs --no-log-prefix --since 1h > /tmp/compose-logs.txt

# Docker info
docker info > /tmp/docker-info.txt

# Teste de rede GHCR
curl -v https://ghcr.io/v2/ 2>&1 | head -30 > /tmp/nettest-ghcr.txt

# Status do runner
cd ~/actions-runner && ./svc.sh status > /tmp/runner-status.txt 2>&1

# Chaves do .env (sem valores)
grep -v '^#' /opt/siscan-rpa/.env | cut -d= -f1 > /tmp/env-keys.txt
```

---

## Problemas específicos do siscan-dashboard

Esta seção cobre problemas que ocorrem apenas com o siscan-dashboard (modo servidor ou HOST).

### Sync retorna "0 registros" mas o banco do RPA tem dados

O `sync_control` registrou um timestamp posterior aos dados do RPA. Isso acontece quando um backup é restaurado após o primeiro sync. A solução é forçar um sync full via menu (Opção 5) ou via comando:

```bash
docker compose -f docker-compose.prd.dashboard.yml exec app python -m src.commands.sync_exames --full
```

### `RPA_DATABASE_URL` inválido ou inacessível

O serviço `sync` falha ao conectar no banco do RPA. Verifique a variável `RPA_DATABASE_URL` no `.env`:

```bash
# Formato esperado:
RPA_DATABASE_URL=postgresql://usuario:senha@host:porta/siscan_rpa

# Testar conectividade (de dentro do container):
docker compose -f docker-compose.prd.dashboard.yml exec app python -c "
from sqlalchemy import create_engine, text
import os
e = create_engine(os.environ['RPA_DATABASE_URL'])
with e.connect() as c: print(c.execute(text('SELECT count(*) FROM exam_records')).scalar())
"
```

### Redis não responde ou container não sobe

Sintoma: container `redis` não aparece no `docker compose ps`, ou o dashboard apresenta lentidão na carga inicial (cache não está funcionando).

| Passo | O que Fazer | Como Fazer |
|---|---|---|
| 1 | Verificar se o container Redis existe | `docker compose -f docker-compose.prd.dashboard.yml ps redis` |
| 2 | Verificar se o Redis responde | `docker compose -f docker-compose.prd.dashboard.yml exec redis redis-cli ping` — esperado: `PONG` |
| 3 | Verificar variáveis no `.env` | `grep REDIS .env` — deve ter `REDIS_HOST=redis` e `REDIS_PORT=6379` |
| 4 | Verificar se o compose inclui o serviço Redis | `grep -A3 'redis:' docker-compose.prd.dashboard.yml` — deve mostrar `image: redis:7-alpine` |
| 5 | Atualizar compose se Redis ausente | O workflow de CD atualiza automaticamente. Para forçar: `curl -fsSL https://raw.githubusercontent.com/Prisma-Consultoria/siscan-dashboard/main/docker-compose.prd.dashboard.yml -o docker-compose.prd.dashboard.yml` |
| 6 | Recriar a stack | `docker compose -f docker-compose.prd.dashboard.yml down && docker compose -f docker-compose.prd.dashboard.yml up -d --wait` |

> O Redis é um serviço local do compose — não precisa de instalação separada. Se o compose estiver atualizado e o `.env` tiver as variáveis `REDIS_HOST` e `REDIS_PORT`, o container sobe automaticamente.

---

### Variáveis faltantes no .env após atualização do assistente

Sintoma: novos recursos não funcionam após atualizar o assistente (ex.: Redis não ativo porque `REDIS_HOST` não está no `.env`).

| Passo | O que Fazer | Como Fazer |
|---|---|---|
| 1 | Executar verificação de consistência | `bash ./siscan-server-setup.sh --product dashboard --check` |
| 2 | O script lista variáveis faltantes | Aceitar a adição automática com valores default do sample |
| 3 | Reiniciar a stack | `docker compose -f docker-compose.prd.dashboard.yml down && docker compose -f docker-compose.prd.dashboard.yml up -d --wait` |

O `--check` compara o `.env` atual com o `.env.server-dashboard.sample` e identifica variáveis que existem no sample mas não no `.env`. Funciona também para o siscan-rpa com `--product rpa --check`.

---

### Build da imagem falha com "toomanyrequests" no Docker Hub

Sintoma: workflow "Docker Image Build" falha no step "Set up Docker BuildX" com:
```
toomanyrequests: too many failed login attempts for username or IP address
```

**Causa:** o build roda em GitHub-hosted runners que compartilham IPs. O Docker Hub aplica rate limit por IP e bloqueia temporariamente quando o limite é atingido.

**Solução:** aguardar alguns minutos e re-executar o workflow. Não é problema do código nem da infraestrutura.

> O CD (deploy) não depende de novo build — ele usa a última imagem publicada no GHCR. Se o build falhou por rate limit mas a imagem anterior está correta, acione o CD manualmente: **Actions → CD — Deploy Produção → Run workflow**.

---

### Dashboard mostra "schema_status: outdated"

As migrations do dashboard não foram aplicadas. O serviço `migrate` pode ter falhado. Verifique os logs:

```bash
docker compose -f docker-compose.prd.dashboard.yml logs migrate
```

Se necessário, force a migration manualmente:

```bash
docker compose -f docker-compose.prd.dashboard.yml run --rm app alembic upgrade head
```
