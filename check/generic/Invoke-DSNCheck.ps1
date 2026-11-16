[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory,
    [double]$FilterCapDistance = 250,
    [string]$RulesFile,
    [string]$PowerMap
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$outputPath = [IO.Path]::GetFullPath($OutputDirectory)
$objectsPath = Join-Path $outputPath 'dbo\objects.jsonl'
if (-not (Test-Path -LiteralPath $objectsPath -PathType Leaf)) {
    throw "Dbo object export was not found: $objectsPath"
}
if (-not $PowerMap) { $PowerMap = Join-Path $outputPath 'power_nets.confirmed.json' }
$powerMapPath = [IO.Path]::GetFullPath($PowerMap)
if (-not (Test-Path -LiteralPath $powerMapPath -PathType Leaf)) {
    throw "Confirmed power map missing: $powerMapPath. Run Invoke-PowerNetReview.ps1 -Mode Draft, review the CSV, then -Mode Confirm."
}
$powerMapData = Get-Content -LiteralPath $powerMapPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([int]$powerMapData.schema_version -ne 1 -or $powerMapData.source_sha256 -ne (Get-FileHash -LiteralPath $objectsPath -Algorithm SHA256).Hash) {
    throw 'Confirmed power map does not match this Dbo export. Repeat Draft and Confirm.'
}
$powerMapReviewStatus = if ($powerMapData.PSObject.Properties.Name -contains 'review_status') { [string]$powerMapData.review_status } else { 'user_confirmed' }
if ($powerMapReviewStatus -notin @('user_confirmed','provisional')) { throw 'Invalid power map review status.' }

$pins = New-Object System.Collections.Generic.List[object]
$allPins = New-Object System.Collections.Generic.List[object]
$parts = @{}
$powerNets = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
$groundNets = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
foreach ($entry in $powerMapData.nets) {
    $net = [string]$entry.net
    if (-not $net) { throw 'Confirmed power map contains an empty net name.' }
    switch ([string]$entry.kind) {
        'power' { if (-not $powerNets.Add($net)) { throw "Duplicate power network: $net" } }
        'ground' { if (-not $groundNets.Add($net)) { throw "Duplicate ground network: $net" } }
        default { throw "Invalid confirmed network kind for $net" }
    }
}
foreach ($net in $powerNets) { if ($groundNets.Contains($net)) { throw "Network confirmed as both power and ground: $net" } }

function Convert-ToNumber {
    param([object]$Value)
    $number = 0.0
    if ([double]::TryParse([string]$Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) { return $number }
    return 0.0
}

function Test-TrueValue {
    param([object]$Value)
    return ([string]$Value -match '^(?i:1|true|yes)$')
}

function Test-PowerPin {
    param([object]$Pin)
    return ([string]$Pin.pin_type -eq '7' -or [string]$Pin.pin_type -match '(?i)^power(?:\s+input)?$')
}

function Test-GroundNet {
    param([string]$Name)
    return ($Name -and $groundNets.Contains($Name))
}

foreach ($line in [IO.File]::ReadAllLines($objectsPath)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try { $record = $line | ConvertFrom-Json } catch { continue }
    if ($null -eq $record.record) { continue }
    switch ([string]$record.record) {
        'part' {
            $parts[[string]$record.id] = [pscustomobject]@{ id=[string]$record.id; page_id=[string]$record.page_id; reference=[string]$record.reference; value=[string]$record.value; source_part=[string]$record.source_part; footprint=[string]$record.pcb_footprint; left=(Convert-ToNumber $record.left); top=(Convert-ToNumber $record.top); right=(Convert-ToNumber $record.right); bottom=(Convert-ToNumber $record.bottom) }
        }
        'pin' {
            $net = [string]$record.net_name
            $pin = [pscustomobject]@{ id=[string]$record.id; owner_id=[string]$record.owner_id; page_id=[string]$record.page_id; net=$net; name=[string]$record.name; number=[string]$record.number; pin_type=[string]$record.pin_type; no_connect=(Test-TrueValue $record.no_connect); connected=(Test-TrueValue $record.connected); x=(Convert-ToNumber $record.offset_hot_x); y=(Convert-ToNumber $record.offset_hot_y) }
            $allPins.Add($pin)
            if ($net -and $net -ne 'NULL' -and -not $pin.no_connect) { $pins.Add($pin) }
        }
    }
}

$groups = @{}
foreach ($pin in $pins) {
    if (-not $groups.ContainsKey($pin.net)) { $groups[$pin.net] = New-Object System.Collections.Generic.List[object] }
    $groups[$pin.net].Add($pin)
}

$connectorParts = @{}
$propertiesPath = Join-Path $outputPath 'dbo\properties.jsonl'
if (Test-Path -LiteralPath $propertiesPath -PathType Leaf) {
    foreach ($line in [IO.File]::ReadLines($propertiesPath)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $property = $line | ConvertFrom-Json
        if ([string]$property.record -ne 'user_property' -or [string]$property.name -notmatch '^(?i:Part Type)$') { continue }
        if ([string]$property.value -match '(?i)插座|连接器|connector|socket') { $connectorParts[[string]$property.owner_id] = $true }
    }
}

$errors = New-Object System.Collections.Generic.List[object]

# Only a user-confirmed supply network counts as an external rail.
$powerPins = @($allPins | Where-Object { Test-PowerPin $_ })
foreach ($powerPin in $powerPins) {
    $net = [string]$powerPin.net
    $external = (-not $powerPin.no_connect -and $powerPin.connected -and ($powerNets.Contains($net) -or $groundNets.Contains($net)))
    if (-not $external) {
        if ($powerPin.connected -and -not $powerPin.no_connect -and $net -and $net -ne 'NULL' -and $connectorParts.ContainsKey([string]$powerPin.owner_id)) { continue }
        $part = $null
        if ($parts.ContainsKey($powerPin.owner_id)) { $part = $parts[$powerPin.owner_id] }
        $reference = if ($null -ne $part) { [string]$part.reference } else { [string]$powerPin.owner_id }
        $pinText = '{0}({1})' -f $powerPin.name, $powerPin.number
        $status = if ($net -and $powerMapReviewStatus -eq 'provisional') { 'manual_review' } else { 'error' }
        $errors.Add([pscustomobject]@{ category='Power引脚未外接电源'; status=$status; rule='器件Power属性引脚未连接已确认的电源/地网络'; page=$powerPin.page_id; part=$reference; pin=$pinText; net=$net; details=('器件={0}; 引脚={1}; 网络={2}' -f $reference, $pinText, $net) })
    }
}

# 3. Check every device independently. A capacitor must be on the same page,
# connect between this exact power net and a ground net, and be within the
# configured drawing-coordinate radius of at least one Power pin.
$capacitors = @($parts.Values | Where-Object { [string]$_.reference -match '^(?i:C[0-9A-Z_]*)$' })
$capPinMap = @{}
foreach ($cap in $capacitors) { $capPinMap[$cap.id] = @($allPins | Where-Object { $_.owner_id -eq $cap.id -and -not $_.no_connect }) }
$devicePowerGroups = @{}
foreach ($powerPin in $powerPins) {
    if (-not $powerPin.net -or $powerPin.net -eq 'NULL' -or -not $parts.ContainsKey($powerPin.owner_id)) { continue }
    # Ground pins and reference-voltage pins are not supply rails and should
    # not create a decoupling-capacitor requirement.
    if (-not $powerNets.Contains([string]$powerPin.net)) { continue }
    $part = $parts[$powerPin.owner_id]
    if ([string]$part.reference -match '^(?i:[RCL][0-9A-Z_]*)$') { continue }
    $key = $powerPin.owner_id + '|' + $powerPin.net
    if (-not $devicePowerGroups.ContainsKey($key)) { $devicePowerGroups[$key] = New-Object System.Collections.Generic.List[object] }
    $devicePowerGroups[$key].Add([pscustomobject]@{ part=$part; pin=$powerPin })
}
foreach ($entry in $devicePowerGroups.GetEnumerator()) {
    $items = @($entry.Value.ToArray()); $part = $items[0].part; $net = [string]$items[0].pin.net; $found = $false
    foreach ($cap in $capacitors) {
        if ($cap.page_id -ne $part.page_id) { continue }
        $capPinsForPart = @($capPinMap[$cap.id]); if ($capPinsForPart.Count -lt 2) { continue }
        if (@($capPinsForPart | Where-Object { [string]$_.net -eq $net }).Count -eq 0) { continue }
        if (@($capPinsForPart | Where-Object { Test-GroundNet ([string]$_.net) }).Count -eq 0) { continue }
        $cx = ($cap.left + $cap.right) / 2.0; $cy = ($cap.top + $cap.bottom) / 2.0
        foreach ($item in $items) {
            $dx = $item.pin.x - $cx; $dy = $item.pin.y - $cy
            if ([math]::Sqrt(($dx * $dx) + ($dy * $dy)) -le $FilterCapDistance) { $found = $true; break }
        }
        if ($found) { break }
    }
    if (-not $found) {
        $pinsText = ($items | ForEach-Object { '{0}({1})' -f $_.pin.name, $_.pin.number }) -join ', '
        $errors.Add([pscustomobject]@{ category='供电器件缺少就近滤波电容'; rule='器件供电网络附近未发现同页、接地的滤波电容'; page=$part.page_id; part=$part.reference; net=$net; details=('器件={0}; Power引脚={1}; page={2}; 搜索半径={3}' -f $part.reference, $pinsText, $part.page_id, $FilterCapDistance) })
    }
}
# Isolated-power check is intentionally a separate pass from single-node
# checking. A named voltage net that only feeds R/C parts is reported once as
# 孤立电源, not again as 单节点网络.
foreach ($net in ($powerNets | Where-Object { $groups.ContainsKey($_) } | Sort-Object)) {
    $members = @($groups[$net].ToArray())
    $owners = @($members | Select-Object -ExpandProperty owner_id -Unique)
    $partInfo = @($owners | ForEach-Object { if ($parts.ContainsKey($_)) { $parts[$_] } })
    if ($partInfo.Count -gt 0 -and (@($partInfo | Where-Object { $_.reference -notmatch '^(?i:R|C)[0-9A-Z_]*$' }).Count -eq 0)) {
        $references = @($partInfo | Select-Object -ExpandProperty reference)
        $details = ($members | ForEach-Object { "$($_.number)@$($_.owner_id)" }) -join ', '
        $errors.Add([pscustomobject]@{ category='孤立电源'; rule='电源只连接了电阻电容'; net=$net; count=$members.Count; parts=($references -join ', '); details=$details })
    }
}

foreach ($net in ($groups.Keys | Sort-Object)) {
    $members = @($groups[$net].ToArray())
    $owners = @($members | Select-Object -ExpandProperty owner_id -Unique)
    $partInfo = @($owners | ForEach-Object { if ($parts.ContainsKey($_)) { $parts[$_] } })
    $references = @($partInfo | Select-Object -ExpandProperty reference)
    $details = ($members | ForEach-Object { "$($_.number)@$($_.owner_id)" }) -join ', '

    if (-not $powerNets.Contains($net) -and $members.Count -lt 2) {
        $errors.Add([pscustomobject]@{ category='单节点网络'; rule='有效连接数少于2个'; net=$net; count=$members.Count; parts=($references -join ', '); details=$details })
    }
    if ($members.Count -ge 2 -and $owners.Count -eq 1) {
        $errors.Add([pscustomobject]@{ category='伪单节点网络'; rule='某网络所连接的pin全属于一个器件'; net=$net; count=$members.Count; parts=($references -join ', '); details=$details })
    }
}

$additional = & (Join-Path $PSScriptRoot 'Invoke-DSNCheck-Additional.ps1') -OutputDirectory $outputPath -RulesFile $RulesFile -Parts $parts -AllPins $allPins -Pins $pins -Groups $groups -PowerNets $powerNets -GroundNets $groundNets -PowerNetEntries $powerMapData.nets
foreach ($issue in $additional.issues) { $errors.Add($issue) }
$categoryOrder = @('单节点网络', '孤立电源', '伪单节点网络', 'Power引脚未外接电源', '供电器件缺少就近滤波电容') + @($additional.categories)
$summary = [ordered]@{}
foreach ($category in $categoryOrder) { $summary[$category] = @($errors | Where-Object category -eq $category).Count }
$report = [ordered]@{ schema_version='1.4'; generated_at=(Get-Date).ToString('s'); filter_cap_distance=$FilterCapDistance; power_map=$powerMapPath; power_map_review_status=$powerMapReviewStatus; confirmed_power_nets=$powerNets.Count; confirmed_ground_nets=$groundNets.Count; rule_coverage=$additional.coverage; configured_rule_targets=$additional.rule_coverage; summary=$summary; errors=@($errors.ToArray()) }
$jsonPath = Join-Path $outputPath 'dsn_check_report.json'
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

$textPath = Join-Path $outputPath 'dsn_check_report.txt'
$text = New-Object System.Collections.Generic.List[string]
$text.Add('Cadence DSN 原理图检查报告'); $text.Add(('生成时间: ' + $report.generated_at)); $text.Add('')
if ($powerMapReviewStatus -eq 'provisional') { $text.Add('注意: 电源/地网络映射未经用户确认；电源相关结论为临时结果。'); $text.Add('') }
$text.Add('规则覆盖:')
foreach ($key in $additional.coverage.Keys) { $text.Add(('  {0}: {1}' -f $key, $additional.coverage[$key])) }
$text.Add('')
foreach ($category in $categoryOrder) {
    $items = @($errors | Where-Object category -eq $category)
    $text.Add(('[{0}] {1} 项' -f $category, $items.Count))
    foreach ($item in $items) {
        if ($item.PSObject.Properties.Name -contains 'count') { $text.Add(('  网络={0}; 连接数={1}; 器件={2}; 引脚={3}' -f $item.net, $item.count, $item.parts, $item.details)) }
        elseif ($item.PSObject.Properties.Name -contains 'status') {
            $text.Add(('  [{0}] {1}; page={2}; 器件={3}; 引脚={4}; 网络={5}; {6}' -f $item.status, $item.rule, $item.page, $item.part, $item.pin, $item.net, $item.details))
        }
        else { $text.Add(('  {0}' -f $item.details)) }
    }
    $text.Add('')
}
$text | Set-Content -LiteralPath $textPath -Encoding UTF8
Write-Output ('DSN check report: ' + $textPath)
Write-Output ('单节点网络={0}; 孤立电源={1}; 伪单节点网络={2}; Power引脚未外接电源={3}; 供电器件缺少就近滤波电容={4}' -f $summary['单节点网络'], $summary['孤立电源'], $summary['伪单节点网络'], $summary['Power引脚未外接电源'], $summary['供电器件缺少就近滤波电容'])
