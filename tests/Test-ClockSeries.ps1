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
    param([string]$Ref, [string]$Value, [string]$A, [string]$B)
    Add-Part $Ref $Value
    Add-Pin $Ref '1' $A '4'; Add-Pin $Ref '2' $B '4'
}
foreach ($number in 1..8) {
    Add-Part "U$number"
    Add-Part "D$number"
    Add-Pin "U$number" CLK "CLK_$number"
    if ($number -ne 8) { Add-Pin "D$number" OUT "SRC_$number" '1' }
}
Add-Resistor R1 33R CLK_1 SRC_1
Add-Resistor R2 34R CLK_2 SRC_2
Add-Pin D3 EXTRA CLK_3 '1'
Add-Resistor R4 22R CLK_4 MID_4
Add-Resistor R5 10R MID_4 SRC_4
Add-Resistor R6 22R CLK_5 SRC_5
Add-Resistor R7 10R CLK_5 SRC_5
Add-Resistor R8 TBD CLK_6 SRC_6
Add-Resistor R9 22R CLK_7 SRC_7
Add-Pin D7 BYPASS CLK_7 '1'
Add-Resistor R10 22R CLK_8 DEAD_8

$result = & (Join-Path $PSScriptRoot '..\check\generic\Invoke-DSNCheck-Additional.ps1') `
    -OutputDirectory (Join-Path $PSScriptRoot 'fixtures\additional') `
    -RulesFile (Join-Path $PSScriptRoot 'clock.rules.test.json') `
    -Parts $parts -AllPins $pins -Pins $pins -Groups $groups -PowerNets $powerNets -GroundNets $groundNets `
    -PowerNetEntries @([pscustomobject]@{ net='3V3'; kind='power'; voltage_v='3.3' }, [pscustomobject]@{ net='GND'; kind='ground'; voltage_v='' })
$issues = @($result.issues | Where-Object { $_.category -eq '时钟信号串阻检查' })
function Assert-Issue {
    param([string]$Ref, [string]$Rule, [string]$Status)
    if (@($issues | Where-Object { $_.part -eq $Ref -and $_.rule -eq $Rule -and $_.status -eq $Status }).Count -ne 1) { throw "Expected $Status/$Rule for $Ref" }
}
if (@($issues | Where-Object { $_.part -eq 'U1' }).Count -ne 0) { throw '33 ohms should pass.' }
Assert-Issue U2 '时钟串阻大于允许值' warning
Assert-Issue U3 '时钟路径没有串阻' error
Assert-Issue U4 '时钟路径存在多个串阻' error
Assert-Issue U5 '时钟路径存在多个串阻' error
Assert-Issue U6 '串阻阻值无法解析' manual_review
Assert-Issue U7 '时钟路径没有串阻' error
Assert-Issue U8 '未找到对端器件引脚' error
if ($issues.Count -ne 7) { throw "Unexpected clock issue count: $($issues.Count)" }
Write-Output 'Clock series tests passed.'
