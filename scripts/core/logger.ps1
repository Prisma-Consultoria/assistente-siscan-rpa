<#
logger.ps1 - Simple logging utility for installer

Usage:
  . .\scripts\core\logger.ps1
  Initialize-Logger -CacheDir $CacheDir -Debug:$true
  Write-Log -Level Info -Message 'Starting'
#>

param()

function Initialize-Logger {
    param(
        [Parameter(Mandatory=$true)][string]$CacheDir,
        [switch]$Debug
    )
    if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null }
    $script:LogFile = Join-Path $CacheDir 'install.log'
    if ($Debug) { $script:LogLevel = 'Debug' } else { $script:LogLevel = 'Info' }
    # create/rotate log if too large
    try {
        if (Test-Path $script:LogFile) {
            $size = (Get-Item $script:LogFile).Length
            if ($size -gt 5MB) { Move-Item $script:LogFile ($script:LogFile + '.' + (Get-Date -Format 'yyyyMMddHHmmss')) }
        }
    }
    catch { }
}

function Write-Log {
    param(
        [ValidateSet('Debug','Info','Warn','Error')][string]$Level = 'Info',
        [Parameter(Mandatory=$true)][string]$Message
    )
    # Avoid logging secrets: if message contains 'Token' or 'Password' redact
    $out = $Message -replace '(?i)(token\s*[:=]\s*)([^\s]+)','$1<redacted>' -replace '(?i)(password\s*[:=]\s*)([^\s]+)','$1<redacted>'
    $ts = (Get-Date).ToString('o')
    $line = "[$ts] [$Level] $out"
    try {
        Add-Content -Path $script:LogFile -Value $line -Encoding UTF8
    }
    catch { }
    switch ($Level) {
        'Debug' { if ($script:LogLevel -eq 'Debug') { Write-Verbose $Message } }
        'Info'  { Write-Host $Message }
        'Warn'  { Write-Warning $Message }
        'Error' { Write-Error $Message }
    }
}

function Write-LogDebug { param([string]$Message) Write-Log -Level Debug -Message $Message }
function Write-LogInfo  { param([string]$Message) Write-Log -Level Info -Message $Message }
function Write-LogWarn  { param([string]$Message) Write-Log -Level Warn -Message $Message }
function Write-LogError { param([string]$Message) Write-Log -Level Error -Message $Message }
