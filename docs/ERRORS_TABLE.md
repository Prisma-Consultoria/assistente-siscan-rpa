# Erros Comuns e Soluções - Assistente SISCAN RPA

Esta tabela lista erros frequentes relacionados a Rede, Docker, Windows, GHCR, Compose, permissões, WSL2, e fornece causas prováveis e soluções práticas.

| # | Erro (mensagem comum) | Causa provável | Solução prática |
|---:|---|---|---|
| 1 | Cannot connect to the Docker daemon | Docker daemon parado / permissão | Iniciar serviço `Restart-Service com.docker.service`; executar PowerShell como Admin; adicionar usuário a `docker-users` |
| 2 | Error response from daemon: pull access denied | Token inválido ou sem permissão | `docker login ghcr.io` com PAT com `read:packages`; regenerar token |
| 3 | mount denied: path not found | Caminho host inexistente ou drive não compartilhado | Criar caminho, habilitar compartilhamento do drive no Docker Desktop |
| 4 | Bind: address already in use | Porta do host já em uso | Identificar PID que usa a porta (Windows: `netstat -ano`; Linux: `ss -ltnp`) e parar processo ou alterar porta no `docker-compose.yml` |
| 5 | Permission denied (file) | ACLs do Windows incorretas | Usar `icacls` / `takeown` para ajustar permissões |
| 6 | network not found | Rede mencionada no compose ausente | `docker network create <name>` ou remover referência (substituir `<name>` pelo nome da rede) |
| 7 | no space left on device | Disco cheio | Limpar logs; `docker system prune` ou expandir disco |
| 8 | TLS handshake timeout | Proxy/inspeção TLS/latência | Verificar proxy; importar CA corporativa; testar sem proxy |
| 9 | unauthorized: authentication required | Login expirado/errado | `docker logout ghcr.io` e `docker login` novamente |
| 10 | Error parsing reference: repository name must be lowercase | Nome de imagem com maiúsculas | Renomear imagem para lowercase |
| 11 | invalid mount config for type "bind" | Bind mal configurado | Corrigir `volumes` no compose e garantir paths absolutos |
| 12 | container is unhealthy | Healthcheck da imagem falhou | Ver logs do app; ajustar healthcheck ou dependências |
| 13 | CrashLoop / restart policy | Exceção na aplicação | `docker logs`; executar container interativo para debug |
| 14 | failed to create LLB definition: failed to authorize | BuildKit / autorização faltando | Ver credenciais, `docker login`, desabilitar buildkit temporariamente |
| 15 | failed to load plugin: conflict of plugins | Plugin incompatível | Ver versões e reinstalar Docker ou plugin |
| 16 | file too large to process | Limites do app | Ajustar configuração do app ou dividir arquivo |
| 17 | Volume mount lost after reboot | Volume não persistente/mal configurado | Declarar volumes no compose e usar volumes nomeados |
| 18 | docker compose config returns error | YAML inválido | Corrigir sintaxe (indentação, variáveis) |
| 19 | Error response from daemon: conflict: unable to delete | Recurso em uso | Parar container/serviço antes de remover imagens |
| 20 | failed to start service: access denied | Serviço Windows sem permissão | Rodar como administrador; ajustar permissões do serviço |
| 21 | docker: command not found | PATH ou Docker não instalado | Instalar Docker Desktop e reiniciar shell |
| 22 | Cannot connect to the Docker daemon at unix:///var/run/docker.sock | WSL/Windows mismatch ou daemon parado | Ver integração WSL2 e permissões socket |
| 23 | ghcr.io resolve name temporarily unavailable | DNS | Testar `nslookup`; ajustar DNS ou contatar NetOps |
| 24 | 504 Gateway Timeout no pull | Proxy filtrando ou latência | Ver logs do proxy; configurar bypass ou aumentar timeout |
| 25 | unauthorized: authentication required (scope) | Token sem scope | Gerar PAT com `read:packages` |
| 26 | Docker Desktop cannot be installed on this edition of Windows | Edição incompatível | Usar WSL2 (Home) ou instalar em Server/Pro com Hyper-V |
| 27 | Not enough memory to allocate | Recursos insuficientes | Aumentar CPU/RAM no Docker Desktop |
| 28 | file path too long | Limite de path do Windows (>260) | Habilitar long paths no Windows ou encurtar caminhos |
| 29 | Permission denied on named pipe \\.\pipe\docker_engine | Acesso ao pipe negado | Executar Docker Desktop como Admin; ajustar permissões |
| 30 | The system cannot find the path specified | Caminho host inválido no compose | Corrigir `volumes` host path e criar diretório |
| 31 | Could not resolve host: ghcr.io | DNS/proxy | Ajustar DNS; testar com `curl` e `nslookup` |
| 32 | Failed to import CA certificate | TLS interception | Importar CA corporativa no Windows e Java (se aplicável) |
| 33 | Windows update broke docker | Kernel/WSL mismatch | Atualizar WSL2 kernel; reinstalar Docker Desktop |
| 34 | Error pulling image: manifest unknown | Tag inexistente | Verificar tag correta no GHCR |
| 35 | Credential helper not working | `credHelpers` mal configurado | Ajustar `~/.docker/config.json` e testar sem helper |
| 36 | Image size too big causing OOM | Imagem pesada | Otimizar imagem (multi-stage build) |
| 37 | Compose up hangs on creating volume | Permissão ou driver de volume | Ver ACLs e driver; testar `docker volume create` manualmente |
| 38 | DNS blocked by firewall | Firewall corporativo | Solicitar liberação de NetOps |
| 39 | Healthcheck failing intermittently | Recursos/latência | Aumentar timeout do healthcheck; escalar recursos |
| 40 | Rate limit errors | Excesso de pulls sem autenticação | Usar autenticação e cache de imagens internas |
| 41 | Error: invalid reference format | Tag/nome inválido | Corrigir formato `name:tag` |
| 42 | The system cannot find the file specified (entrypoint) | Build/context incorreto | Ver `COPY`/`WORKDIR` no Dockerfile e context do build |
| 43 | docker compose up error: bind: permission denied | ACL / políticas | Ajustar permissões NTFS e políticas de segurança |
| 44 | Unknown shorthand flag: 'd' in -d | Versão do compose incompatível | Atualizar Docker Compose ou usar `docker compose up -d` (sem hífen se v2) |
| 45 | EPIPE / Broken pipe ao enviar grandes arquivos | Timeouts/proxy | Ajustar timeouts; evitar inspeção proxy |
| 46 | Image pull stuck at 0% | Problema de rede/DNS | Testar conectividade com `curl` e `tcping` para ghcr.io:443 |
| 47 | mount /var/lib/docker/aufs error | Storage driver incompatible | Verificar driver de storage e versão do Docker |
| 48 | no such image: `image-name` | Tag ausente localmente e pull falhou | Checar `docker pull ghcr.io/<org>/image-name:<tag>` e tags corretas |

--

> Observação: adaptação das soluções conforme políticas da sua organização (ex.: uso de mirrors internos, proxies autenticados, ou agentes de deploy) é recomendada.
