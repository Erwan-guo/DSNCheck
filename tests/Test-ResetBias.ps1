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
foreach ($number in 1..13) { Add-Part "U$number" }
Add-Pin U1 RESET N1; Add-Resistor R1 N1 GND
Add-Pin U2 RST N2; Add-Resistor R2 N2 GND
Add-Pin U3 RSTN N3; Add-Resistor R3 N3 3V3
Add-Pin U4 /RESET N4
Add-Pin U5 RESET_N N5; Add-Resistor R5 N5 GND
Add-Pin U6 'RESET#' N6; Add-Resistor R6 N6 3V3
Add-Pin U7 'R\S\T\' N7; Add-Resistor R7 N7 3V3
Add-Pin U8 CTRL RSTN; Add-Resistor R8 RSTN 3V3
Add-Pin U9 RESET N9; Add-Pin U10 RSTN N9
Add-Pin U11 RESET N1
Add-Pin U12 NRST N12; Add-Resistor R12 N12 3V3
Add-Pin U13 RSTN RESET; Add-Resistor R13 RESET 3V3

function Invoke-ResetCheck {
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
$result = Invoke-ResetCheck ''
$issues = @($result.issues | Where-Object { $_.category -eq '复位信号上拉或下拉检查' })
if ($result.coverage['复位信号上拉或下拉检查'] -ne 'automatic') { throw 'Reset detection should be automatic without rules.' }
Assert-Issue $issues N4 '未找到符合要求的外部上拉/下拉电阻' error
Assert-Issue $issues N5 '未找到符合要求的外部上拉/下拉电阻' error
Assert-Issue $issues N9 '同一复位网络的有效电平标记冲突' manual_review
Assert-Issue $issues RESET '复位引脚与网络名的有效电平标记不一致' manual_review
foreach ($net in @('N1','N2','N3','N6','N7','RSTN','N12')) {
    if (@($issues | Where-Object { $_.net -eq $net }).Count -ne 0) { throw "Unexpected reset issue on $net" }
}
if ($issues.Count -ne 4) { throw "Unexpected reset issue count: $($issues.Count)" }

$configured = Invoke-ResetCheck (Join-Path $PSScriptRoot 'reset.rules.test.json')
$configuredIssues = @($configured.issues | Where-Object { $_.category -eq '复位信号上拉或下拉检查' })
Assert-Issue $configuredIssues N3 '规则偏置方向与复位名称不一致' manual_review
if (@($configuredIssues | Where-Object { $_.net -eq 'N3' -and $_.status -eq 'error' }).Count -ne 0) { throw 'Legacy direction overrode the inferred active-low direction.' }
Write-Output 'Reset bias tests passed.'
