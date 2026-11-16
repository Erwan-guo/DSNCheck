[CmdletBinding()]
param(
    [hashtable]$Parts,
    [object]$AllPins,
    [hashtable]$Groups,
    [object]$PowerNets,
    [object]$GroundNets,
    [object]$ExtraRules
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$category = '特定芯片时钟/锁存信号处理'
$issues = New-Object System.Collections.Generic.List[object]
$coverage = New-Object System.Collections.Generic.List[object]
$pinsByPart = @{}
foreach ($pin in $AllPins) {
    $owner = [string]$pin.owner_id
    if (-not $pinsByPart.ContainsKey($owner)) { $pinsByPart[$owner] = New-Object System.Collections.Generic.List[object] }
    $pinsByPart[$owner].Add($pin)
}

function Get-Field {
    param([object]$Object, [string]$Name, [object]$Default='')
    if ($null -eq $Object -or $Object.PSObject.Properties.Name -notcontains $Name -or $null -eq $Object.$Name) { return $Default }
    return $Object.$Name
}
function Test-Connected {
    param([object]$Pin)
    return ($Pin.connected -and -not $Pin.no_connect -and $Pin.net -and $Pin.net -ne 'NULL')
}
function Add-Finding {
    param([string]$Status, [string]$Rule, [object]$Part, [object]$Pin, [string]$Details)
    $issues.Add([pscustomobject]@{
        category=$category; status=$Status; rule=$Rule; page=[string]$Part.page_id
        part=[string]$Part.reference; pin=('{0}({1})' -f $Pin.name,$Pin.number)
        net=[string]$Pin.net; details=$Details
    })
}
function Get-Ohms {
    param([string]$Text)
    $match = [regex]::Match($Text.Trim(), '^(?<whole>\d+)(?:(?:R(?<fraction>\d+))|(?<decimal>\.\d+)?\s*(?:R|OHM|Ω)?)$', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) { return $null }
    $number = $match.Groups['whole'].Value
    if ($match.Groups['fraction'].Success) { $number += '.' + $match.Groups['fraction'].Value }
    elseif ($match.Groups['decimal'].Success) { $number += $match.Groups['decimal'].Value }
    return [double]::Parse($number, [Globalization.CultureInfo]::InvariantCulture)
}
function Get-Picofarads {
    param([string]$Text)
    $match = [regex]::Match($Text.Trim(), '^(?<whole>\d+)(?:(?<embedded>P|N|U)(?<fraction>\d+)|(?<decimal>\.\d+)?\s*(?<unit>PF|NF|UF|P|N|U))$', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) { return $null }
    $number = $match.Groups['whole'].Value
    if ($match.Groups['fraction'].Success) { $number += '.' + $match.Groups['fraction'].Value }
    elseif ($match.Groups['decimal'].Success) { $number += $match.Groups['decimal'].Value }
    $value = [double]::Parse($number, [Globalization.CultureInfo]::InvariantCulture)
    $unit = if ($match.Groups['embedded'].Success) { $match.Groups['embedded'].Value } else { $match.Groups['unit'].Value }
    switch -Regex ($unit.ToUpperInvariant()) {
        '^N' { return ($value * 1000) }
        '^U' { return ($value * 1000000) }
        default { return $value }
    }
}
function Test-TargetPart {
    param([object]$Part)
    if ([string]$Part.reference -notmatch '^(?i:(?:U|IC|MN)\d+[A-Z]?)$') { return $false }
    $identity = [string]$Part.value + ' ' + [string]$Part.source_part
    return ($identity -match '(?<!\d)(?:273|373|573)(?!\d)')
}

$targets = New-Object System.Collections.Generic.List[object]
$seen = @{}
foreach ($rule in @($ExtraRules)) {
    if ($null -eq $rule) { continue }
    $partPattern = [string](Get-Field $rule 'part_pattern')
    $pinPattern = [string](Get-Field $rule 'pin_pattern')
    $seriesOhms = [double](Get-Field $rule 'series_ohms' 33)
    $shuntPf = [double](Get-Field $rule 'shunt_pf' 33)
    if (-not $partPattern -or -not $pinPattern -or $seriesOhms -le 0 -or $shuntPf -le 0) { throw 'latch_rc_filter requires part_pattern, pin_pattern and positive values' }
    $matched = 0
    foreach ($part in $Parts.Values) {
        if (($part.reference + ' ' + $part.value + ' ' + $part.source_part) -notmatch $partPattern -or -not $pinsByPart.ContainsKey([string]$part.id)) { continue }
        foreach ($pin in $pinsByPart[[string]$part.id]) {
            if ([string]$pin.name -notmatch $pinPattern) { continue }
            $matched++
            $key = [string]$part.id + '|' + [string]$pin.number
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $targets.Add([pscustomobject]@{ part=$part; pin=$pin; series_ohms=$seriesOhms; shunt_pf=$shuntPf })
        }
    }
    $name = [string](Get-Field $rule 'name' $partPattern)
    $coverage.Add([pscustomobject]@{ category=$category; rule=$name; targets=$matched })
    if ($matched -eq 0) { $issues.Add([pscustomobject]@{ category=$category; status='manual_review'; rule='规则未匹配任何目标'; page=''; part=''; pin=''; net=''; details="规则=$name" }) }
}

$automaticCount = 0
foreach ($part in $Parts.Values) {
    if (-not (Test-TargetPart $part)) { continue }
    $partPins = if ($pinsByPart.ContainsKey([string]$part.id)) { @($pinsByPart[[string]$part.id].ToArray()) } else { @() }
    $family = [regex]::Match(([string]$part.value + ' ' + [string]$part.source_part), '(?<!\d)(?<family>273|373|573)(?!\d)').Groups['family'].Value
    $pinPattern = if ($family -eq '273') { '(?i)CLK|CLOCK|(?:^|[_/\d])(?:CK|CP)(?=$|[_/\d])' } else { '(?i)LATCH|LAT|(?:^|[_/\d])LE(?=$|[_/\d])' }
    $matchingPins = @($partPins | Where-Object { [string]$_.name -match $pinPattern })
    if ($matchingPins.Count -eq 0) {
        $issues.Add([pscustomobject]@{ category=$category; status='manual_review'; rule='无法识别时钟或锁存输入引脚'; page=[string]$part.page_id; part=[string]$part.reference; pin=''; net=''; details=("器件=$($part.reference); 型号=$($part.value); 需配置 latch_rc_filter.pin_pattern") })
        continue
    }
    foreach ($pin in $matchingPins) {
        $automaticCount++
        $key = [string]$part.id + '|' + [string]$pin.number
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $targets.Add([pscustomobject]@{ part=$part; pin=$pin; series_ohms=33.0; shunt_pf=33.0 })
    }
}
$coverage.Add([pscustomobject]@{ category=$category; rule='自动识别273/373/573'; targets=$automaticCount })

foreach ($target in $targets) {
    $part = $target.part; $pin = $target.pin
    if (-not (Test-Connected $pin)) { Add-Finding 'manual_review' '时钟或锁存输入未接入有效网络' $part $pin "器件=$($part.reference); 引脚=$($pin.name)"; continue }
    $net = [string]$pin.net
    $resistorCandidates = New-Object System.Collections.Generic.List[object]
    $capacitorCandidates = New-Object System.Collections.Generic.List[object]
    $directDevices = New-Object System.Collections.Generic.List[string]
    if ($Groups.ContainsKey($net)) {
        foreach ($member in $Groups[$net]) {
            if (-not $Parts.ContainsKey([string]$member.owner_id)) { continue }
            $component = $Parts[[string]$member.owner_id]
            if ([string]$component.page_id -ne [string]$part.page_id -or -not $pinsByPart.ContainsKey([string]$component.id)) { continue }
            if ($component.id -ne $part.id -and [string]$component.reference -notmatch '^(?i:(?:R|C|L|FB|FERRITE)\d+[A-Z]?)$' -and [string]$member.pin_type -match '^(?i:1|2|output|bidirectional|bidir)$') {
                $directDevices.Add(('{0}.{1}' -f $component.reference,$member.name))
            }
            $componentPins = @($pinsByPart[[string]$component.id].ToArray() | Where-Object { Test-Connected $_ })
            if ($componentPins.Count -ne 2 -or @($componentPins | Where-Object { $_.net -eq $net }).Count -ne 1) { continue }
            $other = @($componentPins | Where-Object { $_.net -ne $net })[0]
            if ([string]$component.reference -match '^(?i:R\d+[A-Z]?)$') {
                if (-not $PowerNets.Contains([string]$other.net) -and -not $GroundNets.Contains([string]$other.net)) {
                    $resistorCandidates.Add([pscustomobject]@{ part=$component; other_net=[string]$other.net; value=(Get-Ohms ([string]$component.value)) })
                }
            } elseif ([string]$component.reference -match '^(?i:C\d+[A-Z]?)$' -and $GroundNets.Contains([string]$other.net)) {
                $capacitorCandidates.Add([pscustomobject]@{ part=$component; value=(Get-Picofarads ([string]$component.value)) })
            }
        }
    }
    $base = "器件=$($part.reference); 引脚=$($pin.name); 输入网络=$net; page=$($part.page_id)"
    if ($directDevices.Count -gt 0) {
        Add-Finding 'warning' '时钟或锁存输入存在绕过串阻的直连' $part $pin ("$base; 直连器件=$(@($directDevices | Select-Object -Unique) -join ', ')")
    }
    if ($resistorCandidates.Count -eq 0) {
        Add-Finding 'warning' '时钟或锁存输入缺少串联电阻' $part $pin "$base; 建议=$($target.series_ohms)Ω"
    } elseif ($resistorCandidates.Count -gt 1) {
        Add-Finding 'manual_review' '串阻拓扑不唯一' $part $pin ("$base; 候选电阻=$(@($resistorCandidates | ForEach-Object { $_.part.reference }) -join ', ')")
    } else {
        $resistor = $resistorCandidates[0]
        $upstreamPins = @($Groups[$resistor.other_net] | Where-Object { $_.connected -and -not $_.no_connect -and $Parts.ContainsKey([string]$_.owner_id) -and [string]$Parts[[string]$_.owner_id].reference -notmatch '^(?i:(?:R|C|L|FB|FERRITE)\d+[A-Z]?)$' })
        if ($upstreamPins.Count -eq 0) {
            Add-Finding 'manual_review' '串阻另一端未识别到信号器件引脚' $part $pin ("$base; 电阻=$($resistor.part.reference); 另一端网络=$($resistor.other_net); 若经Off-page连接需人工确认")
        }
        if ($null -eq $resistor.value) { Add-Finding 'manual_review' '串阻阻值无法解析' $part $pin ("$base; 电阻=$($resistor.part.reference); 标注=$($resistor.part.value)") }
        elseif ([Math]::Abs([double]$resistor.value - $target.series_ohms) -gt 1e-9) { Add-Finding 'warning' '时钟或锁存串阻不是建议值' $part $pin ("$base; 电阻=$($resistor.part.reference); 实际=$($resistor.value)Ω; 建议=$($target.series_ohms)Ω") }
    }
    if ($capacitorCandidates.Count -eq 0) {
        Add-Finding 'warning' '时钟或锁存输入侧缺少接地电容' $part $pin "$base; 建议=$($target.shunt_pf)pF"
    } elseif (@($capacitorCandidates | Where-Object { $null -ne $_.value -and [Math]::Abs([double]$_.value - $target.shunt_pf) -le 1e-9 }).Count -eq 0) {
        $unknown = @($capacitorCandidates | Where-Object { $null -eq $_.value })
        if ($unknown.Count -gt 0) { Add-Finding 'manual_review' '滤波电容容量无法解析' $part $pin ("$base; 电容=$(@($unknown | ForEach-Object { $_.part.reference + '=' + $_.part.value }) -join ', ')") }
        else { Add-Finding 'warning' '时钟或锁存滤波电容不是建议值' $part $pin ("$base; 电容=$(@($capacitorCandidates | ForEach-Object { $_.part.reference + '=' + $_.part.value }) -join ', '); 建议=$($target.shunt_pf)pF") }
    }
}

return [pscustomobject]@{ issues=@($issues.ToArray()); coverage=@($coverage.ToArray()); targets=$targets.Count }
