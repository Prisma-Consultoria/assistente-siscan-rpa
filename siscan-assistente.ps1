#!/usr/bin/env pwsh
# -------------------------------------------
# CLI do Assistente SIScan
# -------------------------------------------
# Arquivo: siscan-assistente.ps1
# Proposito: Auxiliar no deploy, atualizacao e gerenciamento do ambiente do SIScan RPA.
#
# Uso:
#   pwsh ./siscan-assistente.ps1            # PowerShell Core (recomendado)
#   powershell.exe .\siscan-assistente.ps1  # Windows PowerShell 5.1 (legado)
#
# Comandos rapidos (menu interativo):
#   1) Reiniciar servico existente
#   2) Atualizar imagem e reiniciar servico
#   3) Login / alterar credenciais
#   4) Gerenciar .env (criar/atualizar)
#   5) Sair
#
# Pre-requisitos:
#   - PowerShell 7+ recommended (pwsh). If using Windows PowerShell 5.1, ensure the file is saved as UTF-8 with BOM.
#   - Docker and docker-compose installed and available in PATH.
#
# Codificacao:
#   - Script should be stored as UTF-8. For Windows PowerShell 5.1 compatibility prefer UTF-8 with BOM.
#
# Mantenedores:
#   - Prisma-Consultoria / Team: Infra / DevOps
#
# Registro de alteracoes:
#   2025-11-30  v0.1  Adicionado gerenciamento de .env, tratamento de codificacao e refatoracao.
#
# Observacoes:
#   - O script e propositalmente conservador para suportar PowerShell 5.1 e pwsh.
#   - Para uso em automacao ou nao interativo, considere extrair as funcoes para um modulo.
# -------------------------------------------

# Ajustes robustos de encoding/terminal para multiplos hosts
# - tenta forcar saida UTF-8 para o console
# - em Windows tenta ajustar code page via cmd.exe
# - define defaults para cmdlets de escrita dependendo da versao do PowerShell
try {
    $psMajor = 0
    if ($PSVersionTable -and $PSVersionTable.PSVersion) { $psMajor = $PSVersionTable.PSVersion.Major }

    # Forca saida UTF-8 para PowerShell/Core quando possivel
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
    try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

    # Em Windows, tente ajustar code page via cmd.exe (menos intrusivo que chcp direto em alguns hosts)
    if ($IsWindows -or ($env:OS -and $env:OS -match 'Windows')) {
        try { cmd.exe /c chcp 65001 > $null } catch {}
    }

    # Definir parametros padrao de encoding para cmdlets que gravam arquivos.
    # PowerShell Core (>=6) entende 'utf8'; Windows PowerShell (5.1) e mais seguro usar 'Unicode' (UTF-16 LE)
    if ($psMajor -ge 6) {
        $PSDefaultParameterValues['Out-File:Encoding'] = 'utf8'
        $PSDefaultParameterValues['Set-Content:Encoding'] = 'utf8'
        $PSDefaultParameterValues['Add-Content:Encoding'] = 'utf8'
    } else {
        $PSDefaultParameterValues['Out-File:Encoding'] = 'Unicode'
        $PSDefaultParameterValues['Set-Content:Encoding'] = 'Unicode'
        $PSDefaultParameterValues['Add-Content:Encoding'] = 'Unicode'
    }
} catch {}

$CRED_FILE = "credenciais.txt"
$IMAGE_PATH = "ghcr.io/prisma-consultoria/siscan-rpa-rpa:main"
$COMPOSE_FILE = Join-Path $PSScriptRoot "docker-compose.yml"

function Is-DockerAvailable {
    $null = $null
    try {
        $ver = docker --version 2>&1
        if ($LASTEXITCODE -ne 0) { return @{ok=$false; msg=($ver -join "`n")} }
        return @{ok=$true; msg=($ver -join "`n")} 
    } catch {
        return @{ok=$false; msg=$_}
    }
}

function Get-ExpectedServiceNames {
    param([string]$ComposePath)
    if (-not (Test-Path $ComposePath)) { return @() }

    $lines = Get-Content $ComposePath -ErrorAction SilentlyContinue
    $services = @()
    $inServices = $false
    foreach ($line in $lines) {
        if ($line -match '^\s*services\s*:') { $inServices = $true; continue }
        if ($inServices) {
            if ($line -match '^\s*[^\s]') { break } # fim do bloco services quando voltar ao nivel 0
            if ($line -match '^\s{2,}([a-zA-Z0-9_-]+)\s*:') { $services += $matches[1] }
        }
    }

    return $services
}

function Get-CredentialsFile {
    if (!(Test-Path $CRED_FILE)) { return $null }

    $creds = @{ usuario = $null; token = $null }

    Get-Content $CRED_FILE | ForEach-Object {
        $parts = $_ -split '='
        if ($parts[0] -eq "usuario") { $creds.usuario = $parts[1] }
        if ($parts[0] -eq "token")   { $creds.token   = $parts[1] }
    }

    return $creds
}

function Ask-Credentials {
    Write-Host "`nInforme suas credenciais do GHCR:`n"

    $user = Read-Host "Usuario"
    $tok  = Read-Host "Token"

    # Salvamento em disco comentado: nao gravamos mais credenciais em arquivo por padrao.
    # "usuario=$user" | Out-File $CRED_FILE -Encoding utf8
    # "token=$tok"    | Out-File $CRED_FILE -Encoding utf8 -Append
    # Write-Host "`nCredenciais salvas.`n"

    Write-Host "`nCredenciais obtidas (nao salvas em disco).`n"

    return @{ usuario = $user; token = $tok }
}

function Ensure-Credentials {
    # Sempre solicitar usuario + token do GHCR, mesmo que exista arquivo salvo.
    if (Test-Path $CRED_FILE) { Remove-Item $CRED_FILE -ErrorAction SilentlyContinue }
    return Ask-Credentials
}

function Docker-Login ($creds) {
    Write-Host "`nRealizando login no GHCR..."

    $null = $creds.token | docker login ghcr.io -u $creds.usuario --password-stdin

    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERRO: falha no login."
        return $false
    }

    Write-Host "Login realizado com sucesso."
    return $true
}

function UpdateAndRestart {
    Write-Host "`nAtualizando imagem e reiniciando servico..." -ForegroundColor Yellow

    if (-not (Test-Path "./docker-compose.yml")) {
        Write-Host "Arquivo docker-compose.yml nao encontrado!" -ForegroundColor Red
        return
    }

    # Solicita credenciais sempre e realiza login no GHCR
    Write-Host "`nSolicitando credenciais do GHCR (sempre)..." -ForegroundColor Cyan
    $creds = Ask-Credentials
    if (-not (Docker-Login $creds)) {
        Write-Host "Aviso: falha no login. Tentando continuar com pull (pode falhar)..." -ForegroundColor Yellow
    }

    # Tentar pull direto da imagem especifica (mais robusto para GHCR)
    Write-Host "`nTentando docker pull $IMAGE_PATH..." -ForegroundColor Cyan
    $pullOutput = docker pull $IMAGE_PATH 2>&1
    $pullCode = $LASTEXITCODE

    if ($pullCode -ne 0) {
        Write-Host "Pull direto falhou. Verificando estado do Docker e credenciais..." -ForegroundColor Yellow

        # Captura info do Docker para diagnostico
        $dockerInfo = docker info 2>&1
        $dockerInfoStr = $dockerInfo -join "`n"

        # Tenta detectar se ha usuario autenticado (docker info normalmente exibe 'Username:')
        $isAuthenticated = $dockerInfoStr -match 'Username\s*:'
        if ($isAuthenticated) {
            Write-Host "Docker parece autenticado (Username encontrado)." -ForegroundColor Cyan
        } else {
            Write-Host "Docker nao parece autenticado." -ForegroundColor Yellow
        }

        # Se existir arquivo de credenciais, tentar login com ele primeiro
        $savedCreds = Get-CredentialsFile
        $triedLogin = $false
        if ($savedCreds -and $savedCreds.usuario -and $savedCreds.token) {
            Write-Host "Credenciais salvas encontradas. Tentando login com credenciais salvas..." -ForegroundColor Cyan
            $triedLogin = $true
            if (Docker-Login $savedCreds) {
                Write-Host "Login com credenciais salvas bem-sucedido. Tentando pull novamente..." -ForegroundColor Cyan
                $pullOutput = docker pull $IMAGE_PATH 2>&1
                if ($LASTEXITCODE -eq 0) { Write-Host "Imagem baixada com sucesso." -ForegroundColor Green } else { $pullCode = $LASTEXITCODE }
            } else {
                Write-Host "Login com credenciais salvas falhou." -ForegroundColor Yellow
            }
        }

        # Se ainda nao obteve sucesso, solicitar novamente credenciais ao usuario e tentar login/pull
        if ($pullCode -ne 0) {
            Write-Host "Tentando solicitar usuario/token novamente..." -ForegroundColor Cyan
            $newCreds = Ask-Credentials
            if (Docker-Login $newCreds) {
                Write-Host "Login com novas credenciais bem-sucedido. Tentando pull de novo..." -ForegroundColor Cyan
                $pullOutput = docker pull $IMAGE_PATH 2>&1
                $pullCode = $LASTEXITCODE
            } else {
                Write-Host "Login com novas credenciais falhou." -ForegroundColor Yellow
            }
        }

        # Se ainda falhar, tentar fallback para 'docker compose pull' uma ultima vez
        if ($pullCode -ne 0) {
            Write-Host "Pull ainda falhando. Tentando 'docker compose pull' como ultimo recurso..." -ForegroundColor Yellow
            $composeOutput = docker compose pull 2>&1
            $composeCode = $LASTEXITCODE
            if ($composeCode -ne 0) {
                Write-Host "Erro ao baixar nova imagem via compose." -ForegroundColor Red

                Write-Host "`n--- Detalhes do erro ---`n" -ForegroundColor Red
                Write-Host "Saida do 'docker pull':" -ForegroundColor Red
                Write-Host ($pullOutput -join "`n")
                Write-Host "`nSaida do 'docker compose pull':" -ForegroundColor Red
                Write-Host ($composeOutput -join "`n")
                Write-Host "`nInformacoes do Docker (diagnostico):" -ForegroundColor Red
                Write-Host $dockerInfoStr
                Write-Host "`nAcoes recomendadas:" -ForegroundColor Yellow
                Write-Host "- Verifique sua conexao de rede e resolucao DNS para 'ghcr.io'." -ForegroundColor Yellow
                Write-Host "- Confirme que o token usado possui permissao 'read:packages' no GitHub." -ForegroundColor Yellow
                Write-Host "- Execute 'docker logout ghcr.io' e tente 'docker login ghcr.io' manualmente." -ForegroundColor Yellow
                Write-Host "- Se estiver atras de proxy/firewall, confirme regras para https:443 e SNI." -ForegroundColor Yellow
                return
            } else {
                Write-Host "Compose pull bem-sucedido." -ForegroundColor Green
            }
        }
    }

    # Depois reinicia tudo
    Write-Host "`nRecriando servico..." -ForegroundColor Cyan
    docker compose down
    docker compose up -d

    if ($LASTEXITCODE -eq 0) {
        Write-Host "`nServico atualizado e reiniciado com sucesso!" -ForegroundColor Green
    }
    else {
        Write-Host "`nErro ao reiniciar o servico!" -ForegroundColor Red
    }
}

function Restart-Service {
    if (!(Test-Path $COMPOSE_FILE)) {
        Write-Host "`nArquivo docker-compose.yml nao encontrado."
        return
    }

    Write-Host "`nReiniciando servicos..."
    docker compose down
    docker compose up -d

    if ($LASTEXITCODE -eq 0) {
        Write-Host "Servicos reiniciados com sucesso."
    } else {
        Write-Host "ERRO: falha ao reiniciar servicos."
    }
}

function Check-Service {
    $pattern = "*siscan*"
    $exists = docker ps --format "{{.Names}}" | Where-Object { $_ -like $pattern }
    return -not [string]::IsNullOrEmpty($exists)
}


function Update-EnvFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -ItemType File -Force | Out-Null
    }

    # Detectar BOM/encoding original para preservar ao regravar
    function Detect-FileEncoding {
        param([string]$FilePath)

        try {
            $bytes = [System.IO.File]::ReadAllBytes($FilePath)
        } catch {
            return 'utf8'
        }

        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { return 'utf8bom' }
        if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { return 'unicode' } # UTF-16 LE
        if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) { return 'bigendianunicode' } # UTF-16 BE

        return 'utf8'
    }

    $origEnc = 'utf8'
    if (Test-Path $Path) { $origEnc = Detect-FileEncoding -FilePath $Path }

    # Ler com a codificacao adequada (Get-Content entende nomes basicos)
    try {
        switch ($origEnc) {
            'unicode' { $lines = Get-Content -Path $Path -Encoding Unicode -ErrorAction Stop }
            'bigendianunicode' { $lines = Get-Content -Path $Path -Encoding BigEndianUnicode -ErrorAction Stop }
            default { $lines = Get-Content -Path $Path -Encoding UTF8 -ErrorAction Stop }
        }
    } catch {
        # fallback
        $lines = @()
    }

    $updated = @()

    foreach ($line in $lines) {
        if ($line -match '^\s*([A-Za-z0-9_]+)\s*=\s*(.*)$') {
            $key = $matches[1]
            $val = $matches[2]
            $valDisplay = $val.Trim()

            Write-Host "`nVariavel: $key = $valDisplay" -ForegroundColor Cyan
            $new = Read-Host "Novo valor (Enter para manter)"

            if ($new -ne "") {
                $updated += "$key=$new"
            } else {
                $updated += $line
            }
        } else {
            # mantem comentarios e linhas vazias
            $updated += $line
        }
    }

    # Regrava usando a codificacao original (preserva BOM quando houver) via .NET
    try {
        switch ($origEnc) {
            'utf8bom' {
                $enc = New-Object System.Text.UTF8Encoding($true)
            }
            'unicode' {
                $enc = [System.Text.Encoding]::Unicode
            }
            'bigendianunicode' {
                $enc = [System.Text.Encoding]::BigEndianUnicode
            }
            default {
                # UTF8 without BOM
                $enc = New-Object System.Text.UTF8Encoding($false)
            }
        }

        [System.IO.File]::WriteAllLines($Path, $updated, $enc)
    } catch {
        # Fallback para Set-Content com UTF8 caso algo falhe
        Set-Content -Path $Path -Value $updated -Encoding UTF8
    }

    Write-Host "`nArquivo .env atualizado e salvo em $Path" -ForegroundColor Green
}


function Manage-Env {
    $envFile = Join-Path $PSScriptRoot ".env"
    $templateFiles = @('.env.example', '.env.template', '.env.dist')

    if (-not (Test-Path $envFile)) {
        $found = $null
        foreach ($t in $templateFiles) {
            $p = Join-Path $PSScriptRoot $t
            if (Test-Path $p) { $found = $p; break }
        }

        if ($found) {
            Copy-Item $found $envFile -Force
            Write-Host ".env nao encontrado. Copiado de: $found" -ForegroundColor Yellow
        } else {
            New-Item -Path $envFile -ItemType File -Force | Out-Null
            Write-Host ".env nao encontrado. Criado arquivo vazio: $envFile" -ForegroundColor Yellow
        }
    } else {
        Write-Host ".env encontrado: $envFile" -ForegroundColor Yellow
    }

    Update-EnvFile -Path $envFile
}

# ----- Wrappers / Service adapters (mantem compatibilidade e separam responsabilidades) -----
function UI-ShowMenu { Show-Menu }
function UI-ReadChoice([string]$prompt) { return Read-Host $prompt }
function UI-Pause { Pause }
function UI-Write([string]$msg, [string]$color = $null) {
    if ($null -ne $color) { Write-Host $msg -ForegroundColor $color } else { Write-Host $msg }
}

function Env-Manage { Manage-Env }

function Creds-Ask { Ask-Credentials }
function Creds-Ensure { Ensure-Credentials }
function Creds-Get { Get-CredentialsFile }

function Docker-DoLogin($creds) { return Docker-Login $creds }
function Docker-UpdateAndRestart { UpdateAndRestart }
function Docker-CheckService { return Check-Service }
function Docker-RestartService { Restart-Service }

# Services container (injecao simples)
$Services = {
    UI = [ordered]@{
        ShowMenu = { UI-ShowMenu }
        ReadChoice = { param($p) UI-ReadChoice $p }
        Pause = { UI-Pause }
        Write = { param($m,$c) UI-Write $m $c }
    }
    Env = [ordered]@{
        Manage = { Env-Manage }
    }
    Creds = [ordered]@{
        Ask = { Creds-Ask }
        Ensure = { Creds-Ensure }
        Get = { Creds-Get }
    }
    Docker = [ordered]@{
        Login = { param($c) Docker-DoLogin $c }
        UpdateAndRestart = { Docker-UpdateAndRestart }
        CheckService = { Docker-CheckService }
        RestartService = { Docker-RestartService }
    }
}


function Show-Menu {
    Write-Host "==============================="
    Write-Host "  ASSISTENTE SISCAN RPA"
    Write-Host "==============================="
    Write-Host "1) Reiniciar servico existente"
    Write-Host "2) Atualizar imagem e reiniciar servico"
    Write-Host "3) Login / alterar credenciais"
    Write-Host "4) Gerenciar .env (criar/atualizar)"
    Write-Host "5) Sair"
    Write-Host "==============================="
}

# -------------------------
# MENU PRINCIPAL
# -------------------------

$creds = $null

$running = $true

while ($running) {
    Clear-Host
    Show-Menu
    $op = Read-Host "Selecione uma opcao"

    switch ($op) {
        "1" {
            if (Check-Service) {
                Restart-Service
            } else {
                Write-Host "Nenhum servico encontrado." -ForegroundColor Yellow
                # Mostrar nomes de serviço esperados a partir do docker-compose.yml
                $expected = Get-ExpectedServiceNames -ComposePath $COMPOSE_FILE
                if ($expected -and $expected.Count -gt 0) {
                    Write-Host "Servicos esperados no docker-compose.yml:" -ForegroundColor Cyan
                    foreach ($s in $expected) { Write-Host " - $s" }
                    Write-Host "Verifique se os nomes sao os mesmos ou se o compose esta no caminho correto." -ForegroundColor Yellow
                } else {
                    Write-Host "Nao foi possivel extrair nomes de servico do arquivo docker-compose.yml." -ForegroundColor Yellow
                    Write-Host "Certifique-se de que o arquivo exista em: $COMPOSE_FILE" -ForegroundColor Yellow
                }
            }
            Pause
        }

        "2" {
            UpdateAndRestart
            Pause
        }

        "3" {
            $creds = Ask-Credentials
            if (Docker-Login $creds) {
                Write-Host "`nLogin realizado com sucesso!"
            } else {
                Write-Host "`nFalha no login."
            }
            Pause
        }

        "4" {
            Manage-Env
            Pause
        }

        "5" {
            Write-Host "`nSaindo..."
            $running = $false
            break
        }


        Default {
            Write-Host "`nOpcao invalida."
            Pause
        }
    }
}
