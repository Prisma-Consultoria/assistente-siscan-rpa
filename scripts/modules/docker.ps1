<#
docker.ps1 - Module to validate Docker/Docker Compose and login to registry

Implements:
  Module-Main -Args <hashtable>
#>

function Module-Main {
    param([hashtable]$Args)

    $registry = $Args.Registry
    $registryUser = $Args.RegistryUser
    $token = $Args.Token

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
        Write-Host "Logando no registro privado (não será mostrado o token)..."
        try {
            $secureToken = ConvertTo-SecureString $token -AsPlainText -Force
            $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
            $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

            # GHCR (GitHub Container Registry)
            if ($registry -like '*ghcr.io*') {
                if (-not $registryUser) { Write-Warning "GHCR geralmente requer um usuário (GitHub username)." }
                $args = @('login', 'ghcr.io', '--username', $registryUser, '--password-stdin')
                $proc = Start-Process -FilePath 'docker' -ArgumentList $args -NoNewWindow -RedirectStandardInput Pipe -RedirectStandardOutput Pipe -RedirectStandardError Pipe -PassThru
                $proc.StandardInput.WriteLine($plain); $proc.StandardInput.Close()
                $proc.WaitForExit()
                if ($proc.ExitCode -ne 0) { Write-Error "docker login ghcr.io falhou"; return $false }
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
                        $proc = Start-Process -FilePath 'docker' -ArgumentList @('login', $registry, '--username', $registryUser, '--password-stdin') -NoNewWindow -RedirectStandardInput Pipe -RedirectStandardOutput Pipe -RedirectStandardError Pipe -PassThru
                        $proc.StandardInput.WriteLine($plain); $proc.StandardInput.Close()
                        $proc.WaitForExit()
                        if ($proc.ExitCode -ne 0) { Write-Error "docker login para ACR falhou"; return $false }
                    }
                }
            }
            # AWS ECR
            elseif ($registry -match '\.dkr\.ecr\.') {
                if (Get-Command aws -ErrorAction SilentlyContinue) {
                    $pw = & aws ecr get-login-password 2>$null
                    $proc = Start-Process -FilePath 'docker' -ArgumentList @('login', $registry, '--username', 'AWS', '--password-stdin') -NoNewWindow -RedirectStandardInput Pipe -RedirectStandardOutput Pipe -RedirectStandardError Pipe -PassThru
                    $proc.StandardInput.WriteLine($pw); $proc.StandardInput.Close()
                    $proc.WaitForExit()
                    if ($proc.ExitCode -ne 0) { Write-Warning "docker login ECR falhou" }
                }
                else { Write-Warning "AWS CLI não encontrado; não foi possível autenticar no ECR" }
            }
            else {
                # generic docker login
                if ($registryUser) {
                    $proc = Start-Process -FilePath 'docker' -ArgumentList @('login', $registry, '--username', $registryUser, '--password-stdin') -NoNewWindow -RedirectStandardInput Pipe -RedirectStandardOutput Pipe -RedirectStandardError Pipe -PassThru
                    $proc.StandardInput.WriteLine($plain); $proc.StandardInput.Close()
                    $proc.WaitForExit()
                    if ($proc.ExitCode -ne 0) { Write-Error "docker login falhou"; return $false }
                }
                else {
                    $proc = Start-Process -FilePath 'docker' -ArgumentList @('login', $registry, '--username', 'oauth2', '--password-stdin') -NoNewWindow -RedirectStandardInput Pipe -RedirectStandardOutput Pipe -RedirectStandardError Pipe -PassThru
                    $proc.StandardInput.WriteLine($plain); $proc.StandardInput.Close()
                    $proc.WaitForExit()
                    if ($proc.ExitCode -ne 0) { Write-Warning "docker login com usuário 'oauth2' falhou; você pode precisar fornecer usuário específico." }
                }
            }
        }
        catch { Write-Warning "Erro durante docker login: $_" }
    }

    return $true
}
