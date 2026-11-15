Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$parts = @{}
$groups = @{}
$pins = New-Object System.Collections.Generic.List[object]
$powerNets = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$groundNets = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
[void]$powerNets.Add('3V3')
[void]$powerNets.Add('1V8')
[void]$groundNets.Add('GND')
function Add-Part {
    param([string]$Ref, [string]$Value='')
    $parts[$Ref] = [pscustomobject]@{ id=$Ref; reference=$Ref; value=$Value; source_part='Test.Normal'; page_id='P1' }
}
function Add-Pin {
    param([string]$Owner, [string]$Name, [string]$Net, [string]$Type)
    $pin = [pscustomobject]@{ owner_id=$Owner; page_id='P1'; name=$Name; number=[string]($pins.Count+1); net=$Net; pin_type=$Type; connected=$true; no_connect=$false }
    $pins.Add($pin)
    if (-not $groups.ContainsKey($Net)) { $groups[$Net] = New-Object System.Collections.Generic.List[object] }
    $groups[$Net].Add($pin)
}
function Add-Resistor {
    param([string]$Ref, [string]$Net, [string]$Rail)
    Add-Part $Ref '4K7'
    Add-Pin $Ref 1 $Net '4'
    Add-Pin $Ref 2 $Rail '4'
}
foreach ($ref in @('U1','U2','U3','U4','J1')) { Add-Part $ref }
foreach ($net in @('OK','DUP','CROSS_POWER','CROSS_DIRECTION','NO_BIAS','MULTI_DRIVER','CONNECTOR')) {
    Add-Pin U1 OUT $net '1'
    Add-Pin U2 IN $net '0'
    Add-Pin U3 IN $net '0'
}
Add-Pin U4 OUT MULTI_DRIVER '1'
Add-Pin J1 1 CONNECTOR '4'
Add-Resistor R1 OK 3V3
Add-Resistor R2 DUP 3V3
Add-Resistor R3 DUP 3V3
Add-Resistor R4 CROSS_POWER 3V3
Add-Resistor R5 CROSS_POWER 1V8
Add-Resistor R6 CROSS_DIRECTION 3V3
Add-Resistor R7 CROSS_DIRECTION GND
Add-Resistor R8 CONNECTOR 3V3
Add-Resistor R9 CONNECTOR 3V3

$result = & (Join-Path $PSScriptRoot '..\check\generic\Invoke-DSNCheck-Additional.ps1') `
    -OutputDirectory (Join-Path $PSScriptRoot 'fixtures\additional') `
    -Parts $parts -AllPins $pins -Pins $pins -Groups $groups -PowerNets $powerNets -GroundNets $groundNets `
    -PowerNetEntries @([pscustomobject]@{ net='3V3'; kind='power'; voltage_v='3.3' },[pscustomobject]@{ net='1V8'; kind='power'; voltage_v='1.8' },[pscustomobject]@{ net='GND'; kind='ground'; voltage_v='' })
$issues = @($result.issues | Where-Object { $_.category -eq '网络上拉或下拉检查' })
if ($issues.Count -ne 3) { throw "Expected three network-bias issues, got $($issues.Count)." }
if (@($issues | Where-Object { $_.net -eq 'DUP' -and $_.status -eq 'warning' }).Count -ne 1) { throw 'Expected a duplicate-pull warning.' }
foreach ($net in @('CROSS_POWER','CROSS_DIRECTION')) {
    if (@($issues | Where-Object { $_.net -eq $net -and $_.status -eq 'error' }).Count -ne 1) { throw "Expected conflicting-rail error for $net." }
}
if ($result.coverage['网络上拉或下拉检查'] -ne 'automatic') { throw 'Expected automatic coverage.' }
Write-Output 'Network bias topology tests passed.'
