Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$parts = @{}
$allPins = New-Object System.Collections.Generic.List[object]
$groups = @{}
$powerNets = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$groundNets = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
[void]$powerNets.Add('3V3'); [void]$powerNets.Add('5V')
[void]$groundNets.Add('GND')
$entries = @(
    [pscustomobject]@{ net='3V3'; kind='power'; voltage_v='3.3' },
    [pscustomobject]@{ net='5V'; kind='power'; voltage_v='5' },
    [pscustomobject]@{ net='GND'; kind='ground'; voltage_v='' }
)
function Add-Cap {
    param([string]$Ref, [string]$NetA='3V3', [string]$NetB='GND', [string]$PinA='1', [string]$PinB='2')
    $parts[$Ref] = [pscustomobject]@{ id=$Ref; reference=$Ref; value='100n'; source_part='Test.Normal'; page_id='P1' }
    foreach ($pair in @(@($PinA,$NetA),@($PinB,$NetB))) {
        $pin = [pscustomobject]@{ owner_id=$Ref; page_id='P1'; name=$pair[0]; number=$pair[0]; net=$pair[1]; pin_type='4'; connected=$true; no_connect=$false }
        $allPins.Add($pin)
        if (-not $groups.ContainsKey($pin.net)) { $groups[$pin.net] = New-Object System.Collections.Generic.List[object] }
        $groups[$pin.net].Add($pin)
    }
}
Add-Cap C1
Add-Cap C2
Add-Cap C3
Add-Cap C4
Add-Cap C5 3V3 GND P N
Add-Cap C6 GND 3V3 P N
Add-Cap C7
Add-Cap C8 SIGNAL GND
Add-Cap C9
Add-Cap C10
Add-Cap C11 3V3 GND 1 2
Add-Cap C12
Add-Cap C13 5V 3V3
Add-Cap C14
Add-Cap C15 GND 3V3 P N

$result = & (Join-Path $PSScriptRoot '..\check\generic\Invoke-DSNCheck-Additional.ps1') `
    -OutputDirectory (Join-Path $PSScriptRoot 'fixtures\capacitor') `
    -Parts $parts -AllPins $allPins -Pins $allPins -Groups $groups -PowerNets $powerNets -GroundNets $groundNets -PowerNetEntries $entries
$capIssues = @($result.issues | Where-Object { $_.category -eq '电容耐压降额检查' })
function Assert-Issue {
    param([string]$Part, [string]$Rule, [string]$Status='error')
    if (@($capIssues | Where-Object { $_.part -eq $Part -and $_.rule -eq $Rule -and $_.status -eq $Status }).Count -ne 1) { throw "Expected $Status / $Rule for $Part" }
}
Assert-Issue C2 '非极性电容不满足50%耐压降额等级（一级）'
Assert-Issue C3 '非极性电容不满足50%耐压降额等级（一级）'
Assert-Issue C3 '非极性电容不满足60%耐压降额等级（二级）'
foreach ($level in @('50%耐压降额等级（一级）','60%耐压降额等级（二级）','70%耐压降额等级（三级）')) { Assert-Issue C4 "非极性电容不满足$level" }
Assert-Issue C6 '极性电容不满足三倍耐压'
Assert-Issue C6 '极性电容外部电压极性错误'
Assert-Issue C7 '无法识别本体耐压、外部电压的电容' 'manual_review'
Assert-Issue C8 '无法识别本体耐压、外部电压的电容' 'manual_review'
Assert-Issue C9 '电容极性类型无法识别' 'manual_review'
Assert-Issue C10 '电容极性类型无法识别' 'manual_review'
Assert-Issue C11 '极性电容引脚极性无法识别' 'manual_review'
Assert-Issue C14 '无法识别本体耐压、外部电压的电容' 'manual_review'
Assert-Issue C15 '无法识别本体耐压、外部电压的电容' 'manual_review'
Assert-Issue C15 '极性电容外部电压极性错误'
foreach ($part in @('C1','C5','C12','C13')) {
    if (@($capIssues | Where-Object { $_.part -eq $part }).Count -ne 0) { throw "Unexpected issue for $part" }
}
if (@($capIssues).Count -ne 16) { throw "Unexpected capacitor issue count: $(@($capIssues).Count)" }
Write-Output 'Capacitor derating tests passed.'
