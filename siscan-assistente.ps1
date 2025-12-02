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

# Textos de ajuda para variaveis do .env (usado por Update-EnvFile)
# Carrega textos de ajuda de .env.help.json se presente, caso contrario usa valores embutidos simples
$ENV_HELP_TEXTS = @{
    'SISCAN_USER' = 'Usuário do SISCAN (ex.: nome de usuário fornecido pelo suporte)'
    'SISCAN_PASSWORD' = 'Senha do SISCAN (mantenha confidencial)'
    'HOST_MEDIA_ROOT' = 'Pasta local onde o Assistente salva imagens e relatórios (ex: C:\\siscan\\media ou /var/siscan/media)'
}

$helpPath = Join-Path $PSScriptRoot '.env.help.json'
if (Test-Path $helpPath) {
    try {
        $helpJson = Get-Content -Path $helpPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($helpJson -and $helpJson.keys) {
            $ENV_HELP_TEXTS = @{}
            $ENV_HELP_ENTRIES = @{}
            foreach ($prop in $helpJson.keys.psobject.properties) {
                $k = $prop.Name
                $entry = $helpJson.keys.$k
                if ($entry) {
                    if ($entry.help) { $ENV_HELP_TEXTS[$k] = $entry.help }
                    $ENV_HELP_ENTRIES[$k] = $entry
                }
            }
        }
    } catch {
        # se falhar ao ler o arquivo, mantemos os textos embutidos
    }
}

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
    Write-Host "`nPor favor, informe seu usuario e token (necessario para instalar/atualizar):`n"

    $user = Read-Host "Usuario"
    $tok  = Read-Host "Token"

    # Salvamento em disco comentado: nao gravamos credenciais em arquivo por padrao.
    # "usuario=$user" | Out-File $CRED_FILE -Encoding utf8
    # "token=$tok"    | Out-File $CRED_FILE -Encoding utf8 -Append
    # Write-Host "`nCredenciais salvas.`n"

    Write-Host "`nCredenciais recebidas (não serão salvas em disco).`n"

    return @{ usuario = $user; token = $tok }
}

function Ensure-Credentials {
    # Sempre solicitar usuario + token do GHCR, mesmo que exista arquivo salvo.
    if (Test-Path $CRED_FILE) { Remove-Item $CRED_FILE -ErrorAction SilentlyContinue }
    return Ask-Credentials
}

function Docker-Login ($creds) {
    Write-Host "`nTentando acessar ao servico SISCAN RPA..."

    $null = $creds.token | docker login ghcr.io -u $creds.usuario --password-stdin

    if ($LASTEXITCODE -ne 0) {
        Write-Host "Erro: nao foi possivel acessar com essas credenciais." -ForegroundColor Red
        return $false
    }

    Write-Host "Acesso realizado com sucesso." -ForegroundColor Green
    return $true
}

function UpdateAndRestart {
    param([hashtable]$creds)

    Write-Host "`nAtualizando o SISCAN RPA e reiniciando (pode demorar)..." -ForegroundColor Yellow

    if (-not (Test-Path "./docker-compose.yml")) {
        Write-Host "Arquivo de configuração 'docker-compose.yml' não encontrado." -ForegroundColor Red
        return
    }

    # Se credenciais foram passadas, usa-as; caso contrário, solicita ao usuário.
    if (-not $creds) {
        Write-Host "`nSolicitando suas credenciais ..." -ForegroundColor Cyan
        $creds = Ask-Credentials
        if (-not (Docker-Login $creds)) {
            Write-Host "Aviso: nao foi possivel fazer login; tentarei baixar a atualização mesmo assim (pode falhar)." -ForegroundColor Yellow
        }
    }

    # Tentar pull direto da imagem especifica (mais robusto para GHCR)
    Write-Host "`nBaixando a versao mais recente..." -ForegroundColor Cyan
    $pullOutput = docker pull $IMAGE_PATH 2>&1
    $pullCode = $LASTEXITCODE

    if ($pullCode -ne 0) {
        Write-Host "Nao foi possivel baixar diretamente. Verificando Docker e credenciais..." -ForegroundColor Yellow

        # Captura info do Docker para diagnostico
        $dockerInfo = docker info 2>&1
        $dockerInfoStr = $dockerInfo -join "`n"

        # Tenta detectar se ha usuario autenticado (docker info normalmente exibe 'Username:')
        $isAuthenticated = $dockerInfoStr -match 'Username\s*:'
        if ($isAuthenticated) {
            Write-Host "Parece que ja esta autenticado no Docker." -ForegroundColor Cyan
        } else {
            Write-Host "Nao ha autenticacao ativa no Docker." -ForegroundColor Yellow
        }

        # Se existir arquivo de credenciais, tentar login com ele primeiro
        $savedCreds = Get-CredentialsFile
        $triedLogin = $false
        if ($savedCreds -and $savedCreds.usuario -and $savedCreds.token) {
            Write-Host "Credenciais salvas encontradas; testando acesso com elas..." -ForegroundColor Cyan
            $triedLogin = $true
            if (Docker-Login $savedCreds) {
                Write-Host "Acesso com credenciais salvas OK. Tentando baixar novamente..." -ForegroundColor Cyan
                $pullOutput = docker pull $IMAGE_PATH 2>&1
                if ($LASTEXITCODE -eq 0) { Write-Host "Download concluído com sucesso." -ForegroundColor Green } else { $pullCode = $LASTEXITCODE }
            } else {
                Write-Host "Acesso com credenciais salvas falhou." -ForegroundColor Yellow
            }
        }

        # Se ainda nao obteve sucesso, solicitar novamente credenciais ao usuario e tentar login/pull
        if ($pullCode -ne 0) {
            Write-Host "Por favor, informe usuário e token novamente..." -ForegroundColor Cyan
            $newCreds = Ask-Credentials
            if (Docker-Login $newCreds) {
                Write-Host "Acesso com novas credenciais OK. Tentando baixar novamente..." -ForegroundColor Cyan
                $pullOutput = docker pull $IMAGE_PATH 2>&1
                $pullCode = $LASTEXITCODE
            } else {
                Write-Host "Acesso com novas credenciais falhou." -ForegroundColor Yellow
            }
        }

        # Se ainda falhar, tentar fallback para 'docker compose pull' uma ultima vez
        if ($pullCode -ne 0) {
            Write-Host "Ainda nao foi possivel baixar. Tentando 'docker compose pull' como ultimo recurso..." -ForegroundColor Yellow
            $composeOutput = docker compose pull 2>&1
            $composeCode = $LASTEXITCODE
            if ($composeCode -ne 0) {
                Write-Host "Erro ao baixar a atualizacao via compose." -ForegroundColor Red
                Write-Host "`n--- Detalhes do erro ---`n" -ForegroundColor Red
                Write-Host "Saida do 'docker pull':" -ForegroundColor Red
                Write-Host ($pullOutput -join "`n")
                Write-Host "`nSaida do 'docker compose pull':" -ForegroundColor Red
                Write-Host ($composeOutput -join "`n")
                Write-Host "`nInformacoes do Docker (diagnostico):" -ForegroundColor Red
                Write-Host $dockerInfoStr
                Write-Host "`nAAcoes recomendadas:" -ForegroundColor Yellow
                Write-Host "- Verifique sua conexao de rede e resolucao DNS para 'ghcr.io'." -ForegroundColor Yellow
                Write-Host "- Confirme que o token usado tem permissao de leitura de pacotes no GitHub." -ForegroundColor Yellow
                Write-Host "- Execute 'docker logout ghcr.io' e tente login manualmente se precisar." -ForegroundColor Yellow
                Write-Host "- Se estiver atrás de proxy/firewall, confirme regras para https (porta 443)." -ForegroundColor Yellow
                return
            } else {
                Write-Host "Atualização via compose concluída com sucesso." -ForegroundColor Green
            }
        }
    }

    # Depois reinicia tudo
    Write-Host "`nRecriando o SISCAN RPA..." -ForegroundColor Cyan
    docker compose down
    docker compose up -d

    if ($LASTEXITCODE -eq 0) {
        Write-Host "`nSISCAN RPA atualizado e iniciado com sucesso!" -ForegroundColor Green
    }
    else {
        Write-Host "`nErro ao reiniciar o SISCAN RPA." -ForegroundColor Red
    }
}

function Restart-Service {
    if (!(Test-Path $COMPOSE_FILE)) {
        Write-Host "`nArquivo de configuração 'docker-compose.yml' não foi encontrado." 
        return
    }

    Write-Host "`nReiniciando o SISCAN RPA..."
    docker compose down
    docker compose up -d

    if ($LASTEXITCODE -eq 0) {
        Write-Host "SISCAN RPA reiniciado com sucesso." -ForegroundColor Green
    } else {
        Write-Host "Erro ao reiniciar o SISCAN RPA." -ForegroundColor Red
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
            # Determine se ha entradas de help mais completas
            $entry = $null
            if ($null -ne $ENV_HELP_ENTRIES -and $ENV_HELP_ENTRIES.ContainsKey($key)) { $entry = $ENV_HELP_ENTRIES[$key] }

            # Decide se a variavel e secreta (fallback por nome se info nao existir)
            $isSecret = $false
            if ($entry -and $entry.secret) { $isSecret = $entry.secret }
            elseif ($key -match 'PASSWORD|TOKEN|SECRET|KEY') { $isSecret = $true }

            Write-Host "`nVariavel: $key" -ForegroundColor Cyan
            if ($isSecret) {
                if ($valDisplay -ne "") { Write-Host "Valor atual: (oculto)" -ForegroundColor DarkGray } else { Write-Host "Valor atual: (vazio)" -ForegroundColor DarkGray }
            } else {
                Write-Host "Valor atual: $valDisplay" -ForegroundColor DarkGray
            }

            # Mostrar exemplo e required quando disponivel
            if ($entry -and $entry.example -and $entry.example -ne "") { Write-Host "Exemplo: $($entry.example)" -ForegroundColor DarkGray }
            if ($entry -and $entry.required) { Write-Host "Obrigatório" -ForegroundColor Yellow }

            # Mostrar texto de ajuda se existir
            if ($ENV_HELP_TEXTS.ContainsKey($key)) {
                $help = $ENV_HELP_TEXTS[$key]
                Write-Host "Ajuda: $help" -ForegroundColor DarkCyan
            }

            # Helper para converter SecureString para texto simples
            function Convert-SecureToPlain([System.Security.SecureString]$s) {
                if (-not $s) { return "" }
                $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
                try { return [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) } finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
            }

            if ($isSecret) {
                $secure = Read-Host "Novo valor (Enter para manter)" -AsSecureString
                $newPlain = Convert-SecureToPlain $secure
                if ($newPlain -ne "") {
                    $updated += "$key=$newPlain"
                } else {
                    $updated += $line
                }
            } else {
                $new = Read-Host "Novo valor (Enter para manter)"
                if ($new -ne "") {
                    $updated += "$key=$new"
                } else {
                    $updated += $line
                }
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
    $templateFiles = @('.env.sample', '.env.example', '.env.template', '.env.dist')

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
    Clear-Host

    Write-Host "========================================"
    Write-Host "   Assistente SISCASAN RPA - Fácil e seguro"
    Write-Host "========================================"
    Write-Host ""
        Write-Host " 1) Reiniciar o SISCAN RPA"
        Write-Host "    - Fecha e inicia o serviço (útil para problemas simples)"
        Write-Host " 2) Atualizar / Instalar o SISCAN RPA"
        Write-Host "    - Baixa a versao mais recente do servico SISCAN RPA"
        Write-Host " 3) Editar configurações básicas"
        Write-Host "    - Ajuste caminhos e opções essenciais (.env)"
        Write-Host " 4) Sair"
    Write-Host ""
    Write-Host "----------------------------------------"
}

# -------------------------
# MENU PRINCIPAL
# -------------------------

$creds = $null

$running = $true

while ($running) {
    Show-Menu
    $op = Read-Host "Escolha uma opção (1-4)"

    switch ($op) {
        "1" {
            if (Check-Service) {
                Restart-Service
            } else {
                Write-Host "Nenhum serviço do SISCAN RPA em execucao encontrado." -ForegroundColor Yellow
                $expected = Get-ExpectedServiceNames -ComposePath $COMPOSE_FILE
                if ($expected -and $expected.Count -gt 0) {
                    Write-Host "Servicos esperados no arquivo de configuracao:" -ForegroundColor Cyan
                    foreach ($s in $expected) { Write-Host " - $s" }
                    Write-Host "Verifique se o arquivo 'docker-compose.yml' esta no diretorio correto." -ForegroundColor Yellow
                } else {
                    Write-Host "Nao foi possivel identificar servicos no arquivo de configuracao." -ForegroundColor Yellow
                    Write-Host "Verifique a presenca do arquivo: $COMPOSE_FILE" -ForegroundColor Yellow
                }
            }
            Pause
        }

        "2" {
            # Combina: pedir credenciais e atualizar/reiniciar
            $creds = Ask-Credentials
            if (Docker-Login $creds) {
                UpdateAndRestart -creds $creds
            } else {
                Write-Host "Aviso: nao foi possivel autenticar. Tentarei atualizar mesmo assim..." -ForegroundColor Yellow
                UpdateAndRestart -creds $creds
            }
            Pause
        }

        "3" {
            Manage-Env
            Pause
        }

        "4" {
            Write-Host "`nSaindo..."
            $running = $false
            break
        }

        Default {
            Write-Host "`nOpcao invalida." -ForegroundColor Yellow
            Pause
        }
    }
}
