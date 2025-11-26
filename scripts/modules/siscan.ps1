<#
siscan.ps1 - Module to pull image, configure volumes and deploy Assistente SISCan RPA

Implements Module-Main -ModuleArgs <hashtable>
#>

function Module-Main {
  param([hashtable]$ModuleArgs)

    $registry = $ModuleArgs.Registry
    $token = $ModuleArgs.Token
    $siscanUser = $ModuleArgs.SiscanUser
    $siscanPass = $ModuleArgs.SiscanPass
    # allow overriding the image name via ModuleArgs.Image
    if ($ModuleArgs.ContainsKey('Image') -and $ModuleArgs.Image) {
      $image = $ModuleArgs.Image
    }
    else {
      $image = "$registry/prisma-consultoria/assistente-siscan-rpa:latest"
    }
  $dataDir = "$env:ProgramData\AssistenteSISCan\data"
  $composeFile = "$env:ProgramData\AssistenteSISCan\docker-compose.yml"

    New-Item -ItemType Directory -Path $dataDir -Force | Out-Null

    Write-Host ("Baixando imagem {0} (versao/tag mostrada acima) ..." -f $image)
    Write-LogInfo ("Pulling image: {0}" -f $image)
    try { docker pull $image } catch { Write-Warning ("Falha ao puxar imagem: {0}" -f $_); Write-LogWarn ("docker pull failed for {0}: {1}" -f $image, $_) }

    # Create a minimal docker-compose to run the service using placeholders
    $compose = @"
version: '3.8'
services:
  assistente-siscan-rpa:
    image: {IMAGE}
    restart: unless-stopped
    environment:
      - SISCAN_USER={SISCAN_USER}
      - SISCAN_PASS={SISCAN_PASS}
    volumes:
      - {DATA_DIR}:/app/data
    ports:
      - "8080:8080"
"@

    $compose = $compose -replace '\{IMAGE\}',$image -replace '\{SISCAN_USER\}',$siscanUser -replace '\{SISCAN_PASS\}',$siscanPass -replace '\{DATA_DIR\}',$dataDir
    $compose | Out-File -FilePath $composeFile -Encoding UTF8 -Force

    Write-Host "Iniciando servico via docker compose..."
    try { docker compose -f $composeFile up -d --remove-orphans } catch { Write-Warning ("docker compose up falhou: {0}" -f $_) }

    return $true
}
