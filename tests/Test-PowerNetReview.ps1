Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('DSNCheck-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $tempRoot 'dbo') -Force | Out-Null
try {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures\power_review\dbo\objects.jsonl') -Destination (Join-Path $tempRoot 'dbo\objects.jsonl')
    $fixturePath = Join-Path $tempRoot 'dbo\objects.jsonl'
    $completeRecords = foreach ($line in [IO.File]::ReadAllLines($fixturePath)) {
        $record = $line | ConvertFrom-Json
        if ($record.record -eq 'part') {
            foreach ($field in @('pcb_footprint','left','top','right','bottom')) { $record | Add-Member -NotePropertyName $field -NotePropertyValue '0' }
        } elseif ($record.record -eq 'pin') {
            foreach ($field in @('offset_hot_x','offset_hot_y')) { $record | Add-Member -NotePropertyName $field -NotePropertyValue '0' }
        }
        $record | ConvertTo-Json -Compress -Depth 5
    }
    $completeRecords | Set-Content -LiteralPath $fixturePath -Encoding UTF8
    $review = Join-Path $tempRoot 'power_nets.review.csv'
    $confirmed = Join-Path $tempRoot 'power_nets.confirmed.json'
    $reviewer = Join-Path $PSScriptRoot '..\check\generic\Invoke-PowerNetReview.ps1'
    & $reviewer -InputDirectory $tempRoot -Mode Draft | Out-Null
    $rows = @(Import-Csv -LiteralPath $review -Encoding UTF8)
    foreach ($net in @('3V3','VDD_IO','AVDD','VDD_FILT','STRONG_NET','GROUND_NET','VCC_MISC','1V8','2V5')) {
        if (@($rows | Where-Object net -eq $net).Count -ne 1) { throw "Missing candidate: $net" }
    }
    if (@($rows | Where-Object net -eq 'WEAK_NET').Count -ne 0) { throw '10K resistor was incorrectly propagated.' }
    if (@($rows | Where-Object { $_.net -eq 'VDD_IO' -and $_.kind -eq 'power' -and $_.voltage_v -eq '3.3' }).Count -ne 1) { throw '0R bridge did not inherit 3V3 voltage.' }
    if (@($rows | Where-Object { $_.net -eq 'STRONG_NET' -and $_.source -eq 'strong_pull_review' }).Count -ne 1) { throw 'Strong pull must require review.' }
    if (@($rows | Where-Object { $_.net -eq '1V8' -and $_.kind -eq 'conflict' }).Count -ne 1) { throw 'Conflicting voltage seeds were not flagged.' }
    foreach ($row in $rows) { $row.decision = if ($row.net -eq 'STRONG_NET' -or $row.kind -eq 'conflict') { 'reject' } else { 'accept' } }
    $rows | Export-Csv -LiteralPath $review -NoTypeInformation -Encoding UTF8
    & $reviewer -InputDirectory $tempRoot -Mode Confirm | Out-Null
    $map = Get-Content -LiteralPath $confirmed -Raw -Encoding UTF8 | ConvertFrom-Json
    if (@($map.nets | Where-Object { $_.net -eq 'VDD_FILT' -and $_.kind -eq 'power' }).Count -ne 1) { throw 'Bridge propagation was not confirmed.' }
    if (@($map.nets | Where-Object net -eq 'STRONG_NET').Count -ne 0) { throw 'Rejected strong pull was accepted.' }
    & (Join-Path $PSScriptRoot '..\check\generic\Run-DSNCheck.ps1') -InputDirectory $tempRoot | Out-Null
    $report = Get-Content -LiteralPath (Join-Path $tempRoot 'dsn_check_report.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($report.confirmed_power_nets -ne 5 -or $report.confirmed_ground_nets -ne 1) { throw 'Checker did not consume confirmed map.' }
    if ($report.summary.PSObject.Properties.Name -contains '地符号未标注名称') { throw 'Removed G04 category remains in the report.' }
    Add-Content -LiteralPath $fixturePath -Value '{"record":"wire","net_name":"NEW_NET"}'
    $staleRejected = $false
    try { & (Join-Path $PSScriptRoot '..\check\generic\Run-DSNCheck.ps1') -InputDirectory $tempRoot | Out-Null } catch { $staleRejected = ($_.Exception.Message -match 'does not match') }
    if (-not $staleRejected) { throw 'Stale confirmed map was not rejected.' }
    Write-Output 'Power-net review tests passed.'
} finally {
    if (([IO.Path]::GetFullPath($tempRoot)).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
