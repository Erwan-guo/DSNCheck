[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Manifest,
    [ValidateSet('Draft','Check','ProvisionalCheck')][string]$Mode='Draft',
    [string]$RulesFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$manifestPath = (Resolve-Path -LiteralPath $Manifest).Path
$designs = New-Object System.Collections.Generic.List[object]
$outputs = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($line in [IO.File]::ReadAllLines($manifestPath, [Text.Encoding]::UTF8)) {
    $line = $line.Trim()
    if (-not $line -or $line.StartsWith('#')) { continue }
    $fields = $line.Split('|')
    if ($fields.Count -ne 2) { throw "Expected DSN|output directory in $manifestPath : $line" }
    $dsn = [IO.Path]::GetFullPath($fields[0].Trim())
    $output = [IO.Path]::GetFullPath($fields[1].Trim())
    if (-not (Test-Path -LiteralPath $dsn -PathType Leaf)) { throw "Missing DSN: $dsn" }
    if (-not $outputs.Add($output)) { throw "Duplicate output directory: $output" }
    $designs.Add([pscustomobject]@{ dsn=$dsn; output=$output })
}
if ($designs.Count -eq 0) { throw 'Batch manifest has no designs.' }

$reviewer = Join-Path $PSScriptRoot 'Invoke-PowerNetReview.ps1'
$checker = Join-Path $PSScriptRoot 'Run-DSNCheck.ps1'
foreach ($design in $designs) {
    $export = $design.output
    $objects = Join-Path $export 'dbo\objects.jsonl'
    if (-not (Test-Path -LiteralPath (Join-Path $export 'export.ok') -PathType Leaf) -or -not (Test-Path -LiteralPath $objects -PathType Leaf)) { throw "Incomplete export: $export" }
    $manifestData = Get-Content -LiteralPath (Join-Path $export 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([IO.Path]::GetFullPath([string]$manifestData.source_dsn) -ine $design.dsn) { throw "Export DSN does not match batch manifest: $export" }
    $review = Join-Path $export 'power_nets.review.csv'
    if ($Mode -eq 'Draft' -or ($Mode -eq 'ProvisionalCheck' -and -not (Test-Path -LiteralPath $review))) {
        & $reviewer -InputDirectory $export -Mode Draft
        if ($Mode -eq 'Draft') { continue }
    }
    $map = Join-Path $export 'power_nets.confirmed.json'
    if ($Mode -eq 'ProvisionalCheck') {
        $meta = Get-Content -LiteralPath ([IO.Path]::ChangeExtension($review, '.meta.json')) -Raw -Encoding UTF8 | ConvertFrom-Json
        $hash = (Get-FileHash -LiteralPath $objects -Algorithm SHA256).Hash
        if ($meta.source_sha256 -ne $hash) { throw "Review data is stale: $export" }
        $nets = @(
            Import-Csv -LiteralPath $review -Encoding UTF8 | Where-Object {
                $_.kind -in @('power','ground') -and (
                    $_.source -in @('name_or_symbol','bridge') -or
                    ($_.source -eq 'pin_hint' -and $_.net -match '(?i)V|GND|GROUND|EARTH')
                )
            } | ForEach-Object {
                [pscustomobject]@{ net=$_.net; kind=$_.kind; voltage_v=$_.voltage_v; source=$_.source; evidence=$_.evidence }
            }
        )
        $map = Join-Path $export 'power_nets.provisional.json'
        [ordered]@{ schema_version=1; source_sha256=$hash; review_status='provisional'; generated_at=(Get-Date).ToString('s'); nets=$nets } |
            ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $map -Encoding UTF8
    }
    $arguments = @{ InputDirectory=$export; PowerMap=$map }
    if ($RulesFile) { $arguments.RulesFile=$RulesFile }
    & $checker @arguments
}
