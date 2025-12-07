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
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "  Autenticacao GitHub Container Registry" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan
    
    Write-Host "Para acessar imagens privadas no GHCR, voce precisa:" -ForegroundColor Yellow
    Write-Host "  1. Usuario: Seu username do GitHub (nao o email)" -ForegroundColor Gray
    Write-Host "  2. Token: Personal Access Token (PAT) com permissao 'read:packages'" -ForegroundColor Gray
    Write-Host "`nGerar token em: https://github.com/settings/tokens/new`n" -ForegroundColor Gray

    $user = Read-Host "Usuario"
    
    # Validacao basica do usuario
    if ([string]::IsNullOrWhiteSpace($user)) {
        Write-Host "Aviso: Usuario vazio. Isso provavelmente causara falha de autenticacao." -ForegroundColor Yellow
    }
    
    $tok = Read-Host "Token"
    
    # Validacao basica do token
    if ([string]::IsNullOrWhiteSpace($tok)) {
        Write-Host "Aviso: Token vazio. Isso provavelmente causara falha de autenticacao." -ForegroundColor Yellow
    } elseif ($tok.Length -lt 20) {
        Write-Host "Aviso: Token muito curto. Tokens GitHub PAT tem geralmente 40+ caracteres." -ForegroundColor Yellow
    }

    # Salvamento em disco comentado: nao gravamos credenciais em arquivo por padrao.
    # "usuario=$user" | Out-File $CRED_FILE -Encoding utf8
    # "token=$tok"    | Out-File $CRED_FILE -Encoding utf8 -Append
    # Write-Host "`nCredenciais salvas.`n"

    Write-Host "`nCredenciais recebidas (nao serao salvas em disco).`n"

    return @{ usuario = $user; token = $tok }
}

function Ensure-Credentials {
    # Sempre solicitar usuario + token do GHCR, mesmo que exista arquivo salvo.
    if (Test-Path $CRED_FILE) { Remove-Item $CRED_FILE -ErrorAction SilentlyContinue }
    return Ask-Credentials
}

function Test-GitHubToken ($creds) {
    <#
    .SYNOPSIS
        Testa se o token GitHub e valido e tem as permissoes necessarias.
    #>
    Write-Host "`nTestando token GitHub via API..." -ForegroundColor Cyan
    
    try {
        $headers = @{
            'Authorization' = "Bearer $($creds.token)"
            'Accept' = 'application/vnd.github.v3+json'
        }
        
        $response = Invoke-WebRequest -Uri 'https://api.github.com/user' -Headers $headers -ErrorAction Stop
        
        if ($response.StatusCode -eq 200) {
            $userData = $response.Content | ConvertFrom-Json
            Write-Host "  Token valido! Usuario autenticado: $($userData.login)" -ForegroundColor Green
            
            # Verificar scopes no header
            $scopes = $response.Headers['X-OAuth-Scopes']
            if ($scopes) {
                Write-Host "  Permissoes do token: $scopes" -ForegroundColor Gray
                
                if ($scopes -notmatch 'read:packages') {
                    Write-Host "  AVISO: Token nao tem permissao 'read:packages'!" -ForegroundColor Red
                    Write-Host "  Isso impedira o acesso ao GHCR." -ForegroundColor Red
                    return $false
                } else {
                    Write-Host "  Permissao 'read:packages' confirmada." -ForegroundColor Green
                }
            }
            
            return $true
        }
    } catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        Write-Host "  Falha no teste: HTTP $statusCode" -ForegroundColor Red
        
        if ($statusCode -eq 401) {
            Write-Host "  Token invalido ou expirado." -ForegroundColor Red
        } elseif ($statusCode -eq 403) {
            Write-Host "  Token sem permissoes necessarias." -ForegroundColor Red
        }
        
        return $false
    }
}

function Docker-Login ($creds) {
    Write-Host "`nTentando acessar ao servico SISCAN RPA (ghcr.io)..." -ForegroundColor Cyan

    # Validar se credenciais foram fornecidas
    if (-not $creds -or -not $creds.usuario -or -not $creds.token) {
        Write-Host "Erro: Credenciais invalidas ou vazias." -ForegroundColor Red
        return $false
    }

    # Validar formato do token (PAT do GitHub deve começar com ghp_, gho_, ou ghs_)
    if ($creds.token -notmatch '^gh[pso]_[a-zA-Z0-9]+$') {
        Write-Host "Aviso: O token nao parece ser um Personal Access Token (PAT) valido do GitHub." -ForegroundColor Yellow
        Write-Host "  Tokens validos comecam com: ghp_ (classic), gho_ (OAuth), ou ghs_ (server)" -ForegroundColor Yellow
        Write-Host "  Verifique: https://github.com/settings/tokens" -ForegroundColor Gray
    }
    
    # Testar token via API primeiro (opcional, mas recomendado)
    $tokenValid = Test-GitHubToken $creds
    if (-not $tokenValid) {
        Write-Host "`nToken falhou no teste de API. Tentando login no GHCR mesmo assim..." -ForegroundColor Yellow
    }

    # Capturar saida completa do docker login para diagnostico
    $loginOutput = $creds.token | docker login ghcr.io -u $creds.usuario --password-stdin 2>&1
    $loginExitCode = $LASTEXITCODE

    if ($loginExitCode -ne 0) {
        Write-Host "Erro: Falha na autenticacao com o GitHub Container Registry." -ForegroundColor Red
        Write-Host "`nDetalhes do erro:" -ForegroundColor Yellow
        Write-Host ($loginOutput | Out-String) -ForegroundColor Gray
        
        Write-Host "`nPossiveis causas:" -ForegroundColor Cyan
        Write-Host "  1. Token expirado ou invalido" -ForegroundColor Gray
        Write-Host "  2. Token sem permissao 'read:packages' para o repositorio" -ForegroundColor Gray
        Write-Host "  3. Usuario incorreto (deve ser o username do GitHub, nao email)" -ForegroundColor Gray
        Write-Host "  4. Repositorio privado e token sem acesso a organizacao" -ForegroundColor Gray
        
        Write-Host "`n========================================" -ForegroundColor Cyan
        Write-Host "  Comandos de Diagnostico" -ForegroundColor Cyan
        Write-Host "========================================" -ForegroundColor Cyan
        
        Write-Host "`n1. Verificar se usuario existe no GitHub:" -ForegroundColor Yellow
        Write-Host "   https://github.com/$($creds.usuario)" -ForegroundColor Gray
        
        Write-Host "`n2. Testar autenticacao via API do GitHub:" -ForegroundColor Yellow
        Write-Host "   curl -H `"Authorization: Bearer SEU_TOKEN`" https://api.github.com/user" -ForegroundColor Gray
        Write-Host "   (deve retornar JSON com seus dados, nao 401/403)" -ForegroundColor DarkGray
        
        Write-Host "`n3. Verificar permissoes do token:" -ForegroundColor Yellow
        Write-Host "   curl -I -H `"Authorization: Bearer SEU_TOKEN`" https://api.github.com/user" -ForegroundColor Gray
        Write-Host "   (verifique header 'X-OAuth-Scopes' para confirmar 'read:packages')" -ForegroundColor DarkGray
        
        Write-Host "`n4. Testar acesso ao repositorio da organizacao:" -ForegroundColor Yellow
        Write-Host "   https://github.com/Prisma-Consultoria/siscan-rpa-rpa" -ForegroundColor Gray
        Write-Host "   (se retornar 404, voce nao tem acesso)" -ForegroundColor DarkGray
        
        Write-Host "`n========================================" -ForegroundColor Cyan
        Write-Host "  Solucoes Recomendadas" -ForegroundColor Cyan
        Write-Host "========================================" -ForegroundColor Cyan
        
        Write-Host "`nOpcao A - Gerar novo token:" -ForegroundColor Yellow
        Write-Host "  1. Acesse: https://github.com/settings/tokens/new" -ForegroundColor Gray
        Write-Host "  2. Nome: 'SISCAN RPA - Read Packages'" -ForegroundColor Gray
        Write-Host "  3. Expiration: 90 days" -ForegroundColor Gray
        Write-Host "  4. Selecione scopes:" -ForegroundColor Gray
        Write-Host "     [X] read:packages" -ForegroundColor Green
        Write-Host "     [X] repo (se repositorio privado organizacional)" -ForegroundColor Green
        Write-Host "  5. Generate token e COPIE IMEDIATAMENTE" -ForegroundColor Gray
        
        Write-Host "`nOpcao B - Solicitar acesso a organizacao:" -ForegroundColor Yellow
        Write-Host "  Entre em contato com admin da organizacao Prisma-Consultoria" -ForegroundColor Gray
        Write-Host "  e solicite acesso ao repositorio 'siscan-rpa-rpa'" -ForegroundColor Gray
        
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

function Update-AssistantScript {
    <#
    .SYNOPSIS
        Atualiza o proprio script assistente (siscan-assistente.ps1) com rollback automatico.
    .DESCRIPTION
        Faz backup do script atual, baixa a versao mais recente do repositorio GitHub,
        valida o novo script e oferece rollback em caso de falha.
    #>
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "  Atualizacao do Assistente SISCAN RPA" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan

    $scriptPath = $PSCommandPath
    if (-not $scriptPath) {
        $scriptPath = Join-Path $PSScriptRoot "siscan-assistente.ps1"
    }

    if (-not (Test-Path $scriptPath)) {
        Write-Host "Erro: Nao foi possivel localizar o script atual." -ForegroundColor Red
        return $false
    }

    $backupPath = "${scriptPath}.backup.$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    $tempPath = "${scriptPath}.temp"
    $repoOwner = "Prisma-Consultoria"
    $repoName = "assistente-siscan-rpa"
    $branch = "main"
    $scriptFileName = "siscan-assistente.ps1"
    $downloadUrl = "https://raw.githubusercontent.com/${repoOwner}/${repoName}/${branch}/${scriptFileName}"

    Write-Host "Script atual: $scriptPath" -ForegroundColor Gray
    Write-Host "Backup sera salvo em: $backupPath" -ForegroundColor Gray
    Write-Host "URL de download: $downloadUrl`n" -ForegroundColor Gray

    # Criar backup
    Write-Host "[1/5] Criando backup do script atual..." -ForegroundColor Cyan
    try {
        Copy-Item -Path $scriptPath -Destination $backupPath -Force -ErrorAction Stop
        Write-Host "✓ Backup criado com sucesso." -ForegroundColor Green
    } catch {
        Write-Host "✗ Erro ao criar backup: $_" -ForegroundColor Red
        return $false
    }

    # Baixar nova versao
    Write-Host "`n[2/5] Baixando nova versao do GitHub..." -ForegroundColor Cyan
    try {
        # Tenta usar Invoke-WebRequest (pwsh/PS 5.1+)
        $ProgressPreference = 'SilentlyContinue'  # acelera download
        Invoke-WebRequest -Uri $downloadUrl -OutFile $tempPath -ErrorAction Stop
        $ProgressPreference = 'Continue'
        Write-Host "✓ Download concluido." -ForegroundColor Green
    } catch {
        Write-Host "✗ Erro ao baixar: $_" -ForegroundColor Red
        Write-Host "`nTentando metodo alternativo com curl..." -ForegroundColor Yellow
        
        # Fallback: tentar curl
        try {
            $curlOutput = curl -L -o $tempPath $downloadUrl 2>&1
            if ($LASTEXITCODE -eq 0 -and (Test-Path $tempPath)) {
                Write-Host "✓ Download via curl concluido." -ForegroundColor Green
            } else {
                throw "curl falhou ou arquivo nao foi criado."
            }
        } catch {
            Write-Host "✗ Metodo alternativo falhou: $_" -ForegroundColor Red
            Write-Host "`nRestaurando backup..." -ForegroundColor Yellow
            if (Test-Path $backupPath) {
                Copy-Item -Path $backupPath -Destination $scriptPath -Force
                Write-Host "✓ Script original restaurado." -ForegroundColor Green
            }
            return $false
        }
    }

    # Validar arquivo baixado
    Write-Host "`n[3/5] Validando arquivo baixado..." -ForegroundColor Cyan
    if (-not (Test-Path $tempPath)) {
        Write-Host "✗ Arquivo temporario nao encontrado apos download." -ForegroundColor Red
        Write-Host "Restaurando backup..." -ForegroundColor Yellow
        Copy-Item -Path $backupPath -Destination $scriptPath -Force
        return $false
    }

    $tempSize = (Get-Item $tempPath).Length
    if ($tempSize -lt 1000) {
        Write-Host "✗ Arquivo baixado muito pequeno ($tempSize bytes). Possivel erro." -ForegroundColor Red
        Write-Host "Restaurando backup..." -ForegroundColor Yellow
        Copy-Item -Path $backupPath -Destination $scriptPath -Force
        Remove-Item $tempPath -Force -ErrorAction SilentlyContinue
        return $false
    }

    # Verificar se contem marcadores basicos do script PowerShell
    $tempContent = Get-Content $tempPath -Raw -ErrorAction SilentlyContinue
    if (-not $tempContent -or $tempContent -notmatch '#!/usr/bin/env pwsh' -or $tempContent -notmatch 'function') {
        Write-Host "✗ Arquivo baixado nao parece ser um script PowerShell valido." -ForegroundColor Red
        Write-Host "Restaurando backup..." -ForegroundColor Yellow
        Copy-Item -Path $backupPath -Destination $scriptPath -Force
        Remove-Item $tempPath -Force -ErrorAction SilentlyContinue
        return $false
    }

    Write-Host "✓ Validacao basica OK ($tempSize bytes)." -ForegroundColor Green

    # Substituir script atual pelo novo
    Write-Host "`n[4/5] Aplicando atualizacao..." -ForegroundColor Cyan
    try {
        Copy-Item -Path $tempPath -Destination $scriptPath -Force -ErrorAction Stop
        Remove-Item $tempPath -Force -ErrorAction SilentlyContinue
        Write-Host "✓ Script atualizado com sucesso." -ForegroundColor Green
    } catch {
        Write-Host "✗ Erro ao aplicar atualizacao: $_" -ForegroundColor Red
        Write-Host "Restaurando backup..." -ForegroundColor Yellow
        Copy-Item -Path $backupPath -Destination $scriptPath -Force
        Remove-Item $tempPath -Force -ErrorAction SilentlyContinue
        return $false
    }

    # Teste de sintaxe (opcional, melhor esforco)
    Write-Host "`n[5/5] Verificando sintaxe do novo script..." -ForegroundColor Cyan
    try {
        $null = [System.Management.Automation.PSParser]::Tokenize((Get-Content $scriptPath -Raw), [ref]$null)
        Write-Host "✓ Sintaxe OK." -ForegroundColor Green
    } catch {
        Write-Host "! Aviso: Nao foi possivel validar sintaxe: $_" -ForegroundColor Yellow
        Write-Host "  O script foi atualizado, mas pode conter erros." -ForegroundColor Yellow
        Write-Host "`nDeseja restaurar o backup? (S/N)" -ForegroundColor Yellow
        $resp = Read-Host
        if ($resp -match '^[Ss]') {
            Copy-Item -Path $backupPath -Destination $scriptPath -Force
            Write-Host "✓ Backup restaurado." -ForegroundColor Green
            return $false
        }
    }

    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "  Atualizacao concluida com sucesso!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "`nBackup mantido em: $backupPath" -ForegroundColor Gray
    Write-Host "Para usar a nova versao, reinicie o assistente." -ForegroundColor Cyan
    Write-Host "`nPressione qualquer tecla para sair e reiniciar o assistente..." -ForegroundColor Yellow
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    
    return $true
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
        Write-Host " 4) Atualizar o Assistente"
        Write-Host "    - Baixa a versao mais recente do assistente com rollback automatico"
        Write-Host " 5) Sair"
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
    $op = Read-Host "Escolha uma opção (1-5)"

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
            $updated = Update-AssistantScript
            if ($updated) {
                # Usuario foi instruido a reiniciar; saimos do loop
                $running = $false
                break
            } else {
                # Falha ou cancelamento; volta ao menu
                Pause
            }
        }

        "5" {
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
