Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$parts = @{}
$groups = @{}
$allPins = New-Object System.Collections.Generic.List[object]
$powerNets = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$groundNets = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
[void]$powerNets.Add('3V3')
[void]$groundNets.Add('GND')
$powerNetEntries = @([pscustomobject]@{ net='3V3'; kind='power'; voltage_v='3.3' }, [pscustomobject]@{ net='GND'; kind='ground'; voltage_v='' })
function Add-Part {
    param([string]$Id, [string]$Reference, [string]$Value='')
    $parts[$Id] = [pscustomobject]@{ id=$Id; reference=$Reference; value=$Value; source_part='Test.Normal'; page_id='P1' }
}
function Add-Pin {
    param([string]$Owner, [string]$Name, [string]$Net, [string]$Type='0')
    $pin = [pscustomobject]@{ owner_id=$Owner; page_id='P1'; name=$Name; number=([string]($allPins.Count + 1)); net=$Net; pin_type=$Type; connected=$true; no_connect=$false }
    $allPins.Add($pin)
    if (-not $groups.ContainsKey($Net)) { $groups[$Net] = New-Object System.Collections.Generic.List[object] }
    $groups[$Net].Add($pin)
}

Add-Part 'U1' 'U1'
Add-Part 'U2' 'U2'
Add-Part 'U3' 'U3'
Add-Part 'U4' 'U4'
Add-Part 'U5' 'U5'
Add-Part 'R1' 'R1' '4K7'
Add-Part 'R2' 'R2' '33R'
Add-Part 'C1' 'C1' '100n'
Add-Pin 'U1' 'OE' 'CTRL'
Add-Pin 'U1' 'OUT' 'SLOW'
Add-Pin 'U1' 'FAULT' 'bad-net'
Add-Pin 'R1' '1' 'CTRL' '4'
Add-Pin 'R1' '2' '3V3' '4'
Add-Pin 'U2' 'IN' 'FLOAT'
Add-Pin 'U3' 'DP' 'NET_DIFF'
Add-Pin 'U3' 'DN' 'NET_DIFF'
Add-Pin 'U4' 'CLK' 'CLK_IN'
Add-Pin 'R2' '1' 'CLK_IN' '4'
Add-Pin 'R2' '2' 'CLK_SRC' '4'
Add-Pin 'U5' 'CLK_OUT' 'CLK_SRC' '1'
Add-Pin 'C1' '1' '3V3' '4'
Add-Pin 'C1' '2' 'GND' '4'

$result = & (Join-Path $PSScriptRoot '..\check\generic\Invoke-DSNCheck-Additional.ps1') `
    -OutputDirectory (Join-Path $PSScriptRoot 'fixtures\additional') `
    -RulesFile (Join-Path $PSScriptRoot 'additional.rules.test.json') `
    -Parts $parts -AllPins $allPins -Pins $allPins -Groups $groups -PowerNets $powerNets -GroundNets $groundNets -PowerNetEntries $powerNetEntries
$errors = @($result.issues | Where-Object { $_.status -eq 'error' })
foreach ($category in @('Bus-hold器件输入管脚检查', '差分管脚连接检查', '电容耐压降额检查', '网络命名检查', '压摆率较低器件限制')) {
    if (@($errors | Where-Object { $_.category -eq $category }).Count -ne 1) { throw "Expected one error for $category" }
}
foreach ($category in @('OE上拉检查', '时钟信号串阻检查')) {
    if (@($errors | Where-Object { $_.category -eq $category }).Count -ne 0) { throw "Unexpected error for $category" }
}
if ($result.coverage['复位信号上拉或下拉检查'] -ne 'no_targets') { throw 'Expected no_targets coverage' }
if (@($result.issues | Where-Object { $_.category -eq 'OE上拉检查' -and $_.rule -eq '规则偏置方向与OE命名不一致' -and $_.status -eq 'manual_review' }).Count -ne 1) { throw 'OE rule direction conflict was not reported.' }
Write-Output 'Additional rule tests passed.'
