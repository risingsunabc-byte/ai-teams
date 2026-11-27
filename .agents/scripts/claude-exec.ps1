<#
.SYNOPSIS
  Standalone PowerShell wrapper to execute (Sonnet), read-only verify (Opus), build a portable handoff packet, or roll back the last run via local Claude Code CLI.
.EXAMPLE
  .\.agents\scripts\claude-exec.ps1 -Healthcheck -Workspace .
  .\.agents\scripts\claude-exec.ps1 -Workspace . -PlanFile .agents\plans\plan.md -Model sonnet -Effort high
  .\.agents\scripts\claude-exec.ps1 -Workspace . -PlanFile .agents\plans\plan.md -Verify
  .\.agents\scripts\claude-exec.ps1 -Handoff -Workspace . -HandoffMode fix_review
  .\.agents\scripts\claude-exec.ps1 -Rollback -Workspace .
#>
param(
  [switch]$Healthcheck,
  [switch]$Verify,
  [switch]$NoDiff,
  [switch]$NoBash,
  [string]$Workspace = ".",
  [string]$Plan,
  [string]$PlanFile,
  [string]$SessionKey,
  [string]$SessionMode,
  [string]$ResumeSessionId,
  [switch]$NoHistory,
  [string]$Model,
  [string]$Effort,
  [string]$PermissionMode,
  [Nullable[int]]$MaxTurns,
  [Nullable[int]]$Timeout,
  [string[]]$AllowedFile,
  [string[]]$VerifyCmd,
  [string]$ExtraContext,
  [switch]$Handoff,
  [string]$HandoffMode,
  [string]$Search,
  [Nullable[int]]$MaxBytes,
  [string]$DiffScope,
  [switch]$Rollback
)

$ErrorActionPreference = "Stop"

$Runner = Join-Path $PSScriptRoot "..\plugins\claude-executor\claude_runner.py"
if (-not (Test-Path -LiteralPath $Runner)) {
  Write-Error "[ERROR] Runner script not found: $Runner"
  exit 1
}

$PythonCmd = $null
$PythonPrefix = @()
if (Get-Command python -ErrorAction SilentlyContinue) {
  $PythonCmd = "python"
}
elseif (Get-Command python3 -ErrorAction SilentlyContinue) {
  $PythonCmd = "python3"
}
elseif (Get-Command py -ErrorAction SilentlyContinue) {
  $PythonCmd = "py"
  $PythonPrefix = @("-3")
}
else {
  Write-Error "[ERROR] python, python3, or py launcher not found. Please install Python 3."
  exit 1
}

$RunnerArgs = @($PythonPrefix) + @($Runner)
if ($Healthcheck) {
  $RunnerArgs += "--healthcheck"
  if ($PSBoundParameters.ContainsKey("Workspace") -and $Workspace) {
    $RunnerArgs += @("--workspace", $Workspace)
  }
}
elseif ($Handoff) {
  $RunnerArgs += @("--handoff", "--workspace", $Workspace)
  if ($HandoffMode) { $RunnerArgs += @("--handoff-mode", $HandoffMode) }
  if ($Search) { $RunnerArgs += @("--search", $Search) }
  if ($null -ne $MaxBytes) { $RunnerArgs += @("--max-bytes", "$MaxBytes") }
}
elseif ($Rollback) {
  $RunnerArgs += @("--rollback", "--workspace", $Workspace)
  if ($SessionKey) { $RunnerArgs += @("--session-key", $SessionKey) }
}
else {
  $RunnerArgs += @("--workspace", $Workspace)
  if ($Verify) { $RunnerArgs += "--verify" }
  if ($NoDiff) { $RunnerArgs += "--no-diff" }
  if ($NoBash) { $RunnerArgs += "--no-bash" }
  if ($Plan) { $RunnerArgs += @("--plan", $Plan) }
  if ($PlanFile) { $RunnerArgs += @("--plan-file", $PlanFile) }
  if ($SessionKey) { $RunnerArgs += @("--session-key", $SessionKey) }
  if ($SessionMode) { $RunnerArgs += @("--session-mode", $SessionMode) }
  if ($ResumeSessionId) { $RunnerArgs += @("--resume-session-id", $ResumeSessionId) }
  if ($NoHistory) { $RunnerArgs += "--no-history" }
  if ($Model) { $RunnerArgs += @("--model", $Model) }
  if ($Effort) { $RunnerArgs += @("--effort", $Effort) }
  if ($PermissionMode) { $RunnerArgs += @("--permission-mode", $PermissionMode) }
  if ($null -ne $MaxTurns) { $RunnerArgs += @("--max-turns", "$MaxTurns") }
  if ($null -ne $Timeout) { $RunnerArgs += @("--timeout", "$Timeout") }
  foreach ($f in ($AllowedFile | Where-Object { $_ })) {
    $RunnerArgs += @("--allowed-file", $f)
  }
  foreach ($c in ($VerifyCmd | Where-Object { $_ })) {
    $RunnerArgs += @("--verify-cmd", $c)
  }
  if ($ExtraContext) { $RunnerArgs += @("--extra-context", $ExtraContext) }
  if ($DiffScope) { $RunnerArgs += @("--diff-scope", $DiffScope) }
}

& $PythonCmd @RunnerArgs
exit $LASTEXITCODE
