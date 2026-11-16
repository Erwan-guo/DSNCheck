Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$parts = @{}
$groups = @{}
$pins = New-Object System.Collections.Generic.List[object]
$powerNets = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$groundNets = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
[void]$powerNets.Add('3V3'); [void]$groundNets.Add('GND')
function Add-Part {
    param([string]$Id, [string]$Value='')
    $parts[$Id] = [pscustomobject]@{ id=$Id; reference=$Id; value=$Value; source_part='Test.Normal'; page_id='P1' }
}
function Add-Pin {
    param([string]$Owner, [string]$Name, [string]$Net, [string]$Type='0')
    $pin = [pscustomobject]@{ owner_id=$Owner; page_id='P1'; name=$Name; number=[string]($pins.Count+1); net=$Net; pin_type=$Type; connected=$true; no_connect=$false }
    $pins.Add($pin)
    if (-not $groups.ContainsKey($Net)) { $groups[$Net] = New-Object System.Collections.Generic.List[object] }
    $groups[$Net].Add($pin)
}
function Add-Resistor {
    param([string]$Ref, [string]$Value, [string]$A, [string]$B)
    Add-Part $Ref $Value
    Add-Pin $Ref '1' $A '4'
    Add-Pin $Ref '2' $B '4'
}

foreach ($id in @('U1','U2','U3','U4','U5','U6','U7','U8','U9','U10','U11','U12')) { Add-Part $id }
Add-Pin U1 '/OE' N1
Add-Pin U9 OUT1 N1 '1'
Add-Resistor R1 4K7 N1 3V3
Add-Pin U2 OE N2
Add-Pin U9 OUT2 N2 '1'
Add-Resistor R2 4K7 N2 GND
Add-Pin U3 OE_N N3
Add-Resistor R3 33R N3 D3
Add-Pin U9 OUT3 D3 '1'
Add-Resistor R4 4K7 N3 3V3
Add-Resistor R11 10K D3 GND
Add-Pin U4 'OE#' N4
Add-Resistor R5 33R N4 D4
Add-Pin U9 OUT4 D4 '1'
Add-Resistor R6 4K7 D4 3V3
Add-Pin U5 'O\E\' N5
Add-Pin U9 OUT5 N5 '1'
Add-Pin U6 '/OE' N6
Add-Pin U9 OUT6 N6 '1'
Add-Resistor R7 4K7 N6 GND
Add-Pin U7 '/OE' N7
Add-Pin U8 'OE/RESET' N8
Add-Pin U9 OUT8 N8 '1'
Add-Pin U10 '/OE' N10
Add-Pin U9 GPIO N10 '4'
Add-Resistor R8 4K7 N10 3V3
Add-Pin U11 'OE#' N11
Add-Resistor R9 1K N11 D11
Add-Pin U9 OUT11 D11 '1'
Add-Resistor R10 4K7 N11 3V3
Add-Pin U12 '/OE' N12
Add-Pin U9 GPIO12 N12 '4'

$result = & (Join-Path $PSScriptRoot '..\check\generic\Invoke-DSNCheck-Additional.ps1') `
    -OutputDirectory (Join-Path $PSScriptRoot 'fixtures\additional') `
    -RulesFile (Join-Path $PSScriptRoot 'oe.rules.test.json') `
    -Parts $parts -AllPins $pins -Pins $pins -Groups $groups -PowerNets $powerNets -GroundNets $groundNets `
    -PowerNetEntries @([pscustomobject]@{ net='3V3'; kind='power'; voltage_v='3.3' },[pscustomobject]@{ net='GND'; kind='ground'; voltage_v='' })
$issues = @($result.issues | Where-Object { $_.category -eq 'OE上拉检查' })
function Assert-Issue {
    param([string]$Part, [string]$Rule, [string]$Status)
    if (@($issues | Where-Object { $_.part -eq $Part -and $_.rule -eq $Rule -and $_.status -eq $Status }).Count -ne 1) { throw "Expected $Status/$Rule on $Part" }
}
foreach ($part in @('U1','U2','U3','U4','U10')) { Assert-Issue $part '外部驱动上电状态未确认' 'manual_review' }
Assert-Issue U4 'OE偏置仅位于串阻驱动侧' 'manual_review'
Assert-Issue U3 '串阻驱动侧存在相反偏置' 'manual_review'
Assert-Issue U5 '未找到符合要求的外部上拉/下拉电阻' 'error'
Assert-Issue U6 'OE通过电阻永久拉到有效电平' 'manual_review'
Assert-Issue U7 '未识别到其他芯片驱动OE' 'manual_review'
Assert-Issue U8 '无法从OE引脚名判断有效电平' 'manual_review'
Assert-Issue U10 '外部芯片引脚驱动方向未确认' 'manual_review'
Assert-Issue U11 '未识别到其他芯片驱动OE' 'manual_review'
Assert-Issue U12 '外部芯片引脚驱动方向未确认' 'manual_review'
Assert-Issue U12 '未找到符合要求的外部上拉/下拉电阻' 'manual_review'
if (@($issues | Where-Object { $_.status -eq 'error' }).Count -ne 1) { throw 'Expected exactly one OE bias error.' }
Write-Output 'OE startup-state tests passed.'
