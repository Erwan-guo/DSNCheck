[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [string]$RulesFile,
    [hashtable]$Parts,
    [object]$AllPins,
    [object]$Pins,
    [hashtable]$Groups,
    [object]$PowerNets,
    [object]$GroundNets,
    [object]$PowerNetEntries
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$rules = $null
if ($RulesFile) {
    $rulePath = [IO.Path]::GetFullPath($RulesFile)
    if (-not (Test-Path -LiteralPath $rulePath -PathType Leaf)) { throw "Rules file not found: $rulePath" }
    $rules = Get-Content -LiteralPath $rulePath -Raw -Encoding UTF8 | ConvertFrom-Json
}
$issues = New-Object System.Collections.Generic.List[object]
$ruleCoverage = New-Object System.Collections.Generic.List[object]
$coverage = [ordered]@{
    '单节点网络'='automatic'; '电源管脚检查'='automatic'; '管脚悬空检查'='automatic_candidates'
    '压摆率较低器件限制'='not_configured'; '电容耐压降额检查'='automatic'; '网络命名检查'='automatic'
    'OE上拉检查'='not_configured'; 'Bus-hold器件输入管脚检查'='not_configured'; '差分管脚连接检查'='not_configured'
    '时钟信号串阻检查'='not_configured'; '复位信号上拉或下拉检查'='not_configured'; '中断信号上拉或下拉检查'='not_configured'
    '特定芯片时钟/锁存信号处理'='automatic'; 'OC/OD门上拉检查'='not_configured'; '网络上拉或下拉检查'='not_configured'
}
$newCategories = @($coverage.Keys | Where-Object { $_ -notin @('单节点网络','电源管脚检查') })

function Get-Field {
    param([object]$Object, [string]$Name, [object]$Default='')
    if ($null -eq $Object -or $Object.PSObject.Properties.Name -notcontains $Name) { return $Default }
    $value = $Object.$Name
    if ($null -eq $value) { return $Default }
    return $value
}
function Get-RuleList {
    param([string]$Name)
    $value = Get-Field $rules $Name $null
    if ($null -eq $value) { return }
    return @($value)
}
function Test-Regex {
    param([string]$Text, [string]$Pattern)
    return (-not $Pattern -or ($Text -match $Pattern))
}
function Test-ValidNet {
    param([object]$Pin)
    return ($Pin.connected -and -not $Pin.no_connect -and $Pin.net -and $Pin.net -ne 'NULL')
}
function Test-Supply {
    param([string]$Net)
    return ($Net -and $PowerNets.Contains($Net))
}
function Test-Ground {
    param([string]$Net)
    return ($Net -and $GroundNets.Contains($Net))
}
function Get-Number {
    param([string]$Text)
    $match = [regex]::Match($Text.Trim(), '(?i)^(?<whole>\d+)(?:(?<unit>R|K|M|MEG)(?<fraction>\d+)|(?<decimal>\.\d+)?\s*(?<suffix>R|K|M|MEG|OHM|Ω)?)$')
    if (-not $match.Success) { return $null }
    $number = $match.Groups['whole'].Value
    if ($match.Groups['fraction'].Success) { $number += '.' + $match.Groups['fraction'].Value }
    elseif ($match.Groups['decimal'].Success) { $number += $match.Groups['decimal'].Value }
    $n = [double]::Parse($number, [Globalization.CultureInfo]::InvariantCulture)
    $unit = if ($match.Groups['unit'].Success) { $match.Groups['unit'].Value } else { $match.Groups['suffix'].Value }
    switch ($unit.ToLowerInvariant()) { 'meg' { $n *= 1000000 }; 'm' { $n *= 1000000 }; 'k' { $n *= 1000 } }
    return $n
}
function Add-RuleCoverage {
    param([string]$Category, [object]$Rule, [int]$Targets)
    $name = [string](Get-Field $Rule 'name' '')
    if (-not $name) { $name = [string]($ruleCoverage.Count + 1) }
    $ruleCoverage.Add([pscustomobject]@{ category=$Category; rule=$name; targets=$Targets })
    if ($Targets -eq 0) {
        Add-Issue $Category 'manual_review' '规则未匹配任何目标' $null ("规则=$name; 检查匹配表达式及导出数据")
    }
}
function Add-Issue {
    param([string]$Category, [string]$Status, [string]$Rule, [object]$Pin, [string]$Details)
    $part = ''
    $page = ''
    $net = ''
    $pinText = ''
    if ($null -ne $Pin) {
        $page = [string]$Pin.page_id; $net = [string]$Pin.net
        $pinText = '{0}({1})' -f $Pin.name, $Pin.number
        if ($Parts.ContainsKey([string]$Pin.owner_id)) { $part = [string]$Parts[[string]$Pin.owner_id].reference }
    }
    $issues.Add([pscustomobject]@{ category=$Category; status=$Status; rule=$Rule; page=$page; part=$part; pin=$pinText; net=$net; details=$Details })
}

$pinsByPart = @{}
foreach ($pin in $AllPins) {
    if (-not $pinsByPart.ContainsKey($pin.owner_id)) { $pinsByPart[$pin.owner_id] = New-Object System.Collections.Generic.List[object] }
    $pinsByPart[$pin.owner_id].Add($pin)
}
$resistors = @($Parts.Values | Where-Object { $_.reference -match '^(?i:R[0-9A-Z_]*)$' })
function Find-Bias {
    param([string]$Net, [string]$Direction, [string]$RailPattern)
    $biasMatches = New-Object System.Collections.Generic.List[object]
    if (-not $Groups.ContainsKey($Net)) { return }
    foreach ($member in $Groups[$Net]) {
        if (-not $Parts.ContainsKey($member.owner_id)) { continue }
        $part = $Parts[$member.owner_id]
        if ($part.reference -notmatch '^(?i:R[0-9A-Z_]*)$') { continue }
        foreach ($other in $pinsByPart[$part.id]) {
            if (-not (Test-ValidNet $other) -or $other.net -eq $Net) { continue }
            $ok = if ($Direction -eq 'up') { Test-Supply $other.net } else { Test-Ground $other.net }
            if ($ok -and (Test-Regex $other.net $RailPattern)) {
                $biasMatches.Add([pscustomobject]@{ part=$part; rail=$other.net; ohms=(Get-Number $part.value) })
            }
        }
    }
    return $biasMatches.ToArray()
}
function Find-RailResistor {
    param([string]$Net, [string]$RailKind)
    $railMatches = New-Object System.Collections.Generic.List[object]
    if (-not $Groups.ContainsKey($Net)) { return $railMatches.ToArray() }
    foreach ($member in $Groups[$Net]) {
        if (-not $Parts.ContainsKey([string]$member.owner_id)) { continue }
        $part = $Parts[[string]$member.owner_id]
        if ($part.reference -notmatch '^(?i:R[0-9A-Z_]*)$' -or -not $pinsByPart.ContainsKey($part.id)) { continue }
        foreach ($other in $pinsByPart[$part.id]) {
            if (-not (Test-ValidNet $other) -or [string]$other.net -eq $Net) { continue }
            $isRail = if ($RailKind -eq 'ground') { Test-Ground ([string]$other.net) } else { Test-Supply ([string]$other.net) }
            if ($isRail) {
                $railMatches.Add([pscustomobject]@{ part=$part; rail=[string]$other.net; ohms=(Get-Number ([string]$part.value)) })
            }
        }
    }
    return $railMatches.ToArray()
}
function Get-OEInactiveDirection {
    param([string]$PinName)
    $name = $PinName.Trim()
    $activeLow = $false
    if ($name.StartsWith('/')) { $activeLow = $true; $name = $name.Substring(1) }
    if ($name.EndsWith('#') -or $name.EndsWith('/')) { $activeLow = $true; $name = $name.Substring(0, $name.Length - 1) }
    if ($name -match '(?i)_N$') { $activeLow = $true; $name = $name.Substring(0, $name.Length - 2) }
    if ($name.Contains('\')) { $activeLow = $true; $name = $name.Replace('\', '') }
    if ($name -notmatch '(?i)OE|OUTPUT_ENABLE') { return '' }
    if ($name -match '(?i)OE/[^/]+|[^/]+/OE') { return '' }
    return $(if ($activeLow) { 'up' } else { 'down' })
}
function Get-ResetInactiveDirection {
    param([string]$Name)
    $text = $Name.Trim()
    $activeLow = $false
    if ($text.StartsWith('/')) { $activeLow = $true; $text = $text.Substring(1) }
    if ($text.EndsWith('#') -or $text.EndsWith('/')) { $activeLow = $true; $text = $text.Substring(0, $text.Length - 1) }
    if ($text.Contains('\')) { $activeLow = $true; $text = $text.Replace('\', '') }
    if ($text -notmatch '(?i)RST|(?<!P)RESET') { return '' }
    if ($text -match '(?i)(?:RST|RESET)_?N|N(?:RST|RESET)') { return 'up' }
    return $(if ($activeLow) { 'up' } else { 'down' })
}
function Test-ControlFunctionalPin {
    param([object]$Pin)
    if (-not $Parts.ContainsKey([string]$Pin.owner_id)) { return $false }
    $reference = [string]$Parts[[string]$Pin.owner_id].reference
    if ($reference -match '^(?i:TX|TP)' -or $reference -match '^(?i:(?:XS|XP|J|P)\d)' -or $reference -match '^(?i:(?:R|C|L|FB|FERRITE)\d+[A-Z]?)$') { return $false }
    return $true
}
function Test-ExplicitResetPolarity {
    param([string]$Name)
    $text = $Name.Trim()
    return ($text.StartsWith('/') -or $text.EndsWith('/') -or $text.EndsWith('#') -or $text.Contains('\') -or $text -match '(?i)(?:RST|RESET)_?N|N(?:RST|RESET)')
}
function Test-ExplicitControlPolarity {
    param([string]$Name)
    $text = $Name.Trim()
    return ($text.StartsWith('/') -or $text.EndsWith('/') -or $text.EndsWith('#') -or $text.Contains('\') -or
        $text -match '(?i)(?:^|[_-])(?:N|L|H)(?:$|[_-])|(?:RST|RESET|OE|IRQ|INTR|INT)N(?:$|[_-])|N(?:RST|RESET|OE|IRQ|INTR|INT)')
}
function Test-ResetCandidate {
    param([object]$Pin)
    if (-not (Test-ControlFunctionalPin $Pin)) { return $false }
    return ([bool](Get-ResetInactiveDirection ([string]$Pin.name)) -or [bool](Get-ResetInactiveDirection ([string]$Pin.net)))
}
function Test-OECandidate {
    param([object]$Pin)
    return ((Test-ControlFunctionalPin $Pin) -and [bool](Get-OEInactiveDirection ([string]$Pin.name)))
}
function Get-InterruptInactiveDirection {
    param([string]$Name)
    $text = $Name.Trim()
    $activeLow = $false
    if ($text.StartsWith('/')) { $activeLow = $true; $text = $text.Substring(1) }
    if ($text.EndsWith('#') -or $text.EndsWith('/')) { $activeLow = $true; $text = $text.Substring(0, $text.Length - 1) }
    if ($text.Contains('\')) { $activeLow = $true; $text = $text.Replace('\', '') }
    if ($text -notmatch '(?i)IRQ|INTR|(?:^|[_/\-\d])N?INT(?=$|[_/\-\dN])') { return '' }
    if ($text -match '(?i)N(?:IRQ|INTR|INT)' -or $text -match '(?i)(?:IRQ|INTR|INT)(?:\d+)?N(?:$|[_/-])' -or $text -match '(?i)[_-]N$') { $activeLow = $true }
    return $(if ($activeLow) { 'up' } else { 'down' })
}
function Test-InterruptCandidate {
    param([object]$Pin)
    if (-not $Parts.ContainsKey([string]$Pin.owner_id)) { return $false }
    $reference = [string]$Parts[[string]$Pin.owner_id].reference
    if ($reference -match '^(?i:(?:R|C|L|FB|FERRITE)\d+[A-Z]?)$') { return $false }
    return ([bool](Get-InterruptInactiveDirection ([string]$Pin.name)) -or [bool](Get-InterruptInactiveDirection ([string]$Pin.net)))
}
function Test-OCODPin {
    param([object]$Pin)
    if (-not $Parts.ContainsKey([string]$Pin.owner_id)) { return $false }
    $reference = [string]$Parts[[string]$Pin.owner_id].reference
    if ($reference -match '^(?i:(?:Q|R|C|L|FB|J|P|TP)\d+[A-Z]?)$') { return $false }
    if ($reference -match '^(?i:D\d+[A-Z]?)$' -and $pinsByPart[[string]$Pin.owner_id].Count -le 2) { return $false }
    $type = ([string]$Pin.pin_type).Trim()
    return ($type -eq '3' -or $type -match '^(?i:open[ _-]?(?:collector|drain))$')
}
function Get-SignalPinRole {
    param([object]$Pin)
    if (-not $Parts.ContainsKey([string]$Pin.owner_id)) { return 'unknown' }
    $reference = [string]$Parts[[string]$Pin.owner_id].reference
    if ($reference -match '^(?i:(?:R|C|L|FB|TP)\d+[A-Z]?)$') { return 'auxiliary' }
    if ($reference -match '^(?i:D\d+[A-Z]?)$' -and $pinsByPart[[string]$Pin.owner_id].Count -le 2) { return 'auxiliary' }
    if ($reference -match '^(?i:(?:J|P|Q)\d+[A-Z]?)$') { return 'unknown' }
    $type = ([string]$Pin.pin_type).Trim()
    if ($type -match '^(?i:0|input)$') { return 'receiver' }
    if ($type -match '^(?i:1|output)$' -or (Test-OCODPin $Pin)) { return 'driver' }
    return 'unknown'
}
function Find-OEDrivers {
    param([object]$OEPin, [object]$Rule)
    $driverMatches = New-Object System.Collections.Generic.List[object]
    $pattern = [string](Get-Field $Rule 'driver_part_pattern' '^(?i:(?:U|IC|MN)\d+[A-Z]?)$')
    $maxSeriesOhms = [double](Get-Field $Rule 'max_series_ohms' 100)
    if (-not $pattern -or $maxSeriesOhms -lt 0) { throw 'OE rule needs a driver_part_pattern and nonnegative max_series_ohms' }
    $candidateNets = New-Object System.Collections.Generic.List[object]
    $candidateNets.Add([pscustomobject]@{ net=[string]$OEPin.net; via_series=$false; resistor='' })
    if ($Groups.ContainsKey([string]$OEPin.net)) {
        foreach ($member in $Groups[[string]$OEPin.net]) {
            if (-not $Parts.ContainsKey([string]$member.owner_id)) { continue }
            $resistor = $Parts[[string]$member.owner_id]
            if ($resistor.reference -notmatch '^(?i:R[0-9A-Z_]*)$' -or -not $pinsByPart.ContainsKey($resistor.id)) { continue }
            $ohms = Get-Number ([string]$resistor.value)
            if ($null -eq $ohms -or $ohms -gt $maxSeriesOhms) { continue }
            $resistorPins = @($pinsByPart[$resistor.id].ToArray() | Where-Object { Test-ValidNet $_ })
            if ($resistorPins.Count -ne 2) { continue }
            $other = @($resistorPins | Where-Object { $_.net -ne $OEPin.net })
            if ($other.Count -ne 1 -or (Test-Supply $other[0].net) -or (Test-Ground $other[0].net)) { continue }
            $candidateNets.Add([pscustomobject]@{ net=[string]$other[0].net; via_series=$true; resistor=[string]$resistor.reference })
        }
    }
    foreach ($candidate in $candidateNets) {
        if (-not $Groups.ContainsKey($candidate.net)) { continue }
        foreach ($otherPin in $Groups[$candidate.net]) {
            if ($otherPin.owner_id -eq $OEPin.owner_id -or -not (Test-ValidNet $otherPin) -or -not $Parts.ContainsKey([string]$otherPin.owner_id)) { continue }
            $part = $Parts[[string]$otherPin.owner_id]
            if ([string]$part.reference -notmatch $pattern -or [string]$otherPin.pin_type -eq '7') { continue }
            if ([string]$otherPin.name -match '(?i)VDD|VCC|VSS|GND') { continue }
            $type = [string]$otherPin.pin_type
            $outputType = $type -match '^(?i:1|2|output|bidirectional|bidir|open.?collector|open.?drain)$'
            $driverMatches.Add([pscustomobject]@{ part=$part; pin=$otherPin; net=$candidate.net; via_series=$candidate.via_series; resistor=$candidate.resistor; output_type=$outputType })
        }
    }
    return $driverMatches.ToArray()
}
function Select-RulePins {
    param([object]$Rule)
    $selected = New-Object System.Collections.Generic.List[object]
    $partPattern = [string](Get-Field $Rule 'part_pattern')
    $pinPattern = [string](Get-Field $Rule 'pin_pattern')
    $netPattern = [string](Get-Field $Rule 'net_pattern')
    foreach ($pin in $AllPins) {
        if (-not $Parts.ContainsKey($pin.owner_id)) { continue }
        $part = $Parts[$pin.owner_id]
        $identity = $part.reference + ' ' + $part.value + ' ' + $part.source_part
        $pinName = [string]$pin.name
        if ([string](Get-Field $Rule 'category') -eq 'OE上拉检查') { $pinName = $pinName.Replace('\', '') }
        if ((Test-Regex $identity $partPattern) -and (Test-Regex $pinName $pinPattern) -and (Test-Regex ([string]$pin.net) $netPattern)) { $selected.Add($pin) }
    }
    return $selected.ToArray()
}

# An unconnected, unmarked input is a review candidate. The symbol's pin type
# alone cannot establish that the input is required in every operating mode.
foreach ($pin in $AllPins) {
    if ($pin.pin_type -eq '0' -and -not $pin.no_connect -and -not (Test-ValidNet $pin)) {
        Add-Issue '管脚悬空检查' 'manual_review' '输入引脚无有效连接且未标注No Connect' $pin '需根据器件手册确认该输入能否悬空，或补充有效偏置/连接。'
    }
}

$properties = @{}
$propertiesPath = Join-Path $OutputDirectory 'dbo\properties.jsonl'
if (Test-Path -LiteralPath $propertiesPath -PathType Leaf) {
    foreach ($line in [IO.File]::ReadLines($propertiesPath)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $record = $line | ConvertFrom-Json } catch { continue }
        if ($record.record -notin @('user_property','display_property')) { continue }
        $owner = [string]$record.owner_id
        if (-not $properties.ContainsKey($owner)) { $properties[$owner] = @{} }
        $name = [string]$record.name; $value = [string]$record.value
        if (-not $name -or -not $value) { continue }
        if (-not $properties[$owner].ContainsKey($name) -or $record.record -eq 'user_property') { $properties[$owner][$name] = $value }
    }
}

$naming = Get-Field $rules 'net_naming' $null
if ($null -ne $naming) {
    $coverage['网络命名检查'] = 'configured'
    $required = [string](Get-Field $naming 'required_pattern')
    $excluded = [string](Get-Field $naming 'exclude_pattern' '^(?i:N\d+|NULL)$')
    if ($required) {
        $namingTargets = 0
        foreach ($net in ($Groups.Keys | Sort-Object)) {
            if ($net -match $excluded) { continue }
            $namingTargets++
            if ($net -notmatch $required) { Add-Issue '网络命名检查' 'error' '网络名称不符合项目命名规则' $null ("网络=$net") }
        }
        Add-RuleCoverage '网络命名检查' $naming $namingTargets
    }
}
$namingResult = & (Join-Path $PSScriptRoot 'Invoke-DSNCheck-Naming.ps1') -OutputDirectory $OutputDirectory -Parts $Parts -AllPins $AllPins -Groups $Groups -NamingRule $naming
foreach ($issue in $namingResult.issues) { $issues.Add($issue) }
$ruleCoverage.Add([pscustomobject]@{ category='网络命名检查'; rule='符号与差分/自动网络'; targets=($namingResult.symbols + $namingResult.aliases + $namingResult.differential_pairs) })

foreach ($net in ($Groups.Keys | Sort-Object)) {
    if ((Test-Supply ([string]$net)) -or (Test-Ground ([string]$net)) -or (Test-ExplicitControlPolarity ([string]$net))) { continue }
    $markedPins = New-Object System.Collections.Generic.List[string]
    $anchor = $null
    foreach ($pin in $Groups[$net]) {
        if (-not (Test-ValidNet $pin) -or -not (Test-ControlFunctionalPin $pin)) { continue }
        $name = [string]$pin.name
        if (-not (Test-ExplicitControlPolarity $name)) { continue }
        $kind = ''
        $bias = Get-ResetInactiveDirection $name
        if ($bias) { $kind = 'RESET' }
        else {
            $bias = Get-OEInactiveDirection $name
            if ($bias) { $kind = 'OE' }
            else {
                $bias = Get-InterruptInactiveDirection $name
                if ($bias) { $kind = 'IRQ/INT' }
            }
        }
        if (-not $kind) { continue }
        if ($null -eq $anchor) { $anchor = $pin }
        $reference = [string]$Parts[[string]$pin.owner_id].reference
        $markedPins.Add("$reference.$name($kind; 默认方向=$bias)")
    }
    if ($markedPins.Count -eq 0) { continue }
    Add-Issue '网络命名检查' 'manual_review' '控制网络名称缺少有效电平标记' $anchor ("网络=$net; 引脚=$(@($markedPins | Select-Object -Unique) -join ', '); 建议在网络名标注有效电平")
}

function Get-AttributeVoltage {
    param([string]$Text)
    $values = @(Get-EmbeddedAttributeVoltages $Text | Select-Object -Unique)
    if ($values.Count -ne 1) { return $null }
    return [double]$values[0]
}
function Get-EmbeddedAttributeVoltages {
    param([string]$Text)
    $values = New-Object System.Collections.Generic.List[double]
    $pattern = '(?i)(?<!\d)(?<whole>\d+)(?:\.(?<decimal>\d+))?\s*V(?<fraction>\d+)?'
    foreach ($match in [regex]::Matches($Text, $pattern)) {
        $number = 0.0
        $numberText = $match.Groups['whole'].Value
        if ($match.Groups['decimal'].Success) { $numberText += '.' + $match.Groups['decimal'].Value }
        elseif ($match.Groups['fraction'].Success) { $numberText += '.' + $match.Groups['fraction'].Value }
        if ([double]::TryParse($numberText, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -and $number -gt 0) {
            $values.Add($number)
        }
    }
    return $values.ToArray()
}
function Get-PinPolarity {
    param([object]$Pin)
    $name = ([string]$Pin.name).Trim()
    if ($name -match '(?i)POS|PLUS|ANODE') { return 'positive' }
    if ($name -match '(?i)NEG|MINUS|CATHODE') { return 'negative' }
    if ($name -match '^(?i:P|POS|PLUS|\+|ANODE)$') { return 'positive' }
    if ($name -match '^(?i:N|NEG|MINUS|-|CATHODE)$') { return 'negative' }
    return ''
}
$netVoltages = @{}
foreach ($entry in @($PowerNetEntries)) {
    if ($null -eq $entry) { continue }
    $net = [string](Get-Field $entry 'net')
    if (-not $net) { continue }
    if ([string](Get-Field $entry 'kind') -eq 'ground') { $netVoltages[$net] = 0.0; continue }
    if ([string](Get-Field $entry 'kind') -ne 'power') { continue }
    $text = [string](Get-Field $entry 'voltage_v')
    $voltage = 0.0
    if ($text -and [double]::TryParse($text, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$voltage) -and $voltage -ne 0) { $netVoltages[$net] = $voltage }
}
$capCount = 0
foreach ($part in @($Parts.Values | Where-Object { $_.reference -match '^(?i:C[0-9A-Z_]*)$' })) {
    $capCount++
    $partProperties = if ($properties.ContainsKey($part.id)) { $properties[$part.id] } else { @{} }
    $tokens = New-Object System.Collections.Generic.List[string]
    foreach ($value in @([string]$part.value, [string]$part.source_part)) {
        if ($value -match '(?i)cap_polar') { $tokens.Add('cap_polar') }
        elseif ($value -match '(?i)cap') { $tokens.Add('cap') }
    }
    foreach ($key in $partProperties.Keys) {
        $value = [string]$partProperties[$key]
        if ($value -match '(?i)cap_polar') { $tokens.Add('cap_polar') }
        elseif ($value -match '(?i)cap') { $tokens.Add('cap') }
    }
    $types = @($tokens | Select-Object -Unique)
    $capPins = if ($pinsByPart.ContainsKey($part.id)) { @($pinsByPart[$part.id].ToArray()) } else { @() }
    $anchor = if ($capPins.Count -gt 0) { $capPins[0] } else { $null }
    if ($types.Count -ne 1) {
        Add-Issue '电容耐压降额检查' 'manual_review' '电容极性类型无法识别' $anchor ("器件=$($part.reference); cap/cap_polar 标记缺失或冲突")
        continue
    }
    $ratedCandidates = New-Object System.Collections.Generic.List[object]
    $dedicatedKeys = @('Rated Voltage','Voltage Rating','RatedVoltage','VoltageRating')
    foreach ($key in $dedicatedKeys) {
        if (-not $partProperties.ContainsKey($key)) { continue }
        $rating = Get-AttributeVoltage ([string]$partProperties[$key])
        if ($null -ne $rating) { $ratedCandidates.Add([pscustomobject]@{ value=$rating; source=$key }) }
    }
    foreach ($key in $partProperties.Keys) {
        if ($key -notmatch '(?i)^(?:Description|Desc|Part Description|PartDescription)$') { continue }
        foreach ($rating in @(Get-EmbeddedAttributeVoltages ([string]$partProperties[$key]))) {
            $ratedCandidates.Add([pscustomobject]@{ value=[double]$rating; source=$key })
        }
    }
    if ($ratedCandidates.Count -eq 0) {
        foreach ($key in $partProperties.Keys) {
            if ($key -in $dedicatedKeys -or $key -match '(?i:operat|working|applied|external|supply|voltage_v)') { continue }
            $rating = Get-AttributeVoltage ([string]$partProperties[$key])
            if ($null -ne $rating) { $ratedCandidates.Add([pscustomobject]@{ value=$rating; source=$key }) }
        }
    }
    $ratings = @($ratedCandidates | ForEach-Object { $_.value } | Select-Object -Unique)
    $ratingSources = @($ratedCandidates | ForEach-Object { $_.source } | Select-Object -Unique) -join ', '
    $voltageReasons = New-Object System.Collections.Generic.List[string]
    if ($ratings.Count -ne 1) { $voltageReasons.Add('本体耐压属性缺失、不可解析或数值冲突') }
    $externalKnown = $false
    if ($capPins.Count -ne 2 -or @($capPins | Where-Object { -not (Test-ValidNet $_) }).Count -gt 0) {
        $voltageReasons.Add('未找到两个有效连接的电容引脚')
    } elseif (-not $netVoltages.ContainsKey([string]$capPins[0].net) -or -not $netVoltages.ContainsKey([string]$capPins[1].net)) {
        $voltageReasons.Add('至少一个端点网络缺少已确认的电位值')
    } else {
        $externalKnown = $true
    }
    if ($types[0] -eq 'cap_polar' -and $externalKnown) {
        $positivePins = @($capPins | Where-Object { (Get-PinPolarity $_) -eq 'positive' })
        $negativePins = @($capPins | Where-Object { (Get-PinPolarity $_) -eq 'negative' })
        if ($positivePins.Count -ne 1 -or $negativePins.Count -ne 1) {
            Add-Issue '电容耐压降额检查' 'manual_review' '极性电容引脚极性无法识别' $anchor ("器件=$($part.reference); 需要正负引脚名 P/N、POS/NEG 或 +/-")
        } elseif ([double]$netVoltages[[string]$positivePins[0].net] + 1e-9 -lt [double]$netVoltages[[string]$negativePins[0].net]) {
            Add-Issue '电容耐压降额检查' 'error' '极性电容外部电压极性错误' $positivePins[0] ("器件=$($part.reference); 正端=$($positivePins[0].net):$($netVoltages[[string]$positivePins[0].net])V; 负端=$($negativePins[0].net):$($netVoltages[[string]$negativePins[0].net])V")
        }
    }
    if ($voltageReasons.Count -gt 0) {
        $ratingText = if ($ratings.Count -eq 1) { "; 本体耐压=$($ratings[0])V" } else { '' }
        $sourceText = if ($ratingSources) { "; 本体耐压来源=$ratingSources" } else { '' }
        $voltageRule = '无法识别本体耐压、外部电压的电容'
        if ($ratings.Count -eq 1 -and $voltageReasons -contains '至少一个端点网络缺少已确认的电位值') {
            $voltageRule = '外部电压无法确认'
        } elseif ($ratings.Count -eq 1 -and $voltageReasons -contains '未找到两个有效连接的电容引脚') {
            $voltageRule = '电容端点连接无法确认'
        } elseif ($ratings.Count -ne 1 -and $externalKnown) {
            $voltageRule = '本体耐压无法确认'
        }
        Add-Issue '电容耐压降额检查' 'manual_review' $voltageRule $anchor ("器件=$($part.reference); $($voltageReasons -join '; ')$ratingText$sourceText")
        continue
    }
    $rated = [double]$ratings[0]
    $potentialA = [double]$netVoltages[[string]$capPins[0].net]
    $potentialB = [double]$netVoltages[[string]$capPins[1].net]
    $applied = [Math]::Abs($potentialA - $potentialB)
    $details = "器件=$($part.reference); 两端=$($capPins[0].net):${potentialA}V/$($capPins[1].net):${potentialB}V; 外部电压=${applied}V; 本体耐压=${rated}V"
    if ($types[0] -eq 'cap') {
        foreach ($level in @(@('一级',0.5), @('二级',0.6), @('三级',0.7))) {
            $ratio = [double]$level[1]
            if ($applied -gt $rated * $ratio + 1e-9) {
                $percent = [int]($ratio * 100)
                Add-Issue '电容耐压降额检查' 'error' ("非极性电容不满足{0}%耐压降额等级（{1}）" -f $percent,$level[0]) $anchor $details
            }
        }
        continue
    }
    if ($rated + 1e-9 -lt 3 * $applied) { Add-Issue '电容耐压降额检查' 'error' '极性电容不满足三倍耐压' $anchor $details }
}
$ruleCoverage.Add([pscustomobject]@{ category='电容耐压降额检查'; rule='全部电容'; targets=$capCount })

$slowRules = @(Get-RuleList 'slow_slew')
if ($slowRules.Count -gt 0) { $coverage['压摆率较低器件限制'] = 'configured' }
foreach ($rule in $slowRules) {
    $targets = @(Select-RulePins $rule)
    Add-RuleCoverage '压摆率较低器件限制' $rule $targets.Count
    foreach ($pin in $targets) {
        if (-not (Test-ValidNet $pin)) { continue }
        $maxRise = [double](Get-Field $rule 'max_rise_ns' 0)
        $actualRise = [double](Get-Field $rule 'rise_ns' 0)
        if ($maxRise -le 0 -or $actualRise -le 0) { Add-Issue '压摆率较低器件限制' 'manual_review' '缺少器件输出边沿或接收端上升时间规格' $pin '需从器件手册或实测取得rise_ns与max_rise_ns。' }
        elseif ($actualRise -gt $maxRise) { Add-Issue '压摆率较低器件限制' 'error' '输出边沿慢于接收端限制' $pin ("rise_ns=$actualRise; max_rise_ns=$maxRise") }
    }
}

$biasRules = @(Get-RuleList 'bias_rules')
$biasRules += [pscustomobject]@{ name='自动识别OE引脚'; category='OE上拉检查'; automatic_oe=$true }
$biasRules += [pscustomobject]@{ name='自动识别复位网络'; category='复位信号上拉或下拉检查'; automatic_reset=$true }
$biasRules += [pscustomobject]@{ name='自动识别中断网络'; category='中断信号上拉或下拉检查'; automatic_interrupt=$true }
if (@($biasRules | Where-Object { [string](Get-Field $_ 'category') -eq 'OC/OD门上拉检查' }).Count -eq 0) {
    $biasRules += [pscustomobject]@{ name='自动识别OC/OD引脚'; category='OC/OD门上拉检查'; direction='up'; automatic_ocod=$true }
}
$biasCategories = @('OE上拉检查','复位信号上拉或下拉检查','中断信号上拉或下拉检查','OC/OD门上拉检查','网络上拉或下拉检查')
$checkedResetNets = @{}
$checkedInterruptNets = @{}
$checkedOENets = @{}
$configuredOENets = @{}
foreach ($rule in $biasRules) {
    $category = [string](Get-Field $rule 'category')
    if ($category -notin $biasCategories) { throw "Unsupported bias category: $category" }
    $direction = [string](Get-Field $rule 'direction')
    if ($direction -and $direction -notin @('up','down')) { throw "Invalid bias direction for $category" }
    if ($category -eq 'OC/OD门上拉检查' -and $direction -ne 'up') { throw 'OC/OD bias direction must be up' }
    if ($category -notin @('OE上拉检查','复位信号上拉或下拉检查','中断信号上拉或下拉检查') -and -not $direction) { throw "Invalid bias direction for $category" }
    $automaticReset = [bool](Get-Field $rule 'automatic_reset' $false)
    $automaticOE = [bool](Get-Field $rule 'automatic_oe' $false)
    $automaticInterrupt = [bool](Get-Field $rule 'automatic_interrupt' $false)
    $automaticOCOD = [bool](Get-Field $rule 'automatic_ocod' $false)
    if ($automaticOE) {
        if ($coverage[$category] -eq 'not_configured') { $coverage[$category] = 'automatic' }
        $targets = @($AllPins | Where-Object { (Test-OECandidate $_) -and -not $configuredOENets.ContainsKey([string]$_.net) })
        $ruleCoverage.Add([pscustomobject]@{ category=$category; rule='自动识别OE引脚'; targets=$targets.Count })
    } elseif ($automaticReset) {
        if ($coverage[$category] -eq 'not_configured') { $coverage[$category] = 'automatic' }
        $targets = @($AllPins | Where-Object { Test-ResetCandidate $_ })
        $ruleCoverage.Add([pscustomobject]@{ category=$category; rule='自动识别复位网络'; targets=$targets.Count })
    } elseif ($automaticInterrupt) {
        if ($coverage[$category] -eq 'not_configured') { $coverage[$category] = 'automatic_candidates' }
        $targets = @($AllPins | Where-Object { Test-InterruptCandidate $_ })
        $ruleCoverage.Add([pscustomobject]@{ category=$category; rule='自动识别中断网络'; targets=$targets.Count })
    } elseif ($automaticOCOD) {
        $coverage[$category] = 'automatic'
        $targets = @($AllPins | Where-Object { Test-OCODPin $_ })
        $ruleCoverage.Add([pscustomobject]@{ category=$category; rule='自动识别OC/OD引脚'; targets=$targets.Count })
    } else {
        $coverage[$category] = 'configured'
        $targets = @(Select-RulePins $rule)
        if ($category -eq 'OE上拉检查') {
            foreach ($target in $targets) { $configuredOENets[[string]$target.net] = $true }
        }
        if ($category -eq 'OC/OD门上拉检查') { $targets = @($targets | Where-Object { Test-OCODPin $_ }) }
        Add-RuleCoverage $category $rule $targets.Count
    }
    foreach ($pin in $targets) {
        if ($automaticOE -and $pin.net -and $pin.net -ne 'NULL') {
            if ($checkedOENets.ContainsKey([string]$pin.net)) { continue }
            $checkedOENets[[string]$pin.net] = $true
        }
        if ($category -eq '复位信号上拉或下拉检查') {
            $resetKey = if ($pin.net -and $pin.net -ne 'NULL') { [string]$pin.net } else { [string]$pin.owner_id + '/' + [string]$pin.number }
            if ($checkedResetNets.ContainsKey($resetKey)) { continue }
            $checkedResetNets[$resetKey] = $true
        }
        if ($category -eq '中断信号上拉或下拉检查') {
            $interruptKey = if ($pin.net -and $pin.net -ne 'NULL') { [string]$pin.net } else { [string]$pin.owner_id + '/' + [string]$pin.number }
            if ($checkedInterruptNets.ContainsKey($interruptKey)) { continue }
            $checkedInterruptNets[$interruptKey] = $true
        }
        if (-not (Test-ValidNet $pin)) { Add-Issue $category 'error' '目标引脚未接入有效网络' $pin '无法检查默认电平。'; continue }
        $requiredDirection = $direction
        $drivers = @()
        $driverConfirmed = $true
        $interruptModeUnconfirmed = $false
        $railPattern = [string](Get-Field $rule 'rail_pattern')
        if ($category -eq '复位信号上拉或下拉检查') {
            $namedPins = @($AllPins | Where-Object { $_.net -eq $pin.net -and (Test-ControlFunctionalPin $_) -and (Get-ResetInactiveDirection ([string]$_.name)) })
            $polarities = @($namedPins | ForEach-Object { Get-ResetInactiveDirection ([string]$_.name) } | Select-Object -Unique)
            if ($polarities.Count -gt 1) {
                Add-Issue $category 'manual_review' '同一复位网络的有效电平标记冲突' $pin ("网络=$($pin.net); 引脚=$(@($namedPins | ForEach-Object { $_.name } | Select-Object -Unique) -join ', ')")
                continue
            }
            $inferredDirection = if ($polarities.Count -eq 1) { [string]$polarities[0] } else { Get-ResetInactiveDirection ([string]$pin.net) }
            if (-not $inferredDirection) { Add-Issue $category 'manual_review' '无法从复位名称判断有效电平' $pin ("引脚=$($pin.name); 网络=$($pin.net)"); continue }
            $netDirection = Get-ResetInactiveDirection ([string]$pin.net)
            if ($netDirection -and (Test-ExplicitResetPolarity ([string]$pin.net)) -and $netDirection -ne $inferredDirection) {
                Add-Issue $category 'manual_review' '复位引脚与网络名的有效电平标记不一致' $pin ("引脚方向=$inferredDirection; 网络名方向=$netDirection; 本次按引脚名检查")
            }
            if ($direction -and $direction -ne $inferredDirection) {
                Add-Issue $category 'manual_review' '规则偏置方向与复位名称不一致' $pin ("配置=$direction; 按名称应为=$inferredDirection; 本次按名称检查")
            }
            $requiredDirection = $inferredDirection
            if ($requiredDirection -eq 'down') { $railPattern = '' }
        }
        if ($category -eq '中断信号上拉或下拉检查') {
            $namedPins = @($AllPins | Where-Object { $_.net -eq $pin.net -and (Get-InterruptInactiveDirection ([string]$_.name)) })
            $polarities = @($namedPins | ForEach-Object { Get-InterruptInactiveDirection ([string]$_.name) } | Select-Object -Unique)
            if ($polarities.Count -gt 1) {
                Add-Issue $category 'manual_review' '同一中断网络的有效电平标记冲突' $pin ("网络=$($pin.net); 引脚=$(@($namedPins | ForEach-Object { $_.name } | Select-Object -Unique) -join ', ')")
                continue
            }
            $inferredDirection = if ($polarities.Count -eq 1) { [string]$polarities[0] } else { Get-InterruptInactiveDirection ([string]$pin.net) }
            if (-not $inferredDirection) { Add-Issue $category 'manual_review' '无法从中断名称判断有效电平' $pin ("引脚=$($pin.name); 网络=$($pin.net)"); continue }
            $netDirection = Get-InterruptInactiveDirection ([string]$pin.net)
            if ($netDirection -and $netDirection -ne $inferredDirection) {
                Add-Issue $category 'manual_review' '中断引脚与网络名的有效电平标记不一致' $pin ("引脚方向=$inferredDirection; 网络名方向=$netDirection; 本次按引脚名检查")
            }
            if ($direction -and $direction -ne $inferredDirection) {
                Add-Issue $category 'manual_review' '规则偏置方向与中断名称不一致' $pin ("配置=$direction; 按名称应为=$inferredDirection; 本次按名称检查")
            }
            $requiredDirection = $inferredDirection
            if ($requiredDirection -eq 'down') { $railPattern = '' }
            if ([string]$pin.name -match '.+/.+') {
                $interruptModeUnconfirmed = $true
                Add-Issue $category 'manual_review' '复用中断引脚功能未确认' $pin ("引脚=$($pin.name); 需确认器件实际启用IRQ/INT功能")
            }
        }
        if ($category -eq 'OE上拉检查') {
            $inferredDirection = Get-OEInactiveDirection ([string]$pin.name)
            if (-not $inferredDirection) { Add-Issue $category 'manual_review' '无法从OE引脚名判断有效电平' $pin '仅识别 /OE、Cadence反斜杠上划线、OE_N、OE# 或普通OE；复用功能名需人工确认。'; continue }
            if ($direction -and $direction -ne $inferredDirection) { Add-Issue $category 'manual_review' '规则偏置方向与OE命名不一致' $pin ("配置=$direction; 按引脚名应为=$inferredDirection; 本次按引脚名检查") }
            $requiredDirection = $inferredDirection
            if ((Test-Supply ([string]$pin.net)) -or (Test-Ground ([string]$pin.net))) {
                $railKind = if (Test-Ground ([string]$pin.net)) { '地' } else { '电源' }
                Add-Issue $category 'error' 'OE直接连接电源/地，未通过偏置电阻' $pin ("网络=$($pin.net); 需要=$requiredDirection; OE不能直接连接$railKind，应通过电阻连接到相应电源/地")
                continue
            }
            $staticRailKind = if ($requiredDirection -eq 'up') { 'ground' } else { 'power' }
            $staticRail = @(Find-RailResistor ([string]$pin.net) $staticRailKind)
            if ($staticRail.Count -gt 0) {
                Add-Issue $category 'manual_review' 'OE通过电阻永久拉到有效电平' $pin ("电阻=$(@($staticRail | ForEach-Object { $_.part.reference }) -join ', '); 连接=$($staticRailKind); 需确认该OE允许永久保持有效，以及电阻值满足限流要求")
                continue
            }
            if (-not $automaticOE) {
                $drivers = @(Find-OEDrivers $pin $rule)
                if ($drivers.Count -eq 0) { Add-Issue $category 'manual_review' '未识别到其他芯片驱动OE' $pin '仅处理其他芯片直连或经单个限值内串阻驱动的OE；需确认器件位号模式和引脚连接。'; continue }
                $driverConfirmed = @($drivers | Where-Object { $_.output_type }).Count -gt 0
                if (-not $driverConfirmed) { Add-Issue $category 'manual_review' '外部芯片引脚驱动方向未确认' $pin ("连接引脚=$(@($drivers | ForEach-Object { $_.part.reference + '.' + $_.pin.name }) -join ', '); 需核对器件库引脚类型") }
            }
            if ($requiredDirection -eq 'down') { $railPattern = '' }
        }
        $biasMatches = @(Find-Bias $pin.net $requiredDirection $railPattern)
        if ($category -eq 'OE上拉检查' -and $biasMatches.Count -eq 0 -and @($drivers | Where-Object { $_.via_series }).Count -gt 0 -and @($drivers | Where-Object { -not $_.via_series }).Count -eq 0) {
            foreach ($driver in @($drivers | Where-Object { $_.via_series })) {
                $remoteBias = @(Find-Bias $driver.net $requiredDirection $railPattern)
                if ($remoteBias.Count -gt 0) { Add-Issue $category 'manual_review' 'OE偏置仅位于串阻驱动侧' $pin ("串阻=$($driver.resistor); 驱动侧网络=$($driver.net); 直流偏置可能到达OE，但上电状态需复核"); $biasMatches = $remoteBias; break }
            }
        }
        if ($biasMatches.Count -eq 0) {
            if ($category -eq '中断信号上拉或下拉检查') {
                $wrongDirection = if ($requiredDirection -eq 'up') { 'down' } else { 'up' }
                if (@(Find-Bias $pin.net $wrongDirection '').Count -gt 0) {
                    $wrongStatus = if ($automaticInterrupt -and $interruptModeUnconfirmed) { 'manual_review' } else { 'error' }
                    Add-Issue $category $wrongStatus '中断外部偏置方向与有效电平不符' $pin ("网络=$($pin.net); 推断的默认无效方向=$requiredDirection; 实际存在=$wrongDirection")
                    continue
                }
            }
            $requireExternal = [bool](Get-Field $rule 'require_external_bias' (-not $automaticInterrupt))
            $status = if (($category -eq 'OE上拉检查' -and -not $driverConfirmed) -or ($category -eq '中断信号上拉或下拉检查' -and -not $requireExternal)) { 'manual_review' } else { 'error' }
            Add-Issue $category $status '未找到符合要求的外部上拉/下拉电阻' $pin ("需要=$requiredDirection; 网络=$($pin.net)")
            continue
        }
        $minimum = [double](Get-Field $rule 'min_ohms' 0)
        $maximum = [double](Get-Field $rule 'max_ohms' 0)
        if ($minimum -gt 0 -or $maximum -gt 0) {
            $valid = @($biasMatches | Where-Object { $null -ne $_.ohms -and ($minimum -le 0 -or $_.ohms -ge $minimum) -and ($maximum -le 0 -or $_.ohms -le $maximum) })
            if ($valid.Count -eq 0) { Add-Issue $category 'error' '偏置电阻阻值不在允许范围内' $pin ("需要=$requiredDirection; min_ohms=$minimum; max_ohms=$maximum") }
        }
        $opposite = if ($requiredDirection -eq 'up') { 'down' } else { 'up' }
        if (@(Find-Bias $pin.net $opposite '').Count -gt 0) { Add-Issue $category 'manual_review' '同一网络同时存在上拉和下拉' $pin '需计算分压和输入阈值，不能仅按存在目标电阻判定通过。' }
        if ($category -eq 'OE上拉检查') {
            foreach ($driverNet in @($drivers | Where-Object { $_.via_series } | Select-Object -ExpandProperty net -Unique)) {
                if (@(Find-Bias $driverNet $opposite '').Count -gt 0) {
                    Add-Issue $category 'manual_review' '串阻驱动侧存在相反偏置' $pin ("OE网络=$($pin.net); 驱动侧网络=$driverNet; 需计算上电分压及驱动状态")
                }
            }
            if (-not $automaticOE) { Add-Issue $category 'manual_review' '外部驱动上电状态未确认' $pin '原理图连接无法证明驱动引脚在上电期间高阻或保持无效；需查驱动芯片复位默认态和上电顺序。' }
        }
    }
}

$networkBiasTargets = 0
foreach ($net in @($Groups.Keys | Sort-Object)) {
    if ((Test-Supply $net) -or (Test-Ground $net)) { continue }
    $drivers = New-Object System.Collections.Generic.List[object]
    $receivers = 0
    $uncertain = $false
    foreach ($member in $Groups[$net]) {
        if (-not (Test-ValidNet $member)) { continue }
        switch (Get-SignalPinRole $member) {
            'driver' { $drivers.Add($member) }
            'receiver' { $receivers++ }
            'unknown' { $uncertain = $true }
        }
    }
    if ($uncertain -or $drivers.Count -ne 1 -or $receivers -lt 2) { continue }
    $networkBiasTargets++
    $biases = New-Object System.Collections.Generic.List[object]
    foreach ($direction in @('up','down')) {
        foreach ($match in @(Find-Bias $net $direction '')) {
            $biases.Add([pscustomobject]@{ id=[string]$match.part.id; reference=[string]$match.part.reference; direction=$direction; rail=[string]$match.rail })
        }
    }
    $uniqueBiases = @($biases | Group-Object id | ForEach-Object { $_.Group[0] })
    if ($uniqueBiases.Count -lt 2) { continue }
    $connections = @($uniqueBiases | ForEach-Object { '{0}({1}→{2})' -f $_.reference,$_.direction,$_.rail }) -join ', '
    $rails = @($uniqueBiases | Select-Object -ExpandProperty rail -Unique)
    if ($rails.Count -gt 1) {
        Add-Issue '网络上拉或下拉检查' 'error' '同一网络的偏置电阻连接到不同电源/地网络' $drivers[0] ("网络=$net; 偏置=$connections")
    } else {
        Add-Issue '网络上拉或下拉检查' 'warning' '同一网络存在多个上拉/下拉电阻' $drivers[0] ("网络=$net; 偏置=$connections; 可能增加静态功耗")
    }
}
if ($coverage['网络上拉或下拉检查'] -eq 'not_configured') { $coverage['网络上拉或下拉检查'] = 'automatic' }
$ruleCoverage.Add([pscustomobject]@{ category='网络上拉或下拉检查'; rule='自动检查单驱动多接收网络'; targets=$networkBiasTargets })

$holdRules = @(Get-RuleList 'bus_hold')
if ($holdRules.Count -gt 0) { $coverage['Bus-hold器件输入管脚检查'] = 'configured' }
foreach ($rule in $holdRules) {
    $mode = [string](Get-Field $rule 'mode')
    if ($mode -notin @('external_required','internal_hold')) { throw 'bus_hold.mode must be external_required or internal_hold' }
    $targets = @(Select-RulePins $rule)
    Add-RuleCoverage 'Bus-hold器件输入管脚检查' $rule $targets.Count
    foreach ($pin in $targets) {
        if ($pin.pin_type -ne '0' -and $pin.pin_type -ne 'input') { continue }
        if ($mode -eq 'internal_hold') { continue }
        if (-not (Test-ValidNet $pin)) { Add-Issue 'Bus-hold器件输入管脚检查' 'error' '无Bus-hold输入悬空' $pin '需按器件规则连接电阻上拉或下拉。'; continue }
        $up = @(Find-Bias $pin.net 'up' ''); $down = @(Find-Bias $pin.net 'down' '')
        if ($up.Count -eq 0 -and $down.Count -eq 0) { Add-Issue 'Bus-hold器件输入管脚检查' 'error' '输入网络缺少外部偏置' $pin '未找到连接至电源或地的电阻；有源驱动是否可替代偏置需人工确认。' }
    }
}

$diffRules = @(Get-RuleList 'differential_pairs')
if ($diffRules.Count -gt 0) { $coverage['差分管脚连接检查'] = 'configured' }
foreach ($rule in $diffRules) {
    $partPattern = [string](Get-Field $rule 'part_pattern')
    $positivePin = [string](Get-Field $rule 'positive_pin')
    $negativePin = [string](Get-Field $rule 'negative_pin')
    if (-not $partPattern -or -not $positivePin -or -not $negativePin) { throw 'differential_pairs requires part_pattern and pin patterns' }
    $matchedParts = 0
    foreach ($part in $Parts.Values) {
        if (($part.reference + ' ' + $part.value + ' ' + $part.source_part) -notmatch $partPattern) { continue }
        $matchedParts++
        $pp = @($pinsByPart[$part.id].ToArray() | Where-Object { $_.name -match $positivePin })
        $np = @($pinsByPart[$part.id].ToArray() | Where-Object { $_.name -match $negativePin })
        if ($pp.Count -ne 1 -or $np.Count -ne 1) { Add-Issue '差分管脚连接检查' 'manual_review' '无法唯一识别差分管脚对' $null ("器件=$($part.reference); P=$($pp.Count); N=$($np.Count)"); continue }
        if (-not (Test-ValidNet $pp[0]) -or -not (Test-ValidNet $np[0]) -or $pp[0].net -eq $np[0].net) { Add-Issue '差分管脚连接检查' 'error' '差分正负端悬空或短接' $pp[0] ("P=$($pp[0].net); N=$($np[0].net)"); continue }
        $positiveNet = [string](Get-Field $rule 'positive_net')
        $negativeNet = [string](Get-Field $rule 'negative_net')
        if (($positiveNet -and $pp[0].net -notmatch $positiveNet) -or ($negativeNet -and $np[0].net -notmatch $negativeNet)) { Add-Issue '差分管脚连接检查' 'error' '差分极性与配置的网络命名不一致' $pp[0] ("P=$($pp[0].net); N=$($np[0].net)") }
    }
    Add-RuleCoverage '差分管脚连接检查' $rule $matchedParts
}

$clockRules = @(Get-RuleList 'clock_series')
if ($clockRules.Count -gt 0) { $coverage['时钟信号串阻检查'] = 'configured' }
$clockEdges = @{}
foreach ($resistor in $resistors) {
    if (-not $pinsByPart.ContainsKey($resistor.id)) { continue }
    $resistorPins = @($pinsByPart[$resistor.id].ToArray() | Where-Object { Test-ValidNet $_ })
    if ($resistorPins.Count -ne 2 -or $resistorPins[0].net -eq $resistorPins[1].net) { continue }
    foreach ($side in @(0,1)) {
        $from = [string]$resistorPins[$side].net
        $to = [string]$resistorPins[1 - $side].net
        if (-not $clockEdges.ContainsKey($from)) { $clockEdges[$from] = New-Object System.Collections.Generic.List[object] }
        $clockEdges[$from].Add([pscustomobject]@{ net=$to; part=$resistor; ohms=(Get-Number $resistor.value) })
    }
}
function Test-ClockDevicePin {
    param([object]$Pin, [object]$Target, [string]$SourcePattern)
    if ($Pin.owner_id -eq $Target.owner_id -or -not (Test-ValidNet $Pin) -or -not $Parts.ContainsKey([string]$Pin.owner_id)) { return $false }
    if ($SourcePattern -and $Pin.net -notmatch $SourcePattern) { return $false }
    $reference = [string]$Parts[[string]$Pin.owner_id].reference
    return ($reference -notmatch '^(?i:(?:R|C|L|FB|FERRITE)\d+[A-Z]?)$')
}
foreach ($rule in $clockRules) {
    $sourcePattern = [string](Get-Field $rule 'source_net_pattern')
    $maximum = [double](Get-Field $rule 'max_ohms' 33)
    if ($maximum -le 0) { throw 'clock_series.max_ohms must be positive' }
    $targets = @(Select-RulePins $rule)
    Add-RuleCoverage '时钟信号串阻检查' $rule $targets.Count
    foreach ($pin in $targets) {
        if (-not (Test-ValidNet $pin)) { Add-Issue '时钟信号串阻检查' 'error' '时钟输入无有效连接' $pin '接收引脚悬空。'; continue }
        $paths = New-Object System.Collections.Generic.List[object]
        $stack = New-Object System.Collections.Generic.Stack[object]
        $stack.Push([pscustomobject]@{ net=[string]$pin.net; visited=@([string]$pin.net); resistors=@(); values=@() })
        $truncated = $false
        $steps = 0
        while ($stack.Count -gt 0) {
            if (++$steps -gt 10000) { $truncated = $true; break }
            $state = $stack.Pop()
            $endPins = @()
            if ($Groups.ContainsKey($state.net)) {
                $endPins = @($Groups[$state.net] | Where-Object { Test-ClockDevicePin $_ $pin $sourcePattern })
            }
            if ($endPins.Count -gt 0) {
                foreach ($endPin in $endPins) {
                    $endPart = $Parts[[string]$endPin.owner_id]
                    $paths.Add([pscustomobject]@{ end=([string]$endPart.reference + '.' + [string]$endPin.name); resistors=@($state.resistors); values=@($state.values) })
                }
                continue
            }
            if (-not $clockEdges.ContainsKey($state.net)) { continue }
            foreach ($edge in $clockEdges[$state.net]) {
                if ($state.visited -contains $edge.net -or (Test-Supply $edge.net) -or (Test-Ground $edge.net)) { continue }
                $stack.Push([pscustomobject]@{ net=$edge.net; visited=@($state.visited) + @($edge.net); resistors=@($state.resistors) + @([string]$edge.part.reference); values=@($state.values) + @($edge.ohms) })
            }
        }
        if ($truncated) { Add-Issue '时钟信号串阻检查' 'manual_review' '电阻穿透路径过多' $pin '超过10000个网络状态；需核对网络分支和规则范围。'; continue }
        if ($paths.Count -eq 0) { Add-Issue '时钟信号串阻检查' 'error' '未找到对端器件引脚' $pin ("起始网络=$($pin.net); 源网模式=$sourcePattern"); continue }
        $direct = @($paths | Where-Object { $_.resistors.Count -eq 0 })
        $multiple = @($paths | Where-Object { $_.resistors.Count -gt 1 })
        $usedResistors = @($paths | ForEach-Object { $_.resistors } | Select-Object -Unique)
        if ($direct.Count -gt 0) {
            Add-Issue '时钟信号串阻检查' 'error' '时钟路径没有串阻' $pin ("直连器件=$(@($direct | Select-Object -ExpandProperty end -Unique) -join ', '); 起始网络=$($pin.net)")
        }
        if ($multiple.Count -gt 0 -or $usedResistors.Count -gt 1) {
            $routes = @($paths | ForEach-Object { $_.end + ':' + ($_.resistors -join '+') } | Select-Object -Unique)
            Add-Issue '时钟信号串阻检查' 'error' '时钟路径存在多个串阻' $pin ("路径=$($routes -join '; ')")
        }
        if ($direct.Count -gt 0 -or $multiple.Count -gt 0 -or $usedResistors.Count -gt 1) { continue }
        $value = @($paths[0].values)[0]
        if ($null -eq $value) { Add-Issue '时钟信号串阻检查' 'manual_review' '串阻阻值无法解析' $pin ("电阻=$($usedResistors[0]); 对端=$(@($paths | Select-Object -ExpandProperty end -Unique) -join ', ')"); continue }
        if ([double]$value -gt $maximum) {
            Add-Issue '时钟信号串阻检查' 'warning' '时钟串阻大于允许值' $pin ("电阻=$($usedResistors[0]); 阻值=${value}Ω; 上限=${maximum}Ω; 对端=$(@($paths | Select-Object -ExpandProperty end -Unique) -join ', ')")
        }
    }
}

$latchFilter = & (Join-Path $PSScriptRoot 'Invoke-DSNCheck-LatchFilter.ps1') `
    -Parts $Parts -AllPins $AllPins -Groups $Groups -PowerNets $PowerNets -GroundNets $GroundNets `
    -ExtraRules @(Get-RuleList 'latch_rc_filter')
foreach ($issue in $latchFilter.issues) { $issues.Add($issue) }
foreach ($item in $latchFilter.coverage) { $ruleCoverage.Add($item) }
if (@(Get-RuleList 'latch_rc_filter').Count -gt 0) { $coverage['特定芯片时钟/锁存信号处理'] = 'configured' }

foreach ($category in $newCategories) {
    if ($coverage[$category] -in @('automatic','automatic_candidates')) { continue }
    $configured = @($ruleCoverage | Where-Object { $_.category -eq $category })
    if ($configured.Count -eq 0) { continue }
    $unmatched = @($configured | Where-Object { $_.targets -eq 0 }).Count
    if ($unmatched -eq $configured.Count) { $coverage[$category] = 'no_targets' }
    elseif ($unmatched -gt 0) { $coverage[$category] = 'partial_no_targets' }
}
return [pscustomobject]@{ issues=@($issues.ToArray()); categories=$newCategories; coverage=$coverage; rule_coverage=@($ruleCoverage.ToArray()) }
