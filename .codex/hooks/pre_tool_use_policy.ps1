$ErrorActionPreference = 'Stop'

$rawInput = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($rawInput)) {
  exit 0
}

$payload = $rawInput | ConvertFrom-Json
$command = [string]$payload.tool_input.command
if ([string]::IsNullOrWhiteSpace($command)) {
  exit 0
}

$lower = $command.ToLowerInvariant()
$usesPwsh = $lower -match '(^|[\s;&|])pwsh(\.exe)?([\s;&|]|$)'
$touchesCodeOrDocs =
  ($lower -match '\.(dart|md|txt|yaml|yml|toml|json|xml|svg|ps1|py|js|ts|html|css)(["''\s;|)]|$)') -or
  ($lower -match '(^|[\s"''./\\])(lib|docs|test|tools|assets|windows|resources)[\\/]')
$usesPowerShellCodeOrDocCommand =
  ($lower -match '(^|[\s;&|])(get-content|set-content|add-content|select-string|copy-item|move-item|remove-item|new-item|out-file)([\s;&|]|$)') -or
  ($lower -match '(^|[\s;&|])powershell(\.exe)?([\s;&|]|$)')

if ($usesPowerShellCodeOrDocCommand -and -not $usesPwsh -and $touchesCodeOrDocs) {
  $reason = 'Blocked by VScope hook: use PowerShell 7 (`pwsh`) for code or documentation reads/writes in this repository. Windows PowerShell 5.1 may display or write text with the wrong encoding.'
  @{
    hookSpecificOutput = @{
      hookEventName = 'PreToolUse'
      permissionDecision = 'deny'
      permissionDecisionReason = $reason
    }
  } | ConvertTo-Json -Depth 5 -Compress
  exit 0
}

exit 0
