<# Wrapper: este arquivo foi renomeado para `siscan-assistente.ps1`.
   Para compatibilidade, este wrapper tenta invocar o novo script com os mesmos argumentos.
#>

try {
    $new = Join-Path $PSScriptRoot 'siscan-assistente.ps1'
    if (Test-Path $new) {
        & $new @args
    } else {
        Write-Host "Foi introduzido um novo nome: siscan-assistente.ps1, mas o arquivo não foi encontrado." -ForegroundColor Yellow
        Write-Host "Por favor verifique o conteúdo do repositório ou restaure execute.ps1 a partir de execute.ps1.bak." -ForegroundColor Yellow
    }
} catch {
    Write-Host "Erro ao delegar para siscan-assistente.ps1: $_" -ForegroundColor Red
}
