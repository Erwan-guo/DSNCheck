Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$parts = @{}
$groups = @{}
$pins = New-Object System.Collections.Generic.List[object]
$powerNets = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$groundNets = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
[void]$powerNets.Add('3V3'); [void]$groundNets.Add('GND')
function Add-Part {
    param([string]$Ref, [string]$Value='')
    $parts[$Ref] = [pscustomobject]@{ id=$Ref; reference=$Ref; value=$Value; source_part='Test.Normal'; page_id='P1' }
}
function Add-Pin {
    param([string]$Ref, [string]$Name, [string]$Net, [string]$Type='0')
    $pin = [pscustomobject]@{ owner_id=$Ref; page_id='P1'; name=$Name; number=[string]($pins.Count+1); net=$Net; pin_type=$Type; connected=$true; no_connect=$false }
    $pins.Add($pin)
    if (-not $groups.ContainsKey($Net)) { $groups[$Net] = New-Object System.Collections.Generic.List[object] }
    $groups[$Net].Add($pin)
}
function Add-Resistor {
    param([string]$Ref, [string]$Net, [string]$Rail)
    Add-Part $Ref 10K
    Add-Pin $Ref '1' $Net '4'; Add-Pin $Ref '2' $Rail '4'
}
foreach ($number in 1..19) { Add-Part "U$number" }
Add-Pin U1 IRQ N1; Add-Resistor R1 N1 GND
Add-Pin U2 INT N2; Add-Resistor R2 N2 GND
Add-Pin U3 INT_N N3
Add-Pin U4 /IRQ N4; Add-Resistor R4 N4 3V3
Add-Pin U5 'IRQ#' N5; Add-Resistor R5 N5 3V3
Add-Pin U6 'I\N\T\' N6; Add-Resistor R6 N6 3V3
Add-Pin U7 PHY_INT N7; Add-Resistor R7 N7 GND
Add-Pin U8 IRQ0_N N8; Add-Resistor R8 N8 3V3
Add-Pin U9 GPIO IRQ_N; Add-Resistor R9 IRQ_N 3V3
Add-Pin U10 IRQ N10; Add-Pin U11 IRQ_N N10
Add-Pin U12 INT N2
Add-Pin U13 INT_N INT; Add-Resistor R13 INT 3V3
Add-Pin U14 PRINT N14
Add-Pin U15 INTERFACE N15
Add-Pin U16 IRQ_N N16; Add-Resistor R16 N16 GND
Add-Pin U17 'GPIO2/IRQ' N17; Add-Resistor R17 N17 3V3
Add-Pin U18 'PD18/SPI1_NPCS2/IRQ' N18
Add-Pin U19 'M\D\I\N\T\R\' N19

function Invoke-InterruptCheck {
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
    param([object]$Issues, [string]$Net, [string]$Rule, [string]$Status)
    if (@($Issues | Where-Object { $_.net -eq $Net -and $_.rule -eq $Rule -and $_.status -eq $Status }).Count -ne 1) { throw "Expected $Status/$Rule on $Net" }
}
$result = Invoke-InterruptCheck ''
$issues = @($result.issues | Where-Object { $_.category -eq '中断信号上拉或下拉检查' })
if ($result.coverage['中断信号上拉或下拉检查'] -ne 'automatic_candidates') { throw 'Interrupt detection should run automatically without rules.' }
Assert-Issue $issues N3 '未找到符合要求的外部上拉/下拉电阻' manual_review
Assert-Issue $issues N10 '同一中断网络的有效电平标记冲突' manual_review
Assert-Issue $issues INT '中断引脚与网络名的有效电平标记不一致' manual_review
Assert-Issue $issues N16 '中断外部偏置方向与有效电平不符' error
Assert-Issue $issues N17 '复用中断引脚功能未确认' manual_review
Assert-Issue $issues N18 '复用中断引脚功能未确认' manual_review
Assert-Issue $issues N17 '中断外部偏置方向与有效电平不符' manual_review
foreach ($net in @('N18','N19')) { Assert-Issue $issues $net '未找到符合要求的外部上拉/下拉电阻' manual_review }
foreach ($net in @('N1','N2','N4','N5','N6','N7','N8','IRQ_N','N14','N15')) {
    if (@($issues | Where-Object { $_.net -eq $net }).Count -ne 0) { throw "Unexpected interrupt issue on $net" }
}
if ($issues.Count -ne 9) { throw "Unexpected interrupt issue count: $($issues.Count)" }

$configured = Invoke-InterruptCheck (Join-Path $PSScriptRoot 'interrupt.rules.test.json')
$configuredIssues = @($configured.issues | Where-Object { $_.category -eq '中断信号上拉或下拉检查' })
Assert-Issue $configuredIssues N3 '规则偏置方向与中断名称不一致' manual_review
Assert-Issue $configuredIssues N3 '未找到符合要求的外部上拉/下拉电阻' error
Write-Output 'Interrupt bias tests passed.'
