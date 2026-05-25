# Erros Comuns e Soluções — Assistente SISCAN RPA
<a name="errors"></a>

Versão: 2.0
Data: 2026-03-18

Os erros estão organizados em três grupos:
- **Comuns** — ocorrem em qualquer modo (HOST ou Servidor).
- **Específicos — Modo HOST** — exclusivos de Windows / Docker Desktop / WSL2.
- **Específicos — Modo Servidor** — exclusivos de Ubuntu / PostgreSQL externo / runner.

Para diagnóstico passo a passo de cada categoria, consulte o [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

---

## Erros comuns — ambos os modos

| # | Erro (mensagem comum) | Causa provável | Solução prática |
|---:|---|---|---|
| 1 | `Cannot connect to the Docker daemon` | Docker daemon parado ou sem permissão | Iniciar o Docker; adicionar usuário ao grupo `docker`; executar como Admin/root |
| 2 | `pull access denied` / `unauthorized` | Token GHCR inválido, expirado ou sem `read:packages` | Regenerar PAT; `docker logout ghcr.io` e novo login. Ver [TROUBLESHOOTING.md — Problema A](TROUBLESHOOTING.md) |
| 3 | `mount denied: path not found` | Caminho `HOST_*` inexistente no `.env` | Criar a pasta; verificar variável no `.env` |
| 4 | `Bind: address already in use` | Porta do host em uso | Identificar o processo (`ss -ltnp` / `netstat -ano`) e parar, ou alterar `HOST_APP_EXTERNAL_PORT` |
| 5 | `no space left on device` | Disco cheio | Limpar logs antigos; `docker system prune`; expandir disco |
| 6 | `TLS handshake timeout` | Proxy / inspeção TLS / latência | Verificar configuração de proxy; importar CA corporativa |
| 7 | `network not found` | Rede do compose ausente | `docker network create <name>` ou verificar nome da rede no compose |
| 8 | `container is unhealthy` | Healthcheck falhou | `docker compose logs app --tail=50`; verificar banco e variáveis |
| 9 | `CrashLoop / restart policy` | Exceção na aplicação ao iniciar | `docker compose logs` para identificar a causa raiz; verificar `.env` e banco |
| 10 | `docker compose config returns error` | YAML inválido | Corrigir sintaxe (indentação, variáveis não resolvidas) |
| 11 | `Error pulling image: manifest unknown` | Tag inexistente no GHCR | A tag correta é `main`; verificar `docker pull ghcr.io/prisma-consultoria/siscan-rpa-rpa:main` |
| 12 | `invalid mount config for type "bind"` | Variável `HOST_*` vazia ou caminho inválido | Verificar `.env`; garantir caminhos absolutos e pastas existentes |
| 13 | `ghcr.io resolve name temporarily unavailable` | Falha de DNS | `nslookup ghcr.io`; ajustar DNS ou contatar NetOps |
| 14 | `504 Gateway Timeout` no pull | Proxy filtrando ou latência alta | Ver logs do proxy; solicitar bypass |
| 15 | `Healthcheck failing intermittently` | Recursos escassos ou latência | Verificar uso de CPU/memória; escalar recursos se necessário |
| 16 | `Rate limit errors` | Pulls sem autenticação | Fazer `docker login ghcr.io` antes do pull |
| 17 | `Image pull stuck at 0%` | Problema de rede/DNS | `curl https://ghcr.io` para testar conectividade |
| 18 | `Error response from daemon: conflict: unable to delete` | Recurso em uso | Parar o container antes de remover a imagem |
| 19 | `Compose up hangs on creating volume` | Permissão ou driver de volume | Verificar ACLs; testar `docker volume create` manualmente |
| 20 | `DNS blocked by firewall` | Firewall corporativo bloqueando DNS | Solicitar liberação de `ghcr.io` porta 443 ao time de NetOps |
| 21 | `Unknown shorthand flag: 'd' in -d` | Docker Compose v1 desatualizado | Atualizar para Compose v2: `docker compose version` deve retornar `v2.x.x` |
| 22 | `no such image: image-name` | Tag ausente localmente e pull falhou | `docker pull ghcr.io/prisma-consultoria/siscan-rpa-rpa:main` manualmente |

---

## Erros específicos — Modo HOST (Windows / Docker Desktop)

| # | Erro (mensagem comum) | Causa provável | Solução prática |
|---:|---|---|---|
| 23 | `.\siscan-assistente.ps1 não pode ser carregado` | ExecutionPolicy bloqueando scripts PowerShell | `Set-ExecutionPolicy RemoteSigned -Scope LocalMachine` ou usar `execute.ps1`. Ver [TROUBLESHOOTING.md — Problema 1](TROUBLESHOOTING.md) |
| 24 | `PermissionError: [Errno 13] Permission denied` em volume | Docker Desktop/WSL2 não permite criar subpastas em bind mount | Criar diretórios no Windows antes de subir o container. Ver [TROUBLESHOOTING.md — Problema 2](TROUBLESHOOTING.md) |
| 25 | `is not valid windows path` / `invalid mount config` | Caminho UNC com caracteres especiais (`&`, `%`, etc.) | Mapear unidade de rede (`net use`) ou renomear a pasta. Ver [TROUBLESHOOTING.md — Problema 3](TROUBLESHOOTING.md) |
| 26 | `Permission denied on named pipe \\.\pipe\docker_engine` | Acesso ao pipe do Docker negado | Executar Docker Desktop como Administrador; verificar grupo `docker-users` |
| 27 | `Windows update broke docker` | Kernel / WSL2 desatualizado após update do Windows | `wsl --update`; reinstalar Docker Desktop se necessário |
| 28 | `file path too long` | Path Windows > 260 caracteres | Habilitar long paths: `Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name LongPathsEnabled -Value 1` |
| 29 | `Docker Desktop cannot be installed on this edition` | Edição do Windows sem Hyper-V | Habilitar WSL2; verificar requisitos de hardware e edição do Windows |
| 30 | `Not enough memory to allocate` | Limites de recursos no Docker Desktop | Docker Desktop → Settings → Resources → aumentar memória/CPU alocados |
| 31 | `Credential helper not working` | `credHelpers` mal configurado em `~/.docker/config.json` | Remover entrada de `credHelpers`; testar `docker login ghcr.io` diretamente |

---

## Erros específicos — Modo Servidor (Ubuntu / PostgreSQL externo)

| # | Erro (mensagem comum) | Causa provável | Solução prática |
|---:|---|---|---|
| 32 | `could not connect to server: Connection refused` | `DATABASE_HOST` errado ou PostgreSQL inacessível | Verificar IP/hostname; `nc -zv $DATABASE_HOST 5432`; verificar firewall. Ver [TROUBLESHOOTING.md — Problema 1](TROUBLESHOOTING.md) |
| 33 | `FATAL: password authentication failed` | `DATABASE_PASSWORD` incorreto ou usuário não existe no banco | Verificar credenciais no `.env`; confirmar usuário no PostgreSQL externo |
| 34 | `FATAL: no pg_hba.conf entry for host` | PostgreSQL não permite conexão do IP do servidor de app | Adicionar regra no `pg_hba.conf`; reiniciar o PostgreSQL |
| 35 | Runner GitHub Actions `Offline` | Serviço do runner parado ou sem acesso a `github.com` | `cd ~/actions-runner && ./svc.sh start`; verificar porta 443 para `github.com`. Ver [TROUBLESHOOTING.md — Problema 2](TROUBLESHOOTING.md) |
| 36 | `PermissionError` em diretórios Linux bind-mounted | UID do container diferente do dono das pastas no host | `chown -R <UID> /opt/siscan-rpa/logs` (e demais pastas `HOST_*`). Ver [TROUBLESHOOTING.md — Problema 3](TROUBLESHOOTING.md) |
| 37 | `Cannot connect to the Docker daemon at unix:///var/run/docker.sock` | Usuário não está no grupo `docker` | `sudo usermod -aG docker $USER` + logout/login (fase 7 do `siscan-server-setup.sh` faz isso) |

---

> Adaptação das soluções conforme políticas da organização (mirrors internos, proxies autenticados, agentes de deploy) é recomendada.
