[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [Alias('OutputDirectory')]
    [string]$InputDirectory,
    [string]$RulesFile,
    [string]$PowerMap
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$checker = Join-Path $PSScriptRoot 'Invoke-DSNCheck.ps1'
& $checker -OutputDirectory $InputDirectory -RulesFile $RulesFile -PowerMap $PowerMap
if ((Get-Variable LASTEXITCODE -ErrorAction SilentlyContinue) -and $LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
