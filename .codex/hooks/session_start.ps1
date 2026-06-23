$ErrorActionPreference = 'Stop'

$context = @'
VScope Serial 项目硬规则：
- 本仓库涉及代码或文档读写时，使用 PowerShell 7：pwsh。
- 不要用 Windows PowerShell 5.1 的输出判断源码或文档内容，尤其是中文文本。
- docs/CONTEXT.md 记录长期项目事实；新对话或涉及架构、发布、工作流等大范围决策时再读取，不因上下文压缩自动重读。
- 除非用户明确要求，不要自动提交、自动 push 或自动回滚改动。
'@

@{
  hookSpecificOutput = @{
    hookEventName = 'SessionStart'
    additionalContext = $context
  }
} | ConvertTo-Json -Depth 5 -Compress
