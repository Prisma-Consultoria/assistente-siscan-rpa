
# Solução de problemas completa - Assistente SISCAN RPA
<a name="troubleshooting"></a>

Versão: 1.0
Data: 2025-11-30

Este documento contém procedimentos de diagnóstico e correção para problemas que podem ocorrer durante o deploy e operação do Assistente SISCAN RPA em host Windows com Docker.

## Como usar este guia

- Sempre colecione logs antes de mudanças: `docker logs`, `docker inspect`, `docker compose logs`.
- Reproduza o problema com comandos mínimos.
- Aplique a solução em ambiente de staging quando possível.
- Observação: este repositório fornece `install.ps1` e `install.sh` (veja `README.md`) — use-os apenas após inspecionar o conteúdo quando em produção.

---

## 1. Comandos de coleta rápida

- `docker version` — versão client/server
- `docker info` — status do daemon
- `docker compose version` — versão do compose
- `docker compose config` — validação do `docker-compose.yml`
- `docker compose ps` — estado dos serviços
- `docker logs <container>` — logs do container
- `docker inspect <container>` — metadados do container
- `Test-NetConnection ghcr.io -Port 443` — teste de conectividade a GHCR
- `Resolve-DnsName ghcr.io` / `nslookup ghcr.io` — verificação DNS

---

## 2. Problemas com Docker (daemon, Desktop, WSL2)

Problema: Docker não inicia / Daemon parado
- Sintomas: `docker info` falha, `Cannot connect to the Docker daemon`.
- Diagnóstico:
  - `Get-Service com.docker.service`
  - Verificar logs: `%APPDATA%\Docker\log.txt` e `C:\ProgramData\DockerDesktop\service.txt`.
- Correção:
  - Reiniciar serviço: `Restart-Service com.docker.service` (PowerShell Admin).
  - Se usar WSL2: executar `wsl --update` e reiniciar Docker Desktop.
  - Verificar espaço em disco e memória.

Problema: Docker quebrado após atualização do Windows
- Sintomas: Docker Desktop abre, mas containers não iniciam.
- Diagnóstico: revisar logs no caminho acima; verificar versão WSL2 kernel.
- Correção:
  - Atualizar WSL2 kernel: `wsl --update`.
  - Desabilitar e reabilitar integração WSL2 no Docker Desktop.
  - Reinstalar Docker Desktop versão compatível com OS.

Problema: Falha no login ao GHCR
- Sintomas: `unauthorized: authentication required` ou `pull access denied`.
- Diagnóstico: `docker login ghcr.io -u <user> -p <token>` erros; verificar escopos do token no GitHub.
- Correção:
  - Regenerar PAT com `read:packages` e `repo` (se imagem for privada dentro de repositorio privado).
  - Executar `docker logout ghcr.io` e `docker login ghcr.io` novamente.

Erro: `Mount denied` ou `invalid mount config for type 'bind'`
- Causa: Docker Desktop não autorizado a acessar o drive ou o caminho não existe.
-- Solução:
  - Habilitar file sharing do drive C: nas configurações do Docker Desktop.
  - Garantir que o caminho host existe e tem permissões adequadas.

Erro: `Bind: address already in use`
- Diagnóstico: `netstat -ano | findstr :<porta>` para identificar PID.
- Solução: parar o processo que usa a porta ou alterar mapeamento da porta no `docker-compose.yml`.

---

## 3. Problemas com Docker Compose

Compose não sobe ou falha ao criar serviço
- Diagnóstico: executar `docker compose config` para validar YAML.
- Solução: ajustar indentação, versões ou variáveis de ambiente; checar volumes e paths.

Container fica em loop de reinício (CrashLoop)
- Diagnóstico: `docker logs <container>` mostra stacktrace ou erro.
-- Solução:
  - Ver logs e replicar `docker run --rm -it <image> sh` para debugar manualmente.
  - Ajustar variáveis de ambiente, entrypoint ou healthcheck.

Volumes sem permissão
- Diagnóstico: erros nos logs do container sobre escrita em caminho montado.
- Solução: ajustar ACLs do host (`icacls`) e garantir que o usuário do processo dentro do container tenha permissão (uid/gid se aplicável).

---

## 4. Problemas com GHCR e GitHub

Token inválido / expirado / escopo incorreto
- Verificar via GitHub → Settings → Developer settings → Personal access tokens.
- Geração recomendada: PAT com `read:packages` (mínimo). Adicionalmente `repo` se necessário.

Pull de imagem privada falha
- Verificar `docker login ghcr.io` com o usuário GitHub correto.
- Se o repositório pertence a organização, garantir que o pacote esteja visível para o usuário (read access) ou que PAT seja de um usuário com acesso.

Rate limit / bloqueio por rede
- Diagnóstico: obter mensagens de erro no `docker pull` ou testar com `curl`.
- Solução: adicionar autenticação, solicitar exceção de rede ou usar mirror interno.

---

## 5. Problemas de Windows (permissões, ExecutionPolicy, Defender)

ExecutionPolicy bloqueando scripts
- Sintoma: `script.ps1 cannot be loaded because running scripts is disabled on this system`.
- Solução: executar PowerShell como Admin e `Set-ExecutionPolicy RemoteSigned -Scope LocalMachine` (só se a política de segurança permitir).

Windows Defender bloqueando execução ou acesso a arquivos
- Diagnóstico: logs do Windows Defender e eventos de bloqueio.
- Solução: adicionar exceções para Docker, pastas do projeto e binários conhecidos do Assistente.

Permissões NTFS
- Usar `icacls` e `takeown` para corrigir dono e ACLs.
```powershell
takeown /f C:\assistente-siscan /r /d y
icacls C:\assistente-siscan /grant "Administradores:(OI)(CI)F" /T
```

---

## 6. Rede e Internet

DNS/Conectividade com `ghcr.io`
- `nslookup ghcr.io`
- `Test-NetConnection ghcr.io -Port 443`
- Se `ghcr.io` não resolve, tente `8.8.8.8` como DNS temporário e contate NetOps.

Proxy corporativo
- Configurar variáveis `HTTP_PROXY` e `HTTPS_PROXY` no Docker Desktop (Settings → Resources → Proxies) e no ambiente PowerShell.

---

## 7. Coleta de artefatos para escalonamento

- `docker compose logs --no-log-prefix > compose-logs.txt`
- `docker inspect <container> > inspect-<container>.json`
- `docker images --digests > images.txt`
- Capturar saída de `docker info` e `docker version`
- Reunir timestamps e passos executados antes do erro

---

## 8. Árvores de decisão rápidas (exemplos)

- Erro: `unauthorized` ao puxar imagem → Se token inválido/expirado: regenerar PAT → testar `docker login` → se persistir, verificar rede/proxy.
- Erro: `Mount denied` → Checar compartilhamento do drive no Docker Desktop → ajustar permissões no host → reproduzir com `docker run` de teste.

---

## 9. Notas finais

Documente todas as ações e tempos. Se escalonar, anexe os artefatos coletados nesta seção.
