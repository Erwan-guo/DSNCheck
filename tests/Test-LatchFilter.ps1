Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$parts = @{}
$groups = @{}
$pins = New-Object System.Collections.Generic.List[object]
$powerNets = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$groundNets = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
[void]$powerNets.Add('3V3'); [void]$groundNets.Add('GND')
function Add-Part {
    param([string]$Ref, [string]$Value='', [string]$Page='P1')
    $parts[$Ref] = [pscustomobject]@{ id=$Ref; reference=$Ref; value=$Value; source_part='Test.Normal'; page_id=$Page }
}
function Add-Pin {
    param([string]$Ref, [string]$Name, [string]$Net, [string]$Page='P1', [string]$Type='4')
    $pin = [pscustomobject]@{ owner_id=$Ref; page_id=$Page; name=$Name; number=[string]($pins.Count+1); net=$Net; pin_type=$Type; connected=$true; no_connect=$false }
    $pins.Add($pin)
    if (-not $groups.ContainsKey($Net)) { $groups[$Net] = New-Object System.Collections.Generic.List[object] }
    $groups[$Net].Add($pin)
}
function Add-Resistor {
    param([string]$Ref, [string]$Value, [string]$A, [string]$B)
    Add-Part $Ref $Value
    Add-Pin $Ref '1' $A; Add-Pin $Ref '2' $B
}
function Add-Capacitor {
    param([string]$Ref, [string]$Value, [string]$Signal, [string]$Page='P1')
    Add-Part $Ref $Value $Page
    Add-Pin $Ref '1' $Signal $Page; Add-Pin $Ref '2' GND $Page
}
function Add-Source {
    param([int]$Number)
    Add-Part "D$Number" 'CLOCK_SOURCE'
    Add-Pin "D$Number" OUT "SRC$Number"
}
Add-Part U1 SN74HC273D; Add-Pin U1 CLK F1; Add-Source 1
Add-Resistor R1 33R F1 SRC1; Add-Capacitor C1 33pF F1
Add-Part U2 74HC373; Add-Pin U2 LE F2; Add-Source 2
Add-Capacitor C2 33p F2
Add-Part U3 SN74LVC573A; Add-Pin U3 LE F3; Add-Source 3
Add-Resistor R3 47R F3 SRC3; Add-Capacitor C3 47pF F3
Add-Part U4 74HC273; Add-Pin U4 CP F4; Add-Source 4
Add-Resistor R4 33R F4 SRC4
Add-Part U5 74HC373; Add-Pin U5 LE F5; Add-Source 5
Add-Resistor R5 33R F5 SRC5; Add-Capacitor C5 33pF F5 P2
Add-Part U6 74HC573; Add-Pin U6 LE F6; Add-Source 6
Add-Resistor R6 33R F6 SRC6; Add-Capacitor C6 33pF SRC6
Add-Part U7 74HC273; Add-Pin U7 CLK F7; Add-Source 7
Add-Resistor R7 33R F7 SRC7; Add-Capacitor C7 UNKNOWN F7
Add-Part U8 74HC273; Add-Pin U8 EN F8
Add-Part U9 OTHER_LATCH; Add-Pin U9 LE F9; Add-Source 9
Add-Resistor R9 33R F9 SRC9; Add-Capacitor C9 0.033nF F9
Add-Part U10 74HC273; Add-Pin U10 CLK F10; Add-Source 10
Add-Resistor R10 33R F10 SRC10; Add-Resistor R11 33R F10 SRC11; Add-Capacitor C10 33pF F10
Add-Part U11 74HC573; Add-Pin U11 LE F11
Add-Resistor R12 33R F11 GND; Add-Capacitor C11 33pF F11
Add-Part U12 74HC373; Add-Pin U12 LE F12; Add-Source 12
Add-Resistor R13 33R F12 SRC12; Add-Capacitor C12 33pF F12
Add-Pin D12 BYPASS F12 P1 '1'
Add-Part U13 74HC573; Add-Pin U13 LE F13
Add-Resistor R14 33R F13 DANGLING; Add-Capacitor C13 33pF F13

function Invoke-FilterCheck {
    param([string]$RulesFile)
    $arguments = @{
        OutputDirectory=(Join-Path $PSScriptRoot 'fixtures\additional'); Parts=$parts; AllPins=$pins; Pins=$pins
        Groups=$groups; PowerNets=$powerNets; GroundNets=$groundNets
        PowerNetEntries=@([pscustomobject]@{ net='3V3'; kind='power'; voltage_v='3.3' }, [pscustomobject]@{ net='GND'; kind='ground'; voltage_v='' })
    }
    if ($RulesFile) { $arguments.RulesFile = $RulesFile }
    return (& (Join-Path $PSScriptRoot '..\check\generic\Invoke-DSNCheck-Additional.ps1') @arguments)
}
function Assert-Issue {
    param([object]$Issues, [string]$Part, [string]$Rule, [string]$Status)
    if (@($Issues | Where-Object { $_.part -eq $Part -and $_.rule -eq $Rule -and $_.status -eq $Status }).Count -ne 1) { throw "Expected $Status/$Rule for $Part" }
}
$result = Invoke-FilterCheck ''
$issues = @($result.issues | Where-Object { $_.category -eq '特定芯片时钟/锁存信号处理' })
if ($result.coverage['特定芯片时钟/锁存信号处理'] -ne 'automatic') { throw 'Expected automatic latch filter coverage.' }
foreach ($part in @('U1','U9')) { if (@($issues | Where-Object { $_.part -eq $part }).Count -gt 0) { throw "Unexpected issue for $part" } }
Assert-Issue $issues U2 '时钟或锁存输入缺少串联电阻' warning
Assert-Issue $issues U3 '时钟或锁存串阻不是建议值' warning
Assert-Issue $issues U3 '时钟或锁存滤波电容不是建议值' warning
foreach ($part in @('U4','U5','U6')) { Assert-Issue $issues $part '时钟或锁存输入侧缺少接地电容' warning }
Assert-Issue $issues U7 '滤波电容容量无法解析' manual_review
Assert-Issue $issues U8 '无法识别时钟或锁存输入引脚' manual_review
Assert-Issue $issues U10 '串阻拓扑不唯一' manual_review
Assert-Issue $issues U11 '时钟或锁存输入缺少串联电阻' warning
Assert-Issue $issues U12 '时钟或锁存输入存在绕过串阻的直连' warning
Assert-Issue $issues U13 '串阻另一端未识别到信号器件引脚' manual_review
if ($issues.Count -ne 12) { throw "Unexpected latch filter issue count: $($issues.Count)" }

$configured = Invoke-FilterCheck (Join-Path $PSScriptRoot 'latch-filter.rules.test.json')
$configuredIssues = @($configured.issues | Where-Object { $_.category -eq '特定芯片时钟/锁存信号处理' })
if (@($configuredIssues | Where-Object { $_.part -eq 'U9' }).Count -ne 0) { throw 'Configured latch filter target should pass.' }
if ($configured.coverage['特定芯片时钟/锁存信号处理'] -ne 'configured') { throw 'Expected configured latch filter coverage.' }
Write-Output 'Latch RC filter tests passed.'
