<#
docker.ps1 - Module to validate Docker/Docker Compose and login to registry

Implements:
    Module-Main -ModuleArgs <hashtable>
#>

function Module-Main {
    param([hashtable]$ModuleArgs)

    $registry = $ModuleArgs.Registry
    $registryUser = $ModuleArgs.RegistryUser
    $token = $ModuleArgs.Token

    Write-Host "Validando Docker e Docker Compose..."
    try {
        $docker = Get-Command docker -ErrorAction Stop
    }
    catch { Write-Error "Docker não encontrado. Instale Docker antes."; return $false }

    # Try docker compose (v2 integrated) or docker-compose binary
    $composeFound = $false
    if (Get-Command docker-compose -ErrorAction SilentlyContinue) { $composeFound = $true }
    else {
        try { docker compose version > $null 2>&1; $composeFound = $true } catch { }
    }
    if (-not $composeFound) { Write-Error "Docker Compose não encontrado. Instale Docker Compose."; return $false }

    if ($registry -and $token) {
        Write-Host "Logando no registro privado (nao sera mostrado o token)..."
            try {
                $secureToken = ConvertTo-SecureString $token -AsPlainText -Force
                $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
                $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
                # Trim whitespace/newlines that might come from copy/paste
                if ($plain) { $plain = $plain.Trim() }

            # GHCR (GitHub Container Registry)
                if ($registry -like '*ghcr.io*') {
                if (-not $registryUser) { Write-Warning "GHCR geralmente requer um usuario (GitHub username)." }
                $argList = @('login', 'ghcr.io', '--username', $registryUser, '--password-stdin')
                    # write token to a temp file and redirect stdin to docker to capture output reliably
                    $tf = [System.IO.Path]::GetTempFileName()
                    try {
                        Set-Content -Path $tf -Value $plain -NoNewline -Encoding ASCII
                        $out = Get-Content -Raw -Path $tf | & docker @argList 2>&1
                        Write-LogDebug ("docker login ghcr.io output: {0}" -f ($out -join " | "))
                        if ($LASTEXITCODE -ne 0) { Write-LogWarn ("docker login ghcr.io failed: {0}" -f ($out -join " | ")); return $false }
                    }
                    catch { Write-LogWarn ("docker login ghcr.io exception: {0}" -f $_) }
                    finally { Remove-Item -Path $tf -Force -ErrorAction SilentlyContinue }
            }
            # Azure ACR
            elseif ($registry -like '*.azurecr.io*') {
                # try az acr login when az CLI available
                if (Get-Command az -ErrorAction SilentlyContinue) {
                    $acrName = ($registry -split '\.')[0]
                    try { az acr login --name $acrName | Out-Null }
                    catch { Write-Warning "az acr login falhou; tentando docker login com credenciais" }
                }
                else {
                    if ($registryUser) {
                        $argList = @('login', $registry, '--username', $registryUser, '--password-stdin')
                        try {
                            $tf = [System.IO.Path]::GetTempFileName()
                            try {
                                Set-Content -Path $tf -Value $plain -NoNewline -Encoding ASCII
                                $out = Get-Content -Raw -Path $tf | & docker @argList 2>&1
                                Write-LogDebug ("docker login ACR output: {0}" -f ($out -join " | "))
                                if ($LASTEXITCODE -ne 0) { Write-Error "docker login para ACR falhou"; return $false }
                            }
                            finally { Remove-Item -Path $tf -Force -ErrorAction SilentlyContinue }
                        }
                        catch { Write-LogWarn ("docker login ACR failed: {0}" -f $_) }
                    }
                }
            }
            # AWS ECR
            elseif ($registry -match '\.dkr\.ecr\.') {
                if (Get-Command aws -ErrorAction SilentlyContinue) {
                    $pw = & aws ecr get-login-password 2>$null
                    $argList = @('login', $registry, '--username', 'AWS', '--password-stdin')
                    try {
                        if ($pw) { $pw = $pw.Trim() }
                        $tf = [System.IO.Path]::GetTempFileName()
                        try {
                            Set-Content -Path $tf -Value $pw -NoNewline -Encoding ASCII
                            $out = Get-Content -Raw -Path $tf | & docker @argList 2>&1
                            Write-LogDebug ("docker login ECR output: {0}" -f ($out -join " | "))
                            if ($LASTEXITCODE -ne 0) { Write-Warning "docker login ECR falhou: $($out -join ' | ')" }
                        }
                        finally { Remove-Item -Path $tf -Force -ErrorAction SilentlyContinue }
                    }
                    catch { Write-LogWarn ("docker login ECR failed: {0}" -f $_) }
                }
                else { Write-Warning "AWS CLI não encontrado; não foi possível autenticar no ECR" }
            }
            else {
                # generic docker login
                    if ($registryUser) {
                        $argList = @('login', $registry, '--username', $registryUser, '--password-stdin')
                        try {
                            $tf = [System.IO.Path]::GetTempFileName()
                            try {
                                Set-Content -Path $tf -Value $plain -NoNewline -Encoding ASCII
                                $out = Get-Content -Raw -Path $tf | & docker @argList 2>&1
                                Write-LogDebug ("docker login output: {0}" -f ($out -join " | "))
                                if ($LASTEXITCODE -ne 0) { Write-Error "docker login falhou: $($out -join ' | ')"; return $false }
                            }
                            finally { Remove-Item -Path $tf -Force -ErrorAction SilentlyContinue }
                        }
                        catch { Write-LogWarn ("docker login failed: {0}" -f $_) }
                    }
                    else {
                        $argList = @('login', $registry, '--username', 'oauth2', '--password-stdin')
                        try {
                            $tf = [System.IO.Path]::GetTempFileName()
                            try {
                                Set-Content -Path $tf -Value $plain -NoNewline -Encoding ASCII
                                $out = Get-Content -Raw -Path $tf | & docker @argList 2>&1
                                Write-LogDebug ("docker login oauth2 output: {0}" -f ($out -join " | "))
                                if ($LASTEXITCODE -ne 0) { Write-Warning "docker login com usuário 'oauth2' falhou; você pode precisar fornecer usuário específico. Details: $($out -join ' | ')" }
                            }
                            finally { Remove-Item -Path $tf -Force -ErrorAction SilentlyContinue }
                        }
                        catch { Write-Warning ("docker login oauth2 failed: {0}" -f $_) }
                    }
            }
        }
        catch { Write-Warning ("Erro durante docker login: {0}" -f $_) }
    }

    return $true
}
