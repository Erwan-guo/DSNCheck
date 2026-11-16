[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [Alias('OutputDirectory')]
    [string]$InputDirectory,
    [double]$FilterCapDistance = 250,
    [string]$RulesFile,
    [string]$PowerMap
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$checker = Join-Path $PSScriptRoot 'Invoke-DSNCheck.ps1'
& $checker -OutputDirectory $InputDirectory -FilterCapDistance $FilterCapDistance -RulesFile $RulesFile -PowerMap $PowerMap
if ((Get-Variable LASTEXITCODE -ErrorAction SilentlyContinue) -and $LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
