<#
install.ps1 - Remote installer bootstrap for Assistente SISCan RPA

Usage:
  irm "https://raw.githubusercontent.com/Prisma-Consultoria/assistente-siscan-rpa/main/install.ps1" | iex

Design goals:
- Minimal bootstrap executed by end users
- Secure prompts for tokens/credentials (never logged)
- Modular modules fetched from `scripts/modules/*.ps1`
- Fallback to cached modules if network fails
#>

param(
    [string]$RepoBase = 'https://raw.githubusercontent.com/Prisma-Consultoria/assistente-siscan-rpa/main',
    [string]$CacheDir = "$env:ProgramData\AssistenteSISCan\installer-cache",
    [string]$Version = ''
)

Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::InputEncoding  = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
}
catch {
    # best-effort; continue if not supported
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

Ensure-Directory -Path $CacheDir

function Download-Module {
    param(
        [string]$ModulePath,
        [string]$Destination
    )
    $url = "$RepoBase/$ModulePath"
    try {
        Invoke-RestMethod -Uri $url -OutFile $Destination -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Get-Checksums {
    param([string]$RepoBase, [string]$CacheDir)
    $checksumsUrl = "$RepoBase/scripts/checksums.txt"
    $dest = Join-Path $CacheDir 'checksums.txt'
    try {
        Invoke-RestMethod -Uri $checksumsUrl -OutFile $dest -ErrorAction Stop
        return $dest
    }
    catch {
        return $null
    }
}

function Verify-FileChecksum {
    param([string]$FilePath, [string]$ChecksumsPath)
    if (-not (Test-Path $ChecksumsPath)) { return $true }
    $lines = Get-Content $ChecksumsPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $fileName = Split-Path $FilePath -Leaf
    foreach ($l in $lines) {
        # expected format: SHA256  filename
        if ($l -match '^\s*([A-Fa-f0-9]{64})\s+(.+)$') {
            $expected = $matches[1]
            $entryName = $matches[2]
            if ($entryName -eq $fileName) {
                $actual = (Get-FileHash -Path $FilePath -Algorithm SHA256).Hash.ToLower()
                if ($actual -ne $expected.ToLower()) {
                    Write-Warning ("Checksum mismatch for {0} (expected {1}, got {2})" -f $fileName, $expected, $actual)
                    return $false
                }
                return $true
            }
        }
    }
    # no entry -> allow
    return $true
}

function Read-Secret {
    param([string]$Prompt)
    $secure = Read-Host -AsSecureString -Prompt $Prompt
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { [Runtime.InteropServices.Marshal]::PtrToStringAuto($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function Load-And-Run-Module {
    param(
        [string]$ModuleRelPath,
        [hashtable]$ModuleArgs
    )
    $leaf = Split-Path $ModuleRelPath -Leaf
    $dest = Join-Path $CacheDir $leaf
    # If a local module exists in the repository (during development), prefer it to cached/remote
    if ($PSScriptRoot) {
        $localModulePath = Join-Path $PSScriptRoot $ModuleRelPath
        if (Test-Path $localModulePath) {
            Write-Verbose "Using local module $localModulePath"
            try {
                . $localModulePath
                if (Get-Command -Name Module-Main -ErrorAction SilentlyContinue) {
                    Module-Main -ModuleArgs $ModuleArgs
                    return $true
                }
                else {
                    Write-Warning "Local module $localModulePath does not implement Module-Main"
                    # fallthrough to download/cache behavior
                }
            }
            catch {
                Write-Warning ("Error executing local module {0}: {1}" -f $localModulePath, $_)
                # fallthrough to download/cache behavior
            }
        }
    }

    # Try download fresh module; if fails and cached exists, use cache
    $checksumsFile = Get-Checksums -RepoBase $RepoBase -CacheDir $CacheDir
    if (-not (Download-Module -ModulePath $ModuleRelPath -Destination $dest)) {
        if (-not (Test-Path $dest)) {
            Write-Warning "Failed to download $ModuleRelPath and no cache present."
            return $false
        }
        else { Write-Verbose "Using cached module $leaf" }
    }

    # If checksums file available, verify integrity
    if ($checksumsFile) {
        if (-not (Verify-FileChecksum -FilePath $dest -ChecksumsPath $checksumsFile)) {
            Write-Error "Checksum verification failed for $leaf. Aborting module load."
            return $false
        }
    }

    try {
        . $dest
        if (Get-Command -Name Module-Main -ErrorAction SilentlyContinue) {
            Module-Main -ModuleArgs $ModuleArgs
            return $true
        }
        else {
            Write-Warning "Module $ModuleRelPath does not implement Module-Main"
            return $false
        }
    }
    catch {
        Write-Warning ("Error executing module {0}: {1}" -f $ModuleRelPath, $_)
        return $false
    }
}

function Main {
    Write-Host "Assistente SISCan RPA - Instalador" -ForegroundColor Cyan

    # Registry info
    $registry = Read-Host -Prompt 'Registry URL (ex: ghcr.io or registry.example.com)'
    $registryUser = Read-Host -Prompt 'Registry usuário (se aplicável, deixe em branco para token-only)'
    $token = Read-Secret -Prompt 'Token para imagem privada (entrada oculta)'

    # SISCan credentials
    $siscanUser = Read-Host -Prompt 'SISCan usuário'
    $siscanPass = Read-Secret -Prompt 'SISCan senha (entrada oculta)'

    $moduleArgs = @{
        Registry = $registry;
        RegistryUser = $registryUser;
        Token = $token;
        SiscanUser = $siscanUser;
        SiscanPass = $siscanPass;
        RepoBase = $RepoBase;
        CacheDir = $CacheDir;
    }

    # Validate Docker and Compose and perform registry login
    if (-not (Load-And-Run-Module -ModuleRelPath 'scripts/modules/docker.ps1' -ModuleArgs $moduleArgs)) {
        Write-Error "Docker validation module failed. Aborting."
        exit 1
    }

    # Pull image, configure volumes and deploy
    if (-not (Load-And-Run-Module -ModuleRelPath 'scripts/modules/siscan.ps1' -ModuleArgs $moduleArgs)) {
        Write-Error "SISCan deployment module failed. Aborting."
        exit 1
    }

    Write-Host "Instalação concluída." -ForegroundColor Green
}

try { Main }
catch { Write-Error ("Instalador falhou: {0}" -f $_) }
