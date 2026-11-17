Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('DSNCheck-FilterCap-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $tempRoot 'dbo') -Force | Out-Null
try {
    $records = New-Object System.Collections.Generic.List[string]
    function Add-Part {
        param([string]$Id, [string]$Page)
        $records.Add(([pscustomobject]@{ record='part'; id=$Id; page_id=$Page; reference=$Id; value=''; source_part='Test.Normal'; pcb_footprint=''; left='0'; top='0'; right='10'; bottom='10' } | ConvertTo-Json -Compress))
    }
    function Add-Pin {
        param([string]$Part, [string]$Page, [string]$Name, [string]$Net, [string]$Type, [string]$X, [string]$Connected='1')
        $records.Add(([pscustomobject]@{ record='pin'; id="$Part/$Name"; owner_id=$Part; page_id=$Page; name=$Name; number=$Name; pin_type=$Type; connected=$Connected; no_connect='0'; net_name=$Net; offset_hot_x=$X; offset_hot_y='0' } | ConvertTo-Json -Compress))
    }

    Add-Part U1 P1; Add-Pin U1 P1 VCC 3V3 7 0
    Add-Part C1 P1; Add-Pin C1 P1 1 3V3 4 10000; Add-Pin C1 P1 2 GND 4 10000
    Add-Part U2 P1; Add-Pin U2 P1 VCC 5V 7 0
    Add-Part C2 P2; Add-Pin C2 P2 1 5V 4 0; Add-Pin C2 P2 2 GND 4 0
    Add-Part U3 P2; Add-Pin U3 P2 VCC 3V3 7 0
    Add-Part C3 P2; Add-Pin C3 P2 1 3V3 4 0 '0'; Add-Pin C3 P2 2 GND 4 0

    $objectsPath = Join-Path $tempRoot 'dbo\objects.jsonl'
    $records | Set-Content -LiteralPath $objectsPath -Encoding UTF8
    $hash = (Get-FileHash -LiteralPath $objectsPath -Algorithm SHA256).Hash
    $map = [ordered]@{
        schema_version=1; source_sha256=$hash; review_status='user_confirmed'
        nets=@(
            [pscustomobject]@{ net='3V3'; kind='power'; voltage_v='3.3' }
            [pscustomobject]@{ net='5V'; kind='power'; voltage_v='5' }
            [pscustomobject]@{ net='GND'; kind='ground'; voltage_v='' }
        )
    }
    $map | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $tempRoot 'power_nets.confirmed.json') -Encoding UTF8
    & (Join-Path $PSScriptRoot '..\check\generic\Run-DSNCheck.ps1') -InputDirectory $tempRoot | Out-Null
    $report = Get-Content -LiteralPath (Join-Path $tempRoot 'dsn_check_report.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $issues = @($report.errors | Where-Object { $_.category -eq '供电器件缺少就近滤波电容' })
    if (@($issues | Where-Object part -eq 'U1').Count -ne 0) { throw 'Distant same-page capacitor on the same named rail was rejected.' }
    foreach ($part in @('U2','U3')) {
        if (@($issues | Where-Object part -eq $part).Count -ne 1) { throw "Expected missing same-page capacitor for $part." }
    }
    if ($issues.Count -ne 2) { throw "Unexpected filter capacitor issue count: $($issues.Count)" }
    if ($report.PSObject.Properties.Name -contains 'filter_cap_distance') { throw 'Obsolete filter distance remains in JSON report.' }
    $text = Get-Content -LiteralPath (Join-Path $tempRoot 'dsn_check_report.txt') -Raw -Encoding UTF8
    if ($text -match '搜索半径') { throw 'Obsolete filter distance remains in text report.' }
    Write-Output 'Same-page filter capacitor tests passed.'
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
}
