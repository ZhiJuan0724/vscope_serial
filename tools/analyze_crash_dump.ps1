#requires -Version 5.1

<#
.SYNOPSIS
分析 SerialTools 在 Windows 上生成的原生崩溃转储。

.DESCRIPTION
将本脚本复制到包含 .dmp、配套 .json、日志和对应版本 PDB 的目录后直接运行。
脚本会调用 Windows Debugger（cdb.exe），检查符号是否真正匹配，并生成中文 Markdown
报告及完整调试器原始输出。

.PARAMETER InputDirectory
待分析文件所在目录。省略时使用脚本自身所在目录。

.PARAMETER DumpPath
指定某个 .dmp 文件。省略时分析目录中最后修改的 .dmp。

.PARAMETER OutputPath
指定 Markdown 报告路径。省略时写入转储所在目录。

.PARAMETER DebuggerPath
手动指定 cdb.exe。通常无需设置。

.PARAMETER Offline
不访问 Microsoft 公共符号服务器。应用自身符号仍从输入目录加载。

.EXAMPLE
powershell.exe -ExecutionPolicy Bypass -File .\analyze_crash_dump.ps1

.EXAMPLE
powershell.exe -ExecutionPolicy Bypass -File .\analyze_crash_dump.ps1 -DumpPath .\vscope_crash_xxx.dmp
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$InputDirectory = $PSScriptRoot,

    [string]$DumpPath,

    [string]$OutputPath,

    [string]$DebuggerPath,

    [switch]$Offline
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Problems = [System.Collections.Generic.List[object]]::new()

function Add-Problem {
    param(
        [ValidateSet('错误', '警告', '提示')]
        [string]$Level,
        [string]$Message
    )

    $script:Problems.Add([pscustomobject]@{
        Level   = $Level
        Message = $Message
    })
}

function Resolve-ExistingFile {
    param(
        [string]$Path,
        [string]$BaseDirectory
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    $candidate = if ([System.IO.Path]::IsPathRooted($Path)) {
        $Path
    } else {
        Join-Path $BaseDirectory $Path
    }

    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        return $null
    }

    return (Resolve-Path -LiteralPath $candidate).Path
}

function Find-Cdb {
    param([string]$ExplicitPath)

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        $resolved = Resolve-ExistingFile -Path $ExplicitPath -BaseDirectory (Get-Location).Path
        if ($null -eq $resolved) {
            throw "指定的调试器不存在：$ExplicitPath"
        }
        return $resolved
    }

    $command = Get-Command 'cdb.exe' -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    $roots = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Debuggers\x64\cdb.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Debuggers\x86\cdb.exe'),
        (Join-Path $env:ProgramFiles 'Windows Kits\10\Debuggers\x64\cdb.exe'),
        (Join-Path $env:ProgramFiles 'Windows Kits\10\Debuggers\x86\cdb.exe')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    foreach ($candidate in $roots) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    return $null
}

function Get-JsonValue {
    param(
        [object]$Object,
        [string[]]$Names
    )

    if ($null -eq $Object) {
        return $null
    }

    foreach ($name in $Names) {
        $property = $Object.PSObject.Properties[$name]
        if ($null -ne $property -and $null -ne $property.Value) {
            return [string]$property.Value
        }
    }

    return $null
}

function Escape-MarkdownCell {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return ''
    }

    return ([string]$Value).Replace('|', '\|').Replace("`r", '').Replace("`n", '<br>')
}

function Get-ModuleSymbolStatus {
    param(
        [string]$DebuggerOutput,
        [string]$ModuleName,
        [string]$ExpectedPdbPath
    )

    $escapedModule = [regex]::Escape($ModuleName)
    $modulePattern =
        "(?im)^\S+\s+\S+\s+$escapedModule\s+\S+\s+\(private pdb symbols\)\s+(.+?\.pdb)\s*$"
    $match = [regex]::Match($DebuggerOutput, $modulePattern)

    if (-not $match.Success) {
        return [pscustomobject]@{
            Module     = $ModuleName
            Expected   = $ExpectedPdbPath
            Loaded     = $null
            IsPrivate  = $false
            IsExpected = $false
            State      = '未加载匹配的私有符号'
        }
    }

    $loadedPath = $match.Groups[1].Value.Trim()
    $loadedResolved = Resolve-ExistingFile -Path $loadedPath -BaseDirectory (Get-Location).Path
    $expectedResolved = Resolve-ExistingFile -Path $ExpectedPdbPath -BaseDirectory (Get-Location).Path
    $isExpected = $null -ne $loadedResolved -and
        $null -ne $expectedResolved -and
        [string]::Equals(
            $loadedResolved,
            $expectedResolved,
            [System.StringComparison]::OrdinalIgnoreCase
        )

    return [pscustomobject]@{
        Module     = $ModuleName
        Expected   = $expectedResolved
        Loaded     = if ($null -ne $loadedResolved) { $loadedResolved } else { $loadedPath }
        IsPrivate  = $true
        IsExpected = $isExpected
        State      = if ($isExpected) {
            '匹配，已从当前目录加载私有符号'
        } else {
            '调试器加载了其他位置的符号，当前目录中的 PDB 可能缺失或不匹配'
        }
    }
}

function Get-FirstRegexValue {
    param(
        [string]$Text,
        [string[]]$Patterns
    )

    foreach ($pattern in $Patterns) {
        $match = [regex]::Match($Text, $pattern)
        if ($match.Success) {
            return $match.Groups[1].Value.Trim()
        }
    }

    return $null
}

function Get-StackExcerpt {
    param([string]$DebuggerOutput)

    $markedStack = [regex]::Match(
        $DebuggerOutput,
        '(?ms)^===VSCOPE_STACK_BEGIN===\s*\r?\n(.*?)^===VSCOPE_STACK_END===\s*$'
    )
    if ($markedStack.Success) {
        return $markedStack.Groups[1].Value.Trim()
    }

    $lines = $DebuggerOutput -split "\r?\n"
    $headerIndex = -1
    for ($index = $lines.Count - 1; $index -ge 0; $index--) {
        if ($lines[$index] -match '^Child-SP\s+') {
            $headerIndex = $index
            break
        }
    }

    if ($headerIndex -lt 0) {
        return '未能从调试器输出中提取调用栈。'
    }

    $result = [System.Collections.Generic.List[string]]::new()
    for ($index = $headerIndex; $index -lt $lines.Count -and $result.Count -lt 16; $index++) {
        $line = $lines[$index]
        if ($index -gt $headerIndex -and [string]::IsNullOrWhiteSpace($line)) {
            break
        }
        if ($line -match '^(quit:|0:\d+>)') {
            break
        }
        $result.Add($line)
    }

    return $result -join [Environment]::NewLine
}

$resolvedInputDirectory = if ([System.IO.Path]::IsPathRooted($InputDirectory)) {
    $InputDirectory
} else {
    Join-Path (Get-Location).Path $InputDirectory
}

if (-not (Test-Path -LiteralPath $resolvedInputDirectory -PathType Container)) {
    throw "输入目录不存在：$resolvedInputDirectory"
}
$resolvedInputDirectory = (Resolve-Path -LiteralPath $resolvedInputDirectory).Path

$resolvedDumpPath = Resolve-ExistingFile -Path $DumpPath -BaseDirectory $resolvedInputDirectory
if ($null -eq $resolvedDumpPath) {
    if (-not [string]::IsNullOrWhiteSpace($DumpPath)) {
        throw "指定的转储文件不存在：$DumpPath"
    }
    $latestDump = Get-ChildItem -LiteralPath $resolvedInputDirectory -Filter '*.dmp' -File |
        Sort-Object LastWriteTime |
        Select-Object -Last 1
    if ($null -eq $latestDump) {
        throw "目录中没有找到 .dmp 文件：$resolvedInputDirectory"
    }
    $resolvedDumpPath = $latestDump.FullName
}

$dumpFile = Get-Item -LiteralPath $resolvedDumpPath
$dumpBaseName = [System.IO.Path]::GetFileNameWithoutExtension($dumpFile.Name)
$jsonPath = Join-Path $dumpFile.DirectoryName "$dumpBaseName.json"
$rawOutputPath = Join-Path $dumpFile.DirectoryName "${dumpBaseName}_debugger.txt"
$resolvedOutputPath = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    Join-Path $dumpFile.DirectoryName "${dumpBaseName}_analysis.md"
} elseif ([System.IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath
} else {
    Join-Path (Get-Location).Path $OutputPath
}

$expectedModules = @(
    [pscustomobject]@{
        Module = 'native_serial_reader'
        Pdb    = Join-Path $resolvedInputDirectory 'native_serial_reader.pdb'
    },
    [pscustomobject]@{
        Module = 'vscope_serial'
        Pdb    = Join-Path $resolvedInputDirectory 'vscope_serial.pdb'
    }
)

foreach ($module in $expectedModules) {
    if (-not (Test-Path -LiteralPath $module.Pdb -PathType Leaf)) {
        Add-Problem -Level '错误' -Message "缺少符号文件：$($module.Pdb)"
    }
}

$metadata = $null
if (Test-Path -LiteralPath $jsonPath -PathType Leaf) {
    try {
        $metadata = Get-Content -LiteralPath $jsonPath -Raw -Encoding utf8 | ConvertFrom-Json
    } catch {
        Add-Problem -Level '警告' -Message "配套 JSON 无法解析：$jsonPath；$($_.Exception.Message)"
    }
} else {
    Add-Problem -Level '警告' -Message "没有找到同名 JSON：$jsonPath"
}

$logFiles = @(
    Get-ChildItem -LiteralPath $resolvedInputDirectory -Filter '*.log' -File |
        Sort-Object LastWriteTime -Descending
)
if ($logFiles.Count -eq 0) {
    Add-Problem -Level '提示' -Message '目录中没有 .log；仍可分析转储，但缺少崩溃前的业务日志。'
}

$resolvedDebuggerPath = Find-Cdb -ExplicitPath $DebuggerPath
$debuggerOutput = ''
$debuggerExitCode = $null
$symbolStatuses = @()

if ($null -eq $resolvedDebuggerPath) {
    Add-Problem -Level '错误' -Message (
        '没有找到 cdb.exe。请安装 Windows SDK 的 Debugging Tools for Windows，' +
        '或通过 -DebuggerPath 指定 cdb.exe。'
    )
} else {
    $symbolPath = if ($Offline) {
        $resolvedInputDirectory
    } else {
        $symbolCache = if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
            Join-Path $env:LOCALAPPDATA 'SerialTools\debug_symbols'
        } else {
            Join-Path $env:TEMP 'SerialTools\debug_symbols'
        }
        "srv*$symbolCache*https://msdl.microsoft.com/download/symbols;$resolvedInputDirectory"
    }

    # 不启用 SYMOPT_LOAD_ANYTHING；不匹配的 PDB 必须由调试器拒绝。
    $commands = @(
        '.lines -e'
        '.reload /f'
        '!analyze -v'
        '.echo ===VSCOPE_CONTEXT_BEGIN==='
        '.ecxr'
        'r'
        'u @rip L1'
        '.echo ===VSCOPE_CONTEXT_END==='
        '.echo ===VSCOPE_STACK_BEGIN==='
        '.ecxr'
        'kv 50'
        '.echo ===VSCOPE_STACK_END==='
        'lmvm native_serial_reader'
        'lmvm vscope_serial'
        'q'
    ) -join '; '

    Write-Host "正在分析：$resolvedDumpPath" -ForegroundColor Cyan
    Write-Host "调试器：$resolvedDebuggerPath" -ForegroundColor DarkGray

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $debuggerOutput = (& $resolvedDebuggerPath `
        -z $resolvedDumpPath `
        -y $symbolPath `
        -c $commands 2>&1 | Out-String)
    $debuggerExitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference

    Set-Content -LiteralPath $rawOutputPath -Value $debuggerOutput -Encoding utf8

    foreach ($module in $expectedModules) {
        $status = Get-ModuleSymbolStatus `
            -DebuggerOutput $debuggerOutput `
            -ModuleName $module.Module `
            -ExpectedPdbPath $module.Pdb
        $symbolStatuses += $status

        if (-not $status.IsPrivate) {
            Add-Problem -Level '错误' -Message (
                "$($module.Module)：没有加载匹配的私有 PDB。请使用生成该 EXE/DLL 时" +
                '同时产生的符号文件，版本号相同但重新构建的 PDB 也不能混用。'
            )
        } elseif (-not $status.IsExpected) {
            Add-Problem -Level '错误' -Message "$($module.Module)：$($status.State)"
        }
    }
}

$exceptionCode = Get-JsonValue -Object $metadata -Names @('exceptionCode')
if ([string]::IsNullOrWhiteSpace($exceptionCode)) {
    $exceptionCode = Get-FirstRegexValue -Text $debuggerOutput -Patterns @(
        '(?im)^\s*ExceptionCode:\s*(\S+)',
        '(?im)exception\s+-\s+code\s+([0-9a-f]+)'
    )
}

$exceptionAddress = Get-JsonValue -Object $metadata -Names @('exceptionAddress')
if ([string]::IsNullOrWhiteSpace($exceptionAddress)) {
    $exceptionAddress = Get-FirstRegexValue -Text $debuggerOutput -Patterns @(
        '(?im)^\s*ExceptionAddress:\s*(\S+)'
    )
}

$faultingSymbol = Get-FirstRegexValue -Text $debuggerOutput -Patterns @(
    '(?im)^([A-Za-z0-9_.-]+![A-Za-z0-9_?$@<>~:+.-]+(?:\+0x[0-9a-f]+)?):\s*$',
    '(?im)^\s*SYMBOL_NAME:\s*(.+)$'
)
$contextBlock = Get-FirstRegexValue -Text $debuggerOutput -Patterns @(
    '(?ms)^===VSCOPE_CONTEXT_BEGIN===\s*\r?\n(.*?)^===VSCOPE_CONTEXT_END===\s*$'
)
$faultingInstruction = Get-FirstRegexValue -Text $contextBlock -Patterns @(
    '(?im)^[0-9a-f`]+\s+([0-9a-f]+\s+.+)$'
)
$processName = Get-JsonValue -Object $metadata -Names @('application', 'app')
if ([string]::IsNullOrWhiteSpace($processName)) {
    $processName = Get-FirstRegexValue -Text $debuggerOutput -Patterns @(
        '(?im)^\s*PROCESS_NAME:\s*(.+)$'
    )
}
$failureBucket = Get-FirstRegexValue -Text $debuggerOutput -Patterns @(
    '(?im)^\s*FAILURE_BUCKET_ID:\s*(.+)$'
)
$accessDescription = Get-FirstRegexValue -Text $debuggerOutput -Patterns @(
    '(?im)^\s*(Attempt to (?:read from|write to|execute (?:a )?non-executable (?:memory|address)) .+)$'
)
if ($accessDescription -match '(?i)^Attempt to write to address\s+(.+)$') {
    $accessDescription = "尝试写入地址 $($matches[1])"
} elseif ($accessDescription -match '(?i)^Attempt to read from address\s+(.+)$') {
    $accessDescription = "尝试读取地址 $($matches[1])"
} elseif ($accessDescription -match '(?i)^Attempt to execute .+$') {
    $accessDescription = "尝试执行不可执行内存：$accessDescription"
}

$normalizedExceptionCode = if ([string]::IsNullOrWhiteSpace($exceptionCode)) {
    ''
} else {
    $exceptionCode.ToUpperInvariant()
}
$exceptionDescription = switch ($normalizedExceptionCode) {
    '0XC0000005' { '访问冲突：程序读取、写入或执行了无效内存地址' }
    'C0000005' { '访问冲突：程序读取、写入或执行了无效内存地址' }
    '0XC0000409' { '快速失败：常见于栈缓冲区损坏或安全检查失败' }
    'C0000409' { '快速失败：常见于栈缓冲区损坏或安全检查失败' }
    '0X80000003' { '断点异常' }
    '80000003' { '断点异常' }
    '0XC000001D' { '非法指令' }
    'C000001D' { '非法指令' }
    '0XC0000094' { '整数除零' }
    'C0000094' { '整数除零' }
    default { '未内置该异常代码的中文解释，请结合调试器原始输出判断' }
}

if ($debuggerOutput -match '(?im)WRONG_SYMBOLS') {
    Add-Problem -Level '提示' -Message (
        'Microsoft 系统模块符号未完全匹配，!analyze 的系统模块结论可能不可靠；' +
        '这不影响报告中已经单独验证通过的 SerialTools 私有符号和异常上下文。'
    )
}

$report = [System.Text.StringBuilder]::new()
[void]$report.AppendLine('# SerialTools 原生崩溃分析报告')
[void]$report.AppendLine()
[void]$report.AppendLine("> 生成时间：$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')")
[void]$report.AppendLine()

[void]$report.AppendLine('## 结论概览')
[void]$report.AppendLine()
if (
    $symbolStatuses.Count -gt 0 -and
    @($symbolStatuses | Where-Object { -not $_.IsExpected }).Count -eq 0
) {
    [void]$report.AppendLine('- ✅ 转储可读取，应用私有符号均匹配。')
}
foreach ($problem in $script:Problems) {
    $icon = switch ($problem.Level) {
        '错误' { '❌' }
        '警告' { '⚠️' }
        default { 'ℹ️' }
    }
    [void]$report.AppendLine("- $icon **$($problem.Level)**：$($problem.Message)")
}
[void]$report.AppendLine()

[void]$report.AppendLine('## 崩溃摘要')
[void]$report.AppendLine()
[void]$report.AppendLine('| 项目 | 内容 |')
[void]$report.AppendLine('|---|---|')
$summaryRows = @(
    @('转储文件', $dumpFile.Name),
    @('软件版本', (Get-JsonValue -Object $metadata -Names @('version'))),
    @('崩溃时间（UTC）', (Get-JsonValue -Object $metadata -Names @('timestampUtc', 'timeUtc', 'utcTime'))),
    @('进程', $processName),
    @('进程 ID', (Get-JsonValue -Object $metadata -Names @('processId', 'pid'))),
    @('线程 ID', (Get-JsonValue -Object $metadata -Names @('threadId', 'tid'))),
    @('架构', (Get-JsonValue -Object $metadata -Names @('architecture'))),
    @('异常代码', $exceptionCode),
    @('异常含义', $exceptionDescription),
    @('异常地址', $exceptionAddress),
    @('内存访问', $accessDescription),
    @('故障符号', $faultingSymbol),
    @('故障指令', $faultingInstruction),
    @('Failure Bucket', $failureBucket)
)
foreach ($row in $summaryRows) {
    $value = if ([string]::IsNullOrWhiteSpace([string]$row[1])) { '未取得' } else { $row[1] }
    [void]$report.AppendLine("| $(Escape-MarkdownCell $row[0]) | $(Escape-MarkdownCell $value) |")
}
[void]$report.AppendLine()

[void]$report.AppendLine('## 符号检查')
[void]$report.AppendLine()
[void]$report.AppendLine('| 模块 | 结果 | 实际加载的 PDB |')
[void]$report.AppendLine('|---|---|---|')
if ($symbolStatuses.Count -eq 0) {
    [void]$report.AppendLine('| 未检查 | 调试器不可用 |  |')
} else {
    foreach ($status in $symbolStatuses) {
        $stateIcon = if ($status.IsExpected) { '✅' } else { '❌' }
        [void]$report.AppendLine(
            "| $($status.Module) | $stateIcon $(Escape-MarkdownCell $status.State) | " +
            "$(Escape-MarkdownCell $status.Loaded) |"
        )
    }
}
[void]$report.AppendLine()
[void]$report.AppendLine(
    '> 只有显示“匹配，已从当前目录加载私有符号”时，应用函数名和源码行号才可信。'
)
[void]$report.AppendLine()

[void]$report.AppendLine('## 调用栈')
[void]$report.AppendLine()
[void]$report.AppendLine('```text')
[void]$report.AppendLine((Get-StackExcerpt -DebuggerOutput $debuggerOutput))
[void]$report.AppendLine('```')
[void]$report.AppendLine()

[void]$report.AppendLine('## 文件清单')
[void]$report.AppendLine()
[void]$report.AppendLine('| 文件 | 大小 | 修改时间 |')
[void]$report.AppendLine('|---|---:|---|')
$inventory = Get-ChildItem -LiteralPath $resolvedInputDirectory -File |
    Where-Object {
        $_.Extension -in @('.dmp', '.json', '.pdb', '.log', '.exe', '.dll') -or
        $_.Name.EndsWith('.json.reported', [System.StringComparison]::OrdinalIgnoreCase)
    } |
    Sort-Object Name
foreach ($file in $inventory) {
    [void]$report.AppendLine(
        "| $(Escape-MarkdownCell $file.Name) | $($file.Length) B | " +
        "$($file.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')) |"
    )
}
[void]$report.AppendLine()

[void]$report.AppendLine('## 崩溃前日志')
[void]$report.AppendLine()
if ($logFiles.Count -eq 0) {
    [void]$report.AppendLine('未提供日志文件。')
} else {
    $latestLog = $logFiles[0]
    [void]$report.AppendLine(('来源：`{0}`，最后 40 行。' -f $latestLog.Name))
    [void]$report.AppendLine()
    [void]$report.AppendLine('```text')
    try {
        $logTail = Get-Content -LiteralPath $latestLog.FullName -Encoding utf8 -Tail 40
        [void]$report.AppendLine($logTail -join [Environment]::NewLine)
    } catch {
        [void]$report.AppendLine("日志读取失败：$($_.Exception.Message)")
    }
    [void]$report.AppendLine('```')
}
[void]$report.AppendLine()

[void]$report.AppendLine('## 分析说明')
[void]$report.AppendLine()
[void]$report.AppendLine("- 调试器：$(Escape-MarkdownCell $resolvedDebuggerPath)")
[void]$report.AppendLine("- 调试器退出代码：$(Escape-MarkdownCell $debuggerExitCode)")
[void]$report.AppendLine("- Microsoft 系统符号：$(if ($Offline) { '离线模式，未访问' } else { '已配置公共符号服务器' })")
[void]$report.AppendLine(
    ('- 完整调试器输出：`{0}`' -f [System.IO.Path]::GetFileName($rawOutputPath))
)
[void]$report.AppendLine()
[void]$report.AppendLine(
    '本报告优先用于确定异常类型、故障模块和首个可信的应用栈帧；' +
    '业务原因仍需结合崩溃前日志和对应版本源码判断。'
)

$outputDirectory = Split-Path -Parent $resolvedOutputPath
if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}
Set-Content -LiteralPath $resolvedOutputPath -Value $report.ToString() -Encoding utf8

Write-Host ''
Write-Host '分析完成。' -ForegroundColor Green
Write-Host "可读报告：$resolvedOutputPath" -ForegroundColor Cyan
if (Test-Path -LiteralPath $rawOutputPath -PathType Leaf) {
    Write-Host "完整输出：$rawOutputPath" -ForegroundColor DarkGray
}

$errorCount = @($script:Problems | Where-Object Level -eq '错误').Count
$warningCount = @($script:Problems | Where-Object Level -eq '警告').Count
if ($errorCount -gt 0) {
    Write-Host "发现 $errorCount 个错误、$warningCount 个警告，请先查看报告顶部。" -ForegroundColor Red
    exit 2
}
if ($warningCount -gt 0) {
    Write-Host "发现 $warningCount 个警告，请查看报告顶部。" -ForegroundColor Yellow
}
