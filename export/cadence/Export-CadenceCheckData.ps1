[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Dsn,

    [Parameter(Position = 1)]
    [string]$OutputDirectory,

    [string]$CaptureExe,

    [ValidateRange(30, 3600)]
    [int]$TimeoutSeconds = 600,

    [switch]$ShowCapture,

    [switch]$SkipNativeIscf,

    [switch]$SkipBundledDrc
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-CaptureExe {
    param([string]$RequestedPath)

    if ($RequestedPath) {
        return (Resolve-Path -LiteralPath $RequestedPath).Path
    }

    $command = Get-Command 'Capture.exe' -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $knownPaths = @(
        'D:\Cadence\SPB_16.6\tools\capture\Capture.exe',
        'C:\Cadence\SPB_16.6\tools\capture\Capture.exe'
    )
    foreach ($path in $knownPaths) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            return (Resolve-Path -LiteralPath $path).Path
        }
    }

    throw 'Cannot locate Capture.exe. Supply -CaptureExe explicitly.'
}

function Set-TemporaryEnvironmentValue {
    param(
        [hashtable]$SavedValues,
        [string]$Name,
        [string]$Value
    )

    $SavedValues[$Name] = [Environment]::GetEnvironmentVariable($Name, 'Process')
    [Environment]::SetEnvironmentVariable($Name, $Value, 'Process')
}

$dsnPath = (Resolve-Path -LiteralPath $Dsn).Path
if ([IO.Path]::GetExtension($dsnPath) -ine '.dsn') {
    throw "Input must be an OrCAD Capture .DSN file: $dsnPath"
}

$capturePath = Resolve-CaptureExe -RequestedPath $CaptureExe
$captureDirectory = [IO.Path]::GetDirectoryName($capturePath)
$tclScriptsDirectory = Join-Path $captureDirectory 'tclscripts'
if (-not (Test-Path -LiteralPath $tclScriptsDirectory -PathType Container)) {
    throw "Cadence tclscripts directory was not found beside Capture.exe: $tclScriptsDirectory"
}

if (-not $OutputDirectory) {
    $parent = [IO.Path]::GetDirectoryName($dsnPath)
    $stem = [IO.Path]::GetFileNameWithoutExtension($dsnPath)
    $OutputDirectory = Join-Path $parent ($stem + '_checkdata')
}

$outputPath = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
foreach ($staleName in @('export.ok', 'export.error.json')) {
    $stalePath = Join-Path $outputPath $staleName
    if (Test-Path -LiteralPath $stalePath -PathType Leaf) {
        Remove-Item -LiteralPath $stalePath -Force
    }
}

$captureScriptSource = Join-Path $PSScriptRoot 'capture_export_all.tcl'
if (-not (Test-Path -LiteralPath $captureScriptSource -PathType Leaf)) {
    throw "Capture exporter script is missing: $captureScriptSource"
}

# Capture 16.6 embeds Tcl 8.4 and cannot reliably open a command-line script
# whose path contains non-ANSI characters. Stage only this script under TEMP
# with an ASCII file name; all generated data still goes to OutputDirectory.
$captureScript = Join-Path ([IO.Path]::GetTempPath()) ("capcheck-export-{0}.tcl" -f ([Guid]::NewGuid().ToString('N')))
Copy-Item -LiteralPath $captureScriptSource -Destination $captureScript

$savedEnvironment = @{}
try {
    Set-TemporaryEnvironmentValue $savedEnvironment 'CAPCHECK_DSN' $dsnPath
    Set-TemporaryEnvironmentValue $savedEnvironment 'CAPCHECK_OUT' $outputPath
    Set-TemporaryEnvironmentValue $savedEnvironment 'CAPCHECK_TCLSCRIPTS' $tclScriptsDirectory
    Set-TemporaryEnvironmentValue $savedEnvironment 'CAPCHECK_SKIP_ISCF' ($(if ($SkipNativeIscf) { '1' } else { '0' }))
    Set-TemporaryEnvironmentValue $savedEnvironment 'CAPCHECK_SKIP_BUNDLED_DRC' ($(if ($SkipBundledDrc) { '1' } else { '0' }))

    $startArguments = @{
        FilePath         = $capturePath
        ArgumentList     = '"' + $captureScript.Replace('\', '/') + '"'
        WorkingDirectory = $captureDirectory
        PassThru         = $true
    }
    if (-not $ShowCapture) {
        $startArguments.WindowStyle = 'Hidden'
    }

    Write-Host "Starting Cadence Capture exporter..."
    Write-Host "  DSN:    $dsnPath"
    Write-Host "  Output: $outputPath"

    $process = Start-Process @startArguments
    $successMarker = Join-Path $outputPath 'export.ok'
    $errorPath = Join-Path $outputPath 'export.error.json'
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $captureMissingSince = $null
    while ([DateTime]::UtcNow -lt $deadline) {
        if ((Test-Path -LiteralPath $successMarker -PathType Leaf) -or
            (Test-Path -LiteralPath $errorPath -PathType Leaf)) {
            break
        }
        if ($process.HasExited -and -not (Get-Process -Name 'Capture' -ErrorAction SilentlyContinue)) {
            if ($null -eq $captureMissingSince) {
                $captureMissingSince = [DateTime]::UtcNow
            }
            elseif (([DateTime]::UtcNow - $captureMissingSince).TotalSeconds -ge 3) {
                throw 'Capture.exe exited before Tcl created any output. Check the Cadence product/license selection and Windows compatibility; Capture 16.6 may crash on newer Windows builds.'
            }
        }
        else {
            $captureMissingSince = $null
        }
        Start-Sleep -Milliseconds 500
    }
    if (-not (Test-Path -LiteralPath $successMarker -PathType Leaf) -and
        -not (Test-Path -LiteralPath $errorPath -PathType Leaf)) {
        throw "Cadence export timed out after $TimeoutSeconds seconds. Capture may still be open; it was not terminated because Capture 16.6 can hand work to an existing user session."
    }
}
finally {
    foreach ($name in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
    }
    if (Test-Path -LiteralPath $captureScript -PathType Leaf) {
        Remove-Item -LiteralPath $captureScript -Force
    }
}

$manifestPath = Join-Path $outputPath 'manifest.json'

if (-not (Test-Path -LiteralPath $successMarker -PathType Leaf)) {
    if (Test-Path -LiteralPath $errorPath -PathType Leaf) {
        $details = Get-Content -LiteralPath $errorPath -Raw
        throw "Capture exporter failed: $details"
    }
    throw "Capture exited without producing export.ok. Inspect '$outputPath\capture_export.log'."
}

if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Capture exporter did not produce manifest.json in $outputPath"
}

Write-Host "Cadence check data exported successfully: $outputPath"
Get-Content -LiteralPath $manifestPath
