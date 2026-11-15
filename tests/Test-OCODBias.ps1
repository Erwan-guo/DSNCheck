Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$parts = @{}
$groups = @{}
$pins = New-Object System.Collections.Generic.List[object]
$powerNets = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$groundNets = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
[void]$powerNets.Add('3V3')
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
Add-Part U1
Add-Part U2
Add-Part U3
Add-Part U4
Add-Part Q1
Add-Part R1 4K7
Add-Pin U1 FLAGA N1 '3'
Add-Pin U2 FLAGB N2 'Open Drain'
Add-Pin U3 OD_OUT N3 '1'
Add-Pin U4 FLAGC N4 '5'
Add-Pin Q1 D N5 '3'
Add-Pin R1 1 N1 '4'
Add-Pin R1 2 3V3 '4'

$result = & (Join-Path $PSScriptRoot '..\check\generic\Invoke-DSNCheck-Additional.ps1') `
    -OutputDirectory (Join-Path $PSScriptRoot 'fixtures\additional') `
    -Parts $parts -AllPins $pins -Pins $pins -Groups $groups -PowerNets $powerNets -GroundNets $groundNets `
    -PowerNetEntries @([pscustomobject]@{ net='3V3'; kind='power'; voltage_v='3.3' })
$issues = @($result.issues | Where-Object { $_.category -eq 'OC/OD门上拉检查' })
if ($result.coverage['OC/OD门上拉检查'] -ne 'automatic') { throw 'Expected automatic OC/OD coverage.' }
if (@($issues | Where-Object { $_.part -eq 'U2' -and $_.status -eq 'error' -and $_.rule -eq '未找到符合要求的外部上拉/下拉电阻' }).Count -ne 1) { throw 'Expected missing pull-up on text Open Drain type.' }
if (@($issues | Where-Object { $_.part -ne 'U2' }).Count -ne 0) { throw 'Only the unpulled OC/OD gate should be reported.' }
Write-Output 'OC/OD pin-type tests passed.'
