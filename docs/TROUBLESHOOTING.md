
# Guia de Troubleshooting — Assistente SISCAN RPA
<a name="troubleshooting"></a>

Versão: 2.0
Data: 2025-12-02

Este documento descreve problemas que ocorreram em produção e fornece instruções operacionais, reproduzíveis e específicas para ambiente Windows das prefeituras. Todas as ações abaixo são realizadas em PowerShell (executar como Administrador quando indicado).

Nota: cada tópico usa a tabela obrigatória `| Passo | O que Fazer | Como Fazer |` conforme solicitado.

---

## Regra de Ouro — Antes de agir

| Passo | O que Fazer | Como Fazer |
|---|---|---|
| 1 | Registrar o incidente | Anotar data, hora, usuário, passos exatos executados antes do erro | Usar arquivo `C:\assistente-siscan\logs\incident-YYYYMMDD.txt` ou abrir `notepad C:\assistente-siscan\logs\incident-YYYYMMDD.txt` e colar as saídas dos comandos a seguir |
| 2 | Sempre executar diagnósticos com PowerShell como Administrador | Muitos comandos de diagnóstico requerem privilégios elevados para obter informações completas | Menu Iniciar → digitar `PowerShell` → botão direito → `Executar como administrador` → confirmar UAC |
| 3 | Coletar saídas dos comandos principais antes de alterar configuração | Salve as saídas para permitir reprodutibilidade e análise por suporte | Exemplos: `docker info > C:\assistente-siscan\logs\docker-info.txt`, `docker compose ps > C:\assistente-siscan\logs\compose-ps.txt` |

---

## 1 — Verificações Rápidas e Coleta de Informações

| Passo | O que Fazer | Como Fazer |
|---|---|---|
| 1 | Abrir PowerShell como Administrador | Abrir shell com privilégios para executar os comandos de diagnóstico | Menu Iniciar → digitar `PowerShell` → clicar com o botão direito → `Executar como administrador` |
| 2 | Verificar status do Docker | Confirmar se o Docker Engine está rodando | `docker info` — salvar saída: `docker info > C:\assistente-siscan\logs\docker-info.txt` |
| 3 | Listar serviços do compose | Verificar containers e status | `docker compose ps --all > C:\assistente-siscan\logs\compose-ps.txt` |
| 4 | Coletar logs de um serviço específico | Obter evidência do erro em um container | `docker logs <NomeDoServico> --since 10m > C:\assistente-siscan\logs\<NomeDoServico>-logs.txt` |
| 5 | Coletar logs de todos os serviços | Obter logs agregados do compose | `docker compose logs --no-log-prefix --since 1h > C:\assistente-siscan\logs\compose-logs.txt` |
| 6 | Testar conectividade com GHCR | Verificar TLS e rota até GHCR | `Test-NetConnection ghcr.io -Port 443 -InformationLevel Detailed > C:\assistente-siscan\logs\nettest-ghcr.txt` e `curl -v https://ghcr.io/v2/ 2>&1 | Out-File C:\assistente-siscan\logs\curl-ghcr.txt` |
| 7 | Exportar imagens/localizar tags | Identificar imagens relacionadas ao assistente | `docker images --format '{{.Repository}}:{{.Tag}}' | Select-String 'assistente' > C:\assistente-siscan\logs\images.txt` |


## Problema 1 — ExecutionPolicy bloqueando scripts

Mensagem real observada em produção:

`.\siscan-assistente.ps1 : não pode ser carregado porque a execução de scripts foi desabilitada neste sistema.`

| Passo | O que Fazer | Como Fazer |
|---|---|---|
| 1 | Diagnosticar a política ativa | Executar em PowerShell (Admin): `Get-ExecutionPolicy -List` — verifique as políticas por escopo (MachinePolicy, UserPolicy, Process, CurrentUser, LocalMachine) |
| 2 | Liberar temporariamente para testar | Em PowerShell (Admin): `Set-ExecutionPolicy RemoteSigned -Scope Process -Force` — isto altera apenas a sessão atual |
| 3 | Liberar permanentemente (se permitido) | Em PowerShell (Admin): `Set-ExecutionPolicy RemoteSigned -Scope LocalMachine` (confirmar com `S`) — apenas se política local permitir |
| 4 | Verificar se há GPO forçando bloqueio | Em prompt administrativo: `gpresult /h C:\temp\gpresult.html` e abra o HTML para verificar configurações de Group Policy que definem ExecutionPolicy; alternativamente, peça ao time de TI para revisar a GPO | Se houver GPO com MachinePolicy/UserPolicy definindo política, só o administrador de domínio pode alterar |
| 5 | Solução temporária alternativa sem mudar GPO | Executar o script invocando PowerShell com `-ExecutionPolicy Bypass` no comando de agendamento ou chamada: `pwsh -NoProfile -ExecutionPolicy Bypass -File C:\assistente-siscan\siscan-assistente.ps1` |

Solução recomendada: aplicar `RemoteSigned` localmente para hosts gerenciados, e registrar exceções de GPO para hosts específicos com autorização da TI.

---

## Problema 2 — Falha de Autenticação no GitHub Container Registry (GHCR)

### Sintomas Comuns

- `Error response from daemon: Get "https://ghcr.io/v2/": denied: denied`
- `unauthorized: access to the requested resource is not authorized`
- `pull access denied for ghcr.io/prisma-consultoria/...`
- Script mostra: `Erro: nao foi possivel acessar com essas credenciais`

### Diagnóstico e Solução

| Passo | O que Fazer | Como Fazer |
|---|---|---|
| 1 | Verificar formato do token | Token válido do GitHub começa com `ghp_` (classic PAT), `gho_` (OAuth), ou `ghs_` (server). Se seu token não começar assim, está incorreto. | Exemplo válido: `ghp_1A2b3C4d5E6f7G8h9I0j1K2l3M4n5O6p7Q8r` (40+ caracteres) |
| 2 | Confirmar usuário correto | Deve ser seu **username** do GitHub (não o email). | Ver em: https://github.com/settings/profile → campo "Username" |
| 3 | Verificar permissões do token | Token deve ter scope `read:packages` no mínimo. Para repositórios privados organizacionais, pode precisar de `repo` também. | GitHub → Settings → Developer settings → Personal access tokens → clicar no token → verificar scopes selecionados |
| 4 | Testar autenticação manualmente | Fazer logout e login novamente no terminal | `docker logout ghcr.io` seguido de `echo SEU_TOKEN | docker login ghcr.io -u SEU_USERNAME --password-stdin` — deve retornar `Login Succeeded` |
| 5 | Verificar expiração do token | Tokens podem expirar. Verifique a data de expiração no GitHub. | GitHub → Settings → Developer settings → Personal access tokens → verificar coluna "Expires" |
| 6 | Gerar novo token (se necessário) | Criar novo token com permissões corretas | Acessar: https://github.com/settings/tokens/new → Nome: "SISCAN RPA Read" → Expiração: 90 dias (ou conforme política) → Scopes: ✓ `read:packages` (✓ `repo` se org privada) → Generate token → **COPIAR IMEDIATAMENTE** (só aparece uma vez) |
| 7 | Verificar acesso ao repositório | Confirmar que seu usuário tem acesso ao repositório da organização | Acessar: https://github.com/Prisma-Consultoria/siscan-rpa-rpa → se retornar 404, você não tem acesso → solicitar ao admin da org |
| 8 | Limpar cache de credenciais do Docker | Windows: Credential Manager pode armazenar credenciais antigas | Painel de Controle → Credential Manager → Windows Credentials → procurar `docker-credential-desktop` ou `ghcr.io` → Remove → tentar login novamente |
| 9 | Testar conectividade com GHCR | Verificar se há bloqueio de firewall/proxy | `Test-NetConnection ghcr.io -Port 443` → State deve ser "Success". Se falhar: `curl -v https://ghcr.io/v2/` → deve retornar HTTP 401 (esperado sem auth), não timeout/erro de rede |

### Checklist Rápido de Validação de Token

Antes de usar o token no assistente, valide:

- [ ] Token começa com `ghp_`, `gho_` ou `ghs_`
- [ ] Token tem 40+ caracteres
- [ ] Token foi gerado nas últimas 24h ou não está expirado
- [ ] Token tem scope `read:packages` habilitado
- [ ] Username é o correto (não email)
- [ ] Você tem acesso ao repositório no GitHub (testar acessando a URL no browser logado)

### Como Gerar Token Correto (Passo a Passo)

1. Acessar: https://github.com/settings/tokens/new
2. **Note**: "SISCAN RPA - Read Packages"
3. **Expiration**: 90 days (ou conforme política da organização)
4. **Select scopes**:
   - ✅ `read:packages` (obrigatório)
   - ✅ `repo` (apenas se repositório for privado da organização)
5. Clicar em **Generate token**
6. **COPIAR O TOKEN IMEDIATAMENTE** (aparece só uma vez)
7. Salvar em local seguro (gerenciador de senhas)

### Problema 2B — Falha de Permissão no Pull da Imagem do GHCR

Comportamento: `docker compose pull` retorna erro `unauthorized: access to the requested resource is not authorized` ou `pull access denied`.

| Passo | O que Fazer | Como Fazer |
|---|---|---|
| 1 | Detectar o erro exato | Executar: `docker compose pull` e inspecionar saída/erro; redirecionar para arquivo: `docker compose pull 2>&1 | Out-File C:\assistente-siscan\logs\pull-error.txt` |
| 2 | Verificar status do login Docker | `docker logout ghcr.io` seguido de `docker login ghcr.io -u <GITHUB_USER> -p <PAT>` (PAT com `read:packages`) — confirmar saída `Login Succeeded` |
| 3 | Resetar credenciais locais do Docker | Windows: abrir Credenciais do Windows (Credential Manager) → procurar entradas relacionadas a `ghcr.io`/`docker` e remover; depois executar `docker login ghcr.io` novamente |
| 4 | Seguir passos da seção 2 acima | Ver seção "Problema 2 — Falha de Autenticação" para diagnóstico completo |
| 5 | Como o script deve reagir | Script deve: detectar código de erro 401/403, mostrar mensagem clara `Erro de autenticação GHCR — execute docker login ghcr.io` e abortar pull com código de retorno != 0, gravando detalhes em `C:\assistente-siscan\logs\pull-error.txt` |

Quando solicitar token novamente: sempre quando `docker login` falhar com 401/403. Não armazenar PAT em repositório; usar `docker login` por sessão ou secret manager local.

---

## Problema 3 — "Nenhum serviço encontrado"

Sintoma: comandos PowerShell ou o script retornam mensagem indicando que o serviço do Assistente não existe ou `Get-Service` não lista serviço com nome esperado.

| Passo | O que Fazer | Como Fazer |
|---|---|---|
| 1 | Diagnóstico inicial | Executar PowerShell (Admin): `Get-Service *siscan*` e `docker compose ps` — confirmar ausência do serviço no Windows Services e containers | Se `Get-Service` não retornar nada, o serviço Windows com nome `siscan-*` não está instalado |
| 2 | Verificar nome correto do serviço | Conferir no `docker-compose.yml` e no script de instalação (`siscan-assistente.ps1`) qual nome foi usado para registrar serviço. Procure por `New-Service`, `sc.exe create` ou instruções de registro. |
| 3 | Como reinstalar o serviço | Se houver um instalador que registra o serviço Windows: executar o script de instalação como Admin ou executar manualmente (exemplo): `sc create SiscanService binPath= "C:\assistente-siscan\service-wrapper.exe" start= auto` — substituir pelo binário real; preferir usar o script fornecido que automatiza isso |
| 4 | Verificar logs de instalação | Checar `C:\assistente-siscan\logs\install.log` ou saída do instalador; usar `Get-WinEvent -LogName Application | Where-Object {$_.TimeCreated -gt (Get-Date).AddMinutes(-30)}` para eventos recentes |

Se o assistente roda apenas como container (sem service Windows), confirme `docker compose up` e ajuste o processo de monitoramento da prefeitura para observar containers, não Windows Services.

---

## Problema 4 — `.env` vazio ou não gerado

Sintoma: variáveis de ambiente não preenchidas, containers iniciam com valores vazios ou logs indicam falta de credenciais.

| Passo | O que Fazer | Como Fazer |
|---|---|---|
| 1 | Verificar `.env` e `.env.sample` | `Get-Content C:\assistente-siscan\.env -Raw` e `Get-Content C:\assistente-siscan\.env.sample -Raw` — comparar chaves e valores |
| 2 | Causas comuns | Arquivo `.env` não foi copiado; permissões impedem escrita; script falhou ao gerar arquivo | Verificar saída do instalador em `C:\assistente-siscan\logs\install.log` e verificar se o processo que cria `.env` terminou com sucesso |
| 3 | Recriar `.env` manualmente | `Copy-Item C:\assistente-siscan\.env.sample C:\assistente-siscan\.env -Force` e então editar: `notepad C:\assistente-siscan\.env` preenchendo valores obrigatórios |
| 4 | Corrigir permissões do arquivo | `icacls C:\assistente-siscan\.env /grant "Administradores:(R,W)"` e garantir que a conta que executa o serviço/container consiga ler o arquivo |
| 5 | Como o script impede valores vazios | Implementação recomendada no script: antes de prosseguir, validar com `Select-String -Path .env -Pattern '^[A-Z0-9_]+=\s*$'` e abortar com mensagem clara pedindo preenchimento das variáveis obrigatórias |

---

## Problema 5 — Remoção de variáveis de debug/log

Contexto: variáveis sensíveis de debug/log foram removidas antes de entregar ao cliente em produção.

| Passo | O que Fazer | Como Fazer |
|---|---|---|
| 1 | Quais variáveis foram removidas | Exemplo de variáveis a remover: `DEBUG`, `TRACE`, `DEV_LOG`, `LOCAL_DEBUG_TOKEN`, `SAMPLE_PAYLOAD` — confirmar por audit no repo | Conferir histórico Git: `git log -p -- docs/ .env.sample` e procurar commits que removem `DEBUG`|
| 2 | Por que não devem ir ao cliente | Variáveis de debug podem vazar dados sensíveis, gerar ruído em produção e expor internals | Documentar política de variáveis sensíveis em `docs/CHECKLISTS.md` e remover do `.env.sample` de produção |
| 3 | Como o script limpa automaticamente | Implementar/validar presença de rotina no instalador: após copiar `.env.sample` para `.env`, remover chaves proibidas via PowerShell: `Get-Content .env | Where-Object {$_ -notmatch '^(DEBUG|TRACE|DEV_LOG|LOCAL_DEBUG_TOKEN)='} | Set-Content .env` |
| 4 | Checagem pós-deploy | Script deve validar `.env` e gerar alerta se variáveis proibidas existirem: retornar erro e gravar em `C:\assistente-siscan\logs\security-check.log` |

---

## Problema 6 — Falha no pull por rede instável / firewall

Sintoma: `docker pull` falha intermitentemente, tempo esgota (timeout) ou conexões TLS são interceptadas.

| Passo | O que Fazer | Como Fazer |
|---|---|---|
| 1 | Diagnóstico básico de rede | `Test-NetConnection ghcr.io -Port 443 -InformationLevel Detailed` e `ping ghcr.io` (ping pode não responder em alguns hosts) |
| 2 | Testes de rede adicionais | `curl -v https://ghcr.io/v2/` para verificar handshake TLS; `tracert ghcr.io` para identificar hops problemáticos |
| 3 | Retry manual (PowerShell loop) | Exemplo: `for ($i=0; $i -lt 5; $i++) { docker pull ghcr.io/Prisma-Consultoria/assistente-siscan-rpa:<tag> ; if ($?){ break } ; Start-Sleep -Seconds 30 }` |
| 4 | Comando alternativo se Docker falhar | Baixar a imagem como tar (quando suportado pelo provider) ou pedir ao time de Infra para disponibilizar mirror interno; alternativamente, usar `docker save`/`docker load` em máquina com acesso e transferir o tar |
| 5 | Quando envolver TI da prefeitura | Se `Test-NetConnection` falhar repetidamente ou se houver bloqueio por firewall/proxy, abrir chamado com evidência (`tracert`, `curl -v`) solicitando liberação de `ghcr.io` (porta 443) ou configuração de proxy TLS | Forneça logs de `docker pull` e `Test-NetConnection` ao time de TI para acelerar diagnóstico |

---

## Coleta de artefatos para suporte avançado (sempre coletar quando abrir chamado)

| Passo | O que Fazer | Como Fazer |
|---|---|---|
| 1 | Coletar logs do compose | `docker compose logs --no-log-prefix --since 1h > C:\assistente-siscan\logs\compose-logs.txt` |
| 2 | Coletar info do Docker | `docker info > C:\assistente-siscan\logs\docker-info.txt` e `docker version > C:\assistente-siscan\logs\docker-version.txt` |
| 3 | Coletar política de execução do PowerShell | `Get-ExecutionPolicy -List > C:\assistente-siscan\logs\executionpolicy.txt` |
| 4 | Coletar saída de testes de rede | `Test-NetConnection ghcr.io -Port 443 -InformationLevel Detailed > C:\assistente-siscan\logs\nettest.txt` |
| 5 | Capturar configuração do serviço agendado | `schtasks /Query /TN "Siscan-Extrator" /V /FO LIST > C:\assistente-siscan\logs\taskinfo.txt` |
