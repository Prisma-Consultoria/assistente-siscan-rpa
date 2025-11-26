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
    [switch]$DebugMode,
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

# Load logger (prefer local core module)
if (Test-Path "$PSScriptRoot\scripts\core\logger.ps1") { . "$PSScriptRoot\scripts\core\logger.ps1" }
else { Write-Verbose "Logger not found locally" }
Initialize-Logger -CacheDir $CacheDir -DebugMode:$DebugMode
Write-LogInfo "Installer started (DebugMode=$DebugMode)"

function Download-Module {
    param(
        [string]$ModulePath,
        [string]$Destination
    )
    $url = "$RepoBase/$ModulePath"
    try {
        Invoke-RestMethod -Uri $url -OutFile $Destination -ErrorAction Stop
        Write-LogInfo "Downloaded module $ModulePath to $Destination"
        return $true
    }
    catch {
        Write-LogWarn ("Failed to download module {0} from {1}: {2}" -f $ModulePath, $url, $_)
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

    Write-LogInfo "Loading module $ModuleRelPath (localPreferred)"
    # Try download fresh module; if fails and cached exists, use cache
    $checksumsFile = Get-Checksums -RepoBase $RepoBase -CacheDir $CacheDir
    if (-not (Download-Module -ModulePath $ModuleRelPath -Destination $dest)) {
        if (-not (Test-Path $dest)) {
            Write-LogError "Failed to download $ModuleRelPath and no cache present."
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
        Write-LogInfo "Executing module $dest"
        . $dest
        if (Get-Command -Name Module-Main -ErrorAction SilentlyContinue) {
            # Do not log sensitive args; only presence
            Write-LogDebug "Calling Module-Main for $ModuleRelPath (sensitive values redacted)"
            $result = Module-Main -ModuleArgs $ModuleArgs
            Write-LogInfo "Module $ModuleRelPath executed (result=$result)"
            return $result
        }
        else {
            Write-LogWarn "Module $ModuleRelPath does not implement Module-Main"
            return $false
        }
    }
    catch {
        Write-LogWarn ("Error executing module {0}: {1}" -f $ModuleRelPath, $_)
        return $false
    }
}

function Cleanup-InstallerCache {
    param(
        [int]$OlderThanDays = 7,
        [switch]$Force
    )
    # Remove files older than specified days, unless -Force which removes all
    Write-LogInfo "Cleanup requested (OlderThanDays=$OlderThanDays, Force=$Force)"
    if (-not (Test-Path $CacheDir)) { Write-LogInfo "CacheDir does not exist: $CacheDir"; return }
    if ($Force) {
        Write-LogWarn "Removing entire cache directory $CacheDir (Force)"
        Get-ChildItem -Path $CacheDir -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        return
    }
    $cutoff = (Get-Date).AddDays(-1 * $OlderThanDays)
    Get-ChildItem -Path $CacheDir -File -Recurse | Where-Object { $_.LastWriteTime -lt $cutoff } | ForEach-Object {
        Write-LogInfo "Removing old cache file: $($_.FullName)"
        Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
    }
}

function Cleanup-OldImages {
    param(
        [Parameter(Mandatory=$true)][string]$ImageFull,
        [int]$OlderThanDays = 7
    )
    # ImageFull example: ghcr.io/unanimad/djud-backend:cache-latest
    Write-LogInfo "Cleanup-OldImages: image=$ImageFull, olderThanDays=$OlderThanDays"
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-LogWarn "Docker not found; skipping image cleanup"
        return
    }
    # parse repository and tag
    if ($ImageFull -match '^(.*):([^:]+)$') { $repo = $matches[1]; $currentTag = $matches[2] } else { $repo = $ImageFull; $currentTag = 'latest' }

    Write-LogInfo "Looking for local images for repo $repo (keeping tag $currentTag)"
    $cutoff = (Get-Date).AddDays(-1 * $OlderThanDays)
    $lines = & docker images --format "{{.Repository}}:{{.Tag}} {{.ID}} {{.CreatedAt}}" 2>$null
    foreach ($ln in $lines) {
        if ($ln -match '^([^\s]+)\s+([^\s]+)\s+(.+)$') {
            $img = $matches[1]; $id = $matches[2]; $createdAt = $matches[3]
            if ($img -like "$repo*") {
                # extract tag portion from img (repo:tag)
                if ($img -match '^(.*):([^:]+)$') { $tag = $matches[2] } else { $tag = 'latest' }
                if ($tag -ne $currentTag) {
                    try {
                        $dt = [datetime]::Parse($createdAt)
                    }
                    catch {
                        $dt = Get-Date
                    }
                    if ($dt -lt $cutoff) {
                        Write-LogInfo "Removing image $img ($id) created $dt"
                        try {
                            docker rmi $id 2>&1 | ForEach-Object { Write-LogInfo $_ }
                        }
                        catch {
                            Write-LogWarn ("Failed to remove image {0}: {1}" -f $id, $_)
                        }
                    }
                    else { Write-LogDebug "Keeping image $img (created $dt)" }
                }
            }
        }
    }
}

function Main {
    Write-Host "Assistente SISCan RPA - Instalador" -ForegroundColor Cyan

    # Registry info
    $registry = Read-Host -Prompt 'Registry URL (ex: ghcr.io or registry.example.com)'
    $registryUser = Read-Host -Prompt 'Registry usuario (se aplicavel, deixe em branco para token-only)'
    $token = Read-Secret -Prompt 'Token para imagem privada (entrada oculta)'

    # SISCan credentials
    $siscanUser = Read-Host -Prompt 'SISCan usuario'
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

    # Optional: allow tester or operator to specify an explicit image/tag
    $defaultImage = "$registry/prisma-consultoria/assistente-siscan-rpa:latest"
    $imageInput = Read-Host -Prompt "Imagem a ser usada (pressione Enter para usar padrao: $defaultImage)"
    if ($imageInput -and $imageInput.Trim() -ne '') {
        $moduleArgs.Image = $imageInput.Trim()
        $imageToUse = $moduleArgs.Image
    }
    else {
        $imageToUse = $defaultImage
    }

    # Inform which image/version will be used
    Write-Host "Imagem selecionada: $imageToUse" -ForegroundColor Yellow
    Write-LogInfo "Image to be used for deployment: $imageToUse"

    # Prompt whether to cleanup old images (default Yes)
    $cleanupResp = Read-Host -Prompt 'Deseja remover imagens antigas deste repositorio antes de prosseguir? [S/n]'
    if ([string]::IsNullOrWhiteSpace($cleanupResp) -or $cleanupResp.Trim().ToLower() -in @('s','y','sim','yes')) {
        Write-LogInfo ("User opted to cleanup old images for {0}" -f $imageToUse)
        try { Cleanup-OldImages -ImageFull $imageToUse -OlderThanDays 7 } catch { Write-LogWarn ("Cleanup-OldImages failed: {0}" -f $_) }
    }
    else { Write-LogInfo "User skipped cleanup of old images" }

    # Validate Docker and Compose and perform registry login
    if (-not (Load-And-Run-Module -ModuleRelPath 'scripts/modules/docker.ps1' -ModuleArgs $moduleArgs)) {
        Write-LogError "Docker validation module failed. Aborting."
        exit 1
    }

    # Pull image, configure volumes and deploy
    if (-not (Load-And-Run-Module -ModuleRelPath 'scripts/modules/siscan.ps1' -ModuleArgs $moduleArgs)) {
        Write-Error "SISCan deployment module failed. Aborting."
        exit 1
    }

    Write-Host "Instalacao concluida." -ForegroundColor Green
    Write-LogInfo "Installer finished successfully"
}

try { Main }
catch { Write-LogError ("Instalador falhou: {0}" -f $_); throw }
