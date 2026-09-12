[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory,
    [double]$FilterCapDistance = 250
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$outputPath = [IO.Path]::GetFullPath($OutputDirectory)
$objectsPath = Join-Path $outputPath 'dbo\objects.jsonl'
if (-not (Test-Path -LiteralPath $objectsPath -PathType Leaf)) {
    throw "Dbo object export was not found: $objectsPath"
}

$pins = New-Object System.Collections.Generic.List[object]
$allPins = New-Object System.Collections.Generic.List[object]
$parts = @{}
$globals = New-Object System.Collections.Generic.List[object]
$powerNets = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)

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
    return ($Name -and $Name -match '(?i)(GND|GROUND|AGND|DGND|PGND|VSS|EARTH)')
}

function Test-PowerNetName {
    param([string]$Name)
    # Valid supply names must contain one of the approved voltage forms:
    #   3V75       (integer before V, digits after V)
    #   3.75V      (decimal number followed by V)
    # Prefixes/suffixes such as SYS_3V3 or 3.75V_Eth are allowed.
    return ($Name -and $Name -match '(?i)(?:[0-9]+V[0-9]+|[0-9]+\.[0-9]+V)')
}

foreach ($line in [IO.File]::ReadLines($objectsPath)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try { $record = $line | ConvertFrom-Json } catch { continue }
    if ($null -eq $record.record) { continue }
    switch ([string]$record.record) {
        'part' {
            $parts[[string]$record.id] = [pscustomobject]@{ id=[string]$record.id; page_id=[string]$record.page_id; reference=[string]$record.reference; value=[string]$record.value; left=(Convert-ToNumber $record.left); top=(Convert-ToNumber $record.top); right=(Convert-ToNumber $record.right); bottom=(Convert-ToNumber $record.bottom) }
        }
        'pin' {
            $net = [string]$record.net_name
            $pin = [pscustomobject]@{ id=[string]$record.id; owner_id=[string]$record.owner_id; page_id=[string]$record.page_id; net=$net; name=[string]$record.name; number=[string]$record.number; pin_type=[string]$record.pin_type; no_connect=(Test-TrueValue $record.no_connect); connected=(Test-TrueValue $record.connected); x=(Convert-ToNumber $record.offset_hot_x); y=(Convert-ToNumber $record.offset_hot_y) }
            $allPins.Add($pin)
            if ($net -and $net -ne 'NULL' -and -not $pin.no_connect) { $pins.Add($pin) }
        }
        'global' {
            $net = [string]$record.net_name
            $name = [string]$record.name
            $globals.Add([pscustomobject]@{ id=[string]$record.id; page_id=[string]$record.page_id; name=$name; net=$net })
            if ((Test-PowerNetName $name) -and $net) { [void]$powerNets.Add($net) }
        }
    }
}

foreach ($net in ($pins | Select-Object -ExpandProperty net -Unique)) {
    if (Test-PowerNetName $net) { [void]$powerNets.Add($net) }
}

$groups = @{}
foreach ($pin in $pins) {
    if (-not $groups.ContainsKey($pin.net)) { $groups[$pin.net] = New-Object System.Collections.Generic.List[object] }
    $groups[$pin.net].Add($pin)
}

$errors = New-Object System.Collections.Generic.List[object]

# 1. Capture does not expose a separate ground-symbol subtype in this export;
# unnamed global symbols are reported as unnamed ground/power symbols.
foreach ($global in $globals) {
    if ([string]::IsNullOrWhiteSpace($global.name)) {
        $errors.Add([pscustomobject]@{ category='地符号未标注名称'; rule='地符号的名称为空'; page=$global.page_id; object_id=$global.id; details=('page={0}; object={1}' -f $global.page_id, $global.id) })
    }
}

# 2. A Power pin is externally powered when its net has an active device pin
# or an explicit power-like net name. Nets containing only power pins/passives
# are treated as not externally driven.
$powerPins = @($allPins | Where-Object { Test-PowerPin $_ })
foreach ($powerPin in $powerPins) {
    $net = [string]$powerPin.net
    $connected = (-not $powerPin.no_connect -and $powerPin.connected -and $net -and $net -ne 'NULL')
    $members = @()
    if ($connected -and $groups.ContainsKey($net)) { $members = @($groups[$net].ToArray()) }
    $active = @()
    foreach ($member in $members) {
        if ($member.owner_id -eq $powerPin.owner_id -or -not $parts.ContainsKey($member.owner_id)) { continue }
        $reference = [string]$parts[$member.owner_id].reference
        if ($reference -notmatch '^(?i:[RCL][0-9A-Z_]*)$' -and -not (Test-PowerPin $member)) { $active += $member }
    }
    $external = ($active.Count -gt 0 -or (Test-PowerNetName $net))
    if (-not $external) {
        $part = $null
        if ($parts.ContainsKey($powerPin.owner_id)) { $part = $parts[$powerPin.owner_id] }
        $reference = if ($null -ne $part) { [string]$part.reference } else { [string]$powerPin.owner_id }
        $pinText = '{0}({1})' -f $powerPin.name, $powerPin.number
        $errors.Add([pscustomobject]@{ category='Power引脚未外接电源'; rule='器件Power属性引脚没有检测到外部电源网络'; page=$powerPin.page_id; part=$reference; pin=$pinText; net=$net; details=('器件={0}; 引脚={1}; 网络={2}' -f $reference, $pinText, $net) })
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
    if ((Test-GroundNet ([string]$powerPin.net)) -or [string]$powerPin.name -match '(?i)(GND|GROUND|VSS|REF)') { continue }
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

$categoryOrder = @('单节点网络', '孤立电源', '伪单节点网络', '地符号未标注名称', 'Power引脚未外接电源', '供电器件缺少就近滤波电容')
$summary = [ordered]@{}
foreach ($category in $categoryOrder) { $summary[$category] = @($errors | Where-Object category -eq $category).Count }
$report = [ordered]@{ schema_version='1.1'; generated_at=(Get-Date).ToString('s'); filter_cap_distance=$FilterCapDistance; summary=$summary; errors=@($errors.ToArray()) }
$jsonPath = Join-Path $outputPath 'dsn_check_report.json'
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

$textPath = Join-Path $outputPath 'dsn_check_report.txt'
$text = New-Object System.Collections.Generic.List[string]
$text.Add('Cadence DSN 原理图检查报告'); $text.Add(('生成时间: ' + $report.generated_at)); $text.Add('')
foreach ($category in $categoryOrder) {
    $items = @($errors | Where-Object category -eq $category)
    $text.Add(('[{0}] {1} 项' -f $category, $items.Count))
    foreach ($item in $items) {
        if ($item.PSObject.Properties.Name -contains 'count') { $text.Add(('  网络={0}; 连接数={1}; 器件={2}; 引脚={3}' -f $item.net, $item.count, $item.parts, $item.details)) }
        else { $text.Add(('  {0}' -f $item.details)) }
    }
    $text.Add('')
}
$text | Set-Content -LiteralPath $textPath -Encoding UTF8
Write-Output ('DSN check report: ' + $textPath)
Write-Output ('单节点网络={0}; 孤立电源={1}; 伪单节点网络={2}; 地符号未标注名称={3}; Power引脚未外接电源={4}; 供电器件缺少就近滤波电容={5}' -f $summary['单节点网络'], $summary['孤立电源'], $summary['伪单节点网络'], $summary['地符号未标注名称'], $summary['Power引脚未外接电源'], $summary['供电器件缺少就近滤波电容'])
