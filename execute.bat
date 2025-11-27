@echo off
setlocal enabledelayedexpansion

set CRED_FILE=credenciais.txt
set IMAGE_PATH=ghcr.io/prisma-consultoria/siscan-rpa-rpa:main

echo -------------------------------------
echo   SCRIPT DE LOGIN / GHCR / PULL
echo -------------------------------------
echo.

REM Se o arquivo de credenciais existe
if exist "%CRED_FILE%" (
    echo Arquivo de credenciais encontrado: %CRED_FILE%
    echo.

    set /p USE_SAVED="Deseja manter as credenciais existentes? (s/n): "

    REM LIMPA espaços, CR, LF e TAB
    set "USE_SAVED=%USE_SAVED: =%"
    set "USE_SAVED=%USE_SAVED:`r=%"
    set "USE_SAVED=%USE_SAVED:`n=%"
    set "USE_SAVED=%USE_SAVED:	=%"

    REM Agora funciona 100%
    if /i "%USE_SAVED%"=="s" goto READ_CREDENTIALS

    echo.
    echo Apagando arquivo existente para criar novas credenciais...
    del "%CRED_FILE%"
    echo.
)

:ASK_CREDENTIALS
echo Informe suas credenciais do GitHub Container Registry:
set /p GITHUB_USER="Usuario: "
set /p GITHUB_TOKEN="Token: "

echo Salvando credenciais em %CRED_FILE%...
(
    echo usuario=%GITHUB_USER%
    echo token=%GITHUB_TOKEN%
) > "%CRED_FILE%"
echo Credenciais salvas.
echo.

goto LOGIN

:READ_CREDENTIALS
echo Lendo credenciais de %CRED_FILE%...
for /f "tokens=1,2 delims==" %%a in (%CRED_FILE%) do (
    if "%%a"=="usuario" set GITHUB_USER=%%b
    if "%%a"=="token" set GITHUB_TOKEN=%%b
)
echo Usuario carregado: %GITHUB_USER%
echo.

:LOGIN
echo Realizando login no GHCR...
echo %GITHUB_TOKEN% | docker login ghcr.io -u %GITHUB_USER% --password-stdin

if %errorlevel% neq 0 (
    echo ERRO: Falha no login. Verifique usuario e token.
    goto END
)

echo Login realizado com sucesso.
echo.

echo Executando docker pull: %IMAGE_PATH%
docker pull %IMAGE_PATH%

if %errorlevel% neq 0 (
    echo ERRO: Falha ao fazer pull da imagem.
) else (
    echo Pull realizado com sucesso!
)

:END
echo.
echo Processo concluido.
pause
