[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InputDirectory,
    [string]$RulesFile,
    [double]$TimingMargin = 1.2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$enableCI45Step3 = $false

<##
CI4/CI5 offline checks. The script consumes the Capture Dbo export only;
it never opens, saves, or modifies a DSN file.

Implemented table rows:
  CI4.1  Module/page power-input filter topology
  CI4.5  PGOOD power-sequencing and clamp-risk review
  CI5.1  Bus member mapping and Bus Entry completeness
  CI5.6  Download-mode setup versus reset release

RulesFile is optional. It can provide power_input_rules, pgood_pattern,
boot_mode_pattern, reset_pattern, bus_mappings, and power_timing_ns.
##>

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
    $pinType = if ($Pin.PSObject.Properties.Name -contains 'type') { [string]$Pin.type } else { [string]$Pin.pin_type }
    return ($pinType -eq '7' -or $pinType -match '(?i)^power(?:\s+input)?$')
}

function Test-GroundNet {
    param([string]$Name)
    return ($Name -and $Name -match '(?i)(^|[_\- ])(?:GND|GROUND|AGND|DGND|PGND|VSS|EARTH)([_\- ]|$)')
}

function Test-PowerNetName {
    param([string]$Name)
    return ($Name -and $Name -match '(?i)(?:[0-9]+V[0-9]+|[0-9]+\.[0-9]+V)')
}

function Get-Text {
    param([object]$Value)
    if ($null -eq $Value) { return '' }
    return ([string]$Value).Trim()
}

function Get-ValueMicrofarads {
    param([string]$Value)
    $text = (Get-Text $Value).ToLowerInvariant().Replace('μ', 'u').Replace('µ', 'u')
    $match = [regex]::Match($text, '(?<number>[0-9]+(?:\.[0-9]+)?)(?:\s*)(?<unit>uf|u|nf|n|pf|p|mf|m)?')
    if (-not $match.Success) { return $null }
    $number = [double]::Parse($match.Groups['number'].Value, [Globalization.CultureInfo]::InvariantCulture)
    switch ($match.Groups['unit'].Value) {
        'mf' { return $number * 1000.0 }
        'm'  { return $number * 1000.0 }
        'nf' { return $number / 1000.0 }
        'n'  { return $number / 1000.0 }
        'pf' { return $number / 1000000.0 }
        'p'  { return $number / 1000000.0 }
        default { return $number }
    }
}

function Get-ValueOhms {
    param([string]$Value)
    $text = (Get-Text $Value).ToLowerInvariant().Replace('ω', 'r')
    $match = [regex]::Match($text, '(?<number>[0-9]+(?:\.[0-9]+)?)(?:\s*)(?<unit>meg|m|k|r)?')
    if (-not $match.Success) { return $null }
    $number = [double]::Parse($match.Groups['number'].Value, [Globalization.CultureInfo]::InvariantCulture)
    switch ($match.Groups['unit'].Value) {
        'meg' { return $number * 1000000.0 }
        'm'   { return $number * 1000000.0 }
        'k'   { return $number * 1000.0 }
        default { return $number }
    }
}

function Test-NumericNear {
    param([object]$Actual, [double]$Expected)
    if ($null -eq $Actual) { return $false }
    return ([math]::Abs(([double]$Actual) - $Expected) -le ([math]::Max(0.001, $Expected * 0.01)))
}

function Get-DielectricState {
    param([object]$Part, [hashtable]$Properties)
    $text = ((Get-Text $Part.value) + ' ' + (Get-Text $Part.source_part) + ' ' + (Get-Text $Part.pcb_footprint)).ToLowerInvariant()
    if ($Properties.ContainsKey([string]$Part.id)) {
        foreach ($property in $Properties[[string]$Part.id].ToArray()) {
            $text += ' ' + (Get-Text $property.name) + ' ' + (Get-Text $property.value)
        }
    }
    if ($text -match '(?i)(?:c0g|np0|ceramic|mlcc|x7r|x5r|x7s|x6s|dielectric[^ ]*\s*1)') { return 'ceramic' }
    if ($text -match '(?i)(?:tantalum|tantal|\btan\b)') { return 'tantalum' }
    if ($text -match '(?i)(?:electrolytic|aluminum|aluminium)') { return 'electrolytic' }
    return 'unknown'
}

function Get-DefaultPowerRules {
    return @(
        # Defaults only assert the observable topology. Exact values and
        # dielectric types require a project-specific rules file.
        [pscustomobject]@{ name='一次电源'; pattern='(?i)(VIN|VBUS|VMAIN|12V|24V|5V(?:_?IN)?)'; topology='parallel'; value_uF=@(); count=1; dielectric='unknown' },
        [pscustomobject]@{ name='模拟电源'; pattern='(?i)(AVDD|AVCC|AGND|ANALOG|VREF|VA[0-9_])'; topology='parallel'; value_uF=@(); count=1; dielectric='unknown' },
        [pscustomobject]@{ name='数字电源'; pattern='(?i)(DVDD|DVCC|VDD|VCC|VIO|DIGITAL|3V3|1V8|1V2|1V0)'; topology='parallel'; value_uF=@(); count=1; dielectric='unknown' }
    )
}

function Get-PowerRuleForNet {
    param([string]$Net, [object[]]$Rules)
    foreach ($rule in $Rules) {
        if ($Net -match (Get-Text $rule.pattern)) { return $rule }
    }
    return $null
}

function Expand-BusRange {
    param([string]$Name)
    $match = [regex]::Match((Get-Text $Name), '\[(?<a>-?\d+)\s*(?:\.\.|:)\s*(?<b>-?\d+)\]')
    if (-not $match.Success) { return @() }
    $a = [int]$match.Groups['a'].Value; $b = [int]$match.Groups['b'].Value
    $values = New-Object System.Collections.Generic.List[string]
    $step = if ($a -le $b) { 1 } else { -1 }
    for ($index = $a; ; $index += $step) {
        $values.Add([string]$index)
        if ($index -eq $b) { break }
    }
    return @($values.ToArray())
}

function Get-BusBaseName {
    param([string]$Name)
    return ([regex]::Replace((Get-Text $Name), '\[[^\]]+\]', '')).Trim()
}

function Get-BusMemberIndex {
    param(
        [string]$Member,
        [string]$BusName
    )
    $memberText = (Get-Text $Member).Trim()
    if (-not $memberText) { return '' }
    if ($memberText -match '^-?\d+$') { return $memberText }
    $base = Get-BusBaseName $BusName
    if ($base -and $memberText.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) {
        $suffix = $memberText.Substring($base.Length)
        if ($suffix -match '^[_ ]?(-?\d+)$') { return $Matches[1] }
    }
    $tail = [regex]::Match($memberText, '(?<index>-?\d+)$')
    if ($tail.Success) { return $tail.Groups['index'].Value }
    return $memberText
}

function Get-BusSignalFamily {
    param([string]$BusName)
    $base = Get-BusBaseName $BusName
    if ($base -match '(?i)(?:^|_)DATA$') { return 'D' }
    if ($base -match '(?i)(?:^|_)ADDR(?:ESS)?$') { return 'A' }
    $match = [regex]::Match($base, '(?i)(?:^|_)(?<family>[A-Z]+)$')
    if ($match.Success) { return $match.Groups['family'].Value }
    return ''
}

function Get-PinBusLabel {
    param([string]$PinName, [string]$BusFamily, [int]$NetIndex)
    if (-not $BusFamily) { return $null }
    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($alias in ((Get-Text $PinName) -split '/')) {
        $match = [regex]::Match($alias.Trim(), '(?i)(?:^|_)(?<family>[A-Z]+)(?<index>\d+)$')
        if ($match.Success -and $match.Groups['family'].Value.EndsWith($BusFamily, [StringComparison]::OrdinalIgnoreCase)) {
            $candidates.Add([pscustomobject]@{ family=$match.Groups['family'].Value.ToUpperInvariant(); index=[int]$match.Groups['index'].Value })
        }
    }
    foreach ($candidate in $candidates) { if ($candidate.index -eq $NetIndex) { return $candidate } }
    if ($candidates.Count -gt 0) { return $candidates[0] }
    return $null
}

function Add-Finding {
    param(
        [System.Collections.Generic.List[object]]$List,
        [string]$Id,
        [string]$Category,
        [string]$Status,
        [string]$Page,
        [string]$Net,
        [string]$Part,
        [string]$Details,
        [string]$Needs
    )
    $List.Add([pscustomobject]@{
        id=$Id; category=$Category; status=$Status; page=$Page; net=$Net; part=$Part
        details=$Details; needs_external_data=$Needs
    })
}

$inputPath = [IO.Path]::GetFullPath($InputDirectory)
$objectsPath = Join-Path $inputPath 'dbo\objects.jsonl'
$propertiesPath = Join-Path $inputPath 'dbo\properties.jsonl'
if (-not (Test-Path -LiteralPath $objectsPath -PathType Leaf)) { throw "Dbo object export was not found: $objectsPath" }

$rules = $null
if ($RulesFile) {
    $rulesPath = [IO.Path]::GetFullPath($RulesFile)
    if (-not (Test-Path -LiteralPath $rulesPath -PathType Leaf)) { throw "Rules file was not found: $rulesPath" }
    $rules = Get-Content -Raw -LiteralPath $rulesPath | ConvertFrom-Json
}
$powerRules = if ($null -ne $rules -and $null -ne $rules.power_input_rules) { @($rules.power_input_rules) } else { @(Get-DefaultPowerRules) }
$pgoodPattern = if ($null -ne $rules -and $rules.pgood_pattern) { Get-Text $rules.pgood_pattern } else { '(?i)(PGOOD|PWRGOOD|POWER[_ ]?GOOD)' }
$bootPattern = if ($null -ne $rules -and $rules.boot_mode_pattern) { Get-Text $rules.boot_mode_pattern } else { '(?i)(BOOT|DOWNLOAD|DL[_ ]?MODE|BOOTMODE|BMODE|CFG[0-9]+)' }
$resetPattern = if ($null -ne $rules -and $rules.reset_pattern) { Get-Text $rules.reset_pattern } else { '(?i)(^|[_\- ])(?:RESET|NRST|NRESET|SYSRST|POR)([_\- ]|$)' }

$parts = @{}
$pins = New-Object System.Collections.Generic.List[object]
$globals = New-Object System.Collections.Generic.List[object]
$buses = New-Object System.Collections.Generic.List[object]
$offpages = New-Object System.Collections.Generic.List[object]
$properties = @{}

if (Test-Path -LiteralPath $propertiesPath -PathType Leaf) {
    foreach ($line in [IO.File]::ReadLines($propertiesPath)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $record = $line | ConvertFrom-Json } catch { continue }
        $owner = Get-Text $record.owner_id
        if (-not $properties.ContainsKey($owner)) { $properties[$owner] = New-Object System.Collections.Generic.List[object] }
        $properties[$owner].Add($record)
    }
}

foreach ($line in [IO.File]::ReadLines($objectsPath)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try { $record = $line | ConvertFrom-Json } catch { continue }
    switch (Get-Text $record.record) {
        'part' {
            $parts[(Get-Text $record.id)] = [pscustomobject]@{
                id=(Get-Text $record.id); page=(Get-Text $record.page_id); reference=(Get-Text $record.reference)
                value=(Get-Text $record.value); source_part=(Get-Text $record.source_part); pcb_footprint=(Get-Text $record.pcb_footprint)
                left=(Convert-ToNumber $record.left); top=(Convert-ToNumber $record.top); right=(Convert-ToNumber $record.right); bottom=(Convert-ToNumber $record.bottom)
            }
        }
        'pin' {
            $pin = [pscustomobject]@{
                id=(Get-Text $record.id); owner=(Get-Text $record.owner_id); page=(Get-Text $record.page_id); name=(Get-Text $record.name)
                number=(Get-Text $record.number); type=(Get-Text $record.pin_type); net=(Get-Text $record.net_name)
                connected=(Test-TrueValue $record.connected); no_connect=(Test-TrueValue $record.no_connect)
                x=(Convert-ToNumber $record.offset_hot_x); y=(Convert-ToNumber $record.offset_hot_y)
            }
            $pins.Add($pin)
        }
        'global' { $globals.Add([pscustomobject]@{ page=(Get-Text $record.page_id); name=(Get-Text $record.name); net=(Get-Text $record.net_name) }) }
        'bus_entry' { $buses.Add([pscustomobject]@{ id=(Get-Text $record.id); page=(Get-Text $record.page_id); entry=(Get-Text $record.entry_net); bus=(Get-Text $record.end_net); is_bus=(Get-Text $record.is_bus); is_bundle=(Get-Text $record.is_bundle) }) }
        'offpage_connector' { $offpages.Add([pscustomobject]@{ page=(Get-Text $record.page_id); name=(Get-Text $record.name); net=(Get-Text $record.net_name) }) }
    }
}

$validPins = @($pins | Where-Object { $_.net -and $_.net -ne 'NULL' -and -not $_.no_connect })
$pinsByNet = @{}
foreach ($pin in $validPins) {
    if (-not $pinsByNet.ContainsKey($pin.net)) { $pinsByNet[$pin.net] = New-Object System.Collections.Generic.List[object] }
    $pinsByNet[$pin.net].Add($pin)
}
$findings = New-Object System.Collections.Generic.List[object]

# CI4.1: power input filter network and capacitor topology, page by page.
$pagePowerNets = @{}
foreach ($pin in $validPins) {
    if (-not (Test-PowerNetName $pin.net)) { continue }
    $key = $pin.page + '|' + $pin.net
    if (-not $pagePowerNets.ContainsKey($key)) { $pagePowerNets[$key] = [pscustomobject]@{ page=$pin.page; net=$pin.net } }
}
foreach ($global in $globals) {
    if (-not (Test-PowerNetName $global.name)) { continue }
    $key = $global.page + '|' + $global.net
    if ($global.net -and -not $pagePowerNets.ContainsKey($key)) { $pagePowerNets[$key] = [pscustomobject]@{ page=$global.page; net=$global.net } }
}

$capacitors = @($parts.Values | Where-Object { $_.reference -match '^(?i:C[0-9A-Z_]*)$' })
foreach ($entry in $pagePowerNets.Values) {
    $rule = Get-PowerRuleForNet $entry.net $powerRules
    if ($null -eq $rule) {
        Add-Finding $findings 'CI4.1' '电源输入滤波' 'manual_review' $entry.page $entry.net '' '电源网络已识别，但未匹配一次/模拟/数字电源规则。' '需配置 power_input_rules 或项目电源分类规则。'
        continue
    }
    $pageCaps = @()
    foreach ($cap in $capacitors | Where-Object { $_.page -eq $entry.page }) {
        $capNets = @($validPins | Where-Object { $_.owner -eq $cap.id } | Select-Object -ExpandProperty net -Unique)
        if ($capNets.Count -ge 2) {
            $pageCaps += [pscustomobject]@{ part=$cap; nets=$capNets; dielectric=(Get-DielectricState $cap $properties) }
        }
    }
    $requiredValues = @($rule.value_uF)
    $topology = (Get-Text $rule.topology).ToLowerInvariant()
    $candidates = @()
    if ($topology -eq 'parallel') {
        foreach ($capInfo in $pageCaps) {
            if ($capInfo.nets -contains $entry.net -and @($capInfo.nets | Where-Object { Test-GroundNet $_ }).Count -gt 0) { $candidates += $capInfo }
        }
        $matched = @()
        foreach ($required in $requiredValues) {
            $candidate = $candidates | Where-Object { (Test-NumericNear (Get-ValueMicrofarads $($_.part.value)) ([double]$required)) -and ($_.dielectric -eq 'ceramic' -or $_.dielectric -eq 'unknown') } | Select-Object -First 1
            if ($null -ne $candidate) { $matched += $candidate }
        }
        if ($requiredValues.Count -eq 0) {
            $matched = @($candidates | Select-Object -First ([int](Get-Text $rule.count)))
        }
    } else {
        # A series pair is represented as power -> midpoint -> ground.
        $matched = @()
        foreach ($first in $pageCaps) {
            if (-not ($first.nets -contains $entry.net)) { continue }
            $midpoints = @($first.nets | Where-Object { $_ -ne $entry.net -and -not (Test-GroundNet $_) })
            foreach ($mid in $midpoints) {
                $second = $pageCaps | Where-Object { $_.part.id -ne $first.part.id -and $_.nets -contains $mid -and @($_.nets | Where-Object { Test-GroundNet $_ }).Count -gt 0 } | Select-Object -First 1
                if ($null -eq $second) { continue }
                $valueMatches = $true
                foreach ($required in $requiredValues) {
                    if (-not ((Test-NumericNear (Get-ValueMicrofarads $first.part.value) ([double]$required)) -or (Test-NumericNear (Get-ValueMicrofarads $second.part.value) ([double]$required)))) { $valueMatches = $false }
                }
                if ($valueMatches) { $matched = @($first, $second); break }
            }
            if ($matched.Count -gt 0) { break }
        }
    }
    $requiredCount = [int](Get-Text $rule.count)
    if ($matched.Count -lt $requiredCount) {
        Add-Finding $findings 'CI4.1' '电源输入滤波' 'error' $entry.page $entry.net '' ('未找到符合 {0} 要求的滤波拓扑；实际候选电容: {1}。' -f (Get-Text $rule.name), (($candidates | ForEach-Object { $_.part.reference + '=' + $_.part.value }) -join ', ')) '若电容介质、负载类型或电源分类无法由导出数据确认，需要人工复核。'
    } elseif ((Get-Text $rule.dielectric) -and (Get-Text $rule.dielectric) -ne 'unknown' -and @($matched | Where-Object { $_.dielectric -eq 'unknown' }).Count -gt 0) {
        Add-Finding $findings 'CI4.1' '电源输入滤波' 'manual_review' $entry.page $entry.net '' ('滤波拓扑和值满足 {0}，但至少一个电容的介质属性无法从导出数据确认。' -f (Get-Text $rule.name)) '需BOM、器件型号或厂家属性确认 ceramic/tantalum。'
    }
}

# CI4.5: PGOOD topology, pull-up, receiver power domain and timing review.
$pgoodPins = @($pins | Where-Object { $_.name -match $pgoodPattern -or $_.net -match $pgoodPattern })
$pgoodNets = @($pgoodPins | Where-Object { $_.net } | Select-Object -ExpandProperty net -Unique)
foreach ($net in $pgoodNets) {
    $members = if ($pinsByNet.ContainsKey($net)) { @($pinsByNet[$net].ToArray()) } else { @() }
    $sources = @($members | Where-Object { $_.type -in @('2','3') -or $_.name -match $pgoodPattern })
    $receivers = @($members | Where-Object { $sources -notcontains $_ })
    if ($sources.Count -eq 0) {
        Add-Finding $findings 'CI4.5' 'PGOOD电源时序' 'warning' '' $net '' 'PGOOD网络未识别到明确的输出源引脚。' '需确认源器件引脚类型或提供电源监控规则。'
    }
    $pullup = @($validPins | Where-Object { $_.net -eq $net -and $parts.ContainsKey($_.owner) -and $parts[$_.owner].reference -match '^(?i:R[0-9A-Z_]*)$' })
    if ($pullup.Count -eq 0) {
        Add-Finding $findings 'CI4.5' 'PGOOD电源时序' 'warning' '' $net '' '未发现通过电阻实现的PGOOD上拉路径。' '若输出为推挽或内部上拉，请在规则文件中说明，否则需人工确认。'
    }
    # Step 3 requires pin-specific power-off tolerance and clamp data.
    # Keep the timing/risk assessment disabled until that data is supplied.
    if (-not $enableCI45Step3) { continue }
    foreach ($receiver in $receivers) {
        $receiverPower = @($pins | Where-Object { $_.owner -eq $receiver.owner -and (Test-PowerPin $_) })
        if ($receiverPower.Count -eq 0) {
            Add-Finding $findings 'CI4.5' 'PGOOD电源时序' 'manual_review' $receiver.page $net $receiver.owner 'PGOOD接收器件未导出明确Power属性供电脚，无法判断上电时是否可能被IO钳位。' '需器件引脚属性和数据手册确认。'
            continue
        }
        $unpowered = @($receiverPower | Where-Object { -not $_.net -or $_.net -eq 'NULL' -or -not $_.connected })
        if ($unpowered.Count -gt 0) {
            Add-Finding $findings 'CI4.5' 'PGOOD电源时序' 'error' $receiver.page $net $receiver.owner 'PGOOD接收器件存在未连接或未命名的Power供电脚，存在上电前IO钳位风险。' '需补充供电网络和器件上电时序。'
        }
    }
    $timingKnown = $false
    if ($null -ne $rules -and $null -ne $rules.power_timing_ns) {
        $timingKnown = $true
        $sourceTiming = @()
        foreach ($source in $sources) {
            $sourcePower = @($pins | Where-Object { $_.owner -eq $source.owner -and (Test-PowerPin $_) -and $_.net })
            foreach ($power in $sourcePower) { if ($rules.power_timing_ns.PSObject.Properties.Name -contains $power.net) { $sourceTiming += [double]$rules.power_timing_ns.($power.net).good_ns } }
        }
        foreach ($receiver in $receivers) {
            $receiverPower = @($pins | Where-Object { $_.owner -eq $receiver.owner -and (Test-PowerPin $_) -and $_.net })
            foreach ($power in $receiverPower) {
                if ($rules.power_timing_ns.PSObject.Properties.Name -contains $power.net -and $sourceTiming.Count -gt 0) {
                    $ready = [double]$rules.power_timing_ns.($power.net).ready_ns
                    if ((($sourceTiming | Measure-Object -Maximum).Maximum) -gt $ready) {
                        Add-Finding $findings 'CI4.5' 'PGOOD电源时序' 'error' $receiver.page $net $receiver.owner ('PGOOD有效时间晚于接收器件供电就绪时间：good_ns={0}; ready_ns={1}。' -f (($sourceTiming | Measure-Object -Maximum).Maximum), $ready) '修正电源时序或加入受控隔离。'
                    }
                }
            }
        }
    }
    if (-not $timingKnown) {
        Add-Finding $findings 'CI4.5' 'PGOOD电源时序' 'manual_review' '' $net '' '已重建PGOOD源端、接收端和供电域，但没有电源上电/PGOOD有效时刻参数，无法完成时序比较和内部钳位判定。' '需在 RulesFile 提供 power_timing_ns，并结合器件数据手册确认IO钳位。'
    }
}

# CI5.1: expand each Bus Entry group, check range coverage and optional mapping.
$busGroups = @{}
foreach ($bus in $buses | Where-Object { $_.bus -match '\[' }) {
    $key = $bus.page + '|' + $bus.bus
    if (-not $busGroups.ContainsKey($key)) { $busGroups[$key] = New-Object System.Collections.Generic.List[object] }
    $busGroups[$key].Add($bus)
}
foreach ($entry in $busGroups.GetEnumerator()) {
    $items = @($entry.Value.ToArray()); $page = $items[0].page; $busName = $items[0].bus; $expected = @(Expand-BusRange $busName)
    # Capture exports the member as a full net name (for example PE30),
    # while the bus range expands to indexes (30). Compare canonical indexes.
    $observed = @($items | Where-Object { $_.entry } | ForEach-Object { Get-BusMemberIndex $_.entry $busName })
    $missing = @($expected | Where-Object { $observed -notcontains $_ })
    $extra = @($observed | Where-Object { $expected -notcontains $_ } | Select-Object -Unique)
    $duplicates = @($observed | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    if ($missing.Count -gt 0) { Add-Finding $findings 'CI5.1' '总线成员连接' 'error' $page $busName '' ('Bus Entry 缺少成员: [{0}]。' -f ($missing -join ', ')) '需确认总线范围、Bus Entry 和成员线网。' }
    if ($extra.Count -gt 0) { Add-Finding $findings 'CI5.1' '总线成员连接' 'error' $page $busName '' ('Bus Entry 存在超出总线范围的成员: [{0}]。' -f ($extra -join ', ')) '需修正成员索引或总线范围。' }
    if ($duplicates.Count -gt 0) { Add-Finding $findings 'CI5.1' '总线成员连接' 'warning' $page $busName '' ('同一Page和Bus上重复出现成员: [{0}]；若为分支连接，请在规则中允许。' -f ($duplicates -join ', ')) '需确认重复成员是否为合法分支。' }
    foreach ($memberIndex in $observed | Select-Object -Unique) {
        $memberNames = @($items | Where-Object { (Get-BusMemberIndex $_.entry $busName) -eq $memberIndex } | Select-Object -ExpandProperty entry -Unique)
        $memberPins = @()
        foreach ($memberName in $memberNames) {
            if ($pinsByNet.ContainsKey($memberName)) { $memberPins += @($pinsByNet[$memberName].ToArray()) }
            if ($pinsByNet.ContainsKey($memberIndex)) { $memberPins += @($pinsByNet[$memberIndex].ToArray()) }
        }
        if ($memberPins.Count -eq 0) { Add-Finding $findings 'CI5.1' '总线成员连接' 'warning' $page (($memberNames -join ',') + '[' + $memberIndex + ']') '' ('Bus Entry 成员未解析到任何器件Pin: {0}。' -f ($memberNames -join ', ')) '需检查 Wire、Net Alias、跨页连接器或导出完整性。' }
    }

    # Infer a mapping from numbered pin labels on each device. A constant
    # nonzero offset can be intentional (for example DDR_A2 to A0).
    $family = Get-BusSignalFamily $busName
    $labelGroups = @{}
    if ($family) {
        foreach ($item in $items) {
            $indexText = Get-BusMemberIndex $item.entry $busName
            if ($indexText -notmatch '^\d+$' -or -not $pinsByNet.ContainsKey($item.entry)) { continue }
            foreach ($pin in $pinsByNet[$item.entry].ToArray()) {
                if ($pin.page -ne $page) { continue }
                $label = Get-PinBusLabel $pin.name $family ([int]$indexText)
                if ($null -eq $label) { continue }
                $key = $pin.owner + '|' + $label.family
                if (-not $labelGroups.ContainsKey($key)) { $labelGroups[$key] = New-Object System.Collections.Generic.List[object] }
                if (@($labelGroups[$key] | Where-Object { $_.pinId -eq $pin.id }).Count -gt 0) { continue }
                $labelGroups[$key].Add([pscustomobject]@{ pinId=$pin.id; owner=$pin.owner; net=$item.entry; netIndex=[int]$indexText; pinName=$pin.name; pinIndex=$label.index })
            }
        }
    }
    $comparableGroups = 0
    foreach ($labelGroup in $labelGroups.Values) {
        $connections = @($labelGroup.ToArray())
        if (@($connections | Select-Object -ExpandProperty netIndex -Unique).Count -lt 2) { continue }
        $comparableGroups++
        $offsets = @($connections | ForEach-Object { $_.netIndex - $_.pinIndex } | Select-Object -Unique)
        $examples = ($connections | Sort-Object netIndex | Select-Object -First 8 | ForEach-Object { $_.net + '->' + $_.pinName } ) -join ', '
        if ($connections.Count -gt 8) { $examples += ('（仅列出前8项，共{0}项）' -f $connections.Count) }
        $part = if ($parts.ContainsKey($connections[0].owner)) { $parts[$connections[0].owner].reference } else { $connections[0].owner }
        if ($offsets.Count -gt 1) {
            Add-Finding $findings 'CI5.1' '总线成员映射' 'error' $page $busName $part ('同一器件的总线位号与引脚编号不一致，疑似位序错接：{0}。' -f $examples) '若器件接口本身采用特殊映射，请提供 bus_mappings 规则。'
        } elseif ($offsets[0] -ne 0) {
            Add-Finding $findings 'CI5.1' '总线成员映射' 'manual_review' $page $busName $part ('总线位号与引脚编号存在固定偏移 {0}：{1}。' -f $offsets[0], $examples) '需确认该地址/数据线偏移是否为设计要求，或提供 bus_mappings 规则。'
        }
    }
    if ($comparableGroups -eq 0 -and @($observed | Select-Object -Unique).Count -ge 2) {
        $pagePins = @($items | ForEach-Object {
            if ($pinsByNet.ContainsKey($_.entry)) { $pinsByNet[$_.entry].ToArray() | Where-Object { $_.page -eq $page } }
        })
        if ($pagePins.Count -gt 0) {
            Add-Finding $findings 'CI5.1' '总线成员映射' 'manual_review' $page $busName '' '本页未找到同一器件上至少两个可比较的带位号引脚，无法自动核对总线位序。' '需确认引脚命名、跨页路径，或提供 bus_mappings 规则。'
        }
    }
    if ($null -ne $rules -and $null -ne $rules.bus_mappings) {
        foreach ($mapping in @($rules.bus_mappings)) {
            if ($busName -notmatch (Get-Text $mapping.pattern)) { continue }
            if ($null -eq $mapping.members) { continue }
            foreach ($memberProperty in $mapping.members.PSObject.Properties) {
                $actualPins = @($pins | Where-Object { $_.net -eq $memberProperty.Name })
                $expectedPins = @($memberProperty.Value)
                foreach ($expectedPin in $expectedPins) {
                    if (@($actualPins | Where-Object { $_.number -eq (Get-Text $expectedPin.number) -or $_.name -eq (Get-Text $expectedPin.name) }).Count -eq 0) {
                        Add-Finding $findings 'CI5.1' '总线成员映射' 'error' $page $memberProperty.Name '' ('成员 {0} 未连接到期望引脚 {1}。' -f $memberProperty.Name, (Get-Text $expectedPin.name)) '需修正 Bus Entry、Net Alias 或接口映射。'
                    }
                }
            }
        }
    }
}

# CI5.6: identify boot/download mode paths, FPGA/CPLD intermediaries and RC timing.
$modePins = @($pins | Where-Object { $_.name -match $bootPattern -or $_.net -match $bootPattern })
$resetPins = @($pins | Where-Object { $_.name -match $resetPattern -or $_.net -match $resetPattern })
$modeNets = @($modePins | Where-Object { $_.net } | Select-Object -ExpandProperty net -Unique)
$resetNets = @($resetPins | Where-Object { $_.net } | Select-Object -ExpandProperty net -Unique)
if ($modeNets.Count -eq 0) {
    Add-Finding $findings 'CI5.6' '下载模式时序' 'info' '' '' '' '未按默认 boot_mode_pattern 识别到下载模式/启动配置网络。' '如工程使用其他命名，请通过 RulesFile 配置 boot_mode_pattern。'
}
$resistors = @($parts.Values | Where-Object { $_.reference -match '^(?i:R[0-9A-Z_]*)$' })
foreach ($modeNet in $modeNets) {
    $modeMembers = if ($pinsByNet.ContainsKey($modeNet)) { @($pinsByNet[$modeNet].ToArray()) } else { @() }
    $intermediaries = @($modeMembers | ForEach-Object { if ($parts.ContainsKey($_.owner)) { $parts[$_.owner] } } | Where-Object { (($_.value + ' ' + $_.source_part + ' ' + $_.reference) -match '(?i)(FPGA|CPLD|SRA)') } | Select-Object -Unique)
    if ($intermediaries.Count -gt 0) { Add-Finding $findings 'CI5.6' '下载模式时序' 'error' '' $modeNet '' ('下载模式信号经过 FPGA/CPLD/SRA 等可能需要先上电或配置的器件: {0}。' -f (($intermediaries | ForEach-Object { $_.reference }) -join ', ')) '下载模式信号应直接到CPU，或提供该中间器件的上电/配置时序证明。' }
    $modeCap = $null
    foreach ($cap in $capacitors) {
        $capPins = @($validPins | Where-Object { $_.owner -eq $cap.id })
        if ((@($capPins | Where-Object { $_.net -eq $modeNet }).Count -gt 0) -and (@($capPins | Where-Object { Test-GroundNet $_.net }).Count -gt 0)) {
            $modeCap = $cap
            break
        }
    }
    $modeTau = $null
    foreach ($resistor in $resistors) {
        $rNets = @($validPins | Where-Object { $_.owner -eq $resistor.id } | Select-Object -ExpandProperty net -Unique)
        if ($rNets -contains $modeNet) {
            $other = @($rNets | Where-Object { $_ -ne $modeNet } | Select-Object -First 1)
            if ($other.Count -gt 0 -and (Test-PowerNetName $other -or (Test-GroundNet $other))) {
                if ($null -ne $modeCap) { $r = Get-ValueOhms $resistor.value; $c = Get-ValueMicrofarads $modeCap.value; if ($null -ne $r -and $null -ne $c) { $modeTau = $r * ($c * 1e-6) } }
            }
        }
    }
    if ($null -eq $modeTau) { Add-Finding $findings 'CI5.6' '下载模式时序' 'manual_review' '' $modeNet '' '已识别下载模式网络，但无法仅凭导出数据计算其稳定时间。' '需补充上下拉阻值、电容值、输入阈值、电源斜率和采样时刻。' }
    foreach ($resetNet in $resetNets) {
        $resetTau = $null
        foreach ($resistor in $resistors) {
            $rNets = @($validPins | Where-Object { $_.owner -eq $resistor.id } | Select-Object -ExpandProperty net -Unique)
            if ($rNets -contains $resetNet) {
                $resetCap = $null
                foreach ($cap in $capacitors) {
                    $capPins = @($validPins | Where-Object { $_.owner -eq $cap.id })
                    if ((@($capPins | Where-Object { $_.net -eq $resetNet }).Count -gt 0) -and (@($capPins | Where-Object { Test-GroundNet $_.net }).Count -gt 0)) {
                        $resetCap = $cap
                        break
                    }
                }
                if ($null -ne $resetCap) { $r = Get-ValueOhms $resistor.value; $c = Get-ValueMicrofarads $resetCap.value; if ($null -ne $r -and $null -ne $c) { $resetTau = $r * ($c * 1e-6) } }
            }
        }
        if ($null -ne $modeTau -and $null -ne $resetTau -and (($modeTau * $TimingMargin) -ge ($resetTau * $TimingMargin))) {
            Add-Finding $findings 'CI5.6' '下载模式时序' 'error' '' $modeNet '' ('下载模式稳定时间估计不早于复位释放：mode_tau={0} s; reset_tau={1} s。' -f $modeTau, $resetTau) '调整模式脚配置或复位延时，并结合数据手册确认采样时刻。'
        } elseif ($null -eq $resetTau) {
            Add-Finding $findings 'CI5.6' '下载模式时序' 'manual_review' '' $resetNet '' '已识别复位网络，但无法计算复位释放时间，不能完成模式与复位的时序比较。' '需复位芯片参数或RC网络参数。'
        }
    }
}

$categoryOrder = @('CI4.1','CI4.5','CI5.1','CI5.6')
$summary = [ordered]@{}
foreach ($category in $categoryOrder) {
    $items = @($findings | Where-Object id -eq $category)
    $summary[$category] = [ordered]@{ error=@($items | Where-Object status -eq 'error').Count; warning=@($items | Where-Object status -eq 'warning').Count; manual_review=@($items | Where-Object status -eq 'manual_review').Count; info=@($items | Where-Object status -eq 'info').Count }
}
$outputPath = [IO.Path]::GetFullPath($InputDirectory)
$report = [ordered]@{ schema_version='2.0'; generated_at=(Get-Date).ToString('s'); rules=@('CI4.1','CI4.5','CI5.1','CI5.6'); disabled_steps=@('CI4.5.3'); timing_margin=$TimingMargin; summary=$summary; findings=@($findings.ToArray()) }
$jsonPath = Join-Path $outputPath 'dsn_check_ci4_ci5_report.json'
$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

$text = New-Object System.Collections.Generic.List[string]
$text.Add('DSNCheck CI4/CI5 原理图检查报告')
$text.Add(('生成时间: ' + $report.generated_at)); $text.Add('')
$text.Add('CI4.5 第3步未启用：缺少接收引脚的内部钳位与断电容限资料。')
$text.Add('')
foreach ($category in $categoryOrder) {
    $items = @($findings | Where-Object id -eq $category)
    $text.Add(('[{0}] error={1}; warning={2}; manual_review={3}; info={4}' -f $category, @($items | Where-Object status -eq 'error').Count, @($items | Where-Object status -eq 'warning').Count, @($items | Where-Object status -eq 'manual_review').Count, @($items | Where-Object status -eq 'info').Count))
    foreach ($item in $items) { $text.Add(('  [{0}] page={1}; net={2}; part={3}; {4}' -f $item.status, $item.page, $item.net, $item.part, $item.details)) }
    $text.Add('')
}
$textPath = Join-Path $outputPath 'dsn_check_ci4_ci5_report.txt'
$text | Set-Content -LiteralPath $textPath -Encoding UTF8
Write-Output ('CI4/CI5 report: ' + $textPath)
Write-Output 'CI4.5 step 3: disabled (receiver-pin clamp data unavailable)'
Write-Output (($categoryOrder | ForEach-Object { '{0}: error={1}, warning={2}, manual_review={3}, info={4}' -f $_, $summary[$_].error, $summary[$_].warning, $summary[$_].manual_review, $summary[$_].info }) -join '; ')
