<#
Generate-Checksums.ps1 - Generate SHA256 checksums for module files

Usage:
  pwsh ./scripts/generate-checksums.ps1
#>

param(
    [string]$ModulesPath = "./scripts/modules",
    [string]$OutFile = "./scripts/checksums.txt"
)

Set-StrictMode -Version Latest

if (Test-Path $OutFile) { Remove-Item $OutFile -Force }

Get-ChildItem -Path $ModulesPath -File | ForEach-Object {
    $hash = Get-FileHash -Path $_.FullName -Algorithm SHA256
    "$($hash.Hash)  $($_.Name)" | Out-File -FilePath $OutFile -Encoding utf8 -Append
}

Write-Host "Checksums written to $OutFile"
