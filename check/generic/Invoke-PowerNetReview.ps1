[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$InputDirectory,
    [ValidateSet('Draft','Confirm')][string]$Mode='Draft',
    [string]$ReviewFile,
    [string]$ConfirmedFile,
    [double]$StrongPullMaxOhms=100,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($StrongPullMaxOhms -le 0) { throw 'StrongPullMaxOhms must be positive.' }
$inputPath = [IO.Path]::GetFullPath($InputDirectory)
$objectsPath = Join-Path $inputPath 'dbo\objects.jsonl'
if (-not (Test-Path -LiteralPath $objectsPath -PathType Leaf)) { throw "Missing export: $objectsPath" }
if (-not $ReviewFile) { $ReviewFile = Join-Path $inputPath 'power_nets.review.csv' }
if (-not $ConfirmedFile) { $ConfirmedFile = Join-Path $inputPath 'power_nets.confirmed.json' }
$reviewPath = [IO.Path]::GetFullPath($ReviewFile)
$confirmedPath = [IO.Path]::GetFullPath($ConfirmedFile)
$metaPath = [IO.Path]::ChangeExtension($reviewPath, '.meta.json')
$sourceHash = (Get-FileHash -LiteralPath $objectsPath -Algorithm SHA256).Hash
if ($Mode -eq 'Draft' -and -not $Force -and ((Test-Path -LiteralPath $reviewPath) -or (Test-Path -LiteralPath $metaPath))) {
    throw "Existing review files will not be overwritten: $reviewPath. Use -Force only after preserving your edits."
}

$netNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$parts = @{}
$partPins = @{}
$symbols = New-Object System.Collections.Generic.List[object]
$pins = New-Object System.Collections.Generic.List[object]
foreach ($line in [IO.File]::ReadAllLines($objectsPath)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try { $item = $line | ConvertFrom-Json } catch { throw "Invalid JSON in $objectsPath : $_" }
    $net = if ($item.PSObject.Properties.Name -contains 'net_name') { [string]$item.net_name } else { '' }
    if ($net -and $net -ne 'NULL') { [void]$netNames.Add($net) }
    switch ([string]$item.record) {
        'part' {
            $parts[[string]$item.id] = [pscustomobject]@{ id=[string]$item.id; reference=[string]$item.reference; value=[string]$item.value; source_part=[string]$item.source_part }
        }
        'pin' {
            $pin = [pscustomobject]@{ owner=[string]$item.owner_id; net=$net; name=[string]$item.name; type=[string]$item.pin_type; connected=([string]$item.connected -match '^(?i:1|true|yes)$'); no_connect=([string]$item.no_connect -match '^(?i:1|true|yes)$') }
            $pins.Add($pin)
            if (-not $partPins.ContainsKey($pin.owner)) { $partPins[$pin.owner] = New-Object System.Collections.Generic.List[object] }
            $partPins[$pin.owner].Add($pin)
        }
        'global' { $symbols.Add([pscustomobject]@{ name=[string]$item.name; net=$net }) }
    }
}

function Get-Voltage {
    param([string]$Name)
    $match = [regex]::Match($Name, '(?i)(?<whole>\d+)V(?<fraction>\d+)|(?<decimal>\d+\.\d+)V')
    if (-not $match.Success) { return '' }
    $number = if ($match.Groups['decimal'].Success) { $match.Groups['decimal'].Value } else { $match.Groups['whole'].Value + '.' + $match.Groups['fraction'].Value }
    return ([double]::Parse($number, [Globalization.CultureInfo]::InvariantCulture)).ToString('0.########', [Globalization.CultureInfo]::InvariantCulture)
}
function Test-GroundName {
    param([string]$Name)
    return ($Name -match '(?i)(?:^|[_\-\s])(?:GND|GROUND|AGND|DGND|PGND|VSS|EARTH)(?:$|[_\-\s])')
}
function Add-Seed {
    param([hashtable]$Map, [string]$Net, [string]$Kind, [string]$Voltage, [string]$Why)
    if (-not $Net -or -not $netNames.Contains($Net)) { return }
    if (-not $Map.ContainsKey($Net)) { $Map[$Net] = New-Object System.Collections.Generic.List[object] }
    $Map[$Net].Add([pscustomobject]@{ kind=$Kind; voltage=$Voltage; evidence=$Why })
}
function Get-Ohms {
    param([string]$Value)
    $valueText = $Value.Trim()
    $match = [regex]::Match($valueText, '(?i)^(?<whole>\d+)(?:(?<unit>R|K)(?<fraction>\d+)|(?<decimal>\.\d+)?\s*(?<suffix>R|K|OHM|Ω)?)$')
    if (-not $match.Success) { return $null }
    $number = $match.Groups['whole'].Value
    if ($match.Groups['fraction'].Success) { $number += '.' + $match.Groups['fraction'].Value }
    elseif ($match.Groups['decimal'].Success) { $number += $match.Groups['decimal'].Value }
    $ohms = [double]::Parse($number, [Globalization.CultureInfo]::InvariantCulture)
    $unit = if ($match.Groups['unit'].Success) { $match.Groups['unit'].Value } else { $match.Groups['suffix'].Value }
    if ($unit -eq 'K') { $ohms *= 1000 }
    return $ohms
}

$hardSeeds = @{}
$pinHints = @{}
foreach ($net in $netNames) {
    if (Test-GroundName $net) { Add-Seed $hardSeeds $net 'ground' '' "network name: $net" }
    $voltage = Get-Voltage $net
    if ($voltage) { Add-Seed $hardSeeds $net 'power' $voltage "network name: $net" }
}
foreach ($symbol in $symbols) {
    if (Test-GroundName $symbol.name) { Add-Seed $hardSeeds $symbol.net 'ground' '' "global symbol: $($symbol.name)" }
    $voltage = Get-Voltage $symbol.name
    if ($voltage) { Add-Seed $hardSeeds $symbol.net 'power' $voltage "global symbol: $($symbol.name)" }
}
foreach ($pin in $pins) {
    if (-not $pin.connected -or $pin.no_connect -or -not $pin.net -or $pin.net -eq 'NULL') { continue }
    if (Test-GroundName $pin.name) { Add-Seed $pinHints $pin.net 'ground' '' "pin name: $($pin.name)" }
    elseif ($pin.type -eq '7' -or $pin.type -match '(?i)^power') { Add-Seed $pinHints $pin.net 'power' '' "power pin: $($pin.name)" }
}

$adjacent = @{}
$strongEdges = New-Object System.Collections.Generic.List[object]
$bridgeCount = 0
foreach ($part in $parts.Values) {
    if (-not $partPins.ContainsKey($part.id)) { continue }
    $partPinList = @($partPins[$part.id].ToArray())
    if ($partPinList.Count -ne 2 -or @($partPinList | Where-Object { -not $_.connected -or $_.no_connect -or -not $_.net -or $_.net -eq 'NULL' }).Count -gt 0) { continue }
    $a = $partPinList[0].net; $b = $partPinList[1].net
    if ($a -eq $b) { continue }
    $component = ''
    if ($part.reference -match '^(?i:R\d+[A-Z]?)$') {
        $ohms = Get-Ohms $part.value
        if ($null -eq $ohms) { continue }
        if ($ohms -eq 0) { $component = 'zero_ohm' }
        elseif ($ohms -le $StrongPullMaxOhms) {
            $strongEdges.Add([pscustomobject]@{ a=$a; b=$b; reference=$part.reference; ohms=$ohms })
        }
    } elseif ($part.reference -match '^(?i:(?:FB|FERRITE)\d+[A-Z]?)$' -or ($part.source_part + ' ' + $part.value) -match '(?i)(BEAD|FERRITE|磁珠)') {
        $component = 'ferrite_bead'
    } elseif ($part.reference -match '^(?i:L\d+[A-Z]?)$') {
        $component = 'inductor'
    }
    if (-not $component) { continue }
    $bridgeCount++
    foreach ($side in @(@($a,$b), @($b,$a))) {
        if (-not $adjacent.ContainsKey($side[0])) { $adjacent[$side[0]] = New-Object System.Collections.Generic.List[object] }
        $adjacent[$side[0]].Add([pscustomobject]@{ net=$side[1]; reference=$part.reference; type=$component })
    }
}

$suggestions = @{}
$visited = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($start in $netNames) {
    if ($visited.Contains($start)) { continue }
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($start); [void]$visited.Add($start)
    $members = New-Object System.Collections.Generic.List[string]
    $bridges = New-Object System.Collections.Generic.List[string]
    while ($stack.Count -gt 0) {
        $current = $stack.Pop(); $members.Add($current)
        if (-not $adjacent.ContainsKey($current)) { continue }
        foreach ($edge in $adjacent[$current]) {
            $bridges.Add(('{0}({1})' -f $edge.reference,$edge.type))
            if ($visited.Add($edge.net)) { $stack.Push($edge.net) }
        }
    }
    $seeds = New-Object System.Collections.Generic.List[object]
    foreach ($member in $members) {
        if ($hardSeeds.ContainsKey($member)) { foreach ($seed in $hardSeeds[$member]) { $seeds.Add($seed) } }
    }
    $origin = 'name_or_symbol'
    if ($seeds.Count -eq 0) {
        $origin = 'pin_hint'
        foreach ($member in $members) {
            if ($pinHints.ContainsKey($member)) { foreach ($seed in $pinHints[$member]) { $seeds.Add($seed) } }
        }
    }
    if ($seeds.Count -eq 0) { continue }
    $identities = @($seeds | ForEach-Object { $_.kind + ':' + $_.voltage } | Select-Object -Unique)
    $kind = if ($identities.Count -eq 1) { [string]$seeds[0].kind } else { 'conflict' }
    $voltage = if ($kind -eq 'power') { [string]$seeds[0].voltage } else { '' }
    $evidence = (@($seeds | ForEach-Object { $_.evidence } | Select-Object -Unique) + @($bridges | Select-Object -Unique)) -join '; '
    foreach ($member in $members) {
        $source = if ($hardSeeds.ContainsKey($member)) { 'name_or_symbol' } elseif ($origin -eq 'pin_hint' -and $pinHints.ContainsKey($member)) { 'pin_hint' } else { 'bridge' }
        $suggestions[$member] = [pscustomobject]@{ net=$member; kind=$kind; voltage_v=$voltage; source=$source; evidence=$evidence }
    }
}

$strongCandidates = @{}
foreach ($edge in $strongEdges) {
    foreach ($direction in @(@($edge.a,$edge.b), @($edge.b,$edge.a))) {
        $from = $direction[0]; $to = $direction[1]
        if (-not $suggestions.ContainsKey($from) -or $suggestions.ContainsKey($to) -or $suggestions[$from].kind -eq 'conflict') { continue }
        if (-not $strongCandidates.ContainsKey($to)) { $strongCandidates[$to] = New-Object System.Collections.Generic.List[object] }
        $strongCandidates[$to].Add([pscustomobject]@{ kind=$suggestions[$from].kind; voltage_v=$suggestions[$from].voltage_v; evidence=('{0} {1}Ω from {2}' -f $edge.reference,$edge.ohms,$from) })
    }
}
foreach ($net in $strongCandidates.Keys) {
    $items = @($strongCandidates[$net].ToArray())
    $identities = @($items | ForEach-Object { $_.kind + ':' + $_.voltage_v } | Select-Object -Unique)
    $kind = if ($identities.Count -eq 1) { [string]$items[0].kind } else { 'conflict' }
    $voltage = if ($kind -eq 'power') { [string]$items[0].voltage_v } else { '' }
    $suggestions[$net] = [pscustomobject]@{ net=$net; kind=$kind; voltage_v=$voltage; source='strong_pull_review'; evidence=(($items | ForEach-Object { $_.evidence }) -join '; ') }
}

if ($Mode -eq 'Draft') {
    $rows = @($suggestions.Values | Sort-Object net | ForEach-Object {
        [pscustomobject]@{ net=$_.net; kind=$_.kind; voltage_v=$_.voltage_v; decision=''; source=$_.source; evidence=$_.evidence }
    })
    if ($rows.Count -gt 0) { $rows | Export-Csv -LiteralPath $reviewPath -NoTypeInformation -Encoding UTF8 }
    else { '"net","kind","voltage_v","decision","source","evidence"' | Set-Content -LiteralPath $reviewPath -Encoding UTF8 }
    [ordered]@{ schema_version=1; source_sha256=$sourceHash; candidate_nets=@($rows | ForEach-Object { $_.net }); total_nets=$netNames.Count; bridge_count=$bridgeCount; strong_pull_max_ohms=$StrongPullMaxOhms } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $metaPath -Encoding UTF8
    Write-Output "Review CSV: $reviewPath"
    Write-Output "Candidates: $($rows.Count); bridge components: $bridgeCount; strong-pull edges: $($strongEdges.Count)"
    Write-Output 'Set decision=accept or reject for every row; edit kind/voltage as needed, and append missing networks before Confirm.'
    return
}

if (-not (Test-Path -LiteralPath $reviewPath -PathType Leaf) -or -not (Test-Path -LiteralPath $metaPath -PathType Leaf)) { throw 'Review CSV or metadata missing. Run Draft first.' }
$meta = Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($meta.source_sha256 -ne $sourceHash) { throw 'Export changed since Draft. Generate a fresh review CSV.' }
$rows = @(Import-Csv -LiteralPath $reviewPath -Encoding UTF8)
$reviewed = @{}
$accepted = New-Object System.Collections.Generic.List[object]
foreach ($row in $rows) {
    $net = [string]$row.net
    if (-not $netNames.Contains($net)) { throw "Unknown network in review CSV: $net" }
    if ($reviewed.ContainsKey($net)) { throw "Duplicate network in review CSV: $net" }
    $reviewed[$net] = $true
    $decision = ([string]$row.decision).Trim().ToLowerInvariant()
    if ($decision -notin @('accept','reject')) { throw "Set decision=accept or reject for network: $net" }
    if ($decision -eq 'reject') { continue }
    $kind = ([string]$row.kind).Trim().ToLowerInvariant()
    if ($kind -notin @('power','ground')) { throw "Accepted network needs kind=power or ground: $net" }
    $voltage = ([string]$row.voltage_v).Trim()
    if ($kind -eq 'ground' -and $voltage) { throw "Ground network must not have voltage_v: $net" }
    if ($voltage -and $voltage -notmatch '^\d+(?:\.\d+)?$') { throw "Invalid voltage_v for network: $net" }
    $accepted.Add([pscustomobject]@{ net=$net; kind=$kind; voltage_v=$voltage; source=[string]$row.source; evidence=[string]$row.evidence })
}
foreach ($net in $meta.candidate_nets) {
    if (-not $reviewed.ContainsKey([string]$net)) { throw "Candidate row removed; mark reject instead: $net" }
}
if ($accepted.Count -eq 0) { throw 'No accepted power or ground networks.' }
[ordered]@{ schema_version=1; source_sha256=$sourceHash; confirmed_at=(Get-Date).ToString('s'); reviewed_count=$rows.Count; nets=@($accepted.ToArray()) } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $confirmedPath -Encoding UTF8
Write-Output "Confirmed network map: $confirmedPath"
Write-Output "Accepted: $($accepted.Count); rejected: $($rows.Count - $accepted.Count)"
