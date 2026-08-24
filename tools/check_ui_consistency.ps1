param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$libRoot = Join-Path $repoRoot 'lib'

function Count-Pattern([string]$Pattern) {
    $matches = Get-ChildItem -LiteralPath $libRoot -Recurse -Filter '*.dart' |
        Select-String -Pattern $Pattern
    return @($matches).Count
}

function Count-MultilinePattern([string]$Pattern) {
    $count = 0
    Get-ChildItem -LiteralPath $libRoot -Recurse -Filter '*.dart' | ForEach-Object {
        $content = Get-Content -LiteralPath $_.FullName -Raw -Encoding utf8
        $count += [regex]::Matches(
            $content,
            $Pattern,
            [System.Text.RegularExpressions.RegexOptions]::Singleline
        ).Count
    }
    return $count
}

# 已归零的原生表单下拉不得重新出现；其余历史样式采用只减不增基线。
$limits = @(
    @{ Name = '原生动画表单下拉'; Pattern = '\bDropdownButtonFormField\s*<'; Max = 0 },
    @{ Name = '裸图标按钮'; Pattern = '\bIconButton\s*\('; Max = 23 },
    @{ Name = '弹窗内联圆角样式'; Pattern = 'RoundedRectangleBorder\s*\('; Max = 30 }
)

$failed = $false
foreach ($rule in $limits) {
    $count = Count-Pattern $rule.Pattern
    if ($count -gt $rule.Max) {
        Write-Error "$($rule.Name) 数量为 $count，超过迁移基线 $($rule.Max)。请使用 common_widgets.dart 导出的统一控件。"
        $failed = $true
    } else {
        Write-Host "$($rule.Name): $count / $($rule.Max)"
    }
}

$embeddedLabelCount = Count-MultilinePattern 'InputDecoration\((?:(?!\n\s*\),).){0,500}?\blabelText\s*:'
if ($embeddedLabelCount -gt 0) {
    Write-Error "输入框内嵌标题数量为 $embeddedLabelCount。请使用 AppDialogTextField、AppDialogDropdown 或 AppLabeledField 将标题放在控件外部。"
    $failed = $true
} else {
    Write-Host '输入框内嵌标题: 0 / 0'
}

if ($failed) { exit 1 }
