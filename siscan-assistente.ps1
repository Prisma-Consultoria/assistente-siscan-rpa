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
#   - Para uso em automacao ou não interativo, considere extrair as funções para um modulo.
# -------------------------------------------

# Ajustes robustos de encoding/terminal para multiplos hosts
# - tenta forcar saida UTF-8 para o console
# - em Windows tenta ajustar code page via cmd.exe
# - define defaults para cmdlets de escrita dependendo da versão do PowerShell
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

# Textos de ajuda para variáveis do .env (usado por Update-EnvFile)
# Carrega textos de ajuda de .env.help.json se presente, caso contrario usa valores embutidos simples
$ENV_HELP_TEXTS = @{
    'SISCAN_USER' = 'Usuário do SISCAN (ex.: nome de usuário fornecido pelo suporte)'
    'SISCAN_PASSWORD' = 'Senha do SISCAN (mantenha confidencial)'
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
            # Detecta nomes de serviços (identados com 2 espacos, mas não mais que 4)
            if ($line -match '^\s{2}([a-zA-Z0-9_-]+)\s*:') {
                $serviceName = $matches[1]
                # Ignora propriedades comuns que não sao serviços
                if ($serviceName -notmatch '^(version|volumes|networks|configs|secrets)$') {
                    $services += $serviceName
                }
            }
            # Para quando encontrar outra secao de nivel raiz
            if ($line -match '^[a-zA-Z]') { break }
        }
    }

    return $services
}

function Get-CredentialsFile {
    if (!(Test-Path $CRED_FILE)) { return $null }

    $creds = @{ usuário = $null; token = $null }

    Get-Content $CRED_FILE | ForEach-Object {
        $parts = $_ -split '='
        if ($parts[0] -eq "usuário") { $creds.usuário = $parts[1] }
        if ($parts[0] -eq "token")   { $creds.token   = $parts[1] }
    }

    return $creds
}

function Ask-Credentials {
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "  Autenticação GitHub Container Registry" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan
    
    Write-Host "Para acessar imagens privadas no GHCR, voce precisa:" -ForegroundColor Yellow
    Write-Host "  1. Usuário: Seu username do GitHub (não o email)" -ForegroundColor Gray
    Write-Host "  2. Token: Personal Access Token (PAT) com permissão 'read:packages'" -ForegroundColor Gray
    Write-Host "`nGerar token em: https://github.com/settings/tokens/new`n" -ForegroundColor Gray

    $user = Read-Host "Usuário"
    
    # Validação e limpeza do usuário
    if ([string]::IsNullOrWhiteSpace($user)) {
        Write-Host "Aviso: Usuário vazio. Isso provavelmente causará falha de autenticação." -ForegroundColor Yellow
    } else {
        # Remover espaços em branco no início e fim (comum em copy/paste)
        $user = $user.Trim()
        if ($user.Contains(" ")) {
            Write-Host "Aviso: Usuário contém espaços. Isso pode causar problemas." -ForegroundColor Yellow
        }
    }
    
    $tok = Read-Host "Token"
    
    # Validação e limpeza do token
    if ([string]::IsNullOrWhiteSpace($tok)) {
        Write-Host "Aviso: Token vazio. Isso provavelmente causará falha de autenticação." -ForegroundColor Yellow
    } else {
        # Remover espaços em branco no início e fim (comum em copy/paste)
        $tok = $tok.Trim()
        
        if ($tok.Length -lt 20) {
            Write-Host "Aviso: Token muito curto. Tokens GitHub PAT têm geralmente 40+ caracteres." -ForegroundColor Yellow
        }
        
        if ($tok.Contains(" ")) {
            Write-Host "Aviso: Token contém espaços. Removendo automaticamente..." -ForegroundColor Yellow
            $tok = $tok -replace '\s+', ''
            Write-Host "Token ajustado (sem espaços)." -ForegroundColor Green
        }
    }

    # Salvamento em disco comentário: não gravamos credenciais em arquivo por padrao.
    # "usuário=$user" | Out-File $CRED_FILE -Encoding utf8
    # "token=$tok"    | Out-File $CRED_FILE -Encoding utf8 -Append
    # Write-Host "`nCredenciais salvas.`n"

    Write-Host "`nCredenciais recebidas (não serão salvas em disco).`n"

    return @{ usuário = $user; token = $tok }
}

function Ensure-Credentials {
    # Sempre solicitar usuário + token do GHCR, mesmo que exista arquivo salvo.
    if (Test-Path $CRED_FILE) { Remove-Item $CRED_FILE -ErrorAction SilentlyContinue }
    return Ask-Credentials
}

function Test-GitHubToken ($creds) {
    <#
    .SYNOPSIS
        Testa se o token GitHub e valido (teste simplificado).
    #>
    Write-Host "`nValidando credenciais..." -ForegroundColor Cyan
    
    # Teste basico: apenas verifica se o token tem formato valido
    if ([string]::IsNullOrWhiteSpace($creds.usuario) -or [string]::IsNullOrWhiteSpace($creds.token)) {
        Write-Host "  Usuário ou token vazio." -ForegroundColor Red
        return $false
    }
    
    if ($creds.token.Length -lt 20) {
        Write-Host "  Token muito curto (deve ter 40+ caracteres)." -ForegroundColor Yellow
        return $false
    }
    
    Write-Host "  Formato das credenciais OK." -ForegroundColor Green
    return $true
}

function Docker-Login ($creds) {
    Write-Host "`nTentando acessar ao serviço SISCAN RPA (ghcr.io)..." -ForegroundColor Cyan

    # Validar se credenciais foram fornecidas
    if (-not $creds -or -not $creds.usuario -or -not $creds.token) {
        Write-Host "Erro: Credenciais inválidas ou vazias." -ForegroundColor Red
        return $false
    }

    # Verificar se Docker está funcionando ANTES de tentar login
    Write-Host "Verificando se Docker está acessível..." -ForegroundColor Gray
    try {
        $dockerCheck = docker info 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "`n============================================" -ForegroundColor Red
            Write-Host "  DOCKER NÃO ESTÁ FUNCIONANDO" -ForegroundColor Red
            Write-Host "============================================" -ForegroundColor Red
            Write-Host "`nO Docker não está respondendo corretamente." -ForegroundColor Yellow
            Write-Host "Saída do Docker:" -ForegroundColor Gray
            Write-Host ($dockerCheck | Out-String) -ForegroundColor DarkGray
            Write-Host "`nVerifique:" -ForegroundColor Cyan
            Write-Host "  1. Docker Desktop está iniciado e rodando?" -ForegroundColor White
            Write-Host "  2. Você pode executar 'docker ps' em outro terminal?" -ForegroundColor White
            Write-Host "  3. Há erros no Docker Desktop?" -ForegroundColor White
            Write-Host "`n============================================`n" -ForegroundColor Red
            return $false
        }
        Write-Host "Docker está acessível: OK" -ForegroundColor Green
    } catch {
        Write-Host "Erro ao verificar Docker: $_" -ForegroundColor Red
        return $false
    }

    # Validacao basica do token
    $tokenValid = Test-GitHubToken $creds
    if (-not $tokenValid) {
        Write-Host "`nDeseja continuar mesmo assim? (S/N)" -ForegroundColor Yellow
        $continuar = Read-Host
        if ($continuar -notmatch '^[Ss]') {
            Write-Host "Operação cancelada pelo usuário." -ForegroundColor Yellow
            return $false
        }
    }

    # ESTRATÉGIA 1: Usar echo (funciona melhor em alguns ambientes PowerShell)
    Write-Host "Tentando autenticação (método 1/3 - echo)..." -ForegroundColor Gray
    Write-Host "  Usuario: $($creds.usuario)" -ForegroundColor DarkGray
    Write-Host "  Token: $($creds.token.Substring(0, [Math]::Min(8, $creds.token.Length)))..." -ForegroundColor DarkGray
    try {
        $loginOutput = (echo $creds.token) | docker login ghcr.io -u $creds.usuario --password-stdin 2>&1
        $loginExitCode = $LASTEXITCODE
        
        if ($loginExitCode -eq 0) {
            Write-Host "Login realizado com sucesso! (método echo)" -ForegroundColor Green
            return $true
        } else {
            Write-Host "  Método 1 falhou (exit code: $loginExitCode)" -ForegroundColor DarkGray
        }
    } catch {
        Write-Host "  Método 1 com exceção: $($_.Exception.Message)" -ForegroundColor DarkGray
        $loginOutput = $_.Exception.Message
        $loginExitCode = 1
    }

    # ESTRATÉGIA 2: Usar Write-Output com pipeline
    Write-Host "Tentando autenticação (método 2/3 - Write-Output)..." -ForegroundColor Gray
    try {
        $loginOutput = Write-Output $creds.token | docker login ghcr.io -u $creds.usuario --password-stdin 2>&1
        $loginExitCode = $LASTEXITCODE
        
        if ($loginExitCode -eq 0) {
            Write-Host "Login realizado com sucesso! (método Write-Output)" -ForegroundColor Green
            return $true
        } else {
            Write-Host "  Método 2 falhou (exit code: $loginExitCode)" -ForegroundColor DarkGray
        }
    } catch {
        Write-Host "  Método 2 com exceção: $($_.Exception.Message)" -ForegroundColor DarkGray
        $loginOutput = $_.Exception.Message
        $loginExitCode = 1
    }

    # ESTRATÉGIA 3: Usar arquivo temporário (mais robusto para problemas de encoding/pipeline)
    Write-Host "Tentando autenticação (método 3/3 - arquivo temporário)..." -ForegroundColor Gray
    $tempTokenFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "docker_token_$(Get-Random).txt")
    try {
        # Escrever token em arquivo temporário sem BOM e sem newline extra
        $utf8NoBOM = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tempTokenFile, $creds.token, $utf8NoBOM)
        
        # Usar Get-Content com -Raw para ler sem adicionar newlines
        $loginOutput = Get-Content -Path $tempTokenFile -Raw | docker login ghcr.io -u $creds.usuario --password-stdin 2>&1
        $loginExitCode = $LASTEXITCODE
        
        if ($loginExitCode -eq 0) {
            Write-Host "Login realizado com sucesso! (método arquivo temporário)" -ForegroundColor Green
            return $true
        } else {
            Write-Host "  Método 3 falhou (exit code: $loginExitCode)" -ForegroundColor DarkGray
        }
    } catch {
        Write-Host "  Método 3 com exceção: $($_.Exception.Message)" -ForegroundColor DarkGray
        $loginOutput = $_.Exception.Message
        $loginExitCode = 1
    } finally {
        # Remover arquivo temporário
        if (Test-Path $tempTokenFile) {
            Remove-Item $tempTokenFile -Force -ErrorAction SilentlyContinue
        }
    }

    # Se todas as estratégias falharam, mostrar instruções detalhadas
    if ($loginExitCode -ne 0) {
        Write-Host "`n============================================" -ForegroundColor Red
        Write-Host "  FALHA NO LOGIN (Tentadas 3 estratégias)" -ForegroundColor Red
        Write-Host "============================================" -ForegroundColor Red
        Write-Host "`nDetalhes do último erro:" -ForegroundColor Yellow
        Write-Host ($loginOutput | Out-String) -ForegroundColor Gray
        
        Write-Host "`n========================================" -ForegroundColor Cyan
        Write-Host "  DIAGNOSTICO" -ForegroundColor Cyan
        Write-Host "========================================" -ForegroundColor Cyan
        
        # Verificar se o Docker está funcionando
        try {
            $dockerVersion = docker --version 2>&1
            Write-Host "Docker encontrado: $dockerVersion" -ForegroundColor Green
        } catch {
            Write-Host "PROBLEMA: Docker não está respondendo!" -ForegroundColor Red
            Write-Host "Verifique se o Docker Desktop está rodando." -ForegroundColor Yellow
        }
        
        # Verificar conectividade com ghcr.io
        Write-Host "`nTestando conectividade com ghcr.io..." -ForegroundColor Gray
        try {
            $pingResult = Test-NetConnection -ComputerName ghcr.io -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
            if ($pingResult) {
                Write-Host "Conectividade com ghcr.io: OK" -ForegroundColor Green
            } else {
                Write-Host "PROBLEMA: Não foi possível conectar a ghcr.io porta 443" -ForegroundColor Red
                Write-Host "Verifique firewall/proxy corporativo." -ForegroundColor Yellow
            }
        } catch {
            Write-Host "Não foi possível testar conectividade." -ForegroundColor Gray
        }
        
        Write-Host "`n========================================" -ForegroundColor Cyan
        Write-Host "  O QUE FAZER AGORA" -ForegroundColor Cyan
        Write-Host "========================================" -ForegroundColor Cyan
        
        Write-Host "`nOPCAO A - Fazer login manualmente (RECOMENDADO):" -ForegroundColor Green
        Write-Host "" 
        Write-Host "  PASSO 1: Abra um NOVO terminal PowerShell" -ForegroundColor White
        Write-Host "  ----------------------------------------" -ForegroundColor Gray
        Write-Host "  - Clique com botao direito no menu Iniciar" -ForegroundColor Gray
        Write-Host "  - Selecione 'Windows PowerShell' ou 'Terminal'" -ForegroundColor Gray
        Write-Host "" 
        Write-Host "  PASSO 2: Teste CADA comando abaixo (copie e cole um de cada vez):" -ForegroundColor White
        Write-Host "  ------------------------------------------------------------------" -ForegroundColor Gray
        Write-Host "" 
        Write-Host "  METODO 1 (echo):" -ForegroundColor Cyan
        Write-Host "  echo '$($creds.token)' | docker login ghcr.io -u $($creds.usuario) --password-stdin" -ForegroundColor Yellow
        Write-Host "" 
        Write-Host "  METODO 2 (Write-Output):" -ForegroundColor Cyan
        Write-Host "  Write-Output '$($creds.token)' | docker login ghcr.io -u $($creds.usuario) --password-stdin" -ForegroundColor Yellow
        Write-Host "" 
        Write-Host "  METODO 3 (senha na linha de comando - menos seguro):" -ForegroundColor Cyan
        Write-Host "  docker login ghcr.io -u $($creds.usuario) -p '$($creds.token)'" -ForegroundColor DarkYellow
        Write-Host "" 
        Write-Host "  IMPORTANTE: Teste um método de cada vez!" -ForegroundColor White
        Write-Host "              Pare quando um funcionar (mostrar 'Login Succeeded')" -ForegroundColor White
        Write-Host "" 
        Write-Host "  PASSO 3: Pressione Enter no novo terminal" -ForegroundColor White
        Write-Host "  ------------------------------------------" -ForegroundColor Gray
        Write-Host "" 
        Write-Host "  PASSO 4: Verifique a mensagem que apareceu:" -ForegroundColor White
        Write-Host "  -------------------------------------------" -ForegroundColor Gray
        Write-Host "" 
        Write-Host "  Se aparecer:" -ForegroundColor White
        Write-Host "    'Login Succeeded'" -ForegroundColor Green
        Write-Host "    -> SUCESSO! O login foi realizado corretamente!" -ForegroundColor Green
        Write-Host "" 
        Write-Host "  PASSO 5: Volte para ESTE terminal e responda abaixo:" -ForegroundColor White
        Write-Host "  ----------------------------------------------------" -ForegroundColor Gray
        Write-Host "  - Pressione S (SIM) se o login funcionou" -ForegroundColor Green
        Write-Host "  - Pressione N (NAO) se apareceu erro" -ForegroundColor Yellow
        
        Write-Host "`nOPCAO B - Entrar em contato com suporte técnico:" -ForegroundColor Yellow
        Write-Host "" 
        Write-Host "  Se o login manual tambem falhar, entre em contato com:" -ForegroundColor Gray
        Write-Host "" 
        Write-Host "  Consultor Tecnico - Prisma Consultoria" -ForegroundColor White
        Write-Host "" 
        Write-Host "  Informe a mensagem de erro exibida acima." -ForegroundColor Gray
        
        Write-Host "`n============================================" -ForegroundColor Cyan
        Write-Host "" 
        Write-Host "Voce conseguiu fazer o login manualmente?" -ForegroundColor White
        Write-Host "(S = Sim, apareceu 'Login Succeeded')" -ForegroundColor Green
        Write-Host "(N = Nao, apareceu erro ou preciso de ajuda)" -ForegroundColor Yellow
        $resposta = Read-Host "`nResposta (S/N)"
        
        if ($resposta -match '^[Ss]') {
            Write-Host "`nOtimo! O login foi realizado com sucesso." -ForegroundColor Green
            Write-Host "Continuando o processo de download..." -ForegroundColor Cyan
            return $true
        } else {
            Write-Host "`n============================================" -ForegroundColor Yellow
            Write-Host "  ENTRE EM CONTATO COM SUPORTE" -ForegroundColor Yellow
            Write-Host "============================================" -ForegroundColor Yellow
            Write-Host "" 
            Write-Host "Por favor, entre em contato com:" -ForegroundColor White
            Write-Host "Consultor Tecnico - Prisma Consultoria" -ForegroundColor Cyan
            Write-Host "" 
            Write-Host "Tenha em maos:" -ForegroundColor White
            Write-Host "- A mensagem de erro exibida acima" -ForegroundColor Gray
            Write-Host "- O usuário informado: $($creds.usuario)" -ForegroundColor Gray
            Write-Host "" 
            Write-Host "Operacao cancelada." -ForegroundColor Yellow
            return $false
        }
    }

    Write-Host "Login realizado com sucesso!" -ForegroundColor Green
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
            Write-Host "Aviso: não foi possível fazer login; tentarei baixar a atualização mesmo assim (pode falhar)." -ForegroundColor Yellow
        }
    }

    # Tentar pull direto da imagem especifica (mais robusto para GHCR)
    Write-Host "`nBaixando a versão mais recente..." -ForegroundColor Cyan
    $pullOutput = docker pull $IMAGE_PATH 2>&1
    $pullCode = $LASTEXITCODE

    if ($pullCode -ne 0) {
        Write-Host "Não foi possível baixar diretamente. Verificando Docker e credenciais..." -ForegroundColor Yellow

        # Captura info do Docker para diagnostico
        $dockerInfo = docker info 2>&1
        $dockerInfoStr = $dockerInfo -join "`n"

        # Tenta detectar se ha usuário autenticado (docker info normalmente exibe 'Username:')
        $isAuthenticated = $dockerInfoStr -match 'Username\s*:'
        if ($isAuthenticated) {
            Write-Host "Parece que ja esta autenticado no Docker." -ForegroundColor Cyan
        } else {
            Write-Host "Não há autenticação ativa no Docker." -ForegroundColor Yellow
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

        # Se ainda não obteve sucesso, solicitar novamente credenciais ao usuário e tentar login/pull
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
            Write-Host "Ainda não foi possível baixar. Tentando 'docker compose pull' como último recurso..." -ForegroundColor Yellow
            $composeOutput = docker compose pull 2>&1
            $composeCode = $LASTEXITCODE
            if ($composeCode -ne 0) {
                Write-Host "Erro ao baixar a atualização via compose." -ForegroundColor Red
                Write-Host "`n--- Detalhes do erro ---`n" -ForegroundColor Red
                Write-Host "Saida do 'docker pull':" -ForegroundColor Red
                Write-Host ($pullOutput -join "`n")
                Write-Host "`nSaida do 'docker compose pull':" -ForegroundColor Red
                Write-Host ($composeOutput -join "`n")
                Write-Host "`nInformacoes do Docker (diagnostico):" -ForegroundColor Red
                Write-Host $dockerInfoStr
                Write-Host "`nAAcoes recomendadas:" -ForegroundColor Yellow
                Write-Host "- Verifique sua conexão de rede e resolução DNS para 'ghcr.io'." -ForegroundColor Yellow
                Write-Host "- Confirme que o token usado tem permissão de leitura de pacotes no GitHub." -ForegroundColor Yellow
                Write-Host "- Execute 'docker logout ghcr.io' e tente login manualmente se precisar." -ForegroundColor Yellow
                Write-Host "- Se estiver atrás de proxy/firewall, confirme regras para https (porta 443)." -ForegroundColor Yellow
                return
            } else {
                Write-Host "Atualização via compose concluída com sucesso." -ForegroundColor Green
            }
        }
    }

    Write-Host "`n============================================" -ForegroundColor Green
    Write-Host "  DOWNLOAD CONCLUIDO COM SUCESSO!" -ForegroundColor Green
    Write-Host "============================================`n" -ForegroundColor Green

    # Verificar se .env esta configurado antes de iniciar
    if (-not (Check-EnvConfigured -ShowMessage $false)) {
        Write-Host "Agora é necessário configurar as variáveis do sistema." -ForegroundColor Yellow
        Write-Host "`nDeseja configurar agora? (S/N)" -ForegroundColor Cyan
        $resposta = Read-Host
        
        if ($resposta -match '^[Ss]') {
            Write-Host "`nAbrindo editor de configurações...`n" -ForegroundColor Cyan
            Start-Sleep -Seconds 1
            Manage-Env -SkipRestart
            
            # Verificar novamente apos configuração
            Write-Host "`n`nVerificando configuração..." -ForegroundColor Cyan
            if (Check-EnvConfigured -ShowMessage $false) {
                Write-Host "Configuração OK! Iniciando serviços...`n" -ForegroundColor Green
            } else {
                Write-Host "`nConfiguração ainda incompleta." -ForegroundColor Yellow
                Write-Host "O serviço NÃO será iniciado." -ForegroundColor Red
                Write-Host "Por favor, volte ao menu e escolha a opção 3 para completar a configuração." -ForegroundColor Cyan
                return
            }
        } else {
            Write-Host "`nImagem atualizada, mas serviço NAO foi iniciado." -ForegroundColor Yellow
            Write-Host "Para iniciar o serviço:" -ForegroundColor Cyan
            Write-Host "  1. Escolha a opção 3 no menu para configurar as variáveis" -ForegroundColor White
            Write-Host "  2. Depois escolha a opção 1 para iniciar o serviço" -ForegroundColor White
            return
        }
    } else {
        Write-Host "Configuracao do .env encontrada e validada." -ForegroundColor Green
    }
    
    # Validar caminhos no .env antes de executar compose
    Write-Host "`nValidando caminhos no .env..." -ForegroundColor Cyan
    $envPath = Join-Path $PSScriptRoot ".env"
    if (Test-Path $envPath) {
        $envContent = Get-Content $envPath
        $pathVars = $envContent | Where-Object { $_ -match '^\s*(HOST_.*(?:PATH|DIR|ROOT|MEDIA|CONFIG))\s*=\s*(.+)$' }
        
        $hasProblems = $false
        foreach ($line in $pathVars) {
            if ($line -match '^\s*([A-Za-z0-9_]+)\s*=\s*(.+)$') {
                $varName = $matches[1]
                $varValue = $matches[2].Trim()
                
                if (-not [string]::IsNullOrWhiteSpace($varValue) -and $varValue -notmatch '^\s*$') {
                    $isValid = Test-WindowsPath -PathValue $varValue -VariableName $varName
                    if (-not $isValid) {
                        $hasProblems = $true
                    }
                }
            }
        }
        
        if ($hasProblems) {
            Write-Host "`nProblemas detectados nos caminhos do .env." -ForegroundColor Red
            Write-Host "Docker pode falhar ao montar volumes com estes caminhos." -ForegroundColor Yellow
            Write-Host "`nDeseja continuar mesmo assim? (S/N)" -ForegroundColor Yellow
            $continue = Read-Host
            if ($continue -notmatch '^[Ss]') {
                Write-Host "Operacao cancelada. Corrija os caminhos no .env e tente novamente." -ForegroundColor Yellow
                Write-Host "Use a opcao 3 do menu para editar o .env." -ForegroundColor Cyan
                return
            }
        }
    }
    
    # Depois reinicia tudo
    Write-Host "`nRecriando o SISCAN RPA..." -ForegroundColor Cyan
    docker compose down
    docker compose up -d

    if ($LASTEXITCODE -eq 0) {
        Write-Host "`n============================================" -ForegroundColor Green
        Write-Host "  SISCAN RPA PRONTO PARA USO!" -ForegroundColor Green
        Write-Host "============================================" -ForegroundColor Green
        Write-Host "`nO serviço foi atualizado e iniciado com sucesso!" -ForegroundColor Green
        Write-Host "Voce pode acessar o sistema em: http://localhost:5001" -ForegroundColor Cyan
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
    
    # Verificar se .env esta configurado antes de iniciar
    if (-not (Check-EnvConfigured -ShowMessage $true)) {
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
    # Verifica se ha containers do projeto rodando
    # Busca por: container_name especifico OU containers do projeto siscan-rpa
    $containers = docker ps --format "{{.Names}}" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Aviso: Nao foi possivel consultar containers Docker." -ForegroundColor Yellow
        return $false
    }
    
    # Procura por padroes: extrator-siscan-rpa, siscan-rpa-*, ou siscan (do compose)
    $found = $containers | Where-Object { 
        $_ -like "*extrator-siscan-rpa*" -or 
        $_ -like "*siscan-rpa-*" -or
        $_ -like "*siscan*"
    }
    
    return -not [string]::IsNullOrEmpty($found)
}

function Check-EnvConfigured {
    <#
    .SYNOPSIS
        Verifica se o arquivo .env existe e possui as variáveis obrigatorias configuradas.
    .DESCRIPTION
        Retorna $true se o .env existe e tem SISCAN_USER e SISCAN_PASSWORD configurados.
        Caso contrario, retorna $false e exibe mensagem orientando o usuário.
    #>
    param(
        [switch]$ShowMessage = $true
    )
    
    $envFile = Join-Path $PSScriptRoot ".env"
    
    if (-not (Test-Path $envFile)) {
        if ($ShowMessage) {
            Write-Host "`n============================================" -ForegroundColor Yellow
            Write-Host "  CONFIGURACAO NECESSARIA" -ForegroundColor Yellow
            Write-Host "============================================" -ForegroundColor Yellow
            Write-Host "`nO arquivo .env não foi encontrado." -ForegroundColor Red
            Write-Host "Antes de iniciar o serviço, e necessário configurar as variáveis." -ForegroundColor Yellow
            Write-Host "`nPor favor:" -ForegroundColor Cyan
            Write-Host "  1. Escolha a opção 3 no menu principal" -ForegroundColor White
            Write-Host "  2. Configure as variáveis obrigatorias:" -ForegroundColor White
            Write-Host "     - SISCAN_USER (usuário do SISCAN)" -ForegroundColor Gray
            Write-Host "     - SISCAN_PASSWORD (senha do SISCAN)" -ForegroundColor Gray
            Write-Host "`nDepois volte e escolha a opção 1 para iniciar o serviço." -ForegroundColor Cyan
            Write-Host "============================================`n" -ForegroundColor Yellow
        }
        return $false
    }
    
    # Le o arquivo .env e verifica se tem as variáveis obrigatorias
    $envContent = Get-Content $envFile -ErrorAction SilentlyContinue
    $hasUser = $false
    $hasPassword = $false
    
    foreach ($line in $envContent) {
        if ($line -match '^\s*SISCAN_USER\s*=\s*(.+)$' -and $matches[1].Trim() -ne "") {
            $hasUser = $true
        }
        if ($line -match '^\s*SISCAN_PASSWORD\s*=\s*(.+)$' -and $matches[1].Trim() -ne "") {
            $hasPassword = $true
        }
    }
    
    if (-not ($hasUser -and $hasPassword)) {
        if ($ShowMessage) {
            Write-Host "`n============================================" -ForegroundColor Yellow
            Write-Host "  CONFIGURACAO INCOMPLETA" -ForegroundColor Yellow
            Write-Host "============================================" -ForegroundColor Yellow
            Write-Host "`nO arquivo .env existe, mas variáveis obrigatorias estao faltando ou vazias:" -ForegroundColor Red
            if (-not $hasUser) { Write-Host "  - SISCAN_USER (usuário do SISCAN)" -ForegroundColor Yellow }
            if (-not $hasPassword) { Write-Host "  - SISCAN_PASSWORD (senha do SISCAN)" -ForegroundColor Yellow }
            Write-Host "`nPor favor:" -ForegroundColor Cyan
            Write-Host "  1. Escolha a opção 3 no menu principal" -ForegroundColor White
            Write-Host "  2. Preencha as variáveis que estao faltando" -ForegroundColor White
            Write-Host "`nDepois volte e escolha a opção 1 para iniciar o serviço." -ForegroundColor Cyan
            Write-Host "============================================`n" -ForegroundColor Yellow
        }
        return $false
    }
    
    return $true
}


function Convert-PathToDockerFormat {
    <#
    .SYNOPSIS
        Normaliza caminhos Windows para formato compatível com Docker.
    .DESCRIPTION
        Converte barras invertidas (\) para barras normais (/) automaticamente.
        Docker requer barras normais mesmo em Windows.
    #>
    param([string]$Path)
    
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }
    
    # Converte todas as barras invertidas para normais
    return $Path -replace '\\', '/'
}

function Test-WindowsPath {
    <#
    .SYNOPSIS
        Valida e sanitiza caminhos Windows (locais e UNC) para uso em Docker.
    .DESCRIPTION
        Caminhos UNC com caracteres especiais (&, %, espaços) podem causar problemas.
        Esta função detecta problemas e sugere correções.
    #>
    param(
        [string]$PathValue,
        [string]$VariableName
    )
    
    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return $true  # Caminho vazio é permitido
    }
    
    # Detectar se é caminho UNC
    $isUNC = $PathValue -match '^\\\\[^\\]+\\[^\\]+'
    
    # Caracteres problemáticos em caminhos Docker
    $problematicChars = @('&', '%', '!', '$', '`', '"', "'")
    $hasProblems = $false
    $foundChars = @()
    
    foreach ($char in $problematicChars) {
        if ($PathValue.Contains($char)) {
            $hasProblems = $true
            $foundChars += $char
        }
    }
    
    if ($hasProblems) {
        Write-Host "`n============================================" -ForegroundColor Yellow
        Write-Host "  AVISO: Caminho com caracteres especiais" -ForegroundColor Yellow
        Write-Host "============================================" -ForegroundColor Yellow
        Write-Host "`nVariavel: $VariableName" -ForegroundColor Cyan
        Write-Host "Caminho informado: $PathValue" -ForegroundColor Gray
        Write-Host "`nCaracteres problematicos encontrados: $($foundChars -join ', ')" -ForegroundColor Red
        Write-Host "`nDocker pode falhar ao montar caminhos com estes caracteres." -ForegroundColor Yellow
        
        if ($isUNC) {
            Write-Host "`nSolucoes para caminhos UNC:" -ForegroundColor Cyan
            Write-Host "  1. Use mapeamento de unidade de rede (RECOMENDADO):" -ForegroundColor Green
            Write-Host "     net use Z: $PathValue" -ForegroundColor Gray
            Write-Host "     Depois use: Z:\...caminho..." -ForegroundColor Gray
            Write-Host "`n  2. Renomeie pastas com caracteres especiais" -ForegroundColor Yellow
            Write-Host "     Exemplo: 'Config&Data' -> 'ConfigData'" -ForegroundColor Gray
            Write-Host "`n  3. Use barras normais ao inves de invertidas:" -ForegroundColor Yellow
            Write-Host "     $($PathValue -replace '\\','/')" -ForegroundColor Gray
        } else {
            Write-Host "`nSolucoes:" -ForegroundColor Cyan
            Write-Host "  1. Renomeie pastas com caracteres especiais" -ForegroundColor Green
            Write-Host "  2. Use barras normais: $($PathValue -replace '\\','/')" -ForegroundColor Gray
        }
        
        Write-Host "`n============================================`n" -ForegroundColor Yellow
        return $false
    }
    
    return $true
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

            # Decide se a variavel e secreta (fallback por nome se info não existir)
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
                    # Normalizar caminhos automaticamente (converte \ para /)
                    if ($key -match '_PATH$|_DIR$|_ROOT$|MEDIA|CONFIG') {
                        $new = Convert-PathToDockerFormat -Path $new
                        Write-Host "Caminho normalizado para Docker: $new" -ForegroundColor DarkGray
                        
                        # Validar caminhos
                        $pathValid = Test-WindowsPath -PathValue $new -VariableName $key
                        if (-not $pathValid) {
                            Write-Host "`nDeseja usar este caminho mesmo assim? (S/N)" -ForegroundColor Yellow
                            $confirm = Read-Host
                            if ($confirm -notmatch '^[Ss]') {
                                Write-Host "Mantendo valor anterior." -ForegroundColor Gray
                                $updated += $line
                                continue
                            }
                        }
                    }
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
    param([switch]$SkipRestart)
    
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
            Write-Host ".env não encontrado. Copiado de: $found" -ForegroundColor Yellow
        } else {
            New-Item -Path $envFile -ItemType File -Force | Out-Null
            Write-Host ".env não encontrado. Criado arquivo vazio: $envFile" -ForegroundColor Yellow
        }
    } else {
        Write-Host ".env encontrado: $envFile" -ForegroundColor Yellow
    }

    Update-EnvFile -Path $envFile
    
    # Após editar o .env, oferecer reiniciar os serviços (exceto se chamado com -SkipRestart)
    if (-not $SkipRestart) {
        Write-Host "`n============================================" -ForegroundColor Cyan
        Write-Host "  APLICAR CONFIGURACOES" -ForegroundColor Cyan
        Write-Host "============================================" -ForegroundColor Cyan
        
        # Verificar se há serviços rodando
        if (Check-Service) {
            Write-Host "`nO serviço SISCAN RPA esta em execução." -ForegroundColor Yellow
            Write-Host "Para aplicar as mudancas no .env, e necessário reiniciar o serviço." -ForegroundColor Yellow
            Write-Host "`nDeseja reiniciar o serviço agora? (S/N)" -ForegroundColor Cyan
            $resposta = Read-Host
            
            if ($resposta -match '^[Ss]') {
                Write-Host "`nReiniciando serviço para aplicar as configuracoes...`n" -ForegroundColor Cyan
                Start-Sleep -Seconds 1
                
                # Verificar se configuração está completa antes de reiniciar
                if (Check-EnvConfigured -ShowMessage $false) {
                    docker compose down
                    docker compose up -d
                    
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "`n============================================" -ForegroundColor Green
                        Write-Host "  CONFIGURACOES APLICADAS!" -ForegroundColor Green
                        Write-Host "============================================" -ForegroundColor Green
                        Write-Host "`nO serviço foi reiniciado com sucesso." -ForegroundColor Green
                        Write-Host "As novas configuracoes estao ativas." -ForegroundColor Cyan
                    } else {
                        Write-Host "`nErro ao reiniciar o serviço." -ForegroundColor Red
                        Write-Host "Verifique os logs para mais detalhes." -ForegroundColor Yellow
                    }
                } else {
                    Write-Host "`nConfiguracao incompleta. Servico não foi reiniciado." -ForegroundColor Yellow
                    Write-Host "Complete as variáveis obrigatorias e tente novamente." -ForegroundColor Cyan
                }
            } else {
                Write-Host "`nServico NAO foi reiniciado." -ForegroundColor Yellow
                Write-Host "As mudancas no .env serão aplicadas quando o serviço for reiniciado." -ForegroundColor Cyan
                Write-Host "Voce pode reiniciar manualmente escolhendo a opção 1 no menu." -ForegroundColor Gray
            }
        } else {
            Write-Host "`nNenhum serviço em execução detectado." -ForegroundColor Gray
            Write-Host "As configuracoes serão aplicadas quando o serviço for iniciado." -ForegroundColor Cyan
            Write-Host "Use a opção 1 no menu para iniciar o serviço." -ForegroundColor Gray
        }
    }
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
        Atualiza o proprio script assistente (siscan-assistente.ps1) com rollback automático.
    .DESCRIPTION
        Faz backup do script atual, baixa a versão mais recente do repositório GitHub,
        valida o novo script e oferece rollback em caso de falha.
    #>
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "  Atualização do Assistente SISCAN RPA" -ForegroundColor Cyan
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
    Write-Host "Backup será salvo em: $backupPath" -ForegroundColor Gray
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

    # Baixar nova versão
    Write-Host "`n[2/5] Baixando nova versão do GitHub..." -ForegroundColor Cyan
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
                throw "curl falhou ou arquivo não foi criado."
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
        Write-Host "✗ Arquivo temporario não encontrado apos download." -ForegroundColor Red
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
        Write-Host "✗ Arquivo baixado não parece ser um script PowerShell valido." -ForegroundColor Red
        Write-Host "Restaurando backup..." -ForegroundColor Yellow
        Copy-Item -Path $backupPath -Destination $scriptPath -Force
        Remove-Item $tempPath -Force -ErrorAction SilentlyContinue
        return $false
    }

    Write-Host "✓ Validacao basica OK ($tempSize bytes)." -ForegroundColor Green

    # Substituir script atual pelo novo
    Write-Host "`n[4/5] Aplicando atualização..." -ForegroundColor Cyan
    try {
        Copy-Item -Path $tempPath -Destination $scriptPath -Force -ErrorAction Stop
        Remove-Item $tempPath -Force -ErrorAction SilentlyContinue
        Write-Host "✓ Script atualizado com sucesso." -ForegroundColor Green
    } catch {
        Write-Host "✗ Erro ao aplicar atualização: $_" -ForegroundColor Red
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
    Write-Host "  Atualização concluida com sucesso!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "`nBackup mantido em: $backupPath" -ForegroundColor Gray
    Write-Host "Para usar a nova versão, reinicie o assistente." -ForegroundColor Cyan
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
        Write-Host "    - Baixa a versão mais recente do serviço SISCAN RPA"
        Write-Host " 3) Editar configurações básicas"
        Write-Host "    - Ajuste caminhos e opções essenciais (.env)"
        Write-Host " 4) Atualizar o Assistente"
        Write-Host "    - Baixa a versão mais recente do assistente com rollback automático"
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
                Write-Host "Nenhum serviço do SISCAN RPA em execução encontrado." -ForegroundColor Yellow
                Write-Host "Tentando iniciar o serviço..." -ForegroundColor Cyan
                
                if (-not (Test-Path $COMPOSE_FILE)) {
                    Write-Host "Erro: Arquivo docker-compose.yml não encontrado em: $COMPOSE_FILE" -ForegroundColor Red
                } elseif (-not (Check-EnvConfigured -ShowMessage $true)) {
                    # Mensagem ja exibida pela funcao Check-EnvConfigured
                } else {
                    $expected = Get-ExpectedServiceNames -ComposePath $COMPOSE_FILE
                    if ($expected -and $expected.Count -gt 0) {
                        Write-Host "Servicos encontrados no docker-compose.yml:" -ForegroundColor Cyan
                        foreach ($s in $expected) { Write-Host " - $s" -ForegroundColor Gray }
                        Write-Host "`nIniciando serviços..." -ForegroundColor Cyan
                        docker compose up -d
                        if ($LASTEXITCODE -eq 0) {
                            Write-Host "Servicos iniciados com sucesso!" -ForegroundColor Green
                        } else {
                            Write-Host "Erro ao iniciar os serviços." -ForegroundColor Red
                        }
                    } else {
                        Write-Host "Aviso: Nenhum serviço detectado no arquivo docker-compose.yml" -ForegroundColor Yellow
                        Write-Host "Tentando iniciar mesmo assim..." -ForegroundColor Cyan
                        docker compose up -d
                    }
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
                Write-Host "Aviso: não foi possivel autenticar. Tentarei atualizar mesmo assim..." -ForegroundColor Yellow
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
