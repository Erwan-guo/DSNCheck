[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$InputDirectory,

    [Parameter(Position = 1)]
    [string]$OutputDirectory,

    [string]$NetlistDirectory
)

<##
Creates an offline DSNCheck data package. The input is an export directory
created by capture_export_active.tcl; this script never opens or modifies DSN.
Cadence DRC reports are deliberately not copied.
##>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$inputPath = [IO.Path]::GetFullPath($InputDirectory)
if (-not (Test-Path -LiteralPath $inputPath -PathType Container)) {
    throw "Export directory was not found: $inputPath"
}
$required = @(
    (Join-Path $inputPath 'native\design.iscf'),
    (Join-Path $inputPath 'dbo\objects.jsonl'),
    (Join-Path $inputPath 'dbo\properties.jsonl')
)
foreach ($path in $required) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required export file was not found: $path" }
}

if (-not $OutputDirectory) { $OutputDirectory = $inputPath.TrimEnd('\\') + '_package' }
$outputPath = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $outputPath 'native') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $outputPath 'dbo') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $outputPath 'netlist') -Force | Out-Null

# Copy only data files. In particular, native_drc is intentionally omitted.
Copy-Item -LiteralPath (Join-Path $inputPath 'native\design.iscf') -Destination (Join-Path $outputPath 'native\design.iscf') -Force
foreach ($name in @('objects.jsonl', 'properties.jsonl', 'errors.jsonl')) {
    $source = Join-Path $inputPath "dbo\$name"
    if (Test-Path -LiteralPath $source -PathType Leaf) {
        Copy-Item -LiteralPath $source -Destination (Join-Path $outputPath "dbo\$name") -Force
    }
}

if ($NetlistDirectory) {
    $netlistPath = [IO.Path]::GetFullPath($NetlistDirectory)
    foreach ($name in @('pstxnet.dat', 'pstxprt.dat', 'pstchip.dat')) {
        $source = Join-Path $netlistPath $name
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            Copy-Item -LiteralPath $source -Destination (Join-Path $outputPath "netlist\$name") -Force
        }
    }
}

$parts = @{}
$pins = New-Object System.Collections.Generic.List[object]
$powerNets = @{}
$recordsRead = 0
foreach ($line in [IO.File]::ReadLines((Join-Path $inputPath 'dbo\objects.jsonl'))) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try { $record = $line | ConvertFrom-Json } catch { continue }
    $recordsRead++
    switch ([string]$record.record) {
        'part' {
            $parts[[string]$record.id] = [pscustomobject]@{
                part_id=[string]$record.id; reference=[string]$record.reference; value=[string]$record.value
                pcb_footprint=[string]$record.pcb_footprint; source_library=[string]$record.source_library; source_part=[string]$record.source_part
            }
        }
        'pin' {
            $net = [string]$record.net_name
            if ($net -and $net -ne 'NULL' -and [string]$record.no_connect -notin @('1','true','True')) {
                $pins.Add([pscustomobject]@{
                    pin_id=[string]$record.id; part_id=[string]$record.owner_id; net_name=$net
                    pin_name=[string]$record.name; pin_number=[string]$record.number; pin_type=[string]$record.pin_type
                    page_id=[string]$record.page_id
                })
            }
        }
        'global' {
            $net = [string]$record.net_name
            if ($net -and $net -ne 'NULL') { $powerNets[$net] = $true }
        }
    }
}

$parts.Values | Sort-Object reference | Export-Csv -LiteralPath (Join-Path $outputPath 'netlist\parts.csv') -NoTypeInformation -Encoding UTF8
$pins | Sort-Object net_name,part_id,pin_number | Export-Csv -LiteralPath (Join-Path $outputPath 'netlist\pins.csv') -NoTypeInformation -Encoding UTF8

$groups = @{}
foreach ($pin in $pins) {
    if (-not $groups.ContainsKey($pin.net_name)) { $groups[$pin.net_name] = New-Object System.Collections.Generic.List[object] }
    $groups[$pin.net_name].Add($pin)
}

$netRows = New-Object System.Collections.Generic.List[object]
$logicalJsonl = Join-Path $outputPath 'netlist\logical_netlist.jsonl'
if (Test-Path -LiteralPath $logicalJsonl) { Remove-Item -LiteralPath $logicalJsonl -Force }
$logicalChannel = [IO.StreamWriter]::new($logicalJsonl, $false, [Text.UTF8Encoding]::new($false))
try {
    foreach ($net in ($groups.Keys | Sort-Object)) {
        $members = @($groups[$net].ToArray())
        $ownerIds = @($members | Select-Object -ExpandProperty part_id -Unique)
        $refs = @($ownerIds | ForEach-Object { if ($parts.ContainsKey($_)) { $parts[$_].reference } })
        $isPower = $powerNets.ContainsKey($net) -or ($net -match '(?i)^(GND|GROUND|VCC|VDD|VSS|VBAT|\+[0-9A-Z_.-]+|-[0-9A-Z_.-]+)$')
        $row = [ordered]@{ record='net'; name=$net; pin_count=$members.Count; part_count=$ownerIds.Count; is_power=$isPower; parts=($refs -join ','); pins=@($members | ForEach-Object { [ordered]@{ part_id=$_.part_id; pin_number=$_.pin_number; pin_name=$_.pin_name } }) }
        $logicalChannel.WriteLine(($row | ConvertTo-Json -Compress -Depth 6))
        $netRows.Add([pscustomobject]@{ net_name=$net; pin_count=$members.Count; part_count=$ownerIds.Count; is_power=$isPower; parts=($refs -join ',') })
    }
} finally { $logicalChannel.Dispose() }
$netRows | Export-Csv -LiteralPath (Join-Path $outputPath 'netlist\nets.csv') -NoTypeInformation -Encoding UTF8

$manifest = [ordered]@{
    schema_version='1.0'; package_type='DSNCheck offline export'; generated_at=(Get-Date).ToString('s')
    input_directory=$inputPath; includes=@('native/design.iscf','dbo/objects.jsonl','dbo/properties.jsonl','dbo/errors.jsonl','netlist/parts.csv','netlist/pins.csv','netlist/nets.csv','netlist/logical_netlist.jsonl')
    cadence_netlist_files=@((Get-ChildItem -LiteralPath (Join-Path $outputPath 'netlist') -Filter 'pst*.dat' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }))
    records_read=$recordsRead; parts=$parts.Count; connected_pins=$pins.Count; nets=$netRows.Count; drc_reports_included=$false
}
$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $outputPath 'package_manifest.json') -Encoding UTF8
Write-Output "DSNCheck package ready: $outputPath"
Write-Output "parts=$($parts.Count); pins=$($pins.Count); nets=$($netRows.Count); native_netlists=$($manifest.cadence_netlist_files.Count)"
