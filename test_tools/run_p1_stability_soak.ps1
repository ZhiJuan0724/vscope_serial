param(
    [ValidateRange(1, 8)]
    [int]$NoiseGiB = 1,

    [ValidateRange(1, 3)]
    [int]$ImportGiB = 1,

    [ValidateRange(1, 16)]
    [int]$Channels = 16,

    [switch]$KeepImportFile
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$outputDirectory = Join-Path $projectRoot 'build/p1_stability_soak'
$importPath = Join-Path $outputDirectory 'large_import.bin'
$noiseBytes = [int64]$NoiseGiB * 1024 * 1024 * 1024
$targetImportBytes = [int64]$ImportGiB * 1024 * 1024 * 1024
$rowBytes = 8 + $Channels * 8
$pointCount = [math]::Floor(($targetImportBytes - 4096) / $rowBytes)
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null

Push-Location $projectRoot
try {
    flutter test test/manual/p1_stability_soak_test.dart `
        "--dart-define=RUN_P1_PARSER_SOAK=true" `
        "--dart-define=P1_NOISE_BYTES=$noiseBytes"
    if ($LASTEXITCODE -ne 0) {
        throw "P1 parser soak failed with exit code $LASTEXITCODE"
    }

    python test_tools/generate_plot_bin.py `
        --output $importPath `
        --packets $pointCount `
        --channels $Channels `
        --mode sine `
        --progress 250000
    if ($LASTEXITCODE -ne 0) {
        throw "Large BIN generation failed with exit code $LASTEXITCODE"
    }

    $normalizedImportPath = $importPath.Replace('\', '/')
    flutter test test/manual/p1_stability_soak_test.dart `
        "--dart-define=P1_IMPORT_FILE=$normalizedImportPath" `
        "--dart-define=P1_IMPORT_POINTS=$pointCount"
    if ($LASTEXITCODE -ne 0) {
        throw "P1 large import soak failed with exit code $LASTEXITCODE"
    }
} finally {
    Pop-Location
    if (-not $KeepImportFile -and (Test-Path -LiteralPath $importPath)) {
        Remove-Item -LiteralPath $importPath -Force
    }
}

Write-Host 'P1 parser and large import soak completed.'
