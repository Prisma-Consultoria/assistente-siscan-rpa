#!/usr/bin/env pwsh
# -------------------------------------------
# CLI do Assistente SIScan
# -------------------------------------------
# Arquivo: siscan-assistente.ps1
# Propósito: Auxiliar no deploy, atualização e gerenciamento do ambiente do SIScan RPA.
#
# Uso:
#   pwsh ./siscan-assistente.ps1            # PowerShell Core (recomendado)
#   powershell.exe .\siscan-assistente.ps1  # Windows PowerShell 5.1 (legado)
#
# Comandos rápidos (menu interativo):
#   1) Reiniciar servico existente
#   2) Atualizar imagem e reiniciar servico
#   3) Login / alterar credenciais
#   4) Gerenciar .env (criar/atualizar)
#   5) Sair
#
# Pré-requisitos:
#   - PowerShell 7+ recommended (pwsh). If using Windows PowerShell 5.1, ensure the file is saved as UTF-8 with BOM.
#   - Docker and docker-compose installed and available in PATH.
#
# Codificação:
#   - Script should be stored as UTF-8. For Windows PowerShell 5.1 compatibility prefer UTF-8 with BOM.
#
# Mantenedores:
#   - Prisma-Consultoria / Team: Infra / DevOps
#
# Registro de alterações:
#   2025-11-30  v0.1  Adicionado gerenciamento de .env, tratamento de codificação e refatoração.
#
# Observações:
#   - O script é propositalmente conservador para suportar PowerShell 5.1 e pwsh.
#   - Para uso em automação ou não interativo, considere extrair as funções para um módulo.
# -------------------------------------------

# Ajustes robustos de encoding/terminal para múltiplos hosts
# - tenta forçar saída UTF-8 para o console
# - em Windows tenta ajustar code page via cmd.exe
# - define defaults para cmdlets de escrita dependendo da versão do PowerShell
try {
    $psMajor = 0
    if ($PSVersionTable -and $PSVersionTable.PSVersion) { $psMajor = $PSVersionTable.PSVersion.Major }

    # Força saída UTF-8 para PowerShell/Core quando possível
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
    try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

    # Em Windows, tente ajustar code page via cmd.exe (menos intrusivo que chcp direto em alguns hosts)
    if ($IsWindows -or ($env:OS -and $env:OS -match 'Windows')) {
        try { cmd.exe /c chcp 65001 > $null } catch {}
    }

    # Definir parâmetros padrão de encoding para cmdlets que gravam arquivos.
    # PowerShell Core (>=6) entende 'utf8'; Windows PowerShell (5.1) é mais seguro usar 'Unicode' (UTF-16 LE)
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

    # Salvamento em disco comentado: não gravamos mais credenciais em arquivo por padrão.
    # "usuario=$user" | Out-File $CRED_FILE -Encoding utf8
    # "token=$tok"    | Out-File $CRED_FILE -Encoding utf8 -Append
    # Write-Host "`nCredenciais salvas.`n"

    Write-Host "`nCredenciais obtidas (não salvas em disco).`n"

    return @{ usuario = $user; token = $tok }
}

function Ensure-Credentials {
    # Sempre solicitar usuário + token do GHCR, mesmo que exista arquivo salvo.
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
    Write-Host "`nAtualizando imagem e reiniciando serviço..." -ForegroundColor Yellow

    if (-not (Test-Path "./docker-compose.yml")) {
        Write-Host "Arquivo docker-compose.yml não encontrado!" -ForegroundColor Red
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
    docker pull $IMAGE_PATH
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Pull direto falhou, tentando 'docker compose pull' como fallback..." -ForegroundColor Yellow
        docker compose pull
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Erro ao baixar nova imagem!" -ForegroundColor Red
            return
        }
    }

    # Depois reinicia tudo
    Write-Host "`nRecriando serviço..." -ForegroundColor Cyan
    docker compose down
    docker compose up -d

    if ($LASTEXITCODE -eq 0) {
        Write-Host "`nServiço atualizado e reiniciado com sucesso!" -ForegroundColor Green
    }
    else {
        Write-Host "`nErro ao reiniciar o serviço!" -ForegroundColor Red
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

    # Ler com a codificação adequada (Get-Content entende nomes básicos)
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

            Write-Host "`nVariável: $key = $valDisplay" -ForegroundColor Cyan
            $new = Read-Host "Novo valor (Enter para manter)"

            if ($new -ne "") {
                $updated += "$key=$new"
            } else {
                $updated += $line
            }
        } else {
            # mantém comentários e linhas vazias
            $updated += $line
        }
    }

    # Regrava usando a codificação original (preserva BOM quando houver) via .NET
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
            Write-Host ".env não encontrado. Copiado de: $found" -ForegroundColor Yellow
        } else {
            New-Item -Path $envFile -ItemType File -Force | Out-Null
            Write-Host ".env não encontrado. Criado arquivo vazio: $envFile" -ForegroundColor Yellow
        }
    } else {
        Write-Host ".env encontrado: $envFile" -ForegroundColor Yellow
    }

    Update-EnvFile -Path $envFile
}

# ----- Wrappers / Service adapters (mantêm compatibilidade e separam responsabilidades) -----
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

# Services container (injeção simples)
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
                Write-Host "Nenhum serviço encontrado."
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
            Write-Host "`nOpção inválida."
            Pause
        }
    }
}
