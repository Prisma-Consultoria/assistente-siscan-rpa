# -------------------------------------
#   SCRIPT DE LOGIN / GHCR / PULL
# -------------------------------------

$CRED_FILE = "credenciais.txt"
$IMAGE_PATH = "ghcr.io/prisma-consultoria/siscan-rpa-rpa:main"

Write-Host "-------------------------------------"
Write-Host "  SCRIPT DE LOGIN / GHCR / PULL"
Write-Host "-------------------------------------"
Write-Host ""


function Get-CredentialsFile {
    param ($Path)

    if (!(Test-Path $Path)) {
        return $null
    }

    $creds = @{
        usuario = $null
        token   = $null
    }

    Get-Content $Path | ForEach-Object {
        $parts = $_ -split '='
        if ($parts[0] -eq "usuario") { $creds.usuario = $parts[1] }
        if ($parts[0] -eq "token")   { $creds.token   = $parts[1] }
    }

    return $creds
}


function Ask-Credentials {
    Write-Host "Informe suas credenciais do GitHub Container Registry:"

    $user = Read-Host "Usuario"
    $tok  = Read-Host "Token"

    Write-Host ""
    Write-Host "Salvando credenciais em $CRED_FILE..."

    "usuario=$user" | Out-File $CRED_FILE -Encoding utf8
    "token=$tok"    | Out-File $CRED_FILE -Encoding utf8 -Append

    Write-Host "Credenciais salvas."
    Write-Host ""

    return @{
        usuario = $user
        token   = $tok
    }
}


# =========================
# LÓGICA PRINCIPAL
# =========================

$creds = $null

# Verifica credenciais existentes
if (Test-Path $CRED_FILE) {

    Write-Host "Arquivo de credenciais encontrado: $CRED_FILE"
    Write-Host ""

    $USE_SAVED = Read-Host "Deseja manter as credenciais existentes? (s/n)"
    $USE_SAVED = $USE_SAVED.Trim().ToLower()

    if ($USE_SAVED -eq "s") {
        $creds = Get-CredentialsFile -Path $CRED_FILE
    }
    else {
        Write-Host "`nApagando arquivo existente..."
        Remove-Item $CRED_FILE -ErrorAction SilentlyContinue
        $creds = Ask-Credentials
    }
}
else {
    # Nenhum arquivo, pede credenciais novas
    $creds = Ask-Credentials
}

# =========================
# LOGIN NO GHCR
# =========================

Write-Host "Realizando login no GHCR..."

$null = $creds.token | docker login ghcr.io -u $creds.usuario --password-stdin

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERRO: Falha no login. Verifique usuario e token."
    pause
    exit
}

Write-Host "Login realizado com sucesso."
Write-Host ""


# =========================
# PULL DA IMAGEM
# =========================

Write-Host "Executando docker pull: $IMAGE_PATH"
docker pull $IMAGE_PATH

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERRO: Falha ao fazer pull da imagem."
    pause
    exit
}

Write-Host "Pull realizado com sucesso!"
Write-Host ""
Write-Host "Reiniciando serviços com docker-compose..."

Push-Location $PSScriptRoot

if (Test-Path "docker-compose.yml") {
    docker-compose up -d

    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERRO: Falha ao reiniciar os serviços."
        Write-Host "Execute manualmente: docker-compose up -d"
    }
    else {
        Write-Host "Serviços reiniciados com sucesso."
    }
}
else {
    Write-Host "Aviso: docker-compose.yml não encontrado no diretório $PSScriptRoot"
}

Pop-Location

Write-Host ""
Write-Host "Processo concluído."
pause
