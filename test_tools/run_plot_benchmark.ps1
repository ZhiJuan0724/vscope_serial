param(
    [ValidateSet('quick', 'soak')]
    [string]$Preset = 'quick',

    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$Label = 'optimized'
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$outputDirectory = Join-Path $projectRoot 'build/performance'
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null

Push-Location $projectRoot
try {
    flutter drive `
        --driver=test_driver/integration_test.dart `
        --target=integration_test/plot_performance_test.dart `
        --device-id=windows `
        --profile `
        --dart-define=PLOT_PERF_METRICS=true `
        --dart-define=PLOT_BENCHMARK_PRESET=$Preset `
        --dart-define=PLOT_BENCHMARK_LABEL=$Label `
        --dart-define=PLOT_BENCHMARK_OUTPUT_DIR=$($outputDirectory.Replace('\', '/'))

    if ($LASTEXITCODE -ne 0) {
        throw "绘图性能基准执行失败，退出码: $LASTEXITCODE"
    }
} finally {
    Pop-Location
}

Write-Host "性能报告已保存到: $outputDirectory"
