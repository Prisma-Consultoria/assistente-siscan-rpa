# -------------------------------------------
#   ASSISTENTE SISCAN RPA - MENU PRINCIPAL
# -------------------------------------------

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

    "usuario=$user" | Out-File $CRED_FILE -Encoding utf8
    "token=$tok"    | Out-File $CRED_FILE -Encoding utf8 -Append

    Write-Host "`nCredenciais salvas.`n"

    return @{ usuario = $user; token = $tok }
}

function Ensure-Credentials {
    if (Test-Path $CRED_FILE) {
        $opt = Read-Host "Credenciais ja existem. Usar mesmo arquivo? (s/n)"
        if ($opt.Trim().ToLower() -eq "s") {
            return Get-CredentialsFile
        } else {
            Remove-Item $CRED_FILE -ErrorAction SilentlyContinue
            return Ask-Credentials
        }
    } else {
        return Ask-Credentials
    }
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

    # Primeiro puxa a nova imagem
    Write-Host "`nBaixando nova imagem..." -ForegroundColor Cyan
    docker compose pull

    if ($LASTEXITCODE -ne 0) {
        Write-Host "Erro ao baixar nova imagem!" -ForegroundColor Red
        return
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

    $lines = @()
    try { $lines = Get-Content $Path -ErrorAction Stop } catch { $lines = @() }

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

    # Se arquivo estava vazio, perguntar se deseja adicionar chaves a partir de um template não é obrigatório aqui
    Set-Content -Path $Path -Value $updated -Encoding UTF8
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
