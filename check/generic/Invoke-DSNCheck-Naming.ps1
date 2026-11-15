[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [hashtable]$Parts,
    [object]$AllPins,
    [hashtable]$Groups,
    [object]$NamingRule
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$issues = New-Object System.Collections.Generic.List[object]
$objectsPath = Join-Path $OutputDirectory 'dbo\objects.jsonl'
$wireById = @{}
$wiresByPage = @{}
$symbols = New-Object System.Collections.Generic.List[object]
$aliases = New-Object System.Collections.Generic.List[object]

function Get-RuleValue {
    param([object]$Rule, [string]$Name, [object]$Default)
    if ($null -eq $Rule -or $Rule.PSObject.Properties.Name -notcontains $Name) { return $Default }
    return $Rule.$Name
}
function Add-NamingIssue {
    param([string]$Status, [string]$Rule, [string]$Page, [string]$Part, [string]$Net, [string]$Details)
    $issues.Add([pscustomobject]@{ category='网络命名检查'; status=$Status; rule=$Rule; page=$Page; part=$Part; pin=''; net=$Net; details=$Details })
}
function Get-DiffToken {
    param([string]$Name)
    $match = [regex]::Match($Name.Trim(), '^(?<base>[A-Za-z][A-Za-z0-9_]*?)(?<suffix>[_-]?(?:DP|DN|DM|P|N)|\+|-)$', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) { return $null }
    $base = $match.Groups['base'].Value.TrimEnd('_','-')
    if ($base.Length -lt 2 -and $match.Groups['suffix'].Value -notin @('+','-')) { return $null }
    $suffix = $match.Groups['suffix'].Value.TrimStart('_','-').ToUpperInvariant()
    $sign = if ($suffix -in @('P','DP','+')) { 'P' } else { 'N' }
    return [pscustomobject]@{ base=$base.ToUpperInvariant(); sign=$sign }
}
function Test-AutoNet {
    param([string]$Net)
    return ($Net -match '^(?i:N\d+)$')
}
function Test-BusSymbolCoverage {
    param([string]$Name, [string]$Page, [object]$Symbols)
    foreach ($symbol in $Symbols) {
        if ([string]$symbol.page_id -ne $Page) { continue }
        $range = [regex]::Match([string]$symbol.name, '^(?<base>.+)\[(?<start>\d+)\.\.(?<end>\d+)\]$', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $range.Success) { continue }
        $member = [regex]::Match($Name, ('^(?i:{0})(?<index>\d+)$' -f [regex]::Escape($range.Groups['base'].Value)))
        if (-not $member.Success) { continue }
        $index = [int]$member.Groups['index'].Value
        $start = [int]$range.Groups['start'].Value; $end = [int]$range.Groups['end'].Value
        if ($index -ge [Math]::Min($start,$end) -and $index -le [Math]::Max($start,$end)) { return $true }
    }
    return $false
}

if (Test-Path -LiteralPath $objectsPath -PathType Leaf) { foreach ($line in [IO.File]::ReadLines($objectsPath)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $record = $line | ConvertFrom-Json
    switch ([string]$record.record) {
        'wire' {
            $wireById[[string]$record.id] = $record
            $page = [string]$record.page_id
            if (-not $wiresByPage.ContainsKey($page)) { $wiresByPage[$page] = New-Object System.Collections.Generic.List[object] }
            $wiresByPage[$page].Add($record)
        }
        'offpage_connector' { $symbols.Add($record) }
        'global' { $symbols.Add($record) }
        'net_alias' { $aliases.Add($record) }
    }
} }

$symbolNets = @{}
$symbolsByPageNet = @{}
$symbolNames = @{}
foreach ($symbol in $symbols) {
    $name = ([string]$symbol.name).Trim()
    $page = [string]$symbol.page_id
    if (-not $name) { continue }
    if (-not $symbolNames.ContainsKey($name)) { $symbolNames[$name] = @{} }
    $symbolNames[$name][$page] = $true
    $net = [string]$symbol.net_name
    if (-not $net -and $wiresByPage.ContainsKey($page)) {
        $nearest = @{}
        $left = [double]$symbol.left; $right = [double]$symbol.right
        $top = [double]$symbol.top; $bottom = [double]$symbol.bottom
        $centerX = ($left + $right) / 2; $centerY = ($top + $bottom) / 2
        foreach ($wire in $wiresByPage[$page]) {
            $candidate = [string]$wire.net_name
            if (-not $candidate -or $candidate -eq 'NULL') { continue }
            foreach ($endpoint in @(@([double]$wire.start_x,[double]$wire.start_y),@([double]$wire.end_x,[double]$wire.end_y))) {
                if ($endpoint[0] -lt $left -or $endpoint[0] -gt $right -or $endpoint[1] -lt $top -or $endpoint[1] -gt $bottom) { continue }
                $distance = [Math]::Pow($endpoint[0] - $centerX, 2) + [Math]::Pow($endpoint[1] - $centerY, 2)
                if (-not $nearest.ContainsKey($candidate) -or $distance -lt $nearest[$candidate]) { $nearest[$candidate] = $distance }
            }
        }
        if ($nearest.Count -gt 0) {
            $minimum = @($nearest.Values | Measure-Object -Minimum)[0].Minimum
            $best = @($nearest.Keys | Where-Object { $nearest[$_] -eq $minimum })
            if ($best.Count -eq 1) { $net = $best[0] }
        }
    }
    if (-not $net -or $net -eq 'NULL') { continue }
    $symbolNets[[string]$symbol.id] = $net
    $key = $page + [char]31 + $net
    if (-not $symbolsByPageNet.ContainsKey($key)) { $symbolsByPageNet[$key] = New-Object System.Collections.Generic.List[object] }
    $symbolsByPageNet[$key].Add($symbol)
}

foreach ($key in $symbolsByPageNet.Keys) {
    $items = @($symbolsByPageNet[$key].ToArray())
    $names = @($items | ForEach-Object { ([string]$_.name).Trim() } | Where-Object { $_ } | Select-Object -Unique)
    if ($names.Count -lt 2) { continue }
    $page = [string]$items[0].page_id
    $net = [string]$symbolNets[[string]$items[0].id]
    Add-NamingIssue 'error' '不同名称的Off-page/电源符号直连' $page '' $net ("page=$page; 网络=$net; 符号名=$($names -join ', ')")
}

$missingSeen = @{}
foreach ($alias in $aliases) {
    $name = ([string]$alias.name).Trim(); $page = [string]$alias.page_id
    if (-not $name -or -not $symbolNames.ContainsKey($name) -or -not $wireById.ContainsKey([string]$alias.owner_id)) { continue }
    if ($symbolNames[$name].ContainsKey($page) -or (Test-BusSymbolCoverage $name $page $symbols) -or @($symbolNames[$name].Keys | Where-Object { $_ -ne $page }).Count -eq 0) { continue }
    $wire = $wireById[[string]$alias.owner_id]; $net = [string]$wire.net_name
    if (-not $net -or $net -eq 'NULL') { continue }
    $key = $page + [char]31 + $net
    if ($symbolsByPageNet.ContainsKey($key) -and @($symbolsByPageNet[$key] | Where-Object { $_.name -eq $name }).Count -gt 0) { continue }
    $candidateKey = $key + [char]31 + $name
    if ($missingSeen.ContainsKey($candidateKey)) { continue }
    $missingSeen[$candidateKey] = $true
    Add-NamingIssue 'manual_review' '疑似缺少Off-page/电源符号' $page '' $net ("page=$page; 网络=$net; 本页别名=$name; 其他页有同名符号，本页未找到连接该网络的同名符号")
}
foreach ($pin in $AllPins) {
    $net = [string]$pin.net; $page = [string]$pin.page_id; $name = ([string]$pin.name).Trim()
    if (-not (Test-AutoNet $net) -or -not $pin.connected -or $pin.no_connect -or -not $symbolNames.ContainsKey($name)) { continue }
    if ($symbolNames[$name].ContainsKey($page) -or (Test-BusSymbolCoverage $name $page $symbols) -or @($symbolNames[$name].Keys | Where-Object { $_ -ne $page }).Count -eq 0) { continue }
    $key = $page + [char]31 + $net
    if ($symbolsByPageNet.ContainsKey($key) -and @($symbolsByPageNet[$key] | Where-Object { $_.name -eq $name }).Count -gt 0) { continue }
    $candidateKey = $key + [char]31 + $name
    if ($missingSeen.ContainsKey($candidateKey)) { continue }
    $missingSeen[$candidateKey] = $true
    $part = if ($Parts.ContainsKey([string]$pin.owner_id)) { [string]$Parts[[string]$pin.owner_id].reference } else { '' }
    Add-NamingIssue 'manual_review' '疑似缺少Off-page/电源符号' $page $part $net ("page=$page; 器件=$part; 引脚=$name; 自动网络=$net; 其他页有同名符号")
}

$pinPairs = @{}
foreach ($pin in $AllPins) {
    if (-not $pin.connected -or $pin.no_connect -or -not $pin.net -or $pin.net -eq 'NULL') { continue }
    $token = Get-DiffToken ([string]$pin.name)
    if ($null -eq $token) { continue }
    $key = [string]$pin.owner_id + [char]31 + $token.base
    if (-not $pinPairs.ContainsKey($key)) { $pinPairs[$key] = @{} }
    if (-not $pinPairs[$key].ContainsKey($token.sign)) { $pinPairs[$key][$token.sign] = New-Object System.Collections.Generic.List[object] }
    $pinPairs[$key][$token.sign].Add($pin)
}
foreach ($key in $pinPairs.Keys) {
    $pair = $pinPairs[$key]
    if (-not $pair.ContainsKey('P') -or -not $pair.ContainsKey('N') -or $pair['P'].Count -ne 1 -or $pair['N'].Count -ne 1) { continue }
    $positive = $pair['P'][0]; $negative = $pair['N'][0]
    if ($positive.net -eq $negative.net) { continue }
    $positiveAuto = Test-AutoNet ([string]$positive.net); $negativeAuto = Test-AutoNet ([string]$negative.net)
    $positiveName = Get-DiffToken ([string]$positive.net); $negativeName = Get-DiffToken ([string]$negative.net)
    $reason = ''
    if ($positiveAuto -or $negativeAuto) { $reason = '至少一侧仍是自动命名网络' }
    elseif ($null -ne $positiveName -or $null -ne $negativeName) {
        if ($null -eq $positiveName -or $null -eq $negativeName -or $positiveName.sign -ne 'P' -or $negativeName.sign -ne 'N' -or $positiveName.base -ne $negativeName.base) { $reason = '两侧网络名的差分后缀或基名不匹配' }
    }
    if (-not $reason) { continue }
    $part = if ($Parts.ContainsKey([string]$positive.owner_id)) { [string]$Parts[[string]$positive.owner_id].reference } else { '' }
    Add-NamingIssue 'manual_review' '差分网络命名遗漏或不匹配' ([string]$positive.page_id) $part ([string]$positive.net) ("器件=$part; 引脚=$($positive.name)/$($negative.name); 网络=$($positive.net)/$($negative.net); $reason")
}

$maxPins = [int](Get-RuleValue $NamingRule 'auto_net_max_pins' 8)
if ($maxPins -lt 2) { throw 'net_naming.auto_net_max_pins must be at least 2' }
foreach ($net in $Groups.Keys) {
    if (-not (Test-AutoNet ([string]$net))) { continue }
    $pins = @($Groups[$net] | Where-Object { $_.connected -and -not $_.no_connect } | ForEach-Object { [string]$_.owner_id + '/' + [string]$_.number } | Select-Object -Unique)
    if ($pins.Count -le $maxPins) { continue }
    $pages = @($Groups[$net] | Select-Object -ExpandProperty page_id -Unique)
    Add-NamingIssue 'manual_review' '自动命名网络连接数过多' ($pages -join ', ') '' ([string]$net) ("网络=$net; 有效引脚数=$($pins.Count); 阈值=$maxPins; page=$($pages -join ', ')")
}

return [pscustomobject]@{ issues=@($issues.ToArray()); symbols=$symbols.Count; mapped_symbols=$symbolNets.Count; aliases=$aliases.Count; differential_pairs=$pinPairs.Count; auto_net_max_pins=$maxPins }
