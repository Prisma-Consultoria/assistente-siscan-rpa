# Guia de Deploy — Assistente SISCAN RPA
<a name="deploy"></a>

Versão: 2.0
Data: 2025-12-02

Este documento descreve passo a passo reproduzível para preparar, instalar e operar o Assistente SISCAN RPA em ambientes Windows (focado em prefeituras). Todas as ações são operacionais e apresentadas em tabelas com `Passo | O que Fazer | Como Fazer`.

**Observação:** este guia presume Windows 10/11 (Pro ou Server) com Docker Desktop instalado. Todas as etapas indicam comandos PowerShell para execução local.

## Resumo técnico e informações adicionais

| Passo | O que Fazer | Como Fazer |
|---|---|---|
| 1 | Verificar requisitos de hardware mínimos | CPU: 2 vCPU (produção: 4+ vCPU); RAM: 4 GB (produção: 8+ GB); Disco: 20 GB livres — confirmar em PowerShell: `Get-CimInstance Win32_ComputerSystem | Select-Object NumberOfLogicalProcessors, TotalPhysicalMemory` e verifique espaço em disco com `Get-PSDrive C` |
| 2 | Identificar perfis e responsabilidades | Listar papéis que participarão do deploy: Operador, Administrador Windows, DevOps/Infra, Suporte N2/N3 | Documento interno: registrar contatos e responsáveis; exemplo: `Operador: equipe X (contato)` em `docs/CHECKLISTS.md` |
| 3 | Revisar componentes técnicos do ambiente | Confirmar presença de Docker, Docker Compose, PowerShell e acesso GHCR | Em PowerShell: `docker version`; `docker compose version`; `Get-Host` e teste `Test-NetConnection ghcr.io -Port 443` |
| 4 | Entender o fluxo de deploy (arquitetura) | Fluxo: autenticar GHCR → pull das imagens → criar containers → mapear volumes → monitorar health endpoints | Executar passos em ordem: `docker login ghcr.io`; `docker compose pull`; `docker compose up -d`; `Invoke-WebRequest http://localhost:8080/health` |

| Passo | O que Fazer | Como Fazer |
|---|---|---|
| 5 | Verificar locais de arquivos e logs recomendados | Confirmar paths padrão no host para persitência | Padrões: `C:\assistente-siscan\` (código e compose), `C:\assistente-siscan\media\downloads\`, `C:\assistente-siscan\logs\` — criar com `New-Item -ItemType Directory -Path <path> -Force` |

## 1 — Pré-requisitos

| Passo | O que Fazer | Como Fazer |
|---|---|---|
| 1 | Verificar versão do Windows | Abra PowerShell (Admin) e execute: `systeminfo | Select-String "OS Name|OS Version"` — confirme Windows 10/11 ou Windows Server compatível |
| 2 | Verificar PowerShell | `Get-Host` ou `pwsh -v`; objetivo: PowerShell 5.1+ (Windows PowerShell) ou PowerShell 7+ (recomendado). Se não houver, instalar PowerShell 7 via MSI da Microsoft |
| 3 | Garantir Docker instalado | Abrir Docker Desktop; em PowerShell executar: `docker version` e `docker info` — espere resposta sem erros |
| 4 | Habilitar execução de scripts (temporária ou permanente) | Para testes: execute PowerShell (Admin) e rode: `Set-ExecutionPolicy RemoteSigned -Scope LocalMachine` (confirme com `S`). Se houver GPO restritiva, contate TI para exceção |
| 5 | Credenciais da prefeitura | Tenha um usuário admin local no Windows e credenciais (usuário/ token) do GitHub com `read:packages` para GHCR |
| 6 | Repositório GHCR acessível | Teste conectividade: `Test-NetConnection ghcr.io -Port 443` e `Resolve-DnsName ghcr.io` — ambos devem retornar sucesso |

## 2 — Instalação Completa do Assistente

2.1 Download do script PowerShell

| Passo | O que Fazer | Como Fazer |
|---|---|---|
| 1 | Baixar o script oficial (`siscan-assistente.ps1`) para revisão | Em PowerShell (não executar sem revisar): `Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/Prisma-Consultoria/assistente-siscan-rpa/main/siscan-assistente.ps1' -OutFile C:\assistente-siscan\siscan-assistente.ps1` |
| 2 | Inspecionar o script | Abrir o arquivo no editor (`notepad C:\assistente-siscan\siscan-assistente.ps1`) e verificar se não há comandos não esperados antes de executar |

2.2 Execução como administrador e fluxo inicial

| Passo | O que Fazer | Como Fazer |
|---|---|---|
| 1 | Executar PowerShell como Administrador | Menu Iniciar → digite `PowerShell` → clicar com botão direito → `Executar como administrador` |
| 2 | Executar o instalador interativo | Navegar até a pasta e executar: `cd C:\assistente-siscan` e `.\siscan-assistente.ps1` (ou `pwsh -NoProfile -ExecutionPolicy Bypass -File .\siscan-assistente.ps1`) |
| 3 | Confirmar prompt de path do projeto | Quando solicitado, informar `C:\assistente-scan` ou outro path aprovado pela TI; confirme que o path existe ou permita que o script crie |

2.3 Clone ou pull automático do repositório

| Passo | O que Fazer | Como Fazer |
|---|---|---|
| 1 | Clonar repositório se ainda não existir | `git clone https://github.com/Prisma-Consultoria/assistente-siscan-rpa.git C:\assistente-siscan` |
| 2 | Atualizar repositório existente (pull) | `git -C C:\assistente-siscan pull origin main` — rodar como usuário com acesso à rede |

2.4 Geração do `.env` a partir do `.env.sample`

| Passo | O que Fazer | Como Fazer |
|---|---|---|
| 1 | Copiar `.env.sample` para `.env` | `Copy-Item -Path C:\assistente-siscan\.env.sample -Destination C:\assistente-siscan\.env -Force` |
| 2 | Editar variáveis obrigatórias | `notepad C:\assistente-siscan\.env` — preencher: `GHCR_USER`, `GHCR_TOKEN`, `SISCAN_API_ENDPOINT`, `SISCAN_API_KEY`, `DOWNLOAD_PATH`, `LOG_PATH` |
| 3 | Verificar valores não vazios | Em PowerShell: `Select-String -Path C:\assistente-siscan\.env -Pattern '^[A-Z0-9_]+=\s*$'` — se houver saída, corrigi-la (valores vazios) |

2.5 Criação de pastas necessárias e permissões

| Passo | O que Fazer | Como Fazer |
|---|---|---|
| 1 | Criar diretórios padrão | `New-Item -ItemType Directory -Path C:\assistente-siscan\media\downloads -Force` e `New-Item -ItemType Directory -Path C:\assistente-siscan\logs -Force` |
| 2 | Ajustar permissões (administradores e conta do serviço) | `icacls C:\assistente-siscan /grant "Administradores:(OI)(CI)F" /T` e, se houver conta de serviço, `icacls C:\assistente-siscan /grant "NT SERVICE\docker-<service>:(OI)(CI)M" /T` (substituir conforme política local) |

## 3 — Uso do Menu do Assistente (cada opção detalhada)

Opções disponíveis no `siscan-assistente.ps1`. Cada opção abaixo está documentada com verificações, diagnóstico e mensagens.

### Opção 1 — Pull da imagem

| Passo | O que Fazer | Como Fazer |
|---|---|---|
| 1 | Iniciar processo de pull | No menu, escolher Opção 1. O script executará `docker login ghcr.io -u <USER> -p <TOKEN>` seguido de `docker compose pull` |
| 2 | Verificações feitas pelo script | O script verifica: conexão com `ghcr.io`, autenticação bem-sucedida, existência da tag. Testes: `Test-NetConnection ghcr.io -Port 443`; `docker info` e `docker images` após pull. |
| 3 | Diagnóstico quando serviço/imagem não existe | Mensagem pública exibida: `Imagem não encontrada: ghcr.io/Prisma-Consultoria/assistente-siscan-rpa:<tag>`; instrução exibida para verificar `GHCR_TOKEN` e `TAG` |
| 4 | Mensagens públicas do script | O script escreve no console: `Autenticando...`, `Pull em andamento...`, `Pull concluído` ou `Erro: <mensagem docker>` — logs persistidos em `C:\assistente-siscan\logs\deploy.log` quando habilitado |

### Opção 2 — Criar/Configurar usuário SISCAN

| Passo | O que Fazer | Como Fazer |
|---|---|---|
| 1 | Iniciar criação de usuário | No menu, escolher Opção 2 — o script pede dados do usuário a ser criado (nome, CPF, e-mail, função) |
| 2 | Campos necessários | `Nome`, `CPF`, `Email`, `Senha provisória` (se aplicável), `Perfil (operador/admin)` — preencher todos os campos quando solicitado |
| 3 | Chamadas HTTP realizadas | O script realiza `POST` para `$env:SISCAN_API_ENDPOINT/users` com JSON: `{"nome":"..","cpf":"..","email":"..","perfil":".."}` usando `Invoke-RestMethod -Uri $url -Method Post -Body $json -Headers $headers` |
| 4 | Verificação de sucesso | O script verifica resposta `201 Created` ou `200 OK` e registra no log; em caso de `4xx/5xx` o erro é exibido e gravado em `C:\assistente-siscan\logs\users-create.log` |

### Opção 3 — Reiniciar serviço

| Passo | O que Fazer | Como Fazer |
|---|---|---|
| 1 | Reiniciar containers do assistente | No menu, escolher Opção 3 — o script executa: `docker compose restart` |
| 2 | Comandos usados | `docker compose stop` → `docker compose up -d` se restart falhar; ou `docker compose down && docker compose up -d` para reinicialização completa |
| 3 | Erros comuns | `port already allocated` (porta em uso); `container unhealthy` (checagem de health falhou) — o script mostra instruções para `docker ps -a` e `docker logs <container>` |
| 4 | Logs relevantes | Instruções para coletar logs: `docker compose logs --no-color --timestamps > C:\assistente-siscan\logs\restart-YYYYMMDD.log` |

## 4 — Agendamento do Extrator

| Passo | O que Fazer | Como Fazer |
|---|---|---|
| 1 | Nome da tarefa agendada | `Siscan-Extrator` (padrão) — documentar na TI local para controle |
| 2 | Comando executado pela tarefa | Exemplo PowerShell: `pwsh -NoProfile -ExecutionPolicy Bypass -File C:\assistente-siscan\scripts\extrator.ps1` |
| 3 | Criar tarefa agendada (exemplo) | `schtasks /Create /TN "Siscan-Extrator" /TR "pwsh -NoProfile -ExecutionPolicy Bypass -File C:\assistente-siscan\scripts\extrator.ps1" /SC DAILY /ST 02:00 /RU "NT AUTHORITY\SYSTEM"` |
| 4 | Ação de retry | Na criação do `schtasks` não há retry automático; sugerimos wrapper que faz retry 3x com `Start-Sleep -Seconds 30` entre tentativas e registro em log se falhar |
| 5 | Execução manual | `Start-Process pwsh -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','C:\assistente-siscan\scripts\extrator.ps1' -Wait` |
| 6 | Onde verificar falhas | Event Viewer → `Windows Logs` → `Application` e `System`; além de `C:\assistente-siscan\logs\extrator.log` e `schtasks /Query /TN "Siscan-Extrator" /V /FO LIST` |

---

## Anexos — Comandos úteis (PowerShell)

```powershell
# Verificar execução do Docker
docker info

# Login GHCR
docker login ghcr.io -u <USUARIO_GH> -p <TOKEN>

# Subir serviços
cd C:\assistente-siscan
docker compose pull
docker compose up -d

# Logs
docker compose logs --no-log-prefix --since 10m

# Verificar service Windows (quando aplicável)
Get-Service -Name *siscan* -ErrorAction SilentlyContinue
```

---

Se precisar que eu gere checklists imprimíveis ou um procedimento de roll-back, posso preparar um `CHECKLISTS.md` derivado deste guia.
