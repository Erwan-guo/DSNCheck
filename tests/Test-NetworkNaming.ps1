Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$parts = @{
    U1 = [pscustomobject]@{ reference='U1' }
    U2 = [pscustomobject]@{ reference='U2' }
}
$pins = New-Object System.Collections.Generic.List[object]
$groups = @{}
function Add-Pin {
    param([string]$Owner, [string]$Name, [string]$Net, [string]$Number)
    $pin = [pscustomobject]@{ owner_id=$Owner; page_id='P1'; name=$Name; number=$Number; net=$Net; connected=$true; no_connect=$false }
    $pins.Add($pin)
    if (-not $groups.ContainsKey($Net)) { $groups[$Net] = New-Object System.Collections.Generic.List[object] }
    $groups[$Net].Add($pin)
}
Add-Pin U1 TX_P N123 1
Add-Pin U1 TX_N TX_N 2
Add-Pin U2 RX_P RX_P 1
Add-Pin U2 RX_N RX_N 2
foreach ($number in 1..4) { Add-Pin U2 ('IO'+$number) N999 ([string]($number+2)) }

$result = & (Join-Path $PSScriptRoot '..\check\generic\Invoke-DSNCheck-Naming.ps1') `
    -OutputDirectory (Join-Path $PSScriptRoot 'fixtures\naming') -Parts $parts -AllPins $pins -Groups $groups `
    -NamingRule ([pscustomobject]@{ auto_net_max_pins=3 })
$issues = @($result.issues)
foreach ($rule in @('不同名称的Off-page/电源符号直连','疑似缺少Off-page/电源符号','差分网络命名遗漏或不匹配','自动命名网络连接数过多')) {
    if (@($issues | Where-Object { $_.rule -eq $rule }).Count -ne 1) { throw "Expected exactly one naming issue: $rule" }
}
if (@($issues | Where-Object { $_.net -eq 'BUS2' }).Count -ne 0) { throw 'Bus member was incorrectly treated as a missing off-page connector.' }
if (@($issues | Where-Object { $_.rule -eq '不同名称的Off-page/电源符号直连' -and $_.status -eq 'error' }).Count -ne 1) { throw 'Direct symbol conflict must be an error.' }
if (@($issues | Where-Object { $_.status -eq 'manual_review' }).Count -ne 3) { throw 'Uncertain naming cases must be review candidates.' }
Write-Output 'Network naming tests passed.'
