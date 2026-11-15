[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$InputDirectory,
    [string]$RulesFile,
    [double]$TimingMargin = 1.2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$checker = Join-Path $PSScriptRoot 'Invoke-DSNCheck-CI4-CI5.ps1'
$arguments = @{ InputDirectory=$InputDirectory; TimingMargin=$TimingMargin }
if ($RulesFile) { $arguments.RulesFile = $RulesFile }
& $checker @arguments
if ((Get-Variable LASTEXITCODE -ErrorAction SilentlyContinue) -and $LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
