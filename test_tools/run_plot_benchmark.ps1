param(
    [ValidateSet('quick', 'soak', 'lod', 'lod-quick', 'lod-gate-quick', 'lod-gate')]
    [string]$Preset = 'quick',

    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$Label = 'optimized',

    [ValidateSet('canvas', 'd3d11')]
    [string]$Engine = 'canvas'
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$outputDirectory = Join-Path $projectRoot 'build/performance'
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null

Push-Location $projectRoot
try {
    $target = if ($Preset -in @('lod', 'lod-quick', 'lod-gate-quick', 'lod-gate')) {
        'integration_test/plot_lod_performance_test.dart'
    } else {
        'integration_test/plot_performance_test.dart'
    }
    $lodQuick = if ($Preset -in @('lod-quick', 'lod-gate-quick')) { 'true' } else { 'false' }
    $lodGate = if ($Preset -in @('lod-gate-quick', 'lod-gate')) { 'true' } else { 'false' }
    flutter drive `
        --driver=test_driver/integration_test.dart `
        --target=$target `
        --device-id=windows `
        --profile `
        --dart-define=PLOT_PERF_METRICS=true `
        --dart-define=PLOT_BENCHMARK_PRESET=$Preset `
        --dart-define=PLOT_LOD_BENCHMARK_QUICK=$lodQuick `
        --dart-define=PLOT_LOD_BENCHMARK_GATE=$lodGate `
        --dart-define=PLOT_RENDER_ENGINE=$Engine `
        --dart-define=PLOT_BENCHMARK_LABEL=$Label `
        --dart-define=PLOT_BENCHMARK_OUTPUT_DIR=$($outputDirectory.Replace('\', '/'))

    if ($LASTEXITCODE -ne 0) {
        throw "绘图性能基准执行失败，退出码: $LASTEXITCODE"
    }
} finally {
    Pop-Location
}

Write-Host "性能报告已保存到: $outputDirectory"
