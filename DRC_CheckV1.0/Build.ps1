[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { throw 'Windows .NET Framework 4 compiler was not found.' }
$sources = @('Program.cs', 'Workflow.cs', 'MainForm.cs') | ForEach-Object { Join-Path $PSScriptRoot $_ }
$output = Join-Path $PSScriptRoot 'DRC_CheckV1.0.exe'
& $compiler /nologo /target:winexe /platform:anycpu /codepage:65001 /optimize+ "/out:$output" `
    /reference:System.Windows.Forms.dll /reference:System.Drawing.dll `
    /reference:System.Web.Extensions.dll /reference:Microsoft.VisualBasic.dll $sources
if ($LASTEXITCODE -ne 0) { throw "Build failed with exit code $LASTEXITCODE" }
Write-Output "Built $output"
