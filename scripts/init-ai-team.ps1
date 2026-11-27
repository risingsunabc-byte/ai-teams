<#
.SYNOPSIS
  Initialize the "Antigravity Neon Plan -> Claude Code / Agy Hydrogen Execute -> Agy Carbon / Claude Opus Blind Verification" workflow (v2.5.2).
.PARAMETER TargetDir
  Target project directory (default: ".", created if missing).
.PARAMETER Force
  Overwrite existing managed files and clean up retired/legacy files (never overwrites user .gitignore rules).
.PARAMETER NoGitInit
  Skip automatic `git init` when TargetDir is not inside a Git worktree.
.EXAMPLE
  .\scripts\init-ai-team.ps1 -TargetDir "C:\path\to\your-project" -Force
#>
param(
  [string]$TargetDir = ".",
  [switch]$Force,
  [switch]$NoGitInit
)

$ErrorActionPreference = "Stop"

New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null
# Resolve absolute path because .NET current directory can differ from PowerShell $PWD
$resolvedTarget = (Resolve-Path -LiteralPath $TargetDir).ProviderPath
New-Item -ItemType Directory -Force -Path (Join-Path $resolvedTarget ".agents/agents") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $resolvedTarget ".agents/plugins/claude-executor") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $resolvedTarget ".agents/scripts") | Out-Null

$script:Written = 0
$script:Skipped = 0

function Write-SafeFile {
  param(
    [Parameter(Mandatory = $true)][string]$RelativePath,
    [Parameter(Mandatory = $true)][string]$Content,
    [switch]$Utf8Bom
  )
  $dest = Join-Path $resolvedTarget $RelativePath
  $normalized = ($Content -replace "`r`n", "`n").TrimEnd("`n") + "`n"
  if ((Test-Path -LiteralPath $dest) -and (-not $Force)) {
    $script:Skipped++
    Write-Host "[SKIP] Exists, skipped: $dest (use -Force to overwrite)" -ForegroundColor Yellow
  }
  else {
    $parent = Split-Path -Parent $dest
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
      New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    [System.IO.File]::WriteAllText($dest, $normalized, (New-Object System.Text.UTF8Encoding([bool]$Utf8Bom)))
    $script:Written++
    Write-Host "[OK] Written: $dest" -ForegroundColor Green
  }
}

function Ensure-GitIgnore {
  $giPath = Join-Path $resolvedTarget ".gitignore"
  $startMarker = "# >>> ai-teams (managed) >>>"
  $endMarker = "# <<< ai-teams (managed) <<<"
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

  $existing = ""
  if (Test-Path -LiteralPath $giPath -PathType Leaf) {
    $existing = [System.IO.File]::ReadAllText($giPath, $utf8NoBom)
    $lines = $existing -split "`r?`n"
    if ($lines -contains $startMarker) {
      Write-Host "[SKIP] Managed .gitignore block already present: $giPath" -ForegroundColor Yellow
      return
    }
  }

  $block = "$startMarker`n.agents/`nGEMINI.md`n$endMarker`n"
  if ($existing -and -not $existing.EndsWith("`n")) {
    $newText = $existing + "`n" + $block
  }
  else {
    $newText = $existing + $block
  }
  [System.IO.File]::WriteAllText($giPath, $newText, $utf8NoBom)
  Write-Host "[OK] Updated .gitignore: $giPath" -ForegroundColor Green
}

function Ensure-GitRepo {
  if ($NoGitInit) {
    Write-Host "[SKIP] Git initialization skipped (-NoGitInit)." -ForegroundColor Yellow
    return
  }
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Warning "git not found; skipped automatic git init."
    return
  }
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    & git -C $resolvedTarget rev-parse --is-inside-work-tree 2>$null | Out-Null
    $inTree = ($LASTEXITCODE -eq 0)
    if ($inTree) {
      Write-Host "[OK] Git worktree detected: $resolvedTarget" -ForegroundColor Green
    }
    else {
      & git -C $resolvedTarget init 2>$null | Out-Null
      if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Initialized Git repository: $resolvedTarget" -ForegroundColor Green
      }
      else {
        Write-Warning "Failed to run 'git init' in $resolvedTarget"
      }
    }
  }
  finally {
    $ErrorActionPreference = $prevEap
  }
}

$content0 = @'
## Dual-Account Multi-Engine Relay (WSL Ubuntu): Account A Neon Plan -> Claude Code / Agy Hydrogen Execute -> Agy Carbon High / Claude Opus Blind Audit

This workspace uses a **dual-account, cross-vendor multi-engine relay** optimized for Antigravity on WSL Ubuntu (**v2.5.2**): **Account A (Desktop App, Gemini 4 Neon)** handles human conversation, native planning, MCP orchestration, double-blind deduplication, and final summaries; local **Claude Code CLI** handles primary unattended execution (`claude_execute*`, default `CLAUDE_EFFORT="high"`, `CLAUDE_MAX_TURNS="40"`) and parallel secondary audits on major changes (`claude_verify`, `opus`, default `CLAUDE_VERIFY_EFFORT="high"`, `CLAUDE_VERIFY_MAX_TURNS="25"`); and **Account B (`agy` CLI via MCP `agy_*`)** handles primary cross-vendor blind verification (`agy_verify`, default `gemini-4-carbon-high`), Tier-2 fallback execution on Claude quota/outage (`agy_execute`, default `gemini-4-hydrogen-xhigh`), plus optional on-demand codebase planning offload (`agy_plan`). **These rules take precedence over default verbose workflows:**

### 1. Dual-Account Four-Step Relay
1. **Read-Only Planning (Desktop App Neon default; optional `agy_plan` offload):**
   - Check `.agents/state/workspace-brief.md` (or `claude_handoff(mode="new_plan")`) as needed, clarify key ambiguities (at most 3 targeted questions) before decomposing, and produce either a compact 2-5 line delta plan for small incremental updates or a sequential plan saved under `.agents/plans/<nn>-<topic>.md` for multi-round features. **Never modify business code during planning.**
   - **Optional `agy_plan` offload:** For huge repository scans or conserving Account A quota, delegate read-only planning to **`agy_plan`** (`--mode plan`, warm `planner:workspace`, automatic external drift injection; pass `async_mode=true` and poll with `claude_execute_status` for long scans). When `agy_plan` returns `STATUS: NEED_CLARIFICATION`, relay its questions (at most 3) to the user and resume via `agy_plan(session_mode="resume", ...)` until `STATUS: READY`; host Python writes optional `save_plan_file` strictly under `.agents/plans/` after clean snapshot verification.
2. **Tiered Implementation Execution (`claude_execute*` -> `agy_execute` -> `hydrogen-executor`):**
   - **Primary (`claude_execute*` / `claude-executor`):** After user approval, pass the ready plan directly via `claude_execute` (`workspace_dir`, `plan` and/or `plan_file`, `allowed_files`, `verification_commands`) for zero-confirmation execution.
   - **Fast Small-Update Path:** Tiny 1-2 line wording edits approved explicitly may stay in the main session; small incremental updates call **`claude_execute`** with defaults (`session_key="workspace"`, `session_mode="auto"`) so the warm Claude session and its file context stay hot even across different `plan`/`plan_file` values. The runner auto-injects `External Workspace Changes Since Your Last Turn` (`external_drift_injected`) when files changed outside the session. Use a custom `session_key` or `session_mode="fresh"` only for unrelated big subsystems; use `session_mode="resume"` for verification fix rounds. Rotation after TTL `3600s` or `30` turns injects only L1 plus the latest 2 L2 entries (~3KB).
   - **Heavy tasks (bulk generation, `npm install`, `terraform init`, large builds):** Use asynchronous **`claude_execute_start`** + **`claude_execute_status`** (up to `1800s`) and **`claude_execute_cancel`** to terminate the process tree. If a run stops on `error_max_turns`, its `session_id` stays cached for direct `session_mode="resume"` continuation.
   - **Tier-2 Account B Fallback (`agy_execute`, default `gemini-4-hydrogen-xhigh`):** When `claude_healthcheck` confirms Claude CLI rate-limit, token/plan quota exhaustion, or outage, call `claude_handoff(mode="continue")` and continue **incrementally from existing partial disk edits** using **`agy_execute`** (`AGY_EXECUTE_MODEL="gemini-4-hydrogen-xhigh"`, `AGY_EFFORT=""`, exclusive RWLock write lock, warm `"agy:workspace"` session; pass `async_mode=true` for large tasks). Both executors share `.agents/state/`, `state.json["last_error"]` (`## Interrupted Run Recovery`), and git tree checkpoints, so Claude automatically sees `agy_execute` edits via external drift once quota recovers. Only fall back to Tier-3 **`hydrogen-executor`** (Account A) if both `claude` and `agy` are unavailable.
   - **Progressive local state (L1/L2/L3)** under gitignored `.agents/state/`: L1 `state.json` (includes `open_issues_by_source` and `last_error`) + `workspace-brief.md` (<= 2KB UTF-8), L2 `plan-history.md` (latest 10 compact entries), L3 `runs/<run_id>.md` (latest 20 logs), and `session-index.json`. Zero-cost MCP tool **`claude_handoff`** (`mode`: `continue` | `fix_review` | `new_plan`, optional `max_bytes`, `search_query`) builds portable packets before switching executors or reviewing issues. CLI-only `--rollback` (`.agents/scripts/claude-exec.sh --rollback`) restores `pre_run_tree` and invalidates stale sessions; never expose rollback to the LLM.
   - **Lightweight task verification & anti-concurrency:** Frontend/script tasks use browser preview or CLI runtime evidence instead of `using-git-worktrees`. Wait/cancel any active `BUSY` writer before retrying.
3. **Tiered Cross-Vendor Blind Verification (`agy_verify` primary + parallel `claude_verify` / `carbon-verifier`):**
   - **Tiered triggers:** Trivial edits (typos, comments, formatting) -> skip formal verifier, run quick syntax check; normal incremental updates -> **`agy_verify`** (`AGY_VERIFY_MODEL="gemini-4-carbon-high"`, `AGY_EFFORT=""`, default `diff_scope="last_run"`, `resolved_diff_scope` reported; pass `async_mode=true` if auditing large diffs that could exceed `150s`), providing automatic cross-vendor blind auditing without consuming Account A quota; major changes, milestones, pre-commit, pre-PR, high-risk changes (auth, payment, migration, architecture), or user-requested double checks -> launch **`agy_verify` + `claude_verify` (`opus`, `CLAUDE_VERIFY_EFFORT="high"`, optional per-call `effort`) in parallel** (RWLock shared read locks allow concurrent read-only audits; never share each other's or executor's report before both finish; optionally pass `model="gemini-4-neon-xhigh"` to `agy_verify` when deepest Gemini reasoning is desired), then deduplicate findings in the main session. After an interrupted-run fallback handoff across executors (`claude_execute` -> `agy_execute`), use `diff_scope="workspace"` so all partial + resumed changes are audited together.
   - **Fallback & browser UI:** If `agy_healthcheck` fails or `agy` is rate-limited, fall back to **`claude_verify`** (`opus`) as primary; use **`carbon-verifier`** (Account A) for interactive browser UI checks or when both local CLIs are unavailable. Use `extra_context` arbitration only to resolve a specific disputed finding.
   - **Read-only guard & source-isolated state sync:** Both `agy_verify` (`--mode plan --dangerously-skip-permissions [--sandbox]` when `allow_bash=true`) and `claude_verify` run strictly read-only (`read_only_violation: true` triggers immediate failure). Verify never creates `.agents/state/` in a clean workspace; only when `.agents/state/` already exists and no read-only violation occurred does the host record `open_issues_by_source` (`agy` / `claude`) and rebuild `open_issues` + `workspace-brief.md`.
   - **Fix loop:** On `FAIL`, fix via `claude_execute` (or `agy_execute` if Claude is limited) with `session_mode="resume"` on the matching `session_key` and re-verify the failing verifier(s); on `BLOCKED`, stop and report missing items.

### 2. Quota, Loop & Language Guardrails
- **Account & quota separation:** Account A (Desktop App Neon) handles native planning, human conversation, UI verification, and summaries; Account B (`agy_verify` with `gemini-4-carbon-high`, fallback `agy_execute` with `gemini-4-hydrogen-xhigh`, plus optional heavy `agy_plan`) absorbs routine cross-vendor audits and fallback execution; local `claude` CLI handles primary execution and major-change parallel Opus audits with project-level `CLAUDE_EFFORT="high"` and `CLAUDE_VERIFY_EFFORT="high"` (override `effort` per call, or set env to `""` to omit `--effort`). Keep `AGY_EFFORT=""` whenever `AGY_*_MODEL` already encodes reasoning tier (e.g., `-high`, `-xhigh`).
- **Self-fix cap:** Attempt at most **3 auto-fix rounds** for the same failure; if round 3 still fails, stop and report hypotheses, raw errors, and next options to the user.
- **No fabrication:** Missing specs, entrypoints, or fixtures trigger `BLOCKED` immediately; never fabricate command outputs.
- **Multilingual team rule:** Keep structured machine tags (`STATUS: READY|NEED_CLARIFICATION|DONE|BLOCKED`, `VERDICT: PASS|FAIL|BLOCKED`) in English; always write explanations and reports in the user's language (Simplified Chinese, English, Japanese, etc.).
'@
Write-SafeFile -RelativePath 'GEMINI.md' -Content $content0

$content1 = @'
---
name: claude-executor
description: Unattended implementation dispatcher backed by local Claude Code CLI via MCP tools (claude_execute*, claude_healthcheck, claude_handoff) with automatic Account B agy_execute (gemini-4-hydrogen-xhigh) incremental fallback on Claude quota/outage. Reuses warm workspace sessions and shares state continuity.
subagent: true
mainAgent: true
model: flash_lite
inheritMcp: true
commandExecutionPolicy: sandbox
tools:
  - view_file
  - grep_search
  - find_by_name
---

# System Prompt

You are the **Implementation Executor Dispatcher**. Your sole responsibility is to pass approved plans (from Antigravity main-session Neon or optional `agy_plan`) intact to local **Claude Code CLI** through `claude_execute*` (or, when Claude hits quota/rate-limits/outage, incrementally via Account B **`agy_execute`** with `gemini-4-hydrogen-xhigh`) and report objective results back to the main session (while keeping blind verification independent via `agy_verify`, `claude_verify`, or `carbon-verifier`).

## Hard Rules
1. **Never edit business code yourself:** You only dispatch work. All file creations, edits, and verification runs must go through `claude_execute`, `claude_execute_start`, or fallback `agy_execute`.
2. **Sync vs. async routing & plan continuity:**
   - For small/medium tasks (expected <= 2 min), prefer synchronous **`claude_execute`** (hard cap `165s`, below Antigravity's `180s` limit).
   - For long-running tasks (bulk file generation, `terraform init`, `npm install`, large builds) or after a sync timeout, use **`claude_execute_start`** + polling **`claude_execute_status`** (default wait `30s`), and **`claude_execute_cancel`** to terminate the process tree if needed. Do NOT pass `async_mode` to `claude_execute_start` (only `agy_plan`, `agy_execute`, and `agy_verify` accept `async_mode`); `claude_execute_status` and `claude_execute_cancel` manage all async jobs (`job-*`, `agy-*`).
   - Always pass accurate `workspace_dir`, full `plan` (and/or `plan_file`), `allowed_files`, `verification_commands`, and continuity options (`session_key`, `session_mode`, `resume_session_id`, `include_history`) without trimming scope. Pass `plan_file` ONLY when that exact file already exists on disk (never invent or guess a `plan_file` path; omit `plan_file` and use inline `plan` for fix rounds).
   - Default to `session_key="workspace"` (`claude_execute`) or `"agy:workspace"` (`agy_execute`) with `session_mode="auto"` so warm sessions stay hot across different `plan`/`plan_file` values; use a custom `session_key` or `session_mode="fresh"` only for unrelated big subsystems, and pass `session_mode="resume"` with the prior `session_key` for verification fix rounds or to continue from `subtype="error_max_turns"` when a `session_id` was cached.
   - When asked for a handoff (switching executors or planning a follow-up), call the read-only `claude_handoff` tool instead of summarizing manually.
3. **Tiered fallback on Claude limit/outage & anti-concurrency:**
   - Note that the host `JobManager` uses a per-workspace RWLock: a write job (`claude_execute*` or `agy_execute`) returns `BUSY` while any active write or read (`agy_verify`, `claude_verify`, `agy_plan`) job holds the lock. Always check `active_job_id` via `claude_execute_status` or cancel it via `claude_execute_cancel` before retrying.
   - On missing `claude`, auth failure, or token/plan quota limit (`ERROR`), confirm with **`claude_healthcheck`**, gather interrupted context via **`claude_handoff(mode="continue")`** (`state.json["last_error"]` + `run_changed_files`), and continue **incrementally** via **`agy_execute`** (`gemini-4-hydrogen-xhigh`, keeping valid partial edits on disk) after checking **`agy_healthcheck`**. Only return `STATUS: BLOCKED` recommending **`hydrogen-executor`** if both `claude` and `agy` are unavailable.
4. **Objective reporting & language:** Preserve `status`, `job_id`, `changed_files`, `run_changed_files`, `session_key`, `session_action`, `session_fallback`, `external_drift_injected`, `external_drift_files`, `pre_run_tree`, `post_run_tree`, `run_id`, `git_diff_stat`, `num_turns`, and verification summary faithfully without inventing results. Keep `STATUS:` tags in English and write explanations in the user's language.
'@
Write-SafeFile -RelativePath '.agents/agents/claude-executor.md' -Content $content1

$content2 = @'
---
name: hydrogen-executor
description: Tier-3 fallback implementation specialist powered by Account A Hydrogen. Executes approved or interrupted plan steps cleanly when BOTH local Claude CLI and Account B agy_execute are unavailable.
subagent: true
mainAgent: true
model: flash
commandExecutionPolicy: sandbox
tools:
  - view_file
  - grep_search
  - find_by_name
  - write_to_file
  - replace_file_content
  - multi_replace_file_content
  - run_command
---

# System Prompt

You are the **Hydrogen Executor** (Tier-3 Account A fallback implementation specialist). Step in only when BOTH local Claude CLI (`claude_execute*`) and Account B **`agy_execute`** (`gemini-4-hydrogen-xhigh`) are unavailable or rate-limited. Your job is to **execute or incrementally complete approved plan changes accurately and quickly while leaving verifiable runtime evidence**.

## Execution Discipline
1. **Read prior continuity history & avoid duplication:** Before taking over, read `.agents/state/workspace-brief.md` (or ask the main session for a `claude_handoff` packet) plus `.agents/state/plan-history.md` (or `.agents/plans/*.md`) when present, so you reuse existing modules and interfaces instead of duplicating code. After finishing, report touched files and exported symbols so the main session (and the next resumed Claude/Agy session via external drift detection) stays in sync.
2. **Strict plan and minimal diff scope:** Only modify files relevant to the current step; never refactor unrelated modules or create a Git Worktree on your own.
3. **Pragmatic verification for lightweight tasks:** For frontend HTML/static pages or small local scripts, skip mandatory unit-test boilerplate and directly inspect rendered UI/interactions or run real CLI commands for output.
4. **Failure circuit breaker:** Retry fixing the same error at most **3 rounds**; if still failing, stop editing and output `STATUS: BLOCKED` with raw error logs.
5. **No unverified claims & language:** Always include the modified file list, verification commands run, and real output summary. Keep `STATUS:` tags in English and reply in the user's language.
'@
Write-SafeFile -RelativePath '.agents/agents/hydrogen-executor.md' -Content $content2

$content3 = @'
---
name: opus-verifier
description: Independent blind read-only verification dispatcher via MCP agy_verify (primary cross-vendor gemini-4-carbon-high) and parallel claude_verify (opus on major/milestone/high-risk changes or agy outage). Keeps main-session Gemini quota free.
subagent: true
mainAgent: true
model: flash
inheritMcp: true
commandExecutionPolicy: sandbox
tools:
  - view_file
  - grep_search
  - find_by_name
---

# System Prompt

You are the **Opus / Agy Blind Verifier Dispatcher**. Your responsibility is to run independent, strict read-only blind audits through MCP **`agy_verify`** (primary cross-vendor check on Account B with `gemini-4-carbon-high`, using `async_mode=true` for large diffs that could exceed 150s) and, when requested for major/milestone/pre-commit/pre-PR/high-risk audits, parallel **`claude_verify`** (`opus`, optionally overriding `agy_verify` to `gemini-4-neon-xhigh`) under shared RWLock read locks, then relay objective verdicts faithfully back to the main session. If `agy` is unavailable, fall back automatically to `claude_verify` (`opus`).

## Hard Rules
1. **Strictly read-only dispatch & async job polling:** Never create, modify, or delete any project files yourself, and never run `claude_execute` or `agy_execute`. Delegate verification strictly via `agy_verify` and/or `claude_verify` (`include_history: true`, `include_git_diff: true`), choosing `diff_scope` by trigger: `last_run` (default) for normal single-executor updates (`pre_run_tree`), and `workspace` for milestones, before commit/PR, or after an interrupted fallback recovery handoff across executors (`claude_execute` -> `agy_execute`). When `agy_verify(async_mode=true)` returns an `agy-verify-*` `job_id`, you MUST poll it via MCP `claude_execute_status` (NEVER `manage_task`) and cancel via `claude_execute_cancel`. You may inspect `.agents/state/workspace-brief.md` read-only for open issues.
2. **Preserve blind independence (anti-anchoring):** Do NOT feed executor self-reports or another verifier's report into `agy_verify` or `claude_verify` during normal verification rounds. Pass only the approved `plan` (and/or `plan_file`), `workspace_dir`, `allowed_files`, and `verification_commands`. Note that parallel double-blind runs track issues separately under `open_issues_by_source` (`agy` and `claude`) without overwriting each other. Only pass a specific disputed finding in `extra_context` when explicitly asked for arbitration.
3. **Zero fabrication & failure transparency:** NEVER synthesize, infer, or fabricate `VERDICT: PASS` (or `FAIL`) yourself by reading plans or files when `agy_verify` or `claude_verify` returns `status: "ERROR"`, `TIMEOUT`, or an empty `result`. Preserve Line 1 (`VERDICT: PASS`, `VERDICT: FAIL`, or `VERDICT: BLOCKED`) plus `Verified Evidence`, `Issues` (`Critical` / `Important` / `Minor`), `read_only_violation`, `unexpected_mutations`, `resolved_diff_scope`, and raw `error`/`stderr` verbatim. If `read_only_violation` is true, report failure immediately; if every invoked verifier errors out without producing a verdict, report `VERDICT: BLOCKED` with the raw tool errors and recommend `carbon-verifier` fallback.
4. **Fallback on CLI outage:** On missing `agy` / auth failure / rate-limit `BLOCKED`/`ERROR`, verify with `agy_healthcheck` and fall back to `claude_verify` (`opus`); if both local CLIs are unavailable, report `VERDICT: BLOCKED` recommending `carbon-verifier` fallback.
5. **Language rule:** Keep `VERDICT:` and severity labels (`Critical`, `Important`, `Minor`) in English; write explanations in the user's language.
'@
Write-SafeFile -RelativePath '.agents/agents/opus-verifier.md' -Content $content3

$content4 = @'
---
name: carbon-verifier
description: Strict read-only verification and audit specialist powered by Carbon (Account A fallback & browser UI). Audits git diffs, edge cases, logic flaws, and real runtime evidence in a fresh context, issuing PASS, FAIL, or BLOCKED.
subagent: true
mainAgent: true
model: pro
commandExecutionPolicy: sandbox
tools:
  - view_file
  - grep_search
  - find_by_name
  - run_command
---

# System Prompt

You are the **Carbon Verifier**. You run in an isolated context, **never trusting self-reports from planning or execution and issuing strict verdicts based solely on objective evidence**. In `v2.5.2`, routine cross-vendor blind audits run via Account B `agy_verify` (`gemini-4-carbon-high`) with parallel `claude_verify` (`opus`, `CLAUDE_VERIFY_EFFORT="high"`) on major changes, while you handle interactive browser UI checks, CLI outage fallbacks (`agy`/`claude` unavailable), and direct in-IDE audits.

## Hard Red Lines
1. **Strictly read-only:** Never modify or delete any file, install dependencies, or commit code. `run_command` is strictly limited to read-only inspections and safe verification checks (run Python with `PYTHONDONTWRITEBYTECODE=1 PYTHONPYCACHEPREFIX=/tmp/carbon_pycache python3 -B` so zero `__pycache__` lands in the workspace).
2. **Missing evidence means `BLOCKED`:** If specifications, verification entrypoints, or required context are missing, never guess pass; issue `VERDICT: BLOCKED` immediately.

## Audit Checklist
1. **Diff & Scope Check:** Verify actual changes match the approved plan with no unrelated edits or leftover debug code.
2. **Cross-Plan Continuity & Anti-Duplication:** When `.agents/state/workspace-brief.md` and `.agents/state/plan-history.md` exist, inspect them read-only for open issues and cross-plan continuity, verifying new changes integrate cleanly with prior completed plans without duplicating helpers/modules or breaking earlier contracts (while treating `.agents/state/` itself as gitignored local state).
3. **Blind Independence (Double-Blind & Browser UI):** Operate strictly independently from any prior `claude_verify`, `agy_verify`, or executor summary unless explicitly auditing a specific disputed finding; handle interactive browser UI verification, double-blind fallback, and Claude/Agy outage fallback.
4. **Logic & Edge-Case Deep Dive:** Inspect null/invalid inputs, state-transition flaws, layout/interaction regressions, and side effects.
5. **Evidence Consistency:** Confirm executor reports match real files, command outputs, and rendered results.

## Output Format (Line 1 MUST be the Verdict)
Line 1 must be strictly one of `VERDICT: PASS`, `VERDICT: FAIL`, or `VERDICT: BLOCKED`, followed by these four sections (write narrative prose in the user's language while keeping `VERDICT:` and severity labels in English):
- **Verified Evidence:** Files/diffs inspected and real command/runtime outputs observed.
- **Issues:** Categorized under `Critical`, `Important`, and `Minor` (include location and symptom; write `None` when empty).
- **Blockers:** Missing items (only when `VERDICT: BLOCKED`).
- **Next Steps:** 1-2 sentences with the most direct fix or missing input needed.
'@
Write-SafeFile -RelativePath '.agents/agents/carbon-verifier.md' -Content $content4

$content5 = @'
{
  "name": "claude-executor",
  "displayName": "Claude Code & Antigravity CLI Relay (Sonnet 5.5 / Opus 5.5 / Agy)",
  "description": "Dual-account WSL/POSIX AI team relay: Desktop App Neon plans natively (with optional agy_plan offload), local Claude Code CLI executes (claude_execute*), Account B Antigravity CLI provides fallback execution via agy_execute (gemini-4-hydrogen-xhigh) and primary cross-vendor blind verification via agy_verify (gemini-4-carbon-high), and claude_verify (opus) joins in parallel for major/high-risk double-blind checks with RWLock concurrency and L1/L2/L3 recovery handoffs.",
  "version": "2.5.2"
}
'@
Write-SafeFile -RelativePath '.agents/plugins/claude-executor/plugin.json' -Content $content5

$content6 = @'
{
  "mcpServers": {
    "claude-executor": {
      "command": "python",
      "args": [
        "-B",
        "${PLUGIN_ROOT}/mcp_server.py"
      ],
      "timeoutSeconds": 180,
      "env": {
        "CLAUDE_MODEL": "sonnet",
        "CLAUDE_EFFORT": "high",
        "CLAUDE_PERMISSION_MODE": "bypassPermissions",
        "CLAUDE_STRICT_MCP_CONFIG": "1",
        "CLAUDE_MAX_TURNS": "40",
        "CLAUDE_TIMEOUT_SECONDS": "150",
        "CLAUDE_ASYNC_TIMEOUT_SECONDS": "900",
        "CLAUDE_SESSION_MAX_TURNS": "30",
        "CLAUDE_SESSION_TTL_SECONDS": "3600",
        "CLAUDE_VERIFY_MODEL": "opus",
        "CLAUDE_VERIFY_EFFORT": "high",
        "CLAUDE_VERIFY_MAX_TURNS": "25",
        "AGY_PLAN_MODEL": "",
        "AGY_EXECUTE_MODEL": "gemini-4-hydrogen-xhigh",
        "AGY_VERIFY_MODEL": "gemini-4-carbon-high",
        "AGY_EFFORT": "",
        "AGY_SANDBOX": "1"
      }
    }
  }
}
'@
Write-SafeFile -RelativePath '.agents/plugins/claude-executor/mcp_config.json' -Content $content6

$content7 = @'
#!/usr/bin/env python3
"""Shared headless runner for delegating approved Antigravity plans to Claude Code CLI."""

from __future__ import annotations

import argparse
import glob
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

VALID_PERMISSION_MODES = frozenset({
    "bypassPermissions",
    "dontAsk",
    "acceptEdits",
    "default",
    "plan",
    "auto",
})

VALID_SESSION_MODES = frozenset({"auto", "resume", "fresh"})

DEFAULT_DISALLOWED_TOOLS = [
    "Bash(git push --force:*)",
    "Bash(git push -f:*)",
    "Bash(git reset --hard:*)",
    "Bash(rm -rf /:*)",
]

SYNC_DEFAULT_TIMEOUT_SECONDS = 150
SYNC_MAX_TIMEOUT_SECONDS = 165
ASYNC_DEFAULT_TIMEOUT_SECONDS = 900
ASYNC_MAX_TIMEOUT_SECONDS = 1800
STATUS_DEFAULT_WAIT_SECONDS = 30
STATUS_MAX_WAIT_SECONDS = 120
MAX_COMPLETED_JOBS = 50

DEFAULT_VERIFY_MODEL = "opus"
VALID_EFFORTS = frozenset({"low", "medium", "high", "xhigh", "max"})
DEFAULT_EFFORT = "high"
DEFAULT_VERIFY_EFFORT = "high"
DEFAULT_MAX_TURNS = 40
DEFAULT_VERIFY_MAX_TURNS = 25
MAX_VERIFY_DIFF_BYTES = 24576
DEFAULT_SESSION_MAX_TURNS = 30
DEFAULT_SESSION_TTL_SECONDS = 3600
MAX_PLAN_HISTORY_ENTRIES = 10
MAX_PLAN_HISTORY_INJECT_BYTES = 8192
DEFAULT_SESSION_KEY = "workspace"
MAX_WORKSPACE_BRIEF_BYTES = 2048
MAX_CONTINUITY_INJECT_BYTES = 3072
MAX_RUN_ARCHIVE_FILES = 20
MAX_DRIFT_DIFF_BYTES = 8192
VALID_DIFF_SCOPES = frozenset({"last_run", "workspace"})
VALID_HANDOFF_MODES = frozenset({"continue", "fix_review", "new_plan"})
DEFAULT_HANDOFF_MAX_BYTES = 3072
MIN_HANDOFF_MAX_BYTES = 512
MAX_HANDOFF_MAX_BYTES = 12288
_GIT_SHA_RE = re.compile(r"^[0-9a-f]{40}$")
STATE_REL_DIR = ".agents/state"
SNAPSHOT_SKIP_DIRS = frozenset({
    ".git",
    "node_modules",
    "__pycache__",
    ".pytest_cache",
    ".mypy_cache",
    ".ruff_cache",
    ".cache",
    ".venv",
    "venv",
    "dist",
    "build",
    ".next",
    ".turbo",
})
VERIFY_DISALLOWED_TOOLS = [
    "Edit",
    "Write",
    "NotebookEdit",
    "Bash(git commit:*)",
    "Bash(git push:*)",
    "Bash(git reset:*)",
    "Bash(git checkout:*)",
    "Bash(git restore:*)",
    "Bash(git clean:*)",
    "Bash(git add:*)",
    "Bash(rm:*)",
    "Bash(mv:*)",
    "Bash(cp:*)",
    "Bash(chmod:*)",
    "Bash(chown:*)",
    "Bash(tee:*)",
]
_RESUME_MISSING_RE = re.compile(
    r"(?i)(no conversation found|session[^.\n]*not found|invalid session|unknown session|could not find session)"
)
_state_lock = threading.RLock()

PLAN_STRICT_SYSTEM_PROMPT = (
    "You are the Claude Executor in the Antigravity three-stage relay workflow. "
    "Strictly execute the Antigravity Neon Planner approved plan provided on stdin. "
    "Hard rules: "
    "1. Check the Prior Completed Plans & Existing Artifacts section first when present so you reuse existing modules, types, and interfaces instead of re-reading the entire codebase or duplicating logic. Also read .agents/state/workspace-brief.md when present, and treat any External Workspace Changes Since Your Last Turn section (changes made outside your session) as authoritative: do not revert them. "
    "2. Follow the plan step-by-step and only modify files within the authorized scope; never reformat or refactor unrelated files. "
    "3. Never create a Git Worktree, and never run git commit or git push. "
    "4. Skip mandatory TDD for lightweight frontend/local script tasks, but always run the required verification commands and capture real output. "
    "5. Retry fixing the same error at most 3 times; if still failing on round 3, stop immediately and return STATUS: BLOCKED with hypotheses and raw error logs. "
    "6. Line 1 of your final report MUST be STATUS: DONE or STATUS: BLOCKED, followed by: modified file list, created or updated key files/symbols/interfaces, verification commands with real exit codes and output summaries, and remaining risks (or None). "
    "Keep STATUS tags in English; match the language used in the plan for narrative explanations."
)

_EXEC_PROMPT = (
    "Strictly execute the Antigravity Neon Planner approved implementation plan from stdin "
    "within the authorized file scope, reuse documented prior interfaces, then report modified files, exported symbols, and real verification evidence."
)

VERIFY_STRICT_SYSTEM_PROMPT = (
    "You are the independent Opus Verifier in the Antigravity three-stage relay workflow. "
    "Perform a strict read-only blind audit of the approved plan, workspace code, git diff, and real runtime evidence provided via stdin. "
    "Hard rules: "
    "1. Strictly read-only: NEVER create, edit, overwrite, or delete any file inside the workspace, and NEVER run git commit, git push, or mutating commands. Store any temporary inspection files only under /tmp and run Python checks with PYTHONDONTWRITEBYTECODE=1 or python3 -B so no __pycache__ is created inside the workspace. "
    "2. Independence and zero trust: never rely on executor self-reports; independently read workspace files, inspect logic flaws, edge cases, regressions, and run non-mutating verification commands when bash is permitted. "
    "3. Cross-plan compatibility and anti-duplication: when Prior Completed Plans & Existing Artifacts or .agents/state/plan-history.md is present, inspect it and fail if changes duplicate existing helpers/modules or break prior contracts. Also read .agents/state/workspace-brief.md when present, and note that the provided diff may be turn-scoped (last run only) instead of covering the whole workspace. "
    "4. Missing evidence means BLOCKED: if required specs, verification entrypoints, or context are missing, output VERDICT: BLOCKED immediately without guessing. "
    "5. Output format: Line 1 MUST be strictly VERDICT: PASS, VERDICT: FAIL, or VERDICT: BLOCKED, followed by four sections: Verified Evidence, Issues (categorized under Critical, Important, and Minor; write None when empty), Blockers (when VERDICT: BLOCKED), and Next Steps. "
    "Keep VERDICT: PASS|FAIL|BLOCKED and Critical|Important|Minor headings in English; match the language used in the plan for narrative explanations."
)

_VERIFY_PROMPT = (
    "Perform a strictly read-only independent blind audit of the approved plan, workspace diff, prior plan history, and verification commands from stdin without modifying any workspace files, then start line 1 with VERDICT: PASS, VERDICT: FAIL, or VERDICT: BLOCKED."
)


def _clamp_env_int(name: str, default: int, min_val: int, max_val: int) -> int:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        val = int(raw)
    except ValueError:
        return default
    return max(min_val, min(max_val, val))


def _safe_int(val: Any, default: int = 0) -> int:
    if isinstance(val, bool) or val is None:
        return default
    try:
        return int(val)
    except (TypeError, ValueError, OverflowError):
        return default


def _safe_float(val: Any, default: float = 0.0) -> float:
    if isinstance(val, bool) or val is None:
        return default
    try:
        res = float(val)
    except (TypeError, ValueError):
        return default
    if res != res or res in (float("inf"), float("-inf")):
        return default
    return res


def get_default_model() -> str:
    return os.environ.get("CLAUDE_MODEL", "sonnet").strip() or "sonnet"


def get_default_verify_model() -> str:
    return os.environ.get("CLAUDE_VERIFY_MODEL", DEFAULT_VERIFY_MODEL).strip() or DEFAULT_VERIFY_MODEL


def _get_env_effort(env_var: str, default: str) -> str:
    """Return validated lowercase effort override from env, default if unset, or '' if explicitly empty/invalid."""
    if env_var not in os.environ:
        return default
    raw = os.environ.get(env_var, "").strip().lower()
    return raw if raw in VALID_EFFORTS else ""


def get_default_effort() -> str:
    return _get_env_effort("CLAUDE_EFFORT", DEFAULT_EFFORT)


def get_default_verify_effort() -> str:
    return _get_env_effort("CLAUDE_VERIFY_EFFORT", DEFAULT_VERIFY_EFFORT)


def _resolve_effort(
    effort: Optional[str], default_effort: str
) -> tuple[Optional[str], Optional[str]]:
    if effort is not None and not isinstance(effort, str):
        return None, f"effort must be a string when provided, got: {effort!r}"
    if isinstance(effort, str):
        cleaned = effort.strip().lower()
        if cleaned == "":
            return None, "effort must be a non-empty string when explicitly provided."
        if cleaned not in VALID_EFFORTS:
            return None, f"Invalid effort '{cleaned}'. Allowed: {sorted(VALID_EFFORTS)}"
        return cleaned, None
    return default_effort, None


def get_default_permission_mode() -> str:
    mode = os.environ.get("CLAUDE_PERMISSION_MODE", "bypassPermissions").strip()
    if mode in VALID_PERMISSION_MODES:
        return mode
    return "bypassPermissions"


def get_default_max_turns() -> int:
    return _clamp_env_int("CLAUDE_MAX_TURNS", DEFAULT_MAX_TURNS, 1, 100)


def get_default_verify_max_turns() -> int:
    return _clamp_env_int("CLAUDE_VERIFY_MAX_TURNS", DEFAULT_VERIFY_MAX_TURNS, 1, 100)


def get_default_timeout_seconds(sync: bool = True) -> int:
    if sync:
        return _clamp_env_int(
            "CLAUDE_TIMEOUT_SECONDS",
            SYNC_DEFAULT_TIMEOUT_SECONDS,
            1,
            SYNC_MAX_TIMEOUT_SECONDS,
        )
    return _clamp_env_int(
        "CLAUDE_ASYNC_TIMEOUT_SECONDS",
        ASYNC_DEFAULT_TIMEOUT_SECONDS,
        1,
        ASYNC_MAX_TIMEOUT_SECONDS,
    )


def get_strict_mcp_config() -> bool:
    raw = os.environ.get("CLAUDE_STRICT_MCP_CONFIG", "1").strip().lower()
    return raw not in {"0", "false", "no", "off"}


def get_default_session_max_turns() -> int:
    return _clamp_env_int("CLAUDE_SESSION_MAX_TURNS", DEFAULT_SESSION_MAX_TURNS, 1, 200)


def get_default_session_ttl_seconds() -> int:
    return _clamp_env_int("CLAUDE_SESSION_TTL_SECONDS", DEFAULT_SESSION_TTL_SECONDS, 60, 86400)


def _is_executable_file(path_str: str) -> bool:
    if not path_str or not os.path.isfile(path_str):
        return False
    if os.name == "nt":
        return True
    return os.access(path_str, os.X_OK)


def _semver_key(path_str: str) -> tuple[int, ...]:
    """Extract numeric semver tuple from an nvm node directory path for descending sort."""
    try:
        version_dir = Path(path_str).parents[1].name
    except IndexError:
        return (0,)
    nums = [int(part) for part in re.findall(r"\d+", version_dir)]
    return tuple(nums) if nums else (0,)


def find_claude_binary() -> tuple[Optional[str], Optional[str]]:
    """Locate the local Claude Code CLI binary across POSIX/WSL and Windows."""
    override = os.environ.get("CLAUDE_BIN", "").strip()
    if override:
        expanded = os.path.expanduser(override)
        if _is_executable_file(expanded):
            return expanded, None
        return None, f"CLAUDE_BIN points to invalid/non-executable file: {expanded}"

    if os.name == "nt":
        which_names = ["claude.exe", "claude", "claude.cmd"]
    else:
        which_names = ["claude"]
    for name in which_names:
        found = shutil.which(name)
        if found and _is_executable_file(found):
            return found, None

    candidates: list[str] = []
    if os.name == "nt":
        user_profile = os.environ.get("USERPROFILE", str(Path.home()))
        appdata = os.environ.get("APPDATA", "")
        localappdata = os.environ.get("LOCALAPPDATA", "")
        candidates.extend([
            os.path.join(user_profile, ".local", "bin", "claude.exe"),
            os.path.join(user_profile, ".claude", "local", "claude.exe"),
        ])
        if appdata:
            candidates.append(os.path.join(appdata, "npm", "claude.cmd"))
        if localappdata:
            candidates.append(os.path.join(localappdata, "Programs", "claude", "claude.exe"))
    else:
        home = str(Path.home())
        candidates.extend([
            os.path.join(home, ".local", "bin", "claude"),
            os.path.join(home, ".claude", "local", "claude"),
            os.path.join(home, ".npm-global", "bin", "claude"),
            os.path.join(home, ".local", "share", "pnpm", "claude"),
            os.path.join(home, ".volta", "bin", "claude"),
            os.path.join(home, ".asdf", "shims", "claude"),
            os.path.join(home, ".mise", "shims", "claude"),
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
        ])
        nvm_pattern = os.path.join(home, ".nvm", "versions", "node", "*", "bin", "claude")
        nvm_matches = sorted(glob.glob(nvm_pattern), key=_semver_key, reverse=True)
        candidates.extend(nvm_matches)

    for cand in candidates:
        if _is_executable_file(cand):
            return cand, None

    return (
        None,
        "Claude Code CLI ('claude') not found in PATH or standard install paths. "
        "Install Claude Code CLI or set CLAUDE_BIN.",
    )


def resolve_cmd_shim(cmd_path: str) -> Optional[list[str]]:
    """Resolve an npm .cmd/.bat wrapper directly to [node_exe, target_js] to bypass cmd.exe."""
    shim = Path(cmd_path)
    shim_dir = shim.parent
    js_candidate: Optional[Path] = None

    try:
        shim_text = shim.read_text(encoding="utf-8", errors="replace")[:8192]
    except OSError:
        shim_text = ""

    # Match npm-generated shims such as "%dp0%\node_modules\@anthropic-ai\claude-code\cli.js"
    for match in re.finditer(
        r"(?:%~dp0|%dp0%)[\\/]+([^\"'\r\n]+\.(?:c?js|mjs))",
        shim_text,
        re.IGNORECASE,
    ):
        rel = match.group(1).replace("\\", os.sep).replace("/", os.sep)
        candidate = (shim_dir / rel).resolve()
        if candidate.is_file():
            js_candidate = candidate
            break

    if js_candidate is None:
        fallback_js = shim_dir / "node_modules" / "@anthropic-ai" / "claude-code" / "cli.js"
        if fallback_js.is_file():
            js_candidate = fallback_js.resolve()

    if js_candidate is None:
        return None

    node_names = ("node.exe", "node") if os.name == "nt" else ("node", "node.exe")
    node_bin: Optional[str] = None
    for n in node_names:
        sibling = shim_dir / n
        if sibling.is_file() and (os.name == "nt" or os.access(sibling, os.X_OK)):
            node_bin = str(sibling)
            break
    if node_bin is None:
        node_bin = shutil.which("node.exe") if os.name == "nt" else shutil.which("node")
    if not node_bin:
        return None

    return [node_bin, str(js_candidate)]


def build_claude_argv(claude_bin: str, args: list[str]) -> list[str]:
    """Construct subprocess argv, resolving .cmd/.bat shims cleanly for CreateProcess."""
    if claude_bin.lower().endswith((".cmd", ".bat")):
        resolved = resolve_cmd_shim(claude_bin)
        if resolved:
            return [*resolved, *args]
        if os.name == "nt":
            comspec = os.environ.get("COMSPEC", "cmd.exe")
            return [comspec, "/d", "/s", "/c", claude_bin, *args]
    return [claude_bin, *args]


def build_child_env(claude_bin: str) -> dict[str, str]:
    """Prepare child environment with claude binary dir in PATH and nested flags cleared."""
    env = os.environ.copy()
    env.pop("CLAUDECODE", None)
    env.pop("CLAUDE_CODE_ENTRYPOINT", None)

    bin_path = Path(claude_bin)
    extra_dirs: list[str] = []
    for candidate_dir in (str(bin_path.parent), str(bin_path.resolve().parent)):
        if candidate_dir and candidate_dir not in extra_dirs:
            extra_dirs.append(candidate_dir)

    existing_path = env.get("PATH", "")
    existing_parts = [p for p in existing_path.split(os.pathsep) if p] if existing_path else []
    merged_parts = extra_dirs + [p for p in existing_parts if p not in extra_dirs]
    env["PATH"] = os.pathsep.join(merged_parts)
    return env


def terminate_process_tree(proc: subprocess.Popen[str]) -> None:
    """Terminate a child process and its entire process group/tree safely."""
    if proc.poll() is not None:
        return

    if os.name == "nt":
        try:
            subprocess.run(
                ["taskkill", "/T", "/F", "/PID", str(proc.pid)],
                capture_output=True,
                timeout=5,
            )
        except (OSError, subprocess.TimeoutExpired):
            pass
        if proc.poll() is None:
            try:
                proc.kill()
            except OSError:
                pass
        try:
            proc.wait(timeout=2.0)
        except (subprocess.TimeoutExpired, OSError):
            pass
        return

    pgid: Optional[int] = None
    try:
        pgid = os.getpgid(proc.pid)
    except (ProcessLookupError, OSError):
        pgid = None

    try:
        if pgid is not None:
            os.killpg(pgid, signal.SIGTERM)
        else:
            proc.terminate()
    except (ProcessLookupError, OSError):
        pass

    try:
        proc.wait(timeout=2.0)
    except (subprocess.TimeoutExpired, OSError):
        pass

    # Always SIGKILL the entire process group even if the direct child already exited
    # on SIGTERM, so grandchildren that trap/ignore SIGTERM cannot become orphans.
    try:
        if pgid is not None:
            os.killpg(pgid, signal.SIGKILL)
        elif proc.poll() is None:
            proc.kill()
    except (ProcessLookupError, OSError):
        pass

    if proc.poll() is None:
        try:
            proc.wait(timeout=2.0)
        except (subprocess.TimeoutExpired, OSError):
            pass


def _run_popen_cancellable(
    cmd: list[str],
    stdin_payload: str,
    cwd: str,
    env: dict[str, str],
    timeout_seconds: int,
    cancel_event: Optional[threading.Event] = None,
) -> tuple[str, Optional[int], str, str, float]:
    """Run subprocess in its own process group with threaded pipe draining and cancellation."""
    popen_kwargs: dict[str, Any] = {
        "stdin": subprocess.PIPE,
        "stdout": subprocess.PIPE,
        "stderr": subprocess.PIPE,
        "text": True,
        "encoding": "utf-8",
        "errors": "replace",
        "cwd": cwd,
        "env": env,
    }
    if os.name == "nt":
        popen_kwargs["creationflags"] = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
    else:
        popen_kwargs["start_new_session"] = True

    started = time.monotonic()
    proc = subprocess.Popen(cmd, **popen_kwargs)

    stdout_chunks: list[str] = []
    stderr_chunks: list[str] = []

    def _feed_stdin() -> None:
        if proc.stdin is None:
            return
        try:
            proc.stdin.write(stdin_payload)
            proc.stdin.flush()
        except (BrokenPipeError, OSError, ValueError):
            pass
        finally:
            try:
                proc.stdin.close()
            except (OSError, ValueError):
                pass

    def _drain_stream(stream: Any, target: list[str]) -> None:
        if stream is None:
            return
        try:
            data = stream.read()
            if data:
                target.append(data)
        except (OSError, ValueError):
            pass
        finally:
            try:
                stream.close()
            except (OSError, ValueError):
                pass

    t_in = threading.Thread(target=_feed_stdin, daemon=True)
    t_out = threading.Thread(target=_drain_stream, args=(proc.stdout, stdout_chunks), daemon=True)
    t_err = threading.Thread(target=_drain_stream, args=(proc.stderr, stderr_chunks), daemon=True)
    t_in.start()
    t_out.start()
    t_err.start()

    deadline = started + timeout_seconds
    outcome = "EXITED"
    while True:
        rc = proc.poll()
        if rc is not None:
            outcome = "EXITED"
            break
        if cancel_event is not None and cancel_event.is_set():
            terminate_process_tree(proc)
            outcome = "CANCELLED"
            break
        now = time.monotonic()
        if now >= deadline:
            terminate_process_tree(proc)
            outcome = "TIMEOUT"
            break
        step = min(0.1, deadline - now)
        if cancel_event is not None:
            if cancel_event.wait(timeout=step):
                terminate_process_tree(proc)
                outcome = "CANCELLED"
                break
        else:
            time.sleep(step)

    t_in.join(timeout=0.5)
    t_out.join(timeout=2.0)
    t_err.join(timeout=2.0)

    elapsed = time.monotonic() - started
    return (
        outcome,
        proc.poll(),
        "".join(stdout_chunks),
        "".join(stderr_chunks),
        elapsed,
    )


def _is_state_git_status_line(line: str) -> bool:
    """Return True if a `git status --short` line refers to .agents/state/."""
    body = line[3:].strip() if len(line) > 3 else line.strip()
    norm = body.replace("\\", "/").replace('"', "")
    for part in norm.split(" -> "):
        cleaned = part.strip()
        if cleaned == STATE_REL_DIR or cleaned.startswith(STATE_REL_DIR + "/"):
            return True
    return False


def _run_git_cmd(workspace_dir: str, args: list[str]) -> Optional[subprocess.CompletedProcess[str]]:
    try:
        return subprocess.run(
            ["git", *args],
            cwd=workspace_dir,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None


def _run_git_cmd_env(
    workspace_dir: str,
    args: list[str],
    env: Optional[dict[str, str]] = None,
    *,
    text: bool = True,
    input_bytes: Optional[bytes] = None,
) -> Optional[subprocess.CompletedProcess]:
    """Run a git command with an optional environment override and a bounded timeout."""
    try:
        if text:
            return subprocess.run(
                ["git", *args],
                cwd=workspace_dir,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                env=env,
                input=input_bytes,
                timeout=15,
            )
        return subprocess.run(
            ["git", *args],
            cwd=workspace_dir,
            capture_output=True,
            env=env,
            input=input_bytes,
            timeout=15,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None


def _is_git_worktree(ws_str: str) -> bool:
    """Return True when ws_str is inside a git work tree."""
    proc = _run_git_cmd(ws_str, ["rev-parse", "--is-inside-work-tree"])
    if proc is None or proc.returncode != 0:
        return False
    return proc.stdout.strip().lower() == "true"


def _git_toplevel(ws_str: str) -> Optional[Path]:
    """Return the resolved git top-level directory for ws_str, or None."""
    proc = _run_git_cmd(ws_str, ["rev-parse", "--show-toplevel"])
    if proc is None or proc.returncode != 0:
        return None
    raw = proc.stdout.strip()
    if not raw:
        return None
    try:
        return Path(raw).resolve()
    except OSError:
        return None


def _git_tree_exists(ws_str: str, tree_sha: Optional[str]) -> bool:
    """Return True when tree_sha names an existing git tree object."""
    if not isinstance(tree_sha, str) or not _GIT_SHA_RE.fullmatch(tree_sha):
        return False
    proc = _run_git_cmd(ws_str, ["cat-file", "-t", tree_sha])
    if proc is None or proc.returncode != 0:
        return False
    return proc.stdout.strip() == "tree"


def _capture_git_tree(ws_str: str) -> Optional[str]:
    """Capture a temporary git tree object of the work tree without touching .git/index."""
    if not _is_git_worktree(ws_str):
        return None

    fd = -1
    tmp_idx = ""
    try:
        fd, tmp_idx = tempfile.mkstemp(prefix="ai_teams_git_idx_", suffix=".idx")
        os.close(fd)
        fd = -1
        os.unlink(tmp_idx)
    except OSError:
        if fd >= 0:
            try:
                os.close(fd)
            except OSError:
                pass
        return None

    try:
        env = os.environ.copy()
        env["GIT_INDEX_FILE"] = tmp_idx

        add_proc = _run_git_cmd_env(ws_str, ["add", "-A", "--", "."], env=env)
        if add_proc is None or add_proc.returncode != 0:
            return None

        _run_git_cmd_env(
            ws_str,
            ["rm", "-r", "--cached", "--ignore-unmatch", "-q", "--", STATE_REL_DIR],
            env=env,
        )

        tree_proc = _run_git_cmd_env(ws_str, ["write-tree"], env=env)
        if tree_proc is not None and tree_proc.returncode == 0:
            tree_sha = tree_proc.stdout.strip()
            if _GIT_SHA_RE.fullmatch(tree_sha):
                return tree_sha
        return None
    finally:
        try:
            if os.path.exists(tmp_idx):
                os.unlink(tmp_idx)
        except OSError:
            pass


def collect_external_drift(
    ws_str: str,
    base_tree: Optional[str],
    *,
    current_tree: Optional[str] = None,
    max_bytes: int = MAX_DRIFT_DIFF_BYTES,
) -> dict[str, Any]:
    """Collect bounded drift between a base tree and the current work tree, excluding state."""
    empty: dict[str, Any] = {
        "has_drift": False,
        "drift_files": [],
        "drift_diff": "",
        "drift_truncated": False,
    }
    if not _git_tree_exists(ws_str, base_tree):
        return empty

    cur = current_tree if _git_tree_exists(ws_str, current_tree) else _capture_git_tree(ws_str)
    if not cur or cur == base_tree:
        return empty

    def _git_diff_between(extra_args: list[str]) -> Optional[subprocess.CompletedProcess]:
        base_args = ["diff", *extra_args, str(base_tree), str(cur)]
        proc = _run_git_cmd(
            ws_str, [*base_args, "--", ".", f":(exclude){STATE_REL_DIR}"]
        )
        if proc is not None and proc.returncode == 0:
            return proc
        return _run_git_cmd(ws_str, [*base_args, "--", "."])

    names_proc = _git_diff_between(["--name-only"])
    if names_proc is None or names_proc.returncode != 0:
        return empty

    drift_files: list[str] = []
    for line in names_proc.stdout.splitlines():
        name = line.strip().replace("\\", "/")
        if not name:
            continue
        if name == STATE_REL_DIR or name.startswith(STATE_REL_DIR + "/"):
            continue
        drift_files.append(name)
    if not drift_files:
        return empty

    diff_proc = _git_diff_between([])
    diff_text = ""
    if diff_proc is not None and diff_proc.returncode == 0:
        diff_text = diff_proc.stdout
    diff_truncated = False
    if len(diff_text.encode("utf-8")) > max_bytes:
        diff_truncated = True
        diff_text = (
            _truncate_utf8(diff_text, max_bytes).rstrip()
            + f"\n... [external drift diff truncated at {max_bytes} bytes]"
        )

    return {
        "has_drift": True,
        "drift_files": drift_files[:100],
        "drift_diff": diff_text,
        "drift_truncated": diff_truncated,
    }


def collect_git_evidence(workspace_dir: str) -> dict[str, Any]:
    """Collect git status and diff stat from workspace_dir if it is a git repository."""
    empty = {"is_git_repo": False, "changed_files": [], "git_diff_stat": ""}
    if not workspace_dir or not os.path.isdir(workspace_dir):
        return empty

    probe = _run_git_cmd(workspace_dir, ["rev-parse", "--is-inside-work-tree"])
    if probe is None or probe.returncode != 0 or probe.stdout.strip().lower() != "true":
        return empty

    status_proc = _run_git_cmd(workspace_dir, ["status", "--short"])
    changed_files: list[str] = []
    if status_proc and status_proc.returncode == 0:
        changed_files = [
            line.rstrip()
            for line in status_proc.stdout.splitlines()
            if line.strip() and not _is_state_git_status_line(line)
        ]

    diff_parts: list[str] = []
    unstaged = _run_git_cmd(workspace_dir, ["diff", "--stat"])
    if unstaged and unstaged.returncode == 0 and unstaged.stdout.strip():
        diff_parts.append(unstaged.stdout.strip())
    staged = _run_git_cmd(workspace_dir, ["diff", "--cached", "--stat"])
    if staged and staged.returncode == 0 and staged.stdout.strip():
        if diff_parts:
            diff_parts.append("[staged]\n" + staged.stdout.strip())
        else:
            diff_parts.append(staged.stdout.strip())

    return {
        "is_git_repo": True,
        "changed_files": changed_files,
        "git_diff_stat": "\n".join(diff_parts),
    }


def _run_git_diff_excl_state(
    workspace_dir: str, base_args: list[str]
) -> Optional[subprocess.CompletedProcess[str]]:
    with_excl = _run_git_cmd(
        workspace_dir, [*base_args, "--", ".", f":(exclude){STATE_REL_DIR}"]
    )
    if with_excl is not None and with_excl.returncode == 0:
        return with_excl
    return _run_git_cmd(workspace_dir, base_args)


def _cap_verify_diff(raw_diff: str, max_bytes: int) -> tuple[str, bool]:
    """Bound raw diff text to max_bytes using the standard verification truncation style."""
    if max_bytes >= 0 and len(raw_diff.encode("utf-8")) > max_bytes:
        if max_bytes == 0:
            return f"... [diff truncated at {max_bytes} bytes]", True
        return (
            _truncate_utf8(raw_diff, max_bytes).rstrip()
            + f"\n\n... [diff truncated at {max_bytes} bytes; inspect workspace files directly]",
            True,
        )
    return raw_diff, False


def _resolve_pre_run_tree(
    workspace_dir: str, explicit_tree: Optional[str] = None
) -> Optional[str]:
    """Read-only resolution of the most relevant pre-run tree checkpoint."""
    if _git_tree_exists(workspace_dir, explicit_tree):
        return str(explicit_tree)
    checkpoint = load_workspace_state(workspace_dir).get("checkpoint")
    if isinstance(checkpoint, dict):
        state_tree = checkpoint.get("pre_run_tree")
        if _git_tree_exists(workspace_dir, state_tree):
            return str(state_tree)
    sessions = load_session_index(workspace_dir).get("sessions")
    if not isinstance(sessions, dict):
        return None
    best_tree: Optional[str] = None
    best_ts: Optional[float] = None
    for entry in sessions.values():
        if not isinstance(entry, dict):
            continue
        tree = entry.get("pre_run_tree")
        if not _git_tree_exists(workspace_dir, tree):
            continue
        ts = _safe_float(entry.get("updated_at"), 0.0)
        if best_ts is None or ts > best_ts:
            best_ts = ts
            best_tree = str(tree)
    return best_tree


def collect_verify_diff(
    workspace_dir: str,
    max_bytes: int = MAX_VERIFY_DIFF_BYTES,
    *,
    diff_scope: str = "last_run",
    pre_run_tree: Optional[str] = None,
) -> dict[str, Any]:
    """Collect read-only git status and a diff scoped to the last run or the whole workspace."""
    git_ev = collect_git_evidence(workspace_dir)
    scope_keys: dict[str, Any] = {
        "diff_scope": diff_scope,
        "resolved_diff_scope": "workspace",
        "pre_run_tree": None,
        "last_run_changed_files": [],
    }
    if not git_ev["is_git_repo"]:
        return {**git_ev, "git_diff": "", "diff_truncated": False, **scope_keys}

    if diff_scope == "last_run":
        base_tree = _resolve_pre_run_tree(workspace_dir, pre_run_tree)
        if base_tree is not None:
            current_tree = _capture_git_tree(workspace_dir)
            if current_tree is not None:
                def _diff_between(extra_args: list[str]) -> Optional[subprocess.CompletedProcess[str]]:
                    base_args = ["diff", *extra_args, base_tree, current_tree]
                    proc = _run_git_cmd(
                        workspace_dir,
                        [*base_args, "--", ".", f":(exclude){STATE_REL_DIR}"],
                    )
                    if proc is not None and proc.returncode == 0:
                        return proc
                    return _run_git_cmd(workspace_dir, [*base_args, "--", "."])

                last_run_files: list[str] = []
                names_proc = _diff_between(["--name-status"])
                if names_proc is not None and names_proc.returncode == 0:
                    for raw_line in names_proc.stdout.splitlines():
                        line = raw_line.rstrip()
                        if not line.strip():
                            continue
                        parts = line.split("\t")
                        path = parts[-1].strip().replace("\\", "/")
                        if not path:
                            continue
                        if path == STATE_REL_DIR or path.startswith(STATE_REL_DIR + "/"):
                            continue
                        status_letter = parts[0].strip()[:1] or "?"
                        last_run_files.append(f"{status_letter} {path}")
                        if len(last_run_files) >= 100:
                            break

                stat_proc = _diff_between(["--stat"])
                git_diff_stat = ""
                if stat_proc is not None and stat_proc.returncode == 0:
                    git_diff_stat = stat_proc.stdout.strip()

                raw_diff = ""
                diff_proc = _diff_between([])
                if diff_proc is not None and diff_proc.returncode == 0:
                    raw_diff = diff_proc.stdout.rstrip()
                capped_diff, diff_truncated = _cap_verify_diff(raw_diff, max_bytes)

                return {
                    **git_ev,
                    "git_diff": capped_diff,
                    "diff_truncated": diff_truncated,
                    "git_diff_stat": git_diff_stat,
                    "diff_scope": diff_scope,
                    "resolved_diff_scope": "last_run",
                    "pre_run_tree": base_tree,
                    "last_run_changed_files": last_run_files,
                }

    diff_chunks: list[str] = []
    unstaged = _run_git_diff_excl_state(workspace_dir, ["diff"])
    if unstaged and unstaged.returncode == 0 and unstaged.stdout.strip():
        diff_chunks.append(unstaged.stdout.rstrip())
    staged = _run_git_diff_excl_state(workspace_dir, ["diff", "--cached"])
    if staged and staged.returncode == 0 and staged.stdout.strip():
        diff_chunks.append("[staged]\n" + staged.stdout.rstrip())

    raw_diff = "\n\n".join(diff_chunks)
    capped_diff, diff_truncated = _cap_verify_diff(raw_diff, max_bytes)

    return {
        **git_ev,
        "git_diff": capped_diff,
        "diff_truncated": diff_truncated,
        **scope_keys,
    }


def _atomic_write_text(path: Path, text: str) -> None:
    """Atomically write UTF-8 text via a temporary sibling file and os.replace."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path: Optional[str] = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            newline="\n",
            dir=str(path.parent),
            prefix=f".{path.name}.",
            suffix=".tmp",
            delete=False,
        ) as fh:
            tmp_path = fh.name
            fh.write(text)
            fh.flush()
            try:
                os.fsync(fh.fileno())
            except OSError:
                pass
        os.replace(tmp_path, path)
    except Exception:
        if tmp_path:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
        raise


def _state_dir_path(ws_str: str) -> Path:
    return Path(ws_str) / ".agents" / "state"


def _ensure_state_dir(ws_str: str) -> Path:
    """Create .agents/state/ and ensure its .gitignore ignores local state files."""
    with _state_lock:
        state_dir = _state_dir_path(ws_str)
        state_dir.mkdir(parents=True, exist_ok=True)
        gitignore = state_dir / ".gitignore"
        if not gitignore.exists():
            _atomic_write_text(gitignore, "*\n")
        return state_dir


def load_session_index(ws_str: str) -> dict[str, Any]:
    """Load .agents/state/session-index.json safely, returning an empty schema if missing/corrupt."""
    with _state_lock:
        index_path = _state_dir_path(ws_str) / "session-index.json"
        if not index_path.is_file():
            return {"version": 1, "sessions": {}}
        try:
            loaded = json.loads(index_path.read_text(encoding="utf-8", errors="replace"))
        except (OSError, json.JSONDecodeError):
            return {"version": 1, "sessions": {}}
        if not isinstance(loaded, dict):
            return {"version": 1, "sessions": {}}
        sessions = loaded.get("sessions")
        if not isinstance(sessions, dict):
            sessions = {}
        return {"version": 1, "sessions": dict(sessions)}


def save_session_index(ws_str: str, index_data: dict[str, Any]) -> None:
    """Persist .agents/state/session-index.json atomically under lock."""
    with _state_lock:
        state_dir = _ensure_state_dir(ws_str)
        sessions = index_data.get("sessions")
        payload = {
            "version": 1,
            "sessions": dict(sessions) if isinstance(sessions, dict) else {},
        }
        _atomic_write_text(
            state_dir / "session-index.json",
            json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        )


def _escape_history_markers(text: str) -> str:
    return text.replace("<!-- ENTRY:", "&lt;!-- ENTRY:")


def _truncate_utf8(text: str, max_bytes: int) -> str:
    encoded = text.encode("utf-8")
    if len(encoded) <= max_bytes:
        return text
    return encoded[:max_bytes].decode("utf-8", errors="ignore")


def read_plan_history(
    ws_str: str, max_bytes: int = MAX_PLAN_HISTORY_INJECT_BYTES
) -> str:
    """Read the newest bounded entries from .agents/state/plan-history.md within max_bytes."""
    with _state_lock:
        hist_path = _state_dir_path(ws_str) / "plan-history.md"
        if not hist_path.is_file() or max_bytes <= 0:
            return ""
        try:
            raw = hist_path.read_text(encoding="utf-8", errors="replace").strip()
        except OSError:
            return ""
        if not raw:
            return ""

        blocks = re.findall(
            r"<!-- ENTRY:START -->\s*(.*?)\s*<!-- ENTRY:END -->",
            raw,
            re.DOTALL,
        )
        if not blocks:
            encoded = raw.encode("utf-8")
            if len(encoded) <= max_bytes:
                return raw
            return encoded[-max_bytes:].decode("utf-8", errors="ignore").lstrip()

        selected_rev: list[str] = []
        used_bytes = 0
        for block in reversed(blocks):
            clean = block.strip()
            if not clean:
                continue
            chunk_bytes = len(clean.encode("utf-8"))
            sep_bytes = 2 if selected_rev else 0
            if used_bytes + sep_bytes + chunk_bytes <= max_bytes:
                selected_rev.append(clean)
                used_bytes += sep_bytes + chunk_bytes
            else:
                if not selected_rev:
                    selected_rev.append(_truncate_utf8(clean, max_bytes))
                break

        selected_rev.reverse()
        return "\n\n".join(selected_rev)


def _compact_snippet(text: str, limit: int) -> str:
    lines = [ln.strip() for ln in (text or "").splitlines() if ln.strip()]
    joined = " ".join(lines)
    joined = _escape_history_markers(joined)
    if len(joined) <= limit:
        return joined or "(empty)"
    return joined[: max(0, limit - 3)].rstrip() + "..."


def append_plan_history(
    ws_str: str,
    *,
    status: str,
    plan_text: str,
    plan_file: Optional[str],
    session_key: str,
    session_id: Optional[str],
    session_action: str,
    changed_files: list[str],
    result_text: str,
    num_turns: Optional[int] = None,
    run_id: Optional[str] = None,
    symbols: Optional[list[str]] = None,
    archive_rel_path: Optional[str] = None,
) -> None:
    """Append a compact structured run record to .agents/state/plan-history.md capped at MAX_PLAN_HISTORY_ENTRIES."""
    timestamp_utc = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    plan_summary = _compact_snippet(plan_text, 160)
    outcome_text = _compact_snippet(result_text, 220)

    capped_files = changed_files[:12]
    if capped_files:
        files_str = ", ".join(f"`{p}`" for p in capped_files)
        if len(changed_files) > 12:
            files_str += f" (+{len(changed_files) - 12} more)"
    else:
        files_str = "none"

    clean_symbols = [str(sym) for sym in (symbols or []) if str(sym).strip()]
    capped_symbols = clean_symbols[:12]
    symbols_str = ", ".join(capped_symbols) if capped_symbols else "none"

    entry_lines = [
        "<!-- ENTRY:START -->",
        f"### [{timestamp_utc}] {status} | session_key={session_key} | action={session_action}",
        f"- Plan: {plan_summary} (source: {plan_file or 'inline'})",
        f"- Files: {files_str}   | Symbols: {symbols_str}",
        f"- Outcome: {outcome_text}",
    ]
    if archive_rel_path:
        entry_lines.append(f"- Details: {archive_rel_path}")
    entry_lines.append("<!-- ENTRY:END -->")
    entry_block = "\n".join(entry_lines)

    with _state_lock:
        state_dir = _ensure_state_dir(ws_str)
        hist_path = state_dir / "plan-history.md"
        existing_blocks: list[str] = []
        if hist_path.is_file():
            try:
                existing_raw = hist_path.read_text(encoding="utf-8", errors="replace")
                existing_blocks = re.findall(
                    r"<!-- ENTRY:START -->.*?<!-- ENTRY:END -->",
                    existing_raw,
                    re.DOTALL,
                )
            except OSError:
                existing_blocks = []

        existing_blocks.append(entry_block)
        kept = existing_blocks[-MAX_PLAN_HISTORY_ENTRIES:]
        content = "# Plan Continuity History\n\n" + "\n\n".join(kept) + "\n"
        _atomic_write_text(hist_path, content)


def _ascii_safe(text: str) -> str:
    """Strip C0/DEL control characters while preserving valid UTF-8 runtime text."""
    cleaned = re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]", "", text or "")
    return cleaned.encode("utf-8", errors="replace").decode("utf-8")


def _artifact_sort_key(item: tuple[str, Any]) -> str:
    meta = item[1]
    if isinstance(meta, dict):
        return str(meta.get("updated_at", ""))
    return ""


def _extract_file_symbols(
    ws_str: str, rel_paths: list[str], max_per_file: int = 12
) -> dict[str, list[str]]:
    """Return top-level symbol names per existing source file, bounded and workspace-confined."""
    py_re = re.compile(r"^(?:async\s+)?(?:def|class)\s+([A-Za-z_][A-Za-z0-9_]*)")
    js_re = re.compile(
        r"^export\s+(?:default\s+)?(?:async\s+)?(?:function|class|const|let|var|interface|type|enum)\s+([A-Za-z_$][A-Za-z0-9_$]*)"
    )
    go_rust_re = re.compile(
        r"^(?:pub\s+)?(?:async\s+)?(?:fn|func|struct|trait|type)\s+(?:\([^)]*\)\s*)?([A-Za-z_][A-Za-z0-9_]*)"
    )
    result: dict[str, list[str]] = {}
    try:
        root = Path(ws_str).resolve()
    except OSError:
        return result

    for rel in rel_paths[:40]:
        if not isinstance(rel, str) or not rel.strip():
            continue
        rel_clean = rel.strip()
        try:
            target = (root / rel_clean).resolve()
        except OSError:
            continue
        if target != root and root not in target.parents:
            continue
        try:
            if not target.is_file():
                continue
            if target.stat().st_size > 262144:
                continue
            data = target.read_bytes()
        except OSError:
            continue
        if b"\x00" in data:
            continue
        text = data.decode("utf-8", errors="replace")

        symbols: list[str] = []
        seen: set[str] = set()
        for line in text.splitlines():
            if not line or line[0].isspace():
                continue
            match = py_re.match(line) or js_re.match(line) or go_rust_re.match(line)
            if not match:
                continue
            name = match.group(1)
            if name in seen:
                continue
            seen.add(name)
            symbols.append(name)
            if len(symbols) >= max_per_file:
                break
        if symbols:
            result[rel_clean] = symbols
    return result


def _default_workspace_state() -> dict[str, Any]:
    return {
        "version": 1,
        "checkpoint": {},
        "artifacts": {},
        "open_issues": [],
        "open_issues_by_source": {},
        "last_error": None,
    }


def load_workspace_state(ws_str: str) -> dict[str, Any]:
    """Strictly read-only load of .agents/state/state.json with type normalization."""
    state_path = _state_dir_path(ws_str) / "state.json"
    if not state_path.is_file():
        return _default_workspace_state()
    try:
        loaded = json.loads(state_path.read_text(encoding="utf-8", errors="replace"))
    except (OSError, json.JSONDecodeError):
        return _default_workspace_state()
    if not isinstance(loaded, dict):
        return _default_workspace_state()
    checkpoint = loaded.get("checkpoint")
    artifacts = loaded.get("artifacts")
    open_issues = loaded.get("open_issues")
    raw_by_source = loaded.get("open_issues_by_source")
    raw_last_error = loaded.get("last_error")
    by_source: dict[str, list[str]] = {}
    if isinstance(raw_by_source, dict):
        for src_key, src_items in raw_by_source.items():
            if not isinstance(src_key, str) or not src_key.strip():
                continue
            if isinstance(src_items, list):
                by_source[src_key.strip()] = [
                    item for item in src_items if isinstance(item, str)
                ]
    return {
        "version": 1,
        "checkpoint": dict(checkpoint) if isinstance(checkpoint, dict) else {},
        "artifacts": dict(artifacts) if isinstance(artifacts, dict) else {},
        "open_issues": (
            [item for item in open_issues if isinstance(item, str)]
            if isinstance(open_issues, list)
            else []
        ),
        "open_issues_by_source": by_source,
        "last_error": dict(raw_last_error) if isinstance(raw_last_error, dict) else None,
    }


def save_workspace_state(ws_str: str, state: dict[str, Any]) -> None:
    """Atomically persist .agents/state/state.json under the state lock."""
    checkpoint = state.get("checkpoint")
    artifacts = state.get("artifacts")
    open_issues = state.get("open_issues")
    raw_by_source = state.get("open_issues_by_source")
    raw_last_error = state.get("last_error")
    by_source: dict[str, list[str]] = {}
    if isinstance(raw_by_source, dict):
        for src_key, src_items in raw_by_source.items():
            if isinstance(src_key, str) and src_key.strip() and isinstance(src_items, list):
                by_source[src_key.strip()] = [str(x) for x in src_items if isinstance(x, str)]
    payload = {
        "version": 1,
        "checkpoint": dict(checkpoint) if isinstance(checkpoint, dict) else {},
        "artifacts": dict(artifacts) if isinstance(artifacts, dict) else {},
        "open_issues": list(open_issues) if isinstance(open_issues, list) else [],
        "open_issues_by_source": by_source,
        "last_error": dict(raw_last_error) if isinstance(raw_last_error, dict) else None,
    }
    with _state_lock:
        state_dir = _ensure_state_dir(ws_str)
        _atomic_write_text(
            state_dir / "state.json",
            json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        )


def _prune_deleted_artifacts(ws_str: str, artifacts: dict[str, Any]) -> dict[str, Any]:
    kept: dict[str, Any] = {}
    root = Path(ws_str)
    for rel, meta in artifacts.items():
        if not isinstance(rel, str):
            continue
        try:
            if (root / rel).exists():
                kept[rel] = meta
        except OSError:
            continue
    return kept


def render_workspace_brief(
    ws_str: str, state: dict[str, Any], max_bytes: int = MAX_WORKSPACE_BRIEF_BYTES
) -> str:
    """Render a bounded UTF-8 Markdown workspace brief with three fixed sections."""
    max_bytes = max(0, int(max_bytes))
    if not isinstance(state, dict):
        state = _default_workspace_state()
    checkpoint = state.get("checkpoint")
    if not isinstance(checkpoint, dict):
        checkpoint = {}
    raw_artifacts = state.get("artifacts")
    if not isinstance(raw_artifacts, dict):
        raw_artifacts = {}
    artifacts = _prune_deleted_artifacts(ws_str, raw_artifacts)
    raw_issues = state.get("open_issues")
    if not isinstance(raw_issues, list):
        raw_issues = []

    def _val(key: str, default: str = "none") -> str:
        value = checkpoint.get(key)
        if value is None:
            return default
        text = str(value).strip()
        return text or default

    cp_lines = [
        f"- Status: {_val('status')}",
        f"- Goal: {_val('goal')}",
        f"- Plan file: {_val('plan_file')}",
        f"- Session key: {_val('session_key')}",
        f"- Last verdict: {_val('last_verdict')}",
        f"- Last run id: {_val('last_run_id')}",
    ]

    artifact_lines: list[str] = []
    for rel, meta in sorted(artifacts.items(), key=_artifact_sort_key, reverse=True):
        syms = meta.get("symbols") if isinstance(meta, dict) else None
        sym_list = [str(sym) for sym in syms if isinstance(sym, str)] if isinstance(syms, list) else []
        sym_text = ", ".join(sym_list) if sym_list else "none"
        artifact_lines.append(f"- {rel}: {sym_text}")

    issue_lines = [
        f"- {str(item).strip()}"
        for item in raw_issues
        if isinstance(item, str) and str(item).strip()
    ]
    if not issue_lines:
        issue_lines = ["- none"]

    raw_last_error = state.get("last_error")
    recovery_lines: list[str] = []
    if isinstance(raw_last_error, dict) and raw_last_error:
        touched = raw_last_error.get("run_changed_files")
        if isinstance(touched, list):
            clean_touched = [str(item).strip() for item in touched if str(item).strip()]
        else:
            clean_touched = []
        touched_str = ", ".join(clean_touched[:10]) if clean_touched else "none"
        if len(clean_touched) > 10:
            touched_str += f" (+{len(clean_touched) - 10} more)"
        recovery_lines = [
            f"- Executor: {str(raw_last_error.get('executor') or 'unknown').strip()}",
            f"- Goal: {str(raw_last_error.get('goal') or 'none').strip()}",
            f"- Touched files: {touched_str}",
            f"- Error: {str(raw_last_error.get('error') or 'unknown').strip()}",
            f"- Pre run tree: {str(raw_last_error.get('pre_run_tree') or 'none').strip()}",
        ]

    def _render(art_lines: list[str], iss_lines: list[str], rec_lines: list[str]) -> str:
        sections = [
            "# Workspace Brief",
            "## Current Checkpoint\n" + "\n".join(cp_lines),
            "## Active Artifact & Interface Map\n"
            + ("\n".join(art_lines) if art_lines else "- none"),
            "## Open Verification Issues\n"
            + ("\n".join(iss_lines) if iss_lines else "- none"),
        ]
        if rec_lines:
            sections.append("## Interrupted Run Recovery\n" + "\n".join(rec_lines))
        return _ascii_safe("\n\n".join(sections).rstrip()) + "\n"

    arts = list(artifact_lines)
    issues = list(issue_lines)
    recs = list(recovery_lines)
    text = _render(arts, issues, recs)
    while arts and len(text.encode("utf-8")) > max_bytes:
        arts.pop()
        text = _render(arts, issues, recs)
    while len(issues) > 1 and len(text.encode("utf-8")) > max_bytes:
        issues.pop()
        text = _render(arts, issues, recs)
    if len(text.encode("utf-8")) > max_bytes:
        text = _truncate_utf8(text, max_bytes)
    return text


def write_workspace_brief(ws_str: str, state: dict[str, Any]) -> str:
    """Render and atomically write .agents/state/workspace-brief.md, pruning deleted artifacts."""
    raw_artifacts = state.get("artifacts") if isinstance(state, dict) else None
    if not isinstance(raw_artifacts, dict):
        raw_artifacts = {}
    pruned_state = dict(state) if isinstance(state, dict) else _default_workspace_state()
    pruned_state["artifacts"] = _prune_deleted_artifacts(ws_str, raw_artifacts)
    text = render_workspace_brief(ws_str, pruned_state)
    with _state_lock:
        state_dir = _ensure_state_dir(ws_str)
        _atomic_write_text(state_dir / "workspace-brief.md", text)
    return text


def archive_run_record(ws_str: str, run_id: str, content: str) -> str:
    """Write a bounded L3 run archive under .agents/state/runs/ and prune the oldest files."""
    safe_id = re.sub(r"[^A-Za-z0-9._-]", "_", str(run_id or "")).strip("._-") or "run"
    rel_path = f"{STATE_REL_DIR}/runs/{safe_id}.md"
    with _state_lock:
        state_dir = _ensure_state_dir(ws_str)
        runs_dir = state_dir / "runs"
        runs_dir.mkdir(parents=True, exist_ok=True)
        target = runs_dir / f"{safe_id}.md"
        _atomic_write_text(target, content)
        try:
            entries = [p for p in runs_dir.glob("*.md") if p.is_file()]
            entries.sort(key=lambda p: (p.stat().st_mtime_ns, p.name))
        except OSError:
            entries = []
        excess = len(entries) - MAX_RUN_ARCHIVE_FILES
        for path in entries:
            if excess <= 0:
                break
            if path.name == target.name:
                continue
            try:
                path.unlink()
                excess -= 1
            except OSError:
                continue
    return rel_path


def build_continuity_injection(
    ws_str: str,
    max_bytes: int = MAX_CONTINUITY_INJECT_BYTES,
    max_recent_entries: int = 2,
) -> str:
    """Strictly read-only continuity text: workspace brief plus newest history entries."""
    max_bytes = max(0, int(max_bytes))
    with _state_lock:
        state_dir = _state_dir_path(ws_str)

        brief_text = ""
        brief_path = state_dir / "workspace-brief.md"
        try:
            if brief_path.is_file():
                brief_text = brief_path.read_text(
                    encoding="utf-8", errors="replace"
                ).strip()
        except OSError:
            brief_text = ""

        if not brief_text:
            return read_plan_history(ws_str, max_bytes=max_bytes)

        if len(brief_text.encode("utf-8")) > MAX_WORKSPACE_BRIEF_BYTES:
            brief_text = _truncate_utf8(brief_text, MAX_WORKSPACE_BRIEF_BYTES)

        recent: list[str] = []
        hist_path = state_dir / "plan-history.md"
        try:
            if hist_path.is_file():
                raw = hist_path.read_text(encoding="utf-8", errors="replace")
                blocks = [
                    block.strip()
                    for block in re.findall(
                        r"<!-- ENTRY:START -->\s*(.*?)\s*<!-- ENTRY:END -->",
                        raw,
                        re.DOTALL,
                    )
                    if block.strip()
                ]
                if max_recent_entries > 0:
                    recent = blocks[-max_recent_entries:]
        except OSError:
            recent = []

        text = "\n\n".join([brief_text, *recent])
        while recent and len(text.encode("utf-8")) > max_bytes:
            recent = recent[1:]
            text = "\n\n".join([brief_text, *recent])
        if len(text.encode("utf-8")) > max_bytes:
            text = _truncate_utf8(text, max_bytes)
        return text


def _extract_open_issues(
    result_text: str, verdict: Optional[str], max_items: int = 10
) -> list[str]:
    """Parse itemized verifier issues from Critical/Important/Blockers sections."""
    if verdict == "PASS":
        return []

    lines = (result_text or "").splitlines()

    def _heading_token(line: str) -> Optional[str]:
        stripped = line.strip()
        if not stripped:
            return None
        if not stripped.startswith("#") and not re.fullmatch(
            r"\*{0,2}[A-Za-z][A-Za-z /&-]{0,40}\*{0,2}:?", stripped
        ):
            return None
        token = stripped.lstrip("#").strip()
        token = token.strip("*").strip()
        token = token.rstrip(":").strip()
        token = re.sub(r"\s+", " ", token).strip(" *_`>-")
        return token.lower() or None

    def _clean_item(text: str) -> str:
        cleaned = re.sub(r"[`*_]", "", text)
        cleaned = re.sub(r"\s+", " ", cleaned).strip()
        return _ascii_safe(cleaned)[:200]

    start_tokens = ("critical", "important", "blockers")
    bullet_re = re.compile(r"^\s*(?:[-+*]|\d+[.)])\s+(.*)$")
    inline_re = re.compile(
        r"^\s*(?:(?:[-+*]|\d+[.)])\s+)?(Critical|Important|Blockers?)\s*:\s*(\S.*)$",
        re.IGNORECASE,
    )

    issues: list[str] = []
    in_section = False
    for raw_line in lines:
        line = raw_line.strip()
        if not line:
            continue
        inline = inline_re.match(re.sub(r"[`*_]", "", line))
        if inline:
            inline_text = _clean_item(inline.group(2))
            if inline_text and inline_text.lower().strip(" .:*") != "none":
                issues.append(f"{inline.group(1).capitalize()}: {inline_text}"[:200])
                if len(issues) >= max_items:
                    break
            continue
        token = _heading_token(line)
        if token is not None:
            if any(marker in token for marker in start_tokens):
                in_section = True
                continue
            if in_section:
                break
            continue
        if not in_section:
            continue
        match = bullet_re.match(line)
        if not match:
            continue
        item = _clean_item(match.group(1))
        if not item or item.lower().strip(" .:*") == "none":
            continue
        issues.append(item)
        if len(issues) >= max_items:
            break

    if not issues and verdict in ("FAIL", "BLOCKED"):
        fallback = ""
        for raw_line in lines:
            candidate = raw_line.strip()
            if not candidate:
                continue
            if re.match(r"(?i)^VERDICT\s*:", candidate):
                continue
            fallback = _ascii_safe(_compact_snippet(candidate, 200))
            break
        issues = [fallback or f"Verifier reported {verdict} without itemized issues"]
    return issues


def _update_state_after_execute(
    ws_str: str,
    *,
    status: str,
    plan_text: str,
    plan_file: Optional[str],
    session_key: str,
    session_id: Optional[str],
    session_action: str,
    run_changed_files: list[str],
    result_text: str,
    num_turns: Optional[int],
    pre_run_tree: Optional[str],
    post_run_tree: Optional[str],
    run_id_prefix: str = "exec",
) -> dict[str, str]:
    """Archive an L3 run record and update L1/L2 workspace state plus compact history."""
    now_utc = datetime.now(timezone.utc)
    ts = now_utc.strftime("%Y%m%dT%H%M%SZ")
    iso = now_utc.isoformat()
    clean_prefix = re.sub(r"[^A-Za-z0-9._-]", "-", str(run_id_prefix or "exec")).strip("-") or "exec"
    run_id = f"{clean_prefix}-{ts}-{uuid.uuid4().hex[:6]}"

    plan_excerpt = (plan_text or "").strip()[:4000]
    result_excerpt = (result_text or "").strip()[:8000]
    files_text = "\n".join(f"- {path}" for path in run_changed_files) or "- none"
    turns_str = str(num_turns) if num_turns is not None else "unknown"
    record = (
        f"# Run Record {run_id}\n\n"
        f"- Status: {status}\n"
        f"- Session key: {session_key}\n"
        f"- Session id: {session_id or 'none'}\n"
        f"- Session action: {session_action}\n"
        f"- Plan file: {plan_file or 'inline'}\n"
        f"- Turns: {turns_str}\n"
        f"- Pre run tree: {pre_run_tree or 'none'}\n"
        f"- Post run tree: {post_run_tree or 'none'}\n"
        f"- Updated at: {iso}\n\n"
        f"## Changed Files\n\n{files_text}\n\n"
        f"## Plan (truncated)\n\n{plan_excerpt}\n\n"
        f"## Result (truncated)\n\n{result_excerpt}\n"
    )
    archive_rel_path = archive_run_record(ws_str, run_id, record)
    symbols_by_file = _extract_file_symbols(ws_str, run_changed_files)

    with _state_lock:
        state = load_workspace_state(ws_str)
        checkpoint = state.get("checkpoint")
        merged_checkpoint = dict(checkpoint) if isinstance(checkpoint, dict) else {}
        merged_checkpoint.update(
            {
                "goal": _compact_snippet(plan_text, 160),
                "status": "done" if status == "DONE" else "blocked",
                "plan_file": plan_file,
                "session_key": session_key,
                "session_id": session_id,
                "last_run_id": run_id,
                "last_run_status": status,
                "pre_run_tree": pre_run_tree,
                "post_run_tree": post_run_tree,
                "updated_at": iso,
            }
        )

        artifacts = state.get("artifacts")
        new_artifacts = dict(artifacts) if isinstance(artifacts, dict) else {}
        for rel, syms in symbols_by_file.items():
            new_artifacts[rel] = {
                "symbols": list(syms),
                "updated_at": iso,
                "run_id": run_id,
            }
        for rel in run_changed_files:
            if not isinstance(rel, str) or rel in new_artifacts:
                continue
            try:
                exists = (Path(ws_str) / rel).is_file()
            except OSError:
                exists = False
            if exists:
                new_artifacts[rel] = {
                    "symbols": [],
                    "updated_at": iso,
                    "run_id": run_id,
                }
        new_artifacts = _prune_deleted_artifacts(ws_str, new_artifacts)
        if len(new_artifacts) > 60:
            ordered = sorted(
                new_artifacts.items(), key=_artifact_sort_key, reverse=True
            )
            new_artifacts = dict(ordered[:60])

        if not isinstance(state.get("open_issues"), list):
            state["open_issues"] = []
        if status == "DONE":
            state["last_error"] = None
        state["version"] = 1
        state["checkpoint"] = merged_checkpoint
        state["artifacts"] = new_artifacts
        save_workspace_state(ws_str, state)
        write_workspace_brief(ws_str, state)

    flattened_symbols: list[str] = []
    for syms in symbols_by_file.values():
        flattened_symbols.extend(syms)
    append_plan_history(
        ws_str,
        status=status,
        plan_text=plan_text,
        plan_file=plan_file,
        session_key=session_key,
        session_id=session_id,
        session_action=session_action,
        changed_files=run_changed_files,
        result_text=result_text,
        num_turns=num_turns,
        run_id=run_id,
        symbols=flattened_symbols,
        archive_rel_path=archive_rel_path,
    )
    return {"run_id": run_id, "archive_path": archive_rel_path}


def _record_failed_execute_state(
    ws_str: str,
    *,
    executor: str,
    plan_text: str,
    plan_file: Optional[str],
    run_changed_files: list[str],
    error_msg: Optional[str],
    pre_run_tree: Optional[str],
) -> None:
    """Persist partial interrupted-run metadata without overwriting the last good checkpoint."""
    iso = datetime.now(timezone.utc).isoformat()
    clean_files = [
        _ascii_safe(str(p).strip())[:300]
        for p in (run_changed_files or [])[:40]
        if str(p).strip()
    ]
    entry = {
        "executor": _ascii_safe(str(executor or "unknown").strip()) or "unknown",
        "goal": _compact_snippet(plan_text, 160),
        "plan_file": plan_file,
        "run_changed_files": clean_files,
        "error": _compact_snippet(error_msg or "execution failed", 300),
        "pre_run_tree": pre_run_tree,
        "updated_at": iso,
    }
    with _state_lock:
        state = load_workspace_state(ws_str)
        state["version"] = 1
        state["last_error"] = entry
        save_workspace_state(ws_str, state)
        write_workspace_brief(ws_str, state)


def _record_verify_outcome(
    ws_str: str,
    *,
    status: str,
    result_text: str,
    plan_file: Optional[str],
    resolved_diff_scope: str,
    source: str = "claude",
) -> Optional[str]:
    """Archive the verifier report and update verdict/open-issue state per verifier source."""
    clean_source = re.sub(r"[^A-Za-z0-9._-]", "_", str(source or "claude")).strip("._-") or "claude"
    now_utc = datetime.now(timezone.utc)
    ts = now_utc.strftime("%Y%m%dT%H%M%SZ")
    iso = now_utc.isoformat()
    prefix = "verify" if clean_source == "claude" else f"verify-{clean_source}"
    run_id = f"{prefix}-{ts}-{uuid.uuid4().hex[:6]}"

    report_excerpt = (result_text or "").strip()[:8000]
    record = (
        f"# Verify Record {run_id}\n\n"
        f"- Source: {clean_source}\n"
        f"- Verdict: {status}\n"
        f"- Diff scope: {resolved_diff_scope}\n"
        f"- Plan file: {plan_file or 'inline'}\n"
        f"- Verified at: {iso}\n\n"
        f"## Verifier Report (truncated)\n\n{report_excerpt}\n"
    )
    archive_run_record(ws_str, run_id, record)

    with _state_lock:
        state = load_workspace_state(ws_str)
        checkpoint = state.get("checkpoint")
        merged_checkpoint = dict(checkpoint) if isinstance(checkpoint, dict) else {}
        verdicts = merged_checkpoint.get("verdicts")
        merged_verdicts = dict(verdicts) if isinstance(verdicts, dict) else {}
        merged_verdicts[clean_source] = status
        merged_checkpoint["verdicts"] = merged_verdicts
        merged_checkpoint["last_verdict"] = status
        merged_checkpoint["last_verified_at"] = iso
        merged_checkpoint["last_verify_run_id"] = run_id
        merged_checkpoint["last_verify_source"] = clean_source

        by_source = dict(state.get("open_issues_by_source") or {})
        legacy_issues = (
            state.get("open_issues") if isinstance(state.get("open_issues"), list) else []
        )
        if not by_source and legacy_issues and clean_source != "claude":
            by_source["claude"] = list(legacy_issues)

        if status == "PASS":
            by_source[clean_source] = []
        elif status in ("FAIL", "BLOCKED"):
            by_source[clean_source] = _extract_open_issues(result_text, status)

        active_sources = [k for k, v in by_source.items() if isinstance(v, list) and v]
        flat_issues: list[str] = []
        seen_issues: set[str] = set()
        prefix_source = len(active_sources) > 1
        for src_name in sorted(active_sources):
            for item in by_source[src_name]:
                label = f"[{src_name}] {item}" if prefix_source else item
                if label not in seen_issues:
                    seen_issues.add(label)
                    flat_issues.append(label)

        state["open_issues_by_source"] = by_source
        state["open_issues"] = flat_issues

        has_fail = any(merged_verdicts.get(src) == "FAIL" for src in active_sources)
        has_blocked = any(merged_verdicts.get(src) == "BLOCKED" for src in active_sources)
        if status == "PASS" and not flat_issues:
            merged_checkpoint["status"] = "done"
        elif has_fail or status == "FAIL":
            merged_checkpoint["status"] = "in-review"
        elif has_blocked or status == "BLOCKED":
            merged_checkpoint["status"] = "blocked"
        elif flat_issues:
            merged_checkpoint["status"] = "in-review"
        else:
            merged_checkpoint["status"] = "done"

        if not isinstance(state.get("artifacts"), dict):
            state["artifacts"] = {}
        state["version"] = 1
        state["checkpoint"] = merged_checkpoint
        save_workspace_state(ws_str, state)
        write_workspace_brief(ws_str, state)
    return run_id


def _handoff_search_matches(ws_str: str, query: str, limit: int = 20) -> list[dict[str, Any]]:
    """Case-insensitive substring search across cached state files, newest runs first."""
    state_dir = _state_dir_path(ws_str)
    sources: list[tuple[str, Path]] = [
        (f"{STATE_REL_DIR}/workspace-brief.md", state_dir / "workspace-brief.md"),
        (f"{STATE_REL_DIR}/plan-history.md", state_dir / "plan-history.md"),
    ]
    runs_dir = state_dir / "runs"
    run_files: list[Path] = []
    try:
        if runs_dir.is_dir():
            run_files = [p for p in runs_dir.glob("*.md") if p.is_file()]
            run_files.sort(key=lambda p: p.stat().st_mtime_ns, reverse=True)
    except OSError:
        run_files = []
    for path in run_files:
        sources.append((f"{STATE_REL_DIR}/runs/{path.name}", path))

    needle = query.lower()
    matches: list[dict[str, Any]] = []
    for source, path in sources:
        if len(matches) >= limit:
            break
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for line_no, line in enumerate(text.splitlines(), 1):
            if needle not in line.lower():
                continue
            matches.append(
                {
                    "source": source,
                    "line": line_no,
                    "snippet": _ascii_safe(line.strip()[:200]),
                }
            )
            if len(matches) >= limit:
                break
    return matches


def _handoff_history_entries(ws_str: str, limit: int = 2) -> list[str]:
    hist_path = _state_dir_path(ws_str) / "plan-history.md"
    try:
        if not hist_path.is_file():
            return []
        raw = hist_path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []
    blocks = [
        block.strip()
        for block in re.findall(
            r"<!-- ENTRY:START -->\s*(.*?)\s*<!-- ENTRY:END -->", raw, re.DOTALL
        )
        if block.strip()
    ]
    if limit <= 0:
        return []
    return blocks[-limit:]


def _handoff_latest_run_files(
    ws_str: str, sessions: dict[str, Any], limit: int = 20
) -> list[str]:
    """Best-effort list of files changed by the most recent archived run."""
    runs_dir = _state_dir_path(ws_str) / "runs"
    run_files: list[Path] = []
    try:
        if runs_dir.is_dir():
            run_files = [p for p in runs_dir.glob("*.md") if p.is_file()]
            run_files.sort(key=lambda p: p.stat().st_mtime_ns, reverse=True)
    except OSError:
        run_files = []

    if run_files:
        try:
            text = run_files[0].read_text(encoding="utf-8", errors="replace")
        except OSError:
            text = ""
        collected: list[str] = []
        in_files = False
        for line in text.splitlines():
            stripped = line.strip()
            if stripped.startswith("## "):
                if in_files:
                    break
                in_files = stripped.lower().startswith("## changed files")
                continue
            if in_files and stripped.startswith("- "):
                rel = stripped[2:].strip().strip("`")
                if rel and rel.lower() != "none" and rel not in collected:
                    collected.append(_ascii_safe(rel)[:300])
                if len(collected) >= limit:
                    break
        if collected:
            return collected

    best_files: list[str] = []
    best_ts: Optional[float] = None
    for entry in sessions.values():
        if not isinstance(entry, dict):
            continue
        changed = entry.get("last_changed_files")
        if not isinstance(changed, list):
            continue
        ts = _safe_float(entry.get("updated_at"), 0.0)
        if best_ts is not None and ts <= best_ts:
            continue
        best_ts = ts
        best_files = [
            _ascii_safe(str(path))[:300] for path in changed if str(path).strip()
        ][:limit]
    return best_files


def _truncate_handoff_markdown(text: str, max_bytes: int) -> tuple[str, bool]:
    """Bound handoff Markdown at a line boundary and report whether truncation happened."""
    text = _ascii_safe(text)
    if len(text.encode("utf-8")) <= max_bytes:
        return text, False
    marker = f"\n... [handoff truncated at {max_bytes} bytes]"
    budget = max_bytes - len(marker.encode("utf-8"))
    if budget <= 0:
        return _truncate_utf8(marker.strip(), max(0, max_bytes)), True
    cut_text = _truncate_utf8(text, budget)
    newline_idx = cut_text.rfind("\n")
    if newline_idx > 0:
        cut_text = cut_text[:newline_idx]
    return cut_text.rstrip("\n") + marker, True


def build_handoff_packet(
    workspace_dir: str,
    mode: str = "continue",
    max_bytes: int = DEFAULT_HANDOFF_MAX_BYTES,
    search_query: Optional[str] = None,
) -> dict[str, Any]:
    """Build a zero-LLM, strictly read-only handoff packet for the next agent session."""

    def _err(message: str, ws_val: Any) -> dict[str, Any]:
        return {
            "ok": False,
            "error": message,
            "workspace_dir": ws_val if isinstance(ws_val, str) else "",
            "mode": mode,
            "state_exists": False,
            "max_bytes": (
                max_bytes
                if isinstance(max_bytes, int) and not isinstance(max_bytes, bool)
                else 0
            ),
            "packet_bytes": 0,
            "truncated": False,
            "checkpoint": {},
            "open_issues_count": 0,
            "active_artifacts_count": 0,
            "active_session_keys": [],
            "search_query": (
                search_query.strip()
                if isinstance(search_query, str) and search_query.strip()
                else None
            ),
            "search_matches": [],
            "handoff_markdown": "",
        }

    if not isinstance(workspace_dir, str) or not workspace_dir.strip():
        return _err("workspace_dir is required and must be a non-empty path.", "")
    try:
        ws_path = Path(workspace_dir).expanduser().resolve()
    except OSError as exc:
        return _err(f"Invalid workspace_dir '{workspace_dir}': {exc}", workspace_dir)
    if not ws_path.is_dir():
        return _err(
            f"workspace_dir does not exist or is not a directory: {ws_path}",
            str(ws_path),
        )
    ws_str = str(ws_path)

    if not isinstance(mode, str) or mode not in VALID_HANDOFF_MODES:
        return _err(
            f"mode must be one of {sorted(VALID_HANDOFF_MODES)}, got: {mode!r}", ws_str
        )
    if (
        isinstance(max_bytes, bool)
        or not isinstance(max_bytes, int)
        or not (MIN_HANDOFF_MAX_BYTES <= max_bytes <= MAX_HANDOFF_MAX_BYTES)
    ):
        return _err(
            f"max_bytes must be an integer between {MIN_HANDOFF_MAX_BYTES} and "
            f"{MAX_HANDOFF_MAX_BYTES}, got: {max_bytes!r}",
            ws_str,
        )
    if search_query is not None and not isinstance(search_query, str):
        return _err("search_query must be a string when provided.", ws_str)

    state_dir = _state_dir_path(ws_str)
    state_exists = state_dir.is_dir()
    state = load_workspace_state(ws_str)
    checkpoint = state.get("checkpoint")
    if not isinstance(checkpoint, dict):
        checkpoint = {}
    artifacts = _prune_deleted_artifacts(ws_str, state.get("artifacts") or {})
    raw_issues = state.get("open_issues")
    open_issues = [
        _ascii_safe(str(item).strip())[:200]
        for item in (raw_issues if isinstance(raw_issues, list) else [])
        if isinstance(item, str) and str(item).strip()
    ]
    raw_last_error = state.get("last_error")
    last_error = dict(raw_last_error) if isinstance(raw_last_error, dict) and raw_last_error else None
    sessions = load_session_index(ws_str).get("sessions")
    if not isinstance(sessions, dict):
        sessions = {}
    session_keys = sorted(str(key) for key in sessions.keys())

    clean_query = search_query.strip() if isinstance(search_query, str) else ""
    search_matches = (
        _handoff_search_matches(ws_str, clean_query) if clean_query else []
    )
    git_ev = collect_git_evidence(ws_str)

    def _checkpoint_lines() -> list[str]:
        lines: list[str] = ["## Current Checkpoint"]
        defaults = [
            ("Status", "status"),
            ("Goal", "goal"),
            ("Plan file", "plan_file"),
            ("Session key", "session_key"),
            ("Last verdict", "last_verdict"),
            ("Last run id", "last_run_id"),
            ("Updated at", "updated_at"),
        ]
        for label, key in defaults:
            value = checkpoint.get(key)
            text = _ascii_safe(str(value).strip()) if value is not None else "none"
            lines.append(f"- {label}: {text or 'none'}")
        return lines

    def _artifact_lines() -> list[str]:
        lines: list[str] = ["## Active Artifact & Interface Map"]
        ordered = sorted(artifacts.items(), key=_artifact_sort_key, reverse=True)
        rendered = 0
        for rel, meta in ordered:
            syms = meta.get("symbols") if isinstance(meta, dict) else None
            sym_list = (
                [_ascii_safe(str(sym)) for sym in syms if isinstance(sym, str)]
                if isinstance(syms, list)
                else []
            )
            sym_text = ", ".join(sym_list) if sym_list else "none"
            lines.append(f"- {_ascii_safe(str(rel))}: {sym_text}")
            rendered += 1
            if rendered >= 40:
                break
        if rendered == 0:
            lines.append("- none")
        return lines

    def _issue_lines() -> list[str]:
        lines: list[str] = ["## Open Verification Issues"]
        if open_issues:
            lines.extend(f"- {item}" for item in open_issues[:20])
        else:
            lines.append("- none")
        return lines

    def _recent_lines() -> list[str]:
        lines: list[str] = ["## Recent Runs"]
        entries = _handoff_history_entries(ws_str, 2)
        if entries:
            lines.extend(_ascii_safe(entry) for entry in entries)
        else:
            lines.append("- none")
        return lines

    def _git_lines() -> list[str]:
        lines: list[str] = ["## Git Status"]
        if not git_ev.get("is_git_repo"):
            lines.append("- Not a git repository.")
            return lines
        changed = git_ev.get("changed_files") or []
        if changed:
            lines.append("Changed files (`git status --short`):")
            lines.extend(f"- `{_ascii_safe(str(line))}`" for line in changed[:20])
            if len(changed) > 20:
                lines.append(f"- ... (+{len(changed) - 20} more)")
        else:
            lines.append("Changed files (`git status --short`): none")
        return lines

    def _recovery_lines() -> list[str]:
        if not last_error:
            return []
        touched = last_error.get("run_changed_files")
        clean_touched = (
            [str(item).strip() for item in touched if str(item).strip()]
            if isinstance(touched, list)
            else []
        )
        touched_str = (
            ", ".join(f"`{_ascii_safe(item)}`" for item in clean_touched[:15])
            if clean_touched
            else "none"
        )
        if len(clean_touched) > 15:
            touched_str += f" (+{len(clean_touched) - 15} more)"
        return [
            "## Interrupted Run Recovery",
            f"- Executor: {_ascii_safe(str(last_error.get('executor') or 'unknown'))}",
            f"- Goal: {_ascii_safe(str(last_error.get('goal') or 'none'))}",
            f"- Plan file: {_ascii_safe(str(last_error.get('plan_file') or 'inline'))}",
            f"- Touched files: {touched_str}",
            f"- Error: {_ascii_safe(str(last_error.get('error') or 'unknown'))}",
            f"- Pre run tree: {_ascii_safe(str(last_error.get('pre_run_tree') or 'none'))}",
        ]

    def _session_lines(hint: str) -> list[str]:
        lines: list[str] = ["## Session Continuity"]
        if session_keys:
            lines.append("Active session keys: " + ", ".join(f"`{key}`" for key in session_keys))
        else:
            lines.append("Active session keys: none")
        lines.append(f"Next: {hint}")
        return lines

    def _search_lines() -> list[str]:
        lines: list[str] = ["## Search Matches (query: `" + _ascii_safe(clean_query) + "`)"]
        if search_matches:
            for match in search_matches:
                lines.append(
                    f"- `{match['source']}:{match['line']}`: {match['snippet']}"
                )
        else:
            lines.append("- none")
        return lines

    if not state_exists:
        sections: list[str] = [
            f"# Handoff Packet ({mode})",
            "No `.agents/state/` cache yet for this workspace. Start a fresh executor run; "
            "continuity state is created after the first run.",
        ]
        sections.append("\n".join(_git_lines()))
        if search_matches:
            sections.append("\n".join(_search_lines()))
        markdown = "\n\n".join(section for section in sections if section.strip()) + "\n"
    elif mode == "fix_review":
        sections = [f"# Handoff Packet ({mode})"]
        sections.append("\n".join(_issue_lines()))
        sections.append("\n".join(_checkpoint_lines()))
        files = _handoff_latest_run_files(ws_str, sessions)
        file_lines = ["## Files Changed in the Last Run"]
        if files:
            file_lines.extend(f"- `{path}`" for path in files)
        else:
            file_lines.append("- none recorded")
        sections.append("\n".join(file_lines))
        sections.append(
            "\n".join(
                _session_lines(
                    'resume the existing workspace session with session_mode="resume" '
                    "and fix the open verification issues above."
                )
            )
        )
        if search_matches:
            sections.append("\n".join(_search_lines()))
        markdown = "\n\n".join(sections) + "\n"
    elif mode == "new_plan":
        sections = [f"# Handoff Packet ({mode})"]
        sections.append("\n".join(_artifact_lines()))
        sections.append("\n".join(_checkpoint_lines()))
        sections.append("\n".join(_recent_lines()))
        sections.append(
            "\n".join(
                _session_lines(
                    "reuse the existing modules, types, and interfaces mapped above; "
                    "do not duplicate helpers that already exist."
                )
            )
        )
        if search_matches:
            sections.append("\n".join(_search_lines()))
        markdown = "\n\n".join(sections) + "\n"
    else:
        sections = [f"# Handoff Packet ({mode})"]
        sections.append("\n".join(_checkpoint_lines()))
        if last_error:
            sections.append("\n".join(_recovery_lines()))
        sections.append("\n".join(_artifact_lines()))
        sections.append("\n".join(_issue_lines()))
        sections.append("\n".join(_recent_lines()))
        sections.append("\n".join(_git_lines()))
        next_hint = (
            "continue incrementally from the interrupted run files above without discarding valid "
            "partial changes; verify completed + resumed edits together with diff_scope='workspace'."
            if last_error
            else 'continue on the same workspace session; pass session_key="workspace" session_mode="auto"'
        )
        sections.append("\n".join(_session_lines(next_hint)))
        if search_matches:
            sections.append("\n".join(_search_lines()))
        markdown = "\n\n".join(sections) + "\n"

    markdown, truncated = _truncate_handoff_markdown(markdown, max_bytes)
    return {
        "ok": True,
        "workspace_dir": ws_str,
        "mode": mode,
        "state_exists": state_exists,
        "max_bytes": max_bytes,
        "packet_bytes": len(markdown.encode("utf-8")),
        "truncated": truncated,
        "checkpoint": checkpoint,
        "last_error": last_error,
        "open_issues_count": len(open_issues),
        "active_artifacts_count": len(artifacts),
        "active_session_keys": session_keys,
        "search_query": clean_query or None,
        "search_matches": search_matches,
        "handoff_markdown": markdown,
        "error": None,
    }


def _snapshot_workspace(ws_str: str, max_files: int = 50000) -> dict[str, tuple[int, int]]:
    """Capture a lightweight (mtime_ns, size) file map excluding build/cache/state dirs."""
    snapshot: dict[str, tuple[int, int]] = {}
    root = Path(ws_str)
    if not root.is_dir():
        return snapshot

    stack: list[tuple[Path, str]] = [(root, "")]
    while stack and len(snapshot) < max_files:
        cur_dir, rel_dir = stack.pop()
        try:
            with os.scandir(cur_dir) as it:
                entries = list(it)
        except OSError:
            continue

        for entry in entries:
            name = entry.name
            rel = f"{rel_dir}/{name}" if rel_dir else name
            if rel == STATE_REL_DIR or rel.startswith(STATE_REL_DIR + "/"):
                continue
            try:
                if entry.is_dir(follow_symlinks=False):
                    if name in SNAPSHOT_SKIP_DIRS:
                        continue
                    stack.append((Path(entry.path), rel))
                elif entry.is_file(follow_symlinks=False):
                    st = entry.stat(follow_symlinks=False)
                    snapshot[rel] = (st.st_mtime_ns, st.st_size)
                    if len(snapshot) >= max_files:
                        break
            except OSError:
                continue
    return snapshot


def _diff_snapshots(
    before: dict[str, tuple[int, int]],
    after: dict[str, tuple[int, int]],
) -> list[str]:
    """Return sorted relative file paths created, modified, or deleted during a single run."""
    all_paths = set(before.keys()) | set(after.keys())
    return sorted(rel for rel in all_paths if before.get(rel) != after.get(rel))


def _append_scope_and_commands(
    sections: list[str],
    allowed_files: Optional[list[str]],
    verification_commands: Optional[list[str]],
    *,
    verify_mode: bool = False,
) -> None:
    cleaned_files = [str(f).strip() for f in (allowed_files or []) if str(f).strip()]
    if cleaned_files:
        file_lines = "\n".join(f"- `{item}`" for item in cleaned_files)
        heading = (
            "## Authorized File Scope (Verify No Unapproved Edits Outside This List)"
            if verify_mode
            else "## Authorized File Scope (Do Not Modify Files Outside This List)"
        )
        sections.append(f"{heading}\n\n{file_lines}\n")

    cleaned_cmds = [str(c).strip() for c in (verification_commands or []) if str(c).strip()]
    if cleaned_cmds:
        cmd_lines = "\n".join(f"- `{item}`" for item in cleaned_cmds)
        heading = (
            "## Required Verification Commands (Run Read-Only & Verify Real Outputs)"
            if verify_mode
            else "## Required Verification Commands (Report Real Exit Codes and Output Summaries)"
        )
        sections.append(f"{heading}\n\n{cmd_lines}\n")


def build_plan_stdin(
    plan: str,
    allowed_files: Optional[list[str]] = None,
    verification_commands: Optional[list[str]] = None,
    extra_context: Optional[str] = None,
    prior_history: Optional[str] = None,
    external_drift: Optional[str] = None,
) -> str:
    """Format approved plan, prior history, and constraints into Markdown fed to claude -p via stdin."""
    sections = [
        f"## Approved Implementation Plan (Antigravity Neon Planner)\n\n{plan.strip()}\n"
    ]

    if prior_history and str(prior_history).strip():
        sections.append(
            "## Prior Completed Plans & Existing Artifacts (Reuse Existing Code, Avoid Duplication)\n\n"
            f"{str(prior_history).strip()}\n"
        )

    if external_drift and str(external_drift).strip():
        sections.append(
            "## External Workspace Changes Since Your Last Turn (Made Outside Your Session; Treat As Authoritative)\n\n"
            f"{str(external_drift).strip()}\n"
        )

    _append_scope_and_commands(sections, allowed_files, verification_commands, verify_mode=False)

    if extra_context and str(extra_context).strip():
        sections.append(f"## Additional Context\n\n{str(extra_context).strip()}\n")

    return "\n".join(sections)


def build_verify_stdin(
    plan: str,
    *,
    allowed_files: Optional[list[str]] = None,
    verification_commands: Optional[list[str]] = None,
    prior_history: Optional[str] = None,
    diff_evidence: Optional[dict[str, Any]] = None,
    extra_context: Optional[str] = None,
) -> str:
    """Format approved plan, prior plan history, workspace diff, and audit scope into Markdown."""
    sections = [
        f"## Approved Implementation Plan to Audit\n\n{plan.strip()}\n"
    ]

    _append_scope_and_commands(sections, allowed_files, verification_commands, verify_mode=True)

    if prior_history and str(prior_history).strip():
        sections.append(
            "## Prior Completed Plans & Existing Artifacts (Check Cross-Plan Compatibility & Anti-Duplication)\n\n"
            f"{str(prior_history).strip()}\n"
        )

    if diff_evidence and diff_evidence.get("is_git_repo"):
        changed = diff_evidence.get("changed_files") or []
        diff_stat = (diff_evidence.get("git_diff_stat") or "").strip()
        git_diff = (diff_evidence.get("git_diff") or "").rstrip()
        resolved_scope = diff_evidence.get("resolved_diff_scope") or "workspace"
        last_run_files = diff_evidence.get("last_run_changed_files") or []
        diff_lines = ["## Current Workspace Diff & Status"]
        scope_line = f"Diff scope: {resolved_scope}"
        if resolved_scope == "last_run":
            base_tree = str(diff_evidence.get("pre_run_tree") or "")
            scope_line += f" (turn-scoped: changes since pre_run_tree {base_tree[:12]})"
        diff_lines.append(scope_line)
        if resolved_scope == "last_run" and last_run_files:
            diff_lines.append("Changes since last run checkpoint:")
            diff_lines.extend(f"- `{line}`" for line in last_run_files[:100])
        if changed:
            diff_lines.append("Changed files (`git status --short`):")
            diff_lines.extend(f"- `{line}`" for line in changed[:60])
            if len(changed) > 60:
                diff_lines.append(f"- ... (+{len(changed) - 60} more)")
        else:
            diff_lines.append("Changed files (`git status --short`): none")
        if diff_stat:
            diff_lines.append(f"\nDiff stat:\n```text\n{diff_stat}\n```")
        if git_diff:
            diff_lines.append(f"\nPatch (`git diff`):\n```diff\n{git_diff}\n```")
        elif resolved_scope == "last_run":
            diff_lines.append("No file changes since the last executor run checkpoint.")
        sections.append("\n".join(diff_lines) + "\n")

    if extra_context and str(extra_context).strip():
        sections.append(f"## Additional Audit Focus / Context\n\n{str(extra_context).strip()}\n")

    return "\n".join(sections)


def parse_claude_output(stdout: str) -> dict[str, Any]:
    """Parse JSON result from `claude -p --output-format json`, with line-scan fallback."""
    stripped = (stdout or "").strip()
    empty_res: dict[str, Any] = {
        "parsed_json": False,
        "result": stripped,
        "is_error": False,
        "num_turns": None,
        "total_cost_usd": None,
        "subtype": None,
        "session_id": None,
    }
    if not stripped:
        return empty_res

    obj: Optional[dict[str, Any]] = None
    try:
        loaded = json.loads(stripped)
        if isinstance(loaded, dict):
            obj = loaded
    except json.JSONDecodeError:
        for line in reversed(stripped.splitlines()):
            candidate = line.strip()
            if not candidate.startswith("{"):
                continue
            try:
                loaded = json.loads(candidate)
                if isinstance(loaded, dict):
                    obj = loaded
                    break
            except json.JSONDecodeError:
                continue

    if obj is None:
        return empty_res

    raw_result = obj.get("result")
    result_text = raw_result if isinstance(raw_result, str) else (
        "" if raw_result is None else json.dumps(raw_result, ensure_ascii=False)
    )
    return {
        "parsed_json": True,
        "result": result_text,
        "is_error": bool(obj.get("is_error", False)),
        "num_turns": obj.get("num_turns"),
        "total_cost_usd": obj.get("total_cost_usd"),
        "subtype": obj.get("subtype"),
        "session_id": obj.get("session_id"),
    }


def parse_verdict(result_text: str) -> Optional[str]:
    """Extract VERDICT: PASS|FAIL|BLOCKED from the first non-empty line; fail closed if missing."""
    for line in (result_text or "").splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        match = re.match(
            r"^\s*(?:\*\*)?VERDICT:\s*(PASS|FAIL|BLOCKED)(?:\*\*)?\b",
            stripped,
        )
        return match.group(1) if match else None
    return None


def _format_claude_cli_error(
    label: str,
    *,
    rc: Optional[int],
    subtype: Optional[str],
    is_error_subtype: bool,
    num_turns: Optional[int],
    resolved_max_turns: int,
    result_text: str,
    stderr_text: str,
) -> str:
    if is_error_subtype:
        turns_info = (
            f" (num_turns={num_turns}/{resolved_max_turns})"
            if subtype == "error_max_turns" and num_turns is not None
            else ""
        )
        base = f"{label} finished with error subtype '{subtype}'{turns_info}"
        if result_text:
            return f"{base}: {result_text}"
        if stderr_text:
            return f"{base} (stderr: {stderr_text[:300]})"
        return base
    return result_text or stderr_text or f"{label} exited with code {rc}"


def _error_response(
    status: str,
    error: str,
    *,
    model: Optional[str] = None,
    effort: Optional[str] = None,
    permission_mode: Optional[str] = None,
    claude_bin: Optional[str] = None,
    workspace_dir: str = "",
    exit_code: Optional[int] = None,
    duration_seconds: float = 0.0,
    result: str = "",
    stderr: str = "",
    git_evidence: Optional[dict[str, Any]] = None,
    job_id: Optional[str] = None,
    active_job_id: Optional[str] = None,
    session_key: Optional[str] = None,
    session_mode: Optional[str] = None,
    session_action: Optional[str] = None,
    session_fallback: Optional[bool] = None,
    plan_file: Optional[str] = None,
    run_changed_files: Optional[list[str]] = None,
) -> dict[str, Any]:
    ev = git_evidence if git_evidence is not None else {
        "is_git_repo": False,
        "changed_files": [],
        "git_diff_stat": "",
    }
    payload: dict[str, Any] = {
        "status": status,
        "model": model,
        "effort": effort or None,
        "permission_mode": permission_mode,
        "claude_bin": claude_bin,
        "workspace_dir": workspace_dir,
        "exit_code": exit_code,
        "duration_seconds": round(duration_seconds, 3),
        "num_turns": None,
        "total_cost_usd": None,
        "subtype": None,
        "session_id": None,
        "is_git_repo": ev["is_git_repo"],
        "changed_files": ev["changed_files"],
        "git_diff_stat": ev["git_diff_stat"],
        "run_changed_files": run_changed_files if run_changed_files is not None else [],
        "result": result,
        "stderr": stderr,
        "error": error,
    }
    if job_id is not None:
        payload["job_id"] = job_id
    if active_job_id is not None:
        payload["active_job_id"] = active_job_id
    if session_key is not None:
        payload["session_key"] = session_key
    if session_mode is not None:
        payload["session_mode"] = session_mode
    if session_action is not None:
        payload["session_action"] = session_action
    if session_fallback is not None:
        payload["session_fallback"] = session_fallback
    if plan_file is not None:
        payload["plan_file"] = plan_file
    return payload


def _verify_error_response(
    status: str,
    error: str,
    *,
    verdict: str = "ERROR",
    model: Optional[str] = None,
    effort: Optional[str] = None,
    permission_mode: Optional[str] = "bypassPermissions",
    claude_bin: Optional[str] = None,
    workspace_dir: str = "",
    exit_code: Optional[int] = None,
    duration_seconds: float = 0.0,
    result: str = "",
    stderr: str = "",
    git_evidence: Optional[dict[str, Any]] = None,
    job_id: Optional[str] = None,
    active_job_id: Optional[str] = None,
    plan_file: Optional[str] = None,
    history_injected: bool = False,
    diff_included: bool = False,
    diff_scope: Optional[str] = None,
    resolved_diff_scope: Optional[str] = None,
    allow_bash: bool = True,
    unexpected_mutations: Optional[list[str]] = None,
) -> dict[str, Any]:
    ev = git_evidence if git_evidence is not None else {
        "is_git_repo": False,
        "changed_files": [],
        "git_diff_stat": "",
    }
    mutations = list(unexpected_mutations) if unexpected_mutations else []
    payload: dict[str, Any] = {
        "status": status,
        "verdict": verdict,
        "model": model,
        "effort": effort or None,
        "permission_mode": permission_mode,
        "claude_bin": claude_bin,
        "workspace_dir": workspace_dir,
        "exit_code": exit_code,
        "duration_seconds": round(duration_seconds, 3),
        "num_turns": None,
        "total_cost_usd": None,
        "subtype": None,
        "session_id": None,
        "plan_file": plan_file,
        "history_injected": history_injected,
        "diff_included": diff_included,
        "diff_scope": diff_scope,
        "resolved_diff_scope": resolved_diff_scope,
        "allow_bash": allow_bash,
        "read_only_violation": bool(mutations),
        "unexpected_mutations": mutations,
        "is_git_repo": ev["is_git_repo"],
        "changed_files": ev["changed_files"],
        "git_diff_stat": ev["git_diff_stat"],
        "result": result,
        "stderr": stderr,
        "error": error,
    }
    if job_id is not None:
        payload["job_id"] = job_id
    if active_job_id is not None:
        payload["active_job_id"] = active_job_id
    return payload


@dataclass
class JobRecord:
    job_id: str
    workspace_dir: str
    model: str
    permission_mode: str
    max_turns: int
    timeout_seconds: int
    started_at: float
    is_async: bool
    lock_mode: str = "write"
    effort: Optional[str] = None
    cancel_event: threading.Event = field(default_factory=threading.Event)
    done_event: threading.Event = field(default_factory=threading.Event)
    result: Optional[dict[str, Any]] = None


class JobManager:
    """Tracks active/completed jobs with per-workspace RWLock (write exclusive, read shared)."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._active_writer: dict[str, str] = {}
        self._active_readers: dict[str, set[str]] = {}
        self._jobs: dict[str, JobRecord] = {}

    def active_count(self) -> int:
        with self._lock:
            return len(self._active_writer) + sum(
                len(readers) for readers in self._active_readers.values()
            )

    def register_job(
        self,
        workspace_dir: str,
        model: str,
        permission_mode: str,
        max_turns: int,
        timeout_seconds: int,
        is_async: bool,
        cancel_event: Optional[threading.Event] = None,
        job_prefix: Optional[str] = None,
        lock_mode: str = "write",
        effort: Optional[str] = None,
    ) -> tuple[Optional[JobRecord], Optional[str]]:
        if lock_mode not in ("write", "read"):
            raise ValueError(f"Invalid lock_mode: {lock_mode!r}")
        with self._lock:
            writer_id = self._active_writer.get(workspace_dir)
            if writer_id is not None:
                return None, writer_id
            readers = self._active_readers.get(workspace_dir)
            if lock_mode == "write" and readers:
                return None, sorted(readers)[0]
            prefix = job_prefix if job_prefix else ("job" if is_async else "sync")
            job_id = f"{prefix}-{uuid.uuid4().hex[:12]}"
            record = JobRecord(
                job_id=job_id,
                workspace_dir=workspace_dir,
                model=model,
                permission_mode=permission_mode,
                max_turns=max_turns,
                timeout_seconds=timeout_seconds,
                started_at=time.monotonic(),
                is_async=is_async,
                lock_mode=lock_mode,
                effort=effort,
                cancel_event=cancel_event if cancel_event is not None else threading.Event(),
            )
            if lock_mode == "write":
                self._active_writer[workspace_dir] = job_id
            else:
                self._active_readers.setdefault(workspace_dir, set()).add(job_id)
            self._jobs[job_id] = record
            return record, None

    def finish_job(self, job: JobRecord, result: dict[str, Any]) -> None:
        with self._lock:
            job.result = result
            if self._active_writer.get(job.workspace_dir) == job.job_id:
                del self._active_writer[job.workspace_dir]
            readers = self._active_readers.get(job.workspace_dir)
            if readers is not None:
                readers.discard(job.job_id)
                if not readers:
                    del self._active_readers[job.workspace_dir]
            job.done_event.set()
            self._prune_completed_locked()

    def _prune_completed_locked(self) -> None:
        completed = [j for j in self._jobs.values() if j.done_event.is_set()]
        if len(completed) <= MAX_COMPLETED_JOBS:
            return
        completed.sort(key=lambda j: j.started_at)
        for old in completed[: len(completed) - MAX_COMPLETED_JOBS]:
            self._jobs.pop(old.job_id, None)

    def get_job(self, job_id: str) -> Optional[JobRecord]:
        with self._lock:
            return self._jobs.get(job_id)

    def cancel_all(self, wait_seconds: float = 3.0) -> None:
        with self._lock:
            active_ids: list[str] = list(self._active_writer.values())
            for reader_set in self._active_readers.values():
                active_ids.extend(reader_set)
            active_jobs = [
                self._jobs[jid] for jid in active_ids if jid in self._jobs
            ]
        for job in active_jobs:
            job.cancel_event.set()
        deadline = time.monotonic() + wait_seconds
        for job in active_jobs:
            remaining = deadline - time.monotonic()
            if remaining > 0:
                job.done_event.wait(timeout=remaining)


JOB_MANAGER = JobManager()


def _rollback_safe_rel(root: Path, raw_path: str) -> Optional[str]:
    """Normalize a tracked diff path and reject state, git metadata, and escaping paths."""
    norm = raw_path.replace("\\", "/")
    while norm.startswith("./"):
        norm = norm[2:]
    if not norm or norm.startswith("/") or re.match(r"^[A-Za-z]:", norm):
        return None
    if norm == STATE_REL_DIR or norm.startswith(STATE_REL_DIR + "/"):
        return None
    if norm == ".git" or norm.startswith(".git/"):
        return None
    try:
        resolved = (root / norm).resolve()
    except OSError:
        return None
    if resolved != root and root not in resolved.parents:
        return None
    return norm


def _rollback_prune_empty_dirs(start: Path, root: Path) -> None:
    """Remove empty parent directories strictly below root, never .agents or .git."""
    current = start
    while current != root and root in current.parents:
        if current.name in (".agents", ".git"):
            return
        try:
            current.rmdir()
        except OSError:
            return
        current = current.parent


def _rollback_restore_paths(
    ws_str: str, target_tree: str, rel_paths: list[str]
) -> tuple[bool, Optional[str]]:
    """Restore tracked paths from target_tree using a throwaway index; never touch .git/index."""
    if not rel_paths:
        return True, None
    fd = -1
    tmp_idx = ""
    try:
        fd, tmp_idx = tempfile.mkstemp(prefix="ai_teams_rollback_idx_", suffix=".idx")
        os.close(fd)
        fd = -1
        os.unlink(tmp_idx)
    except OSError as exc:
        if fd >= 0:
            try:
                os.close(fd)
            except OSError:
                pass
        return False, f"Failed to create a temporary git index: {exc}"

    try:
        env = os.environ.copy()
        env["GIT_INDEX_FILE"] = tmp_idx
        read_tree = _run_git_cmd_env(ws_str, ["read-tree", target_tree], env=env)
        if read_tree is None or read_tree.returncode != 0:
            return False, f"git read-tree {target_tree} failed."
        payload = b"".join(rel.encode("utf-8") + b"\x00" for rel in rel_paths)
        checkout = _run_git_cmd_env(
            ws_str,
            ["checkout-index", "-f", "-z", "--stdin"],
            env=env,
            text=False,
            input_bytes=payload,
        )
        if checkout is None or checkout.returncode != 0:
            return False, "git checkout-index --stdin failed."
        return True, None
    finally:
        for leftover in (tmp_idx, tmp_idx + ".lock"):
            try:
                if os.path.exists(leftover):
                    os.unlink(leftover)
            except OSError:
                pass


def rollback_last_run(
    workspace_dir: str, session_key: Optional[str] = None
) -> dict[str, Any]:
    """Restore workspace files to the last pre-run tree. CLI-only; never exposed via MCP."""

    def _result(
        ok: bool,
        status: str,
        error: Optional[str],
        *,
        ws_val: str = "",
        restored_tree: Optional[str] = None,
        restored_files: Optional[list[str]] = None,
        removed_files: Optional[list[str]] = None,
        invalidated: Optional[list[str]] = None,
    ) -> dict[str, Any]:
        return {
            "ok": ok,
            "status": status,
            "workspace_dir": ws_val,
            "restored_tree": restored_tree,
            "restored_files": list(restored_files or []),
            "removed_files": list(removed_files or []),
            "invalidated_session_keys": list(invalidated or []),
            "error": error,
        }

    if not isinstance(workspace_dir, str) or not workspace_dir.strip():
        return _result(
            False, "ERROR", "workspace_dir is required and must be a non-empty path."
        )
    try:
        ws_path = Path(workspace_dir).expanduser().resolve()
    except OSError as exc:
        return _result(False, "ERROR", f"Invalid workspace_dir '{workspace_dir}': {exc}")
    if not ws_path.is_dir():
        return _result(
            False,
            "ERROR",
            f"workspace_dir does not exist or is not a directory: {ws_path}",
            ws_val=str(ws_path),
        )
    ws_str = str(ws_path)

    if session_key is not None and (
        not isinstance(session_key, str) or not session_key.strip()
    ):
        return _result(
            False,
            "ERROR",
            "session_key must be a non-empty string when provided.",
            ws_val=ws_str,
        )
    clean_session_key = session_key.strip() if isinstance(session_key, str) else None

    if not _is_git_worktree(ws_str):
        return _result(
            False,
            "ERROR",
            "Refusing rollback: workspace_dir is not inside a git work tree.",
            ws_val=ws_str,
        )
    top_level = _git_toplevel(ws_str)
    if top_level is None or ws_path != top_level.resolve():
        return _result(
            False,
            "ERROR",
            "Refusing rollback: workspace_dir must be the git repository root.",
            ws_val=ws_str,
        )

    job, active_id = JOB_MANAGER.register_job(
        workspace_dir=ws_str,
        model="rollback",
        permission_mode="none",
        max_turns=0,
        timeout_seconds=60,
        is_async=False,
        job_prefix="rollback",
    )
    if job is None:
        return _result(
            False,
            "BUSY",
            f"Another Claude task ({active_id}) is already running in workspace '{ws_str}'.",
            ws_val=ws_str,
        )

    res: Optional[dict[str, Any]] = None
    try:
        res = _rollback_last_run_locked(ws_str, clean_session_key, _result)
        return res
    except Exception as exc:
        res = _result(
            False,
            "ERROR",
            f"Unexpected internal failure while rolling back: {exc}",
            ws_val=ws_str,
        )
        return res
    finally:
        if res is None:
            res = _result(
                False,
                "ERROR",
                "Unexpected internal failure while rolling back the last run.",
                ws_val=ws_str,
            )
        JOB_MANAGER.finish_job(job, res)


def _rollback_last_run_locked(
    ws_str: str, session_key: Optional[str], result_fn: Any
) -> dict[str, Any]:
    """Resolve the checkpoint, restore tracked files, then invalidate continuity state."""
    target_tree: Optional[str] = None
    if session_key is not None:
        entry = load_session_index(ws_str)["sessions"].get(session_key)
        candidate = entry.get("pre_run_tree") if isinstance(entry, dict) else None
        if _git_tree_exists(ws_str, candidate):
            target_tree = str(candidate)
    else:
        checkpoint = load_workspace_state(ws_str).get("checkpoint")
        candidate = checkpoint.get("pre_run_tree") if isinstance(checkpoint, dict) else None
        if _git_tree_exists(ws_str, candidate):
            target_tree = str(candidate)
        else:
            entry = load_session_index(ws_str)["sessions"].get(DEFAULT_SESSION_KEY)
            candidate = entry.get("pre_run_tree") if isinstance(entry, dict) else None
            if _git_tree_exists(ws_str, candidate):
                target_tree = str(candidate)

    if target_tree is None:
        return result_fn(
            False,
            "ERROR",
            "No valid pre_run_tree checkpoint found; nothing to roll back.",
            ws_val=ws_str,
        )

    current_tree = _capture_git_tree(ws_str)
    if current_tree is None:
        return result_fn(
            False,
            "ERROR",
            "Failed to capture the current git tree; rollback aborted.",
            ws_val=ws_str,
            restored_tree=target_tree,
        )

    root = Path(ws_str).resolve()
    removed_files: list[str] = []
    restore_files: list[str] = []
    problems: list[str] = []

    if current_tree != target_tree:
        diff_proc = _run_git_cmd_env(
            ws_str,
            [
                "diff",
                "--no-renames",
                "-z",
                "--name-status",
                target_tree,
                current_tree,
                "--",
                ".",
                f":(exclude){STATE_REL_DIR}",
            ],
            text=False,
        )
        if diff_proc is None or diff_proc.returncode != 0:
            diff_proc = _run_git_cmd_env(
                ws_str,
                [
                    "diff",
                    "--no-renames",
                    "-z",
                    "--name-status",
                    target_tree,
                    current_tree,
                    "--",
                    ".",
                ],
                text=False,
            )
        if diff_proc is None or diff_proc.returncode != 0:
            return result_fn(
                False,
                "ERROR",
                "Failed to compute the rollback diff.",
                ws_val=ws_str,
                restored_tree=target_tree,
            )

        tokens = (diff_proc.stdout or b"").split(b"\x00")
        entries: list[tuple[str, str]] = []
        index = 0
        while index + 1 < len(tokens):
            status_token = tokens[index]
            path_token = tokens[index + 1]
            index += 2
            if not status_token or not path_token:
                continue
            letter = status_token.decode("ascii", errors="ignore")[:1]
            if letter not in ("A", "D", "M", "T"):
                continue
            try:
                raw_path = path_token.decode("utf-8")
            except UnicodeDecodeError:
                continue
            rel = _rollback_safe_rel(root, raw_path)
            if rel is not None:
                entries.append((letter, rel))

        for letter, rel in entries:
            target_path = root / rel
            if letter == "A":
                try:
                    if target_path.is_symlink() or target_path.is_file():
                        os.unlink(target_path)
                        removed_files.append(rel)
                        _rollback_prune_empty_dirs(target_path.parent, root)
                except OSError as exc:
                    problems.append(f"Failed to remove {rel}: {exc}")
                continue
            if letter == "T":
                try:
                    if target_path.is_symlink() or target_path.is_file():
                        os.unlink(target_path)
                except OSError as exc:
                    problems.append(f"Failed to replace {rel}: {exc}")
            restore_files.append(rel)

        if restore_files:
            restored_ok, restore_err = _rollback_restore_paths(
                ws_str, target_tree, restore_files
            )
            if not restored_ok:
                return result_fn(
                    False,
                    "ERROR",
                    restore_err or "Failed to restore tracked files.",
                    ws_val=ws_str,
                    restored_tree=target_tree,
                    restored_files=restore_files,
                    removed_files=removed_files,
                )
        if problems:
            return result_fn(
                False,
                "ERROR",
                "; ".join(problems[:5]),
                ws_val=ws_str,
                restored_tree=target_tree,
                restored_files=restore_files,
                removed_files=removed_files,
            )

    now_utc = datetime.now(timezone.utc)
    iso = now_utc.isoformat()
    invalidated: list[str] = []
    if _state_dir_path(ws_str).is_dir():
        with _state_lock:
            index_data = load_session_index(ws_str)
            sessions = index_data["sessions"]
            if session_key is not None and session_key in sessions:
                del sessions[session_key]
                invalidated.append(session_key)
            for key in list(sessions.keys()):
                entry = sessions[key]
                has_target_tree = (
                    isinstance(entry, dict) and entry.get("pre_run_tree") == target_tree
                )
                if has_target_tree or key == DEFAULT_SESSION_KEY:
                    del sessions[key]
                    if key not in invalidated:
                        invalidated.append(key)
            save_session_index(ws_str, index_data)

            state = load_workspace_state(ws_str)
            checkpoint = state.get("checkpoint")
            merged_checkpoint = dict(checkpoint) if isinstance(checkpoint, dict) else {}
            merged_checkpoint["status"] = "rolled_back"
            merged_checkpoint["pre_run_tree"] = None
            merged_checkpoint["post_run_tree"] = None
            merged_checkpoint["last_rollback_at"] = iso
            artifacts = state.get("artifacts")
            state["version"] = 1
            state["checkpoint"] = merged_checkpoint
            state["artifacts"] = _prune_deleted_artifacts(
                ws_str, artifacts if isinstance(artifacts, dict) else {}
            )
            save_workspace_state(ws_str, state)
            write_workspace_brief(ws_str, state)

    return result_fn(
        True,
        "ROLLED_BACK",
        None,
        ws_val=ws_str,
        restored_tree=target_tree,
        restored_files=restore_files,
        removed_files=removed_files,
        invalidated=sorted(invalidated),
    )


def _count_plan_history_entries(ws_str: str) -> int:
    hist_path = _state_dir_path(ws_str) / "plan-history.md"
    if not hist_path.is_file():
        return 0
    try:
        text = hist_path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return 0
    return len(re.findall(r"<!-- ENTRY:START -->.*?<!-- ENTRY:END -->", text, re.DOTALL))


def _collect_workspace_state_summary(
    workspace_dir: Optional[str],
) -> tuple[bool, Optional[dict[str, Any]], Optional[str]]:
    """Inspect .agents/state/ read-only for healthcheck reporting."""
    if workspace_dir is None or not isinstance(workspace_dir, str) or not workspace_dir.strip():
        return True, None, None
    try:
        ws_path = Path(workspace_dir).expanduser().resolve()
        if not ws_path.is_dir():
            ws_err = f"workspace_dir does not exist or is not a directory: {ws_path}"
            return False, {"workspace_dir": str(ws_path), "exists": False, "error": ws_err}, ws_err
        ws_str = str(ws_path)
        state_dir = _state_dir_path(ws_str)
        idx = load_session_index(ws_str)
        sessions = idx.get("sessions", {})
        state_data = load_workspace_state(ws_str)
        checkpoint = state_data.get("checkpoint")
        if not isinstance(checkpoint, dict):
            checkpoint = {}
        runs_dir = state_dir / "runs"
        try:
            archived_runs = (
                len([p for p in runs_dir.glob("*.md") if p.is_file()])
                if runs_dir.is_dir()
                else 0
            )
        except OSError:
            archived_runs = 0
        open_issues = state_data.get("open_issues")
        ws_state = {
            "workspace_dir": ws_str,
            "exists": True,
            "state_dir": str(state_dir),
            "state_dir_exists": state_dir.is_dir(),
            "gitignore_exists": (state_dir / ".gitignore").is_file(),
            "plan_history_exists": (state_dir / "plan-history.md").is_file(),
            "plan_history_entries": _count_plan_history_entries(ws_str),
            "session_index_exists": (state_dir / "session-index.json").is_file(),
            "cached_sessions": len(sessions),
            "session_keys": sorted(sessions.keys()),
            "workspace_brief_exists": (state_dir / "workspace-brief.md").is_file(),
            "state_json_exists": (state_dir / "state.json").is_file(),
            "open_issues_count": (
                len(open_issues) if isinstance(open_issues, list) else 0
            ),
            "archived_runs": archived_runs,
            "last_checkpoint_status": checkpoint.get("status") or None,
            "has_pre_run_tree": bool(checkpoint.get("pre_run_tree")),
            "error": None,
        }
        return True, ws_state, None
    except OSError as exc:
        ws_err = f"Invalid workspace_dir '{workspace_dir}': {exc}"
        return False, {"workspace_dir": workspace_dir, "exists": False, "error": ws_err}, ws_err


def healthcheck(workspace_dir: Optional[str] = None) -> dict[str, Any]:
    """Verify local Claude Code CLI availability, version, and optional workspace continuity state."""
    claude_bin, err = find_claude_binary()
    auth_dir = Path.home() / ".claude"
    auth_dir_exists = auth_dir.exists()

    version_str: Optional[str] = None
    version_rc: Optional[int] = None

    if claude_bin:
        try:
            proc = subprocess.run(
                build_claude_argv(claude_bin, ["--version"]),
                env=build_child_env(claude_bin),
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=15,
            )
            version_rc = proc.returncode
            out = (proc.stdout or proc.stderr or "").strip()
            version_str = out or None
            if proc.returncode != 0:
                err = f"'claude --version' exited with code {proc.returncode}: {out}"
        except subprocess.TimeoutExpired:
            err = "'claude --version' timed out after 15s"
        except OSError as exc:
            err = f"Failed to execute '{claude_bin} --version': {exc}"

    ws_ok, ws_state, ws_err = _collect_workspace_state_summary(workspace_dir)
    if ws_err and err is None:
        err = ws_err

    sync_to = get_default_timeout_seconds(sync=True)
    res: dict[str, Any] = {
        "ok": bool(claude_bin and version_rc == 0 and ws_ok),
        "claude_bin": claude_bin,
        "version": version_str,
        "auth_dir": str(auth_dir),
        "auth_dir_exists": auth_dir_exists,
        "default_model": get_default_model(),
        "default_effort": get_default_effort() or None,
        "default_verify_model": get_default_verify_model(),
        "default_verify_effort": get_default_verify_effort() or None,
        "default_permission_mode": get_default_permission_mode(),
        "default_max_turns": get_default_max_turns(),
        "default_verify_max_turns": get_default_verify_max_turns(),
        "default_timeout_seconds": sync_to,
        "default_sync_timeout_seconds": sync_to,
        "default_async_timeout_seconds": get_default_timeout_seconds(sync=False),
        "default_session_max_turns": get_default_session_max_turns(),
        "default_session_ttl_seconds": get_default_session_ttl_seconds(),
        "strict_mcp_config": get_strict_mcp_config(),
        "active_jobs": JOB_MANAGER.active_count(),
        "error": err,
    }
    if ws_state is not None:
        res["workspace_state"] = ws_state
    return res


def _derive_session_key(
    session_key: Optional[str],
    resolved_plan_file: Optional[str],
) -> tuple[Optional[str], Optional[str]]:
    if session_key is not None:
        if not isinstance(session_key, str) or not session_key.strip():
            return None, "session_key must be a non-empty string."
        cleaned = session_key.strip()
        if not re.fullmatch(r"[A-Za-z0-9._:/-]{1,200}", cleaned):
            return (
                None,
                "session_key may only contain ASCII letters, digits, and . _ : / - (1-200 chars).",
            )
        return cleaned, None

    # Auto mode is a single hot workspace session; plan changes do not rotate it.
    return DEFAULT_SESSION_KEY, None


def _resolve_session_plan(
    ws_str: str,
    *,
    session_key: str,
    session_mode: str,
    resume_session_id: Optional[str],
    plan_sha256: str,
    session_max_turns: int,
    session_ttl_seconds: int,
    now_ts: Optional[float] = None,
) -> tuple[Optional[str], str, Optional[str]]:
    """Resolve whether to resume an existing Claude session or start a fresh one."""
    if resume_session_id:
        return resume_session_id, "explicit_resume", None

    if session_mode == "fresh":
        return None, "fresh", None

    with _state_lock:
        idx = load_session_index(ws_str)
        entry = idx.get("sessions", {}).get(session_key)

    has_sid = isinstance(entry, dict) and isinstance(entry.get("session_id"), str) and bool(
        entry["session_id"].strip()
    )

    if session_mode == "resume":
        if not has_sid:
            return (
                None,
                "error",
                f"Cannot resume session for session_key '{session_key}': "
                f"no cached session_id found in {STATE_REL_DIR}/session-index.json.",
            )
        return str(entry["session_id"]).strip(), "resumed", None

    # session_mode == "auto"
    if not has_sid:
        return None, "fresh", None

    now = time.time() if now_ts is None else now_ts
    updated_at = _safe_float(entry.get("updated_at"), 0.0)
    if (now - updated_at) > session_ttl_seconds:
        return None, "rotated_ttl", None

    cumulative_turns = _safe_int(entry.get("cumulative_turns"), 0)
    if cumulative_turns >= session_max_turns:
        return None, "rotated_turns", None

    return str(entry["session_id"]).strip(), "resumed", None


def _delete_session_if_matches(
    ws_str: str, session_key: str, expected_session_id: str
) -> None:
    with _state_lock:
        idx = load_session_index(ws_str)
        sessions = idx.get("sessions", {})
        entry = sessions.get(session_key)
        if isinstance(entry, dict) and entry.get("session_id") == expected_session_id:
            del sessions[session_key]
            save_session_index(ws_str, idx)


def _record_session_completion(
    ws_str: str,
    *,
    session_key: str,
    session_id: Optional[str],
    target_session_id: Optional[str],
    session_action: str,
    session_fallback: bool,
    plan_sha256: str,
    status: str,
    resolved_plan_file: Optional[str],
    run_changed_files: list[str],
    num_turns: Optional[int],
    pre_run_tree: Optional[str] = None,
    post_run_tree: Optional[str] = None,
) -> None:
    if not session_id:
        return
    now_ts = time.time()
    turn_delta = num_turns if (isinstance(num_turns, int) and num_turns >= 0) else 0
    with _state_lock:
        idx = load_session_index(ws_str)
        sessions = idx["sessions"]
        existing = sessions.get(session_key)
        resumed_same = (
            session_action in ("resumed", "explicit_resume")
            and not session_fallback
            and isinstance(existing, dict)
            and (target_session_id is None or existing.get("session_id") == target_session_id)
        )
        if resumed_same:
            prev_turns = _safe_int(existing.get("cumulative_turns"), 0)
            prev_runs = _safe_int(existing.get("run_count"), 0)
            created_at = _safe_float(existing.get("created_at"), now_ts)
        else:
            prev_turns = 0
            prev_runs = 0
            created_at = now_ts

        sessions[session_key] = {
            "session_id": session_id,
            "plan_sha256": plan_sha256,
            "cumulative_turns": prev_turns + turn_delta,
            "run_count": prev_runs + 1,
            "created_at": created_at,
            "updated_at": now_ts,
            "last_status": status,
            "last_plan_file": resolved_plan_file,
            "last_changed_files": list(run_changed_files[:50]),
            "pre_run_tree": pre_run_tree,
            "post_run_tree": post_run_tree,
        }
        save_session_index(ws_str, idx)


def _validate_base_execution_inputs(
    *,
    workspace_dir: str,
    plan: Optional[str],
    plan_file: Optional[str],
    allowed_files: Optional[list[str]],
    verification_commands: Optional[list[str]],
    model: Optional[str],
    effort: Optional[str] = None,
    max_turns: Optional[int],
    timeout_seconds: Optional[int],
    include_history: bool,
    default_model: str,
    default_effort: str = "",
    default_max_turns: int,
    enforce_sync_cap: bool,
    sync_cap_hint: str,
    err_fn: Any,
    find_binary_fn: Any = None,
    missing_bin_msg: str = "Claude Code CLI not found.",
) -> tuple[Optional[dict[str, Any]], Optional[dict[str, Any]]]:
    """Validate workspace, plan/plan_file, lists, limits, and CLI binary cleanly."""
    if not isinstance(workspace_dir, str) or not workspace_dir.strip():
        return None, err_fn("ERROR", "workspace_dir is required and must be a non-empty path.")

    try:
        ws_path = Path(workspace_dir).expanduser().resolve()
    except OSError as exc:
        return None, err_fn("ERROR", f"Invalid workspace_dir '{workspace_dir}': {exc}")

    if not ws_path.is_dir():
        return None, err_fn(
            "ERROR",
            f"workspace_dir does not exist or is not a directory: {ws_path}",
            workspace_dir=str(ws_path),
        )

    ws_str = str(ws_path)
    resolved_model = model.strip() if isinstance(model, str) and model.strip() else default_model
    resolved_effort, effort_err = _resolve_effort(effort, default_effort)

    def _fail(msg: str, *, status: str = "ERROR", pf: Optional[str] = None) -> tuple[None, dict[str, Any]]:
        return None, err_fn(
            status,
            msg,
            model=resolved_model,
            effort=(resolved_effort or None),
            workspace_dir=ws_str,
            git_evidence=collect_git_evidence(ws_str),
            plan_file=pf,
        )

    if effort_err:
        return _fail(effort_err)

    if plan is not None and not isinstance(plan, str):
        return _fail("plan must be a string when provided.")

    resolved_plan_file: Optional[str] = None
    file_plan_text = ""
    if plan_file is not None:
        if not isinstance(plan_file, str) or not plan_file.strip():
            return _fail("plan_file must be a non-empty file path string.")
        raw_pf = Path(plan_file.strip()).expanduser()
        try:
            pf_path = raw_pf.resolve() if raw_pf.is_absolute() else (ws_path / raw_pf).resolve()
        except OSError as exc:
            return _fail(f"Invalid plan_file '{plan_file}': {exc}")
        if not pf_path.is_file():
            return _fail(f"plan_file does not exist or is not a file: {pf_path}")
        try:
            file_plan_text = pf_path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as exc:
            return _fail(f"Failed to read plan_file '{pf_path}': {exc}")
        try:
            resolved_plan_file = pf_path.relative_to(ws_path).as_posix()
        except ValueError:
            resolved_plan_file = str(pf_path)

    effective_plan = plan if (isinstance(plan, str) and plan.strip()) else file_plan_text
    if not effective_plan.strip():
        return _fail("Either plan or a non-empty plan_file is required.", pf=resolved_plan_file)

    if not isinstance(include_history, bool):
        return _fail(f"include_history must be a boolean, got: {include_history!r}", pf=resolved_plan_file)

    if allowed_files is not None and (
        not isinstance(allowed_files, (list, tuple))
        or not all(isinstance(item, str) for item in allowed_files)
    ):
        return _fail("allowed_files must be a list of file path strings.", pf=resolved_plan_file)

    if verification_commands is not None and (
        not isinstance(verification_commands, (list, tuple))
        or not all(isinstance(item, str) for item in verification_commands)
    ):
        return _fail("verification_commands must be a list of command strings.", pf=resolved_plan_file)

    if max_turns is None:
        resolved_max_turns = default_max_turns
    elif isinstance(max_turns, bool) or not isinstance(max_turns, int) or not (1 <= max_turns <= 100):
        return _fail(f"max_turns must be an integer between 1 and 100, got: {max_turns!r}", pf=resolved_plan_file)
    else:
        resolved_max_turns = max_turns

    max_allowed_timeout = SYNC_MAX_TIMEOUT_SECONDS if enforce_sync_cap else ASYNC_MAX_TIMEOUT_SECONDS
    if timeout_seconds is None:
        resolved_timeout = get_default_timeout_seconds(sync=enforce_sync_cap)
    elif isinstance(timeout_seconds, bool) or not isinstance(timeout_seconds, int) or timeout_seconds < 1:
        return _fail(
            f"timeout_seconds must be an integer between 1 and {max_allowed_timeout}, got: {timeout_seconds!r}",
            pf=resolved_plan_file,
        )
    elif enforce_sync_cap and timeout_seconds > SYNC_MAX_TIMEOUT_SECONDS:
        return _fail(
            f"Synchronous {sync_cap_hint} caps timeout_seconds at {SYNC_MAX_TIMEOUT_SECONDS}s "
            "(below Antigravity's 180s MCP limit).",
            pf=resolved_plan_file,
        )
    elif timeout_seconds > max_allowed_timeout:
        return _fail(
            f"timeout_seconds must be an integer between 1 and {max_allowed_timeout}, got: {timeout_seconds!r}",
            pf=resolved_plan_file,
        )
    else:
        resolved_timeout = timeout_seconds

    resolver = find_binary_fn if callable(find_binary_fn) else find_claude_binary
    cli_bin, bin_err = resolver()
    if not cli_bin:
        return _fail(bin_err or missing_bin_msg, status="BLOCKED", pf=resolved_plan_file)

    return {
        "ws_str": ws_str,
        "effective_plan": effective_plan,
        "resolved_plan_file": resolved_plan_file,
        "include_history": include_history,
        "resolved_model": resolved_model,
        "resolved_effort": resolved_effort,
        "resolved_max_turns": resolved_max_turns,
        "resolved_timeout": resolved_timeout,
        "claude_bin": cli_bin,
    }, None


def _validate_and_prepare(
    workspace_dir: str,
    plan: Optional[str],
    allowed_files: Optional[list[str]],
    verification_commands: Optional[list[str]],
    model: Optional[str],
    max_turns: Optional[int],
    permission_mode: Optional[str],
    timeout_seconds: Optional[int],
    *,
    effort: Optional[str] = None,
    enforce_sync_cap: bool,
    plan_file: Optional[str] = None,
    session_key: Optional[str] = None,
    session_mode: Optional[str] = None,
    resume_session_id: Optional[str] = None,
    include_history: bool = True,
) -> tuple[Optional[dict[str, Any]], Optional[dict[str, Any]]]:
    """Validate arguments and resolve binary/config/session; returns (prepared, error_response)."""
    resolved_perm = (
        permission_mode.strip()
        if isinstance(permission_mode, str) and permission_mode.strip()
        else get_default_permission_mode()
    )

    def _exec_err(status: str, msg: str, **kw: Any) -> dict[str, Any]:
        return _error_response(status, msg, permission_mode=resolved_perm, **kw)

    base, err_resp = _validate_base_execution_inputs(
        workspace_dir=workspace_dir,
        plan=plan,
        plan_file=plan_file,
        allowed_files=allowed_files,
        verification_commands=verification_commands,
        model=model,
        effort=effort,
        max_turns=max_turns,
        timeout_seconds=timeout_seconds,
        include_history=include_history,
        default_model=get_default_model(),
        default_effort=get_default_effort(),
        default_max_turns=get_default_max_turns(),
        enforce_sync_cap=enforce_sync_cap,
        sync_cap_hint="claude_execute",
        err_fn=_exec_err,
    )
    if err_resp is not None or base is None:
        return None, err_resp

    ws_str = base["ws_str"]
    resolved_plan_file = base["resolved_plan_file"]
    resolved_model = base["resolved_model"]
    resolved_effort = base["resolved_effort"]

    if resolved_perm not in VALID_PERMISSION_MODES:
        return None, _error_response(
            "ERROR",
            f"Invalid permission_mode '{resolved_perm}'. Allowed: {sorted(VALID_PERMISSION_MODES)}",
            model=resolved_model,
            effort=resolved_effort or None,
            permission_mode=resolved_perm,
            workspace_dir=ws_str,
            git_evidence=collect_git_evidence(ws_str),
            plan_file=resolved_plan_file,
        )

    if session_mode is not None and not isinstance(session_mode, str):
        return None, _error_response(
            "ERROR",
            f"session_mode must be a string, got: {session_mode!r}",
            model=resolved_model,
            effort=resolved_effort or None,
            permission_mode=resolved_perm,
            workspace_dir=ws_str,
            git_evidence=collect_git_evidence(ws_str),
            plan_file=resolved_plan_file,
        )
    resolved_session_mode = (
        session_mode.strip()
        if isinstance(session_mode, str) and session_mode.strip()
        else "auto"
    )
    if resolved_session_mode not in VALID_SESSION_MODES:
        return None, _error_response(
            "ERROR",
            f"Invalid session_mode '{resolved_session_mode}'. Allowed: {sorted(VALID_SESSION_MODES)}",
            model=resolved_model,
            effort=resolved_effort or None,
            permission_mode=resolved_perm,
            workspace_dir=ws_str,
            git_evidence=collect_git_evidence(ws_str),
            plan_file=resolved_plan_file,
        )

    resolved_resume_sid: Optional[str] = None
    if resume_session_id is not None:
        if (
            not isinstance(resume_session_id, str)
            or not resume_session_id.strip()
            or "\n" in resume_session_id
            or "\r" in resume_session_id
        ):
            return None, _error_response(
                "ERROR",
                "resume_session_id must be a single-line non-empty string.",
                model=resolved_model,
                effort=resolved_effort or None,
                permission_mode=resolved_perm,
                workspace_dir=ws_str,
                git_evidence=collect_git_evidence(ws_str),
                plan_file=resolved_plan_file,
                session_mode=resolved_session_mode,
            )
        if resolved_session_mode == "fresh":
            return None, _error_response(
                "ERROR",
                "Cannot combine resume_session_id with session_mode='fresh'.",
                model=resolved_model,
                effort=resolved_effort or None,
                permission_mode=resolved_perm,
                workspace_dir=ws_str,
                git_evidence=collect_git_evidence(ws_str),
                plan_file=resolved_plan_file,
                session_mode=resolved_session_mode,
            )
        resolved_resume_sid = resume_session_id.strip()

    resolved_session_key, key_err = _derive_session_key(session_key, resolved_plan_file)
    if key_err or resolved_session_key is None:
        return None, _error_response(
            "ERROR",
            key_err or "Invalid session_key.",
            model=resolved_model,
            effort=resolved_effort or None,
            permission_mode=resolved_perm,
            workspace_dir=ws_str,
            git_evidence=collect_git_evidence(ws_str),
            plan_file=resolved_plan_file,
            session_mode=resolved_session_mode,
        )

    plan_sha256 = hashlib.sha256(base["effective_plan"].strip().encode("utf-8")).hexdigest()
    if resolved_session_mode == "resume" and not resolved_resume_sid:
        _, _, resume_err = _resolve_session_plan(
            ws_str,
            session_key=resolved_session_key,
            session_mode=resolved_session_mode,
            resume_session_id=None,
            plan_sha256=plan_sha256,
            session_max_turns=get_default_session_max_turns(),
            session_ttl_seconds=get_default_session_ttl_seconds(),
        )
        if resume_err:
            return None, _error_response(
                "ERROR",
                resume_err,
                model=resolved_model,
                effort=resolved_effort or None,
                permission_mode=resolved_perm,
                workspace_dir=ws_str,
                git_evidence=collect_git_evidence(ws_str),
                plan_file=resolved_plan_file,
                session_key=resolved_session_key,
                session_mode=resolved_session_mode,
            )

    return {
        **base,
        "plan_sha256": plan_sha256,
        "resolved_session_key": resolved_session_key,
        "resolved_session_mode": resolved_session_mode,
        "resolved_resume_sid": resolved_resume_sid,
        "resolved_perm": resolved_perm,
    }, None


def _validate_and_prepare_verify(
    workspace_dir: str,
    plan: Optional[str],
    allowed_files: Optional[list[str]],
    verification_commands: Optional[list[str]],
    model: Optional[str],
    max_turns: Optional[int],
    timeout_seconds: Optional[int],
    *,
    effort: Optional[str] = None,
    plan_file: Optional[str] = None,
    include_history: bool = True,
    include_git_diff: bool = True,
    diff_scope: str = "last_run",
    allow_bash: bool = True,
    enforce_sync_cap: bool = True,
) -> tuple[Optional[dict[str, Any]], Optional[dict[str, Any]]]:
    """Validate arguments for read-only verify_plan without touching .agents/state/."""
    def _v_err(status: str, msg: str, **kw: Any) -> dict[str, Any]:
        scope_kw = (
            diff_scope.strip()
            if isinstance(diff_scope, str) and diff_scope.strip() in VALID_DIFF_SCOPES
            else None
        )
        kw.setdefault("diff_scope", scope_kw)
        return _verify_error_response(
            status,
            msg,
            verdict=("BLOCKED" if status == "BLOCKED" else "ERROR"),
            allow_bash=allow_bash if isinstance(allow_bash, bool) else True,
            **kw,
        )

    if not isinstance(include_git_diff, bool):
        return None, _v_err("ERROR", f"include_git_diff must be a boolean, got: {include_git_diff!r}")
    if not isinstance(allow_bash, bool):
        return None, _v_err("ERROR", f"allow_bash must be a boolean, got: {allow_bash!r}")
    if not isinstance(diff_scope, str) or diff_scope.strip() not in VALID_DIFF_SCOPES:
        return None, _verify_error_response(
            "ERROR",
            f"diff_scope must be one of {sorted(VALID_DIFF_SCOPES)}, got: {diff_scope!r}",
            verdict="ERROR",
            allow_bash=allow_bash if isinstance(allow_bash, bool) else True,
        )

    base, err_resp = _validate_base_execution_inputs(
        workspace_dir=workspace_dir,
        plan=plan,
        plan_file=plan_file,
        allowed_files=allowed_files,
        verification_commands=verification_commands,
        model=model,
        effort=effort,
        max_turns=max_turns,
        timeout_seconds=timeout_seconds,
        include_history=include_history,
        default_model=get_default_verify_model(),
        default_effort=get_default_verify_effort(),
        default_max_turns=get_default_verify_max_turns(),
        enforce_sync_cap=enforce_sync_cap,
        sync_cap_hint="claude_verify",
        err_fn=_v_err,
    )
    if err_resp is not None or base is None:
        return None, err_resp

    return {
        **base,
        "include_git_diff": include_git_diff,
        "allow_bash": allow_bash,
        "diff_scope": diff_scope.strip(),
    }, None


def _run_prepared(
    prepared: dict[str, Any],
    allowed_files: Optional[list[str]],
    verification_commands: Optional[list[str]],
    extra_context: Optional[str],
    *,
    cancel_event: Optional[threading.Event] = None,
    job_id: Optional[str] = None,
) -> dict[str, Any]:
    ws_str = prepared["ws_str"]
    effective_plan = prepared["effective_plan"]
    resolved_plan_file = prepared["resolved_plan_file"]
    plan_sha256 = prepared["plan_sha256"]
    session_key = prepared["resolved_session_key"]
    session_mode = prepared["resolved_session_mode"]
    resume_sid_arg = prepared["resolved_resume_sid"]
    include_history = prepared["include_history"]
    resolved_model = prepared["resolved_model"]
    resolved_effort = prepared["resolved_effort"]
    resolved_perm = prepared["resolved_perm"]
    resolved_max_turns = prepared["resolved_max_turns"]
    resolved_timeout = prepared["resolved_timeout"]
    claude_bin = prepared["claude_bin"]

    state_dir_existed = _state_dir_path(ws_str).is_dir()
    _ensure_state_dir(ws_str)
    pre_run_tree = _capture_git_tree(ws_str)
    before_snapshot = _snapshot_workspace(ws_str)

    target_session_id, session_action, resolve_err = _resolve_session_plan(
        ws_str,
        session_key=session_key,
        session_mode=session_mode,
        resume_session_id=resume_sid_arg,
        plan_sha256=plan_sha256,
        session_max_turns=get_default_session_max_turns(),
        session_ttl_seconds=get_default_session_ttl_seconds(),
    )
    if resolve_err:
        return _error_response(
            "ERROR",
            resolve_err,
            model=resolved_model,
            effort=resolved_effort or None,
            permission_mode=resolved_perm,
            claude_bin=claude_bin,
            workspace_dir=ws_str,
            git_evidence=collect_git_evidence(ws_str),
            job_id=job_id,
            session_key=session_key,
            session_mode=session_mode,
            session_action=session_action,
            plan_file=resolved_plan_file,
        )

    external_drift_injected = False
    external_drift_files: list[str] = []
    drift_text: Optional[str] = None
    if target_session_id is not None:
        with _state_lock:
            cached_entry = load_session_index(ws_str)["sessions"].get(session_key)
        cached_post = (
            cached_entry.get("post_run_tree")
            if isinstance(cached_entry, dict)
            else None
        )
        drift_info = collect_external_drift(
            ws_str, cached_post, current_tree=pre_run_tree
        )
        if drift_info["has_drift"]:
            drift_list = list(drift_info["drift_files"])
            drift_text = (
                "Files changed outside your session: "
                + ", ".join(drift_list)
                + "\n\n```diff\n"
                + str(drift_info["drift_diff"]).rstrip()
                + "\n```\n"
            )
            external_drift_injected = True
            external_drift_files = drift_list

    def _build_cli_args(active_resume_sid: Optional[str]) -> list[str]:
        # Pass -p prompt BEFORE --disallowedTools and join disallowed tools into a single
        # comma-separated string so variadic option parsing never consumes subsequent flags.
        args = [
            "-p",
            _EXEC_PROMPT,
            "--model",
            resolved_model,
        ]
        if resolved_effort:
            args.extend(["--effort", resolved_effort])
        args.extend([
            "--permission-mode",
            resolved_perm,
            "--max-turns",
            str(resolved_max_turns),
        ])
        if active_resume_sid:
            args.extend(["--resume", active_resume_sid])
        args.extend([
            "--output-format",
            "json",
            "--append-system-prompt",
            PLAN_STRICT_SYSTEM_PROMPT,
            "--disallowedTools",
            ",".join(DEFAULT_DISALLOWED_TOOLS),
        ])
        if get_strict_mcp_config():
            args.append("--strict-mcp-config")
        return args

    def _run_attempt(
        active_resume_sid: Optional[str],
        use_history: bool,
        timeout_budget: float,
        attempt_drift: Optional[str],
    ) -> tuple[str, Optional[int], str, str, bool]:
        prior_hist = (
            build_continuity_injection(ws_str)
            if (use_history and include_history)
            else ""
        )
        stdin_payload = build_plan_stdin(
            plan=effective_plan,
            allowed_files=allowed_files,
            verification_commands=verification_commands,
            extra_context=extra_context,
            prior_history=prior_hist or None,
            external_drift=attempt_drift,
        )
        cmd = build_claude_argv(claude_bin, _build_cli_args(active_resume_sid))
        outcome_val, rc_val, out_raw, err_raw, _ = _run_popen_cancellable(
            cmd=cmd,
            stdin_payload=stdin_payload,
            cwd=ws_str,
            env=build_child_env(claude_bin),
            timeout_seconds=int(max(1, round(timeout_budget))),
            cancel_event=cancel_event,
        )
        return outcome_val, rc_val, out_raw, err_raw, bool(prior_hist)

    run_started = time.monotonic()
    try:
        outcome, rc, stdout_raw, stderr_raw, history_injected = _run_attempt(
            target_session_id,
            target_session_id is None,
            float(resolved_timeout),
            drift_text,
        )
    except OSError as exc:
        return _error_response(
            "ERROR",
            f"Failed to launch Claude Code CLI '{claude_bin}': {exc}",
            model=resolved_model,
            effort=resolved_effort or None,
            permission_mode=resolved_perm,
            claude_bin=claude_bin,
            workspace_dir=ws_str,
            git_evidence=collect_git_evidence(ws_str),
            job_id=job_id,
            session_key=session_key,
            session_mode=session_mode,
            session_action=session_action,
            session_fallback=False,
            plan_file=resolved_plan_file,
        )

    session_fallback = False
    parsed = parse_claude_output(stdout_raw or "") if outcome == "EXITED" else {
        "parsed_json": False,
        "result": (stdout_raw or "").strip(),
        "is_error": False,
        "num_turns": None,
        "total_cost_usd": None,
        "subtype": None,
        "session_id": None,
    }

    subtype = parsed["subtype"]
    is_err_sub = isinstance(subtype, str) and subtype.startswith("error_")
    attempt_failed = outcome == "EXITED" and (rc != 0 or parsed["is_error"] or is_err_sub)
    combined_err = f"{parsed['result'] or ''}\n{stderr_raw or ''}"

    if (
        target_session_id is not None
        and attempt_failed
        and _RESUME_MISSING_RE.search(combined_err)
    ):
        _delete_session_if_matches(ws_str, session_key, target_session_id)
        remaining_budget = resolved_timeout - (time.monotonic() - run_started)
        if cancel_event is not None and cancel_event.is_set():
            outcome = "CANCELLED"
        elif remaining_budget < 1.0:
            outcome = "TIMEOUT"
        else:
            session_fallback = True
            session_action = "fallback_fresh"
            target_session_id = None
            external_drift_injected = False
            external_drift_files = []
            try:
                outcome, rc, stdout_raw, stderr_raw, history_injected = _run_attempt(
                    None,
                    True,
                    remaining_budget,
                    None,
                )
            except OSError as exc:
                return _error_response(
                    "ERROR",
                    f"Failed to launch fallback Claude Code CLI '{claude_bin}': {exc}",
                    model=resolved_model,
                    effort=resolved_effort or None,
                    permission_mode=resolved_perm,
                    claude_bin=claude_bin,
                    workspace_dir=ws_str,
                    git_evidence=collect_git_evidence(ws_str),
                    job_id=job_id,
                    session_key=session_key,
                    session_mode=session_mode,
                    session_action=session_action,
                    session_fallback=True,
                    plan_file=resolved_plan_file,
                )
            if outcome == "EXITED":
                parsed = parse_claude_output(stdout_raw or "")

    total_elapsed = time.monotonic() - run_started
    after_snapshot = _snapshot_workspace(ws_str)
    run_changed_files = _diff_snapshots(before_snapshot, after_snapshot)
    git_ev = collect_git_evidence(ws_str)
    stderr_text = (stderr_raw or "").strip()

    if outcome == "CANCELLED":
        return _error_response(
            "CANCELLED",
            "Claude Code CLI execution was cancelled and its process tree was terminated.",
            model=resolved_model,
            effort=resolved_effort or None,
            permission_mode=resolved_perm,
            claude_bin=claude_bin,
            workspace_dir=ws_str,
            exit_code=rc,
            duration_seconds=total_elapsed,
            result=(stdout_raw or "").strip(),
            stderr=stderr_text,
            git_evidence=git_ev,
            job_id=job_id,
            session_key=session_key,
            session_mode=session_mode,
            session_action=session_action,
            session_fallback=session_fallback,
            plan_file=resolved_plan_file,
            run_changed_files=run_changed_files,
        )

    if outcome == "TIMEOUT":
        return _error_response(
            "TIMEOUT",
            f"Claude Code CLI timed out after {resolved_timeout}s and process tree was terminated.",
            model=resolved_model,
            effort=resolved_effort or None,
            permission_mode=resolved_perm,
            claude_bin=claude_bin,
            workspace_dir=ws_str,
            exit_code=rc,
            duration_seconds=total_elapsed,
            result=(stdout_raw or "").strip(),
            stderr=stderr_text,
            git_evidence=git_ev,
            job_id=job_id,
            session_key=session_key,
            session_mode=session_mode,
            session_action=session_action,
            session_fallback=session_fallback,
            plan_file=resolved_plan_file,
            run_changed_files=run_changed_files,
        )

    err_msg: Optional[str] = None
    subtype = parsed["subtype"]
    is_error_subtype = isinstance(subtype, str) and subtype.startswith("error_")
    if rc != 0 or parsed["is_error"] or is_error_subtype:
        status = "ERROR"
        err_msg = _format_claude_cli_error(
            "Claude Code CLI",
            rc=rc,
            subtype=subtype,
            is_error_subtype=is_error_subtype,
            num_turns=parsed["num_turns"],
            resolved_max_turns=resolved_max_turns,
            result_text=parsed["result"] or "",
            stderr_text=stderr_text,
        )
    elif re.search(r"(?m)^\s*STATUS:\s*BLOCKED\b", parsed["result"] or ""):
        status = "BLOCKED"
    else:
        status = "DONE"

    final_session_id = parsed["session_id"] or target_session_id
    post_run_tree: Optional[str] = None
    run_id: Optional[str] = None
    if status in ("DONE", "BLOCKED"):
        post_run_tree = _capture_git_tree(ws_str)
        if final_session_id:
            _record_session_completion(
                ws_str,
                session_key=session_key,
                session_id=final_session_id,
                target_session_id=target_session_id,
                session_action=session_action,
                session_fallback=session_fallback,
                plan_sha256=plan_sha256,
                status=status,
                resolved_plan_file=resolved_plan_file,
                run_changed_files=run_changed_files,
                num_turns=parsed["num_turns"],
                pre_run_tree=pre_run_tree,
                post_run_tree=post_run_tree,
            )
        state_result = _update_state_after_execute(
            ws_str,
            status=status,
            plan_text=effective_plan,
            plan_file=resolved_plan_file,
            session_key=session_key,
            session_id=final_session_id,
            session_action=session_action,
            run_changed_files=run_changed_files,
            result_text=parsed["result"] or "",
            num_turns=parsed["num_turns"],
            pre_run_tree=pre_run_tree,
            post_run_tree=post_run_tree,
        )
        run_id = state_result.get("run_id")
    elif status == "ERROR":
        if subtype == "error_max_turns" and final_session_id:
            post_run_tree = _capture_git_tree(ws_str)
            _record_session_completion(
                ws_str,
                session_key=session_key,
                session_id=final_session_id,
                target_session_id=target_session_id,
                session_action=session_action,
                session_fallback=session_fallback,
                plan_sha256=plan_sha256,
                status=status,
                resolved_plan_file=resolved_plan_file,
                run_changed_files=run_changed_files,
                num_turns=parsed["num_turns"],
                pre_run_tree=pre_run_tree,
                post_run_tree=post_run_tree,
            )
        if state_dir_existed or run_changed_files:
            _record_failed_execute_state(
                ws_str,
                executor="claude",
                plan_text=effective_plan,
                plan_file=resolved_plan_file,
                run_changed_files=run_changed_files,
                error_msg=err_msg,
                pre_run_tree=pre_run_tree,
            )

    payload: dict[str, Any] = {
        "status": status,
        "model": resolved_model,
        "effort": resolved_effort or None,
        "permission_mode": resolved_perm,
        "claude_bin": claude_bin,
        "workspace_dir": ws_str,
        "exit_code": rc,
        "duration_seconds": round(total_elapsed, 3),
        "num_turns": parsed["num_turns"],
        "total_cost_usd": parsed["total_cost_usd"],
        "subtype": subtype,
        "session_id": final_session_id,
        "session_key": session_key,
        "session_mode": session_mode,
        "session_action": session_action,
        "session_fallback": session_fallback,
        "plan_file": resolved_plan_file,
        "history_injected": history_injected,
        "is_git_repo": git_ev["is_git_repo"],
        "changed_files": git_ev["changed_files"],
        "run_changed_files": run_changed_files,
        "git_diff_stat": git_ev["git_diff_stat"],
        "result": parsed["result"],
        "stderr": stderr_text,
        "error": err_msg,
        "pre_run_tree": pre_run_tree,
        "post_run_tree": post_run_tree,
        "external_drift_injected": external_drift_injected,
        "external_drift_files": external_drift_files,
        "run_id": run_id,
    }
    if job_id is not None:
        payload["job_id"] = job_id
    return payload


def execute_plan(
    workspace_dir: str,
    plan: Optional[str] = None,
    allowed_files: Optional[list[str]] = None,
    verification_commands: Optional[list[str]] = None,
    extra_context: Optional[str] = None,
    model: Optional[str] = None,
    max_turns: Optional[int] = None,
    permission_mode: Optional[str] = None,
    timeout_seconds: Optional[int] = None,
    *,
    effort: Optional[str] = None,
    plan_file: Optional[str] = None,
    session_key: Optional[str] = None,
    session_mode: Optional[str] = None,
    resume_session_id: Optional[str] = None,
    include_history: bool = True,
    enforce_sync_cap: bool = True,
    cancel_event: Optional[threading.Event] = None,
) -> dict[str, Any]:
    """Execute an approved plan using headless Claude Code CLI and return structured evidence."""
    prepared, err_resp = _validate_and_prepare(
        workspace_dir=workspace_dir,
        plan=plan,
        allowed_files=allowed_files,
        verification_commands=verification_commands,
        model=model,
        max_turns=max_turns,
        permission_mode=permission_mode,
        timeout_seconds=timeout_seconds,
        effort=effort,
        enforce_sync_cap=enforce_sync_cap,
        plan_file=plan_file,
        session_key=session_key,
        session_mode=session_mode,
        resume_session_id=resume_session_id,
        include_history=include_history,
    )
    if err_resp is not None or prepared is None:
        assert err_resp is not None
        return err_resp

    job, active_id = JOB_MANAGER.register_job(
        workspace_dir=prepared["ws_str"],
        model=prepared["resolved_model"],
        permission_mode=prepared["resolved_perm"],
        max_turns=prepared["resolved_max_turns"],
        timeout_seconds=prepared["resolved_timeout"],
        is_async=False,
        cancel_event=cancel_event,
        effort=prepared["resolved_effort"] or None,
    )
    if job is None:
        return _error_response(
            "BUSY",
            f"Another Claude task ({active_id}) is already running in workspace '{prepared['ws_str']}'. "
            "Check it with claude_execute_status or stop it with claude_execute_cancel before retrying.",
            model=prepared["resolved_model"],
            effort=prepared["resolved_effort"] or None,
            permission_mode=prepared["resolved_perm"],
            claude_bin=prepared["claude_bin"],
            workspace_dir=prepared["ws_str"],
            git_evidence=collect_git_evidence(prepared["ws_str"]),
            active_job_id=active_id,
            session_key=prepared["resolved_session_key"],
            session_mode=prepared["resolved_session_mode"],
            plan_file=prepared["resolved_plan_file"],
        )

    res: Optional[dict[str, Any]] = None
    try:
        res = _run_prepared(
            prepared=prepared,
            allowed_files=allowed_files,
            verification_commands=verification_commands,
            extra_context=extra_context,
            cancel_event=job.cancel_event,
            job_id=job.job_id,
        )
        return res
    finally:
        if res is None:
            res = _error_response(
                "ERROR",
                "Unexpected internal failure while executing Claude Code CLI.",
                model=prepared["resolved_model"],
                effort=prepared["resolved_effort"] or None,
                permission_mode=prepared["resolved_perm"],
                claude_bin=prepared["claude_bin"],
                workspace_dir=prepared["ws_str"],
                job_id=job.job_id,
                session_key=prepared["resolved_session_key"],
                session_mode=prepared["resolved_session_mode"],
                plan_file=prepared["resolved_plan_file"],
            )
        JOB_MANAGER.finish_job(job, res)


def start_async_plan(
    workspace_dir: str,
    plan: Optional[str] = None,
    allowed_files: Optional[list[str]] = None,
    verification_commands: Optional[list[str]] = None,
    extra_context: Optional[str] = None,
    model: Optional[str] = None,
    max_turns: Optional[int] = None,
    permission_mode: Optional[str] = None,
    timeout_seconds: Optional[int] = None,
    *,
    effort: Optional[str] = None,
    plan_file: Optional[str] = None,
    session_key: Optional[str] = None,
    session_mode: Optional[str] = None,
    resume_session_id: Optional[str] = None,
    include_history: bool = True,
) -> dict[str, Any]:
    """Start an approved long-running plan asynchronously and return a job_id immediately."""
    prepared, err_resp = _validate_and_prepare(
        workspace_dir=workspace_dir,
        plan=plan,
        allowed_files=allowed_files,
        verification_commands=verification_commands,
        model=model,
        max_turns=max_turns,
        permission_mode=permission_mode,
        timeout_seconds=timeout_seconds,
        effort=effort,
        enforce_sync_cap=False,
        plan_file=plan_file,
        session_key=session_key,
        session_mode=session_mode,
        resume_session_id=resume_session_id,
        include_history=include_history,
    )
    if err_resp is not None or prepared is None:
        assert err_resp is not None
        return err_resp

    job, active_id = JOB_MANAGER.register_job(
        workspace_dir=prepared["ws_str"],
        model=prepared["resolved_model"],
        permission_mode=prepared["resolved_perm"],
        max_turns=prepared["resolved_max_turns"],
        timeout_seconds=prepared["resolved_timeout"],
        is_async=True,
        effort=prepared["resolved_effort"] or None,
    )
    if job is None:
        return _error_response(
            "BUSY",
            f"Another Claude task ({active_id}) is already running in workspace '{prepared['ws_str']}'. "
            "Poll it with claude_execute_status or stop it with claude_execute_cancel first.",
            model=prepared["resolved_model"],
            effort=prepared["resolved_effort"] or None,
            permission_mode=prepared["resolved_perm"],
            claude_bin=prepared["claude_bin"],
            workspace_dir=prepared["ws_str"],
            git_evidence=collect_git_evidence(prepared["ws_str"]),
            active_job_id=active_id,
            session_key=prepared["resolved_session_key"],
            session_mode=prepared["resolved_session_mode"],
            plan_file=prepared["resolved_plan_file"],
        )

    def _worker() -> None:
        res: Optional[dict[str, Any]] = None
        try:
            res = _run_prepared(
                prepared=prepared,
                allowed_files=allowed_files,
                verification_commands=verification_commands,
                extra_context=extra_context,
                cancel_event=job.cancel_event,
                job_id=job.job_id,
            )
        except Exception as exc:
            res = _error_response(
                "ERROR",
                f"Background worker failed: {exc}",
                model=prepared["resolved_model"],
                effort=prepared["resolved_effort"] or None,
                permission_mode=prepared["resolved_perm"],
                claude_bin=prepared["claude_bin"],
                workspace_dir=prepared["ws_str"],
                job_id=job.job_id,
                session_key=prepared["resolved_session_key"],
                session_mode=prepared["resolved_session_mode"],
                plan_file=prepared["resolved_plan_file"],
            )
        finally:
            if res is None:
                res = _error_response(
                    "ERROR",
                    "Background worker exited without result.",
                    model=prepared["resolved_model"],
                    effort=prepared["resolved_effort"] or None,
                    permission_mode=prepared["resolved_perm"],
                    claude_bin=prepared["claude_bin"],
                    workspace_dir=prepared["ws_str"],
                    job_id=job.job_id,
                    session_key=prepared["resolved_session_key"],
                    session_mode=prepared["resolved_session_mode"],
                    plan_file=prepared["resolved_plan_file"],
                )
            JOB_MANAGER.finish_job(job, res)

    threading.Thread(target=_worker, daemon=True).start()

    return {
        "status": "STARTED",
        "job_id": job.job_id,
        "workspace_dir": prepared["ws_str"],
        "model": prepared["resolved_model"],
        "effort": prepared["resolved_effort"] or None,
        "permission_mode": prepared["resolved_perm"],
        "max_turns": prepared["resolved_max_turns"],
        "timeout_seconds": prepared["resolved_timeout"],
        "claude_bin": prepared["claude_bin"],
        "session_key": prepared["resolved_session_key"],
        "session_mode": prepared["resolved_session_mode"],
        "plan_file": prepared["resolved_plan_file"],
        "error": None,
    }


def get_async_job_status(
    job_id: str,
    wait_seconds: Optional[int] = None,
    *,
    poll_cancel_event: Optional[threading.Event] = None,
) -> dict[str, Any]:
    """Long-poll status/result of an async (or active sync) job without terminating it on poll cancel."""
    if not isinstance(job_id, str) or not job_id.strip():
        return _error_response("ERROR", "job_id is required and must be a non-empty string.")
    clean_id = job_id.strip()

    if wait_seconds is None:
        resolved_wait = STATUS_DEFAULT_WAIT_SECONDS
    elif (
        isinstance(wait_seconds, bool)
        or not isinstance(wait_seconds, int)
        or not (0 <= wait_seconds <= STATUS_MAX_WAIT_SECONDS)
    ):
        return _error_response(
            "ERROR",
            f"wait_seconds must be an integer between 0 and {STATUS_MAX_WAIT_SECONDS}, got: {wait_seconds!r}",
            job_id=clean_id,
        )
    else:
        resolved_wait = wait_seconds

    job = JOB_MANAGER.get_job(clean_id)
    if job is None:
        return _error_response("ERROR", f"Unknown job_id: {clean_id}", job_id=clean_id)

    deadline = time.monotonic() + resolved_wait
    while not job.done_event.is_set():
        if poll_cancel_event is not None and poll_cancel_event.is_set():
            break
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        job.done_event.wait(timeout=min(0.1, remaining))

    if job.done_event.is_set() and job.result is not None:
        res = dict(job.result)
        res["job_id"] = job.job_id
        return res

    git_ev = collect_git_evidence(job.workspace_dir)
    return {
        "status": "RUNNING",
        "job_id": job.job_id,
        "workspace_dir": job.workspace_dir,
        "model": job.model,
        "effort": job.effort,
        "permission_mode": job.permission_mode,
        "max_turns": job.max_turns,
        "elapsed_seconds": round(time.monotonic() - job.started_at, 3),
        "timeout_seconds": job.timeout_seconds,
        "is_git_repo": git_ev["is_git_repo"],
        "changed_files": git_ev["changed_files"],
        "git_diff_stat": git_ev["git_diff_stat"],
        "error": None,
    }


def cancel_async_job(job_id: str) -> dict[str, Any]:
    """Cancel a running job, terminating its entire process tree and releasing the workspace lock."""
    if not isinstance(job_id, str) or not job_id.strip():
        return _error_response("ERROR", "job_id is required and must be a non-empty string.")
    clean_id = job_id.strip()

    job = JOB_MANAGER.get_job(clean_id)
    if job is None:
        return _error_response("ERROR", f"Unknown job_id: {clean_id}", job_id=clean_id)

    if job.done_event.is_set() and job.result is not None:
        res = dict(job.result)
        res["job_id"] = job.job_id
        res["note"] = "Job already finished before cancellation."
        return res

    job.cancel_event.set()
    job.done_event.wait(timeout=5.0)
    if job.done_event.is_set() and job.result is not None:
        res = dict(job.result)
        res["job_id"] = job.job_id
        return res

    return _error_response(
        "CANCELLED",
        "Cancellation requested; process tree termination is unwinding.",
        model=job.model,
        effort=job.effort,
        permission_mode=job.permission_mode,
        workspace_dir=job.workspace_dir,
        duration_seconds=time.monotonic() - job.started_at,
        git_evidence=collect_git_evidence(job.workspace_dir),
        job_id=job.job_id,
    )


def cancel_all_jobs(wait_seconds: float = 3.0) -> None:
    """Terminate all active Claude process trees cleanly (used on MCP server shutdown)."""
    JOB_MANAGER.cancel_all(wait_seconds=wait_seconds)


def _run_verify_prepared(
    prepared: dict[str, Any],
    allowed_files: Optional[list[str]],
    verification_commands: Optional[list[str]],
    extra_context: Optional[str],
    *,
    cancel_event: Optional[threading.Event] = None,
    job_id: Optional[str] = None,
) -> dict[str, Any]:
    ws_str = prepared["ws_str"]
    effective_plan = prepared["effective_plan"]
    resolved_plan_file = prepared["resolved_plan_file"]
    include_history = prepared["include_history"]
    include_git_diff = prepared["include_git_diff"]
    allow_bash = prepared["allow_bash"]
    diff_scope = prepared.get("diff_scope") or "last_run"
    resolved_model = prepared["resolved_model"]
    resolved_effort = prepared["resolved_effort"]
    resolved_max_turns = prepared["resolved_max_turns"]
    resolved_timeout = prepared["resolved_timeout"]
    claude_bin = prepared["claude_bin"]

    # Snapshot pre-existing state BEFORE any read so continuity writes only happen when opted in.
    state_dir_existed = _state_dir_path(ws_str).is_dir()

    # Read-only audit: NEVER create .agents/state/, never touch session-index.json or plan-history.md.
    prior_hist = build_continuity_injection(ws_str) if include_history else ""
    history_injected = bool(prior_hist)
    diff_evidence = (
        collect_verify_diff(ws_str, diff_scope=diff_scope) if include_git_diff else None
    )
    resolved_diff_scope = (
        diff_evidence.get("resolved_diff_scope") if diff_evidence else None
    )
    diff_included = bool(include_git_diff and diff_evidence is not None and diff_evidence.get("is_git_repo"))

    stdin_payload = build_verify_stdin(
        plan=effective_plan,
        allowed_files=allowed_files,
        verification_commands=verification_commands,
        prior_history=prior_hist or None,
        diff_evidence=diff_evidence,
        extra_context=extra_context,
    )

    disallowed = list(VERIFY_DISALLOWED_TOOLS)
    if not allow_bash:
        disallowed.append("Bash")

    cli_args = [
        "-p",
        _VERIFY_PROMPT,
        "--model",
        resolved_model,
    ]
    if resolved_effort:
        cli_args.extend(["--effort", resolved_effort])
    cli_args.extend([
        "--permission-mode",
        "bypassPermissions",
        "--max-turns",
        str(resolved_max_turns),
        "--no-session-persistence",
        "--output-format",
        "json",
        "--append-system-prompt",
        VERIFY_STRICT_SYSTEM_PROMPT,
        "--disallowedTools",
        ",".join(disallowed),
    ])
    if get_strict_mcp_config():
        cli_args.append("--strict-mcp-config")

    cmd = build_claude_argv(claude_bin, cli_args)
    child_env = build_child_env(claude_bin)
    child_env["PYTHONDONTWRITEBYTECODE"] = "1"

    before_snapshot = _snapshot_workspace(ws_str)
    try:
        outcome, rc, stdout_raw, stderr_raw, elapsed = _run_popen_cancellable(
            cmd=cmd,
            stdin_payload=stdin_payload,
            cwd=ws_str,
            env=child_env,
            timeout_seconds=resolved_timeout,
            cancel_event=cancel_event,
        )
    except OSError as exc:
        after_snapshot = _snapshot_workspace(ws_str)
        unexpected_mutations = _diff_snapshots(before_snapshot, after_snapshot)
        return _verify_error_response(
            "ERROR",
            f"Failed to launch Claude Code CLI '{claude_bin}': {exc}",
            verdict="ERROR",
            model=resolved_model,
            effort=resolved_effort or None,
            claude_bin=claude_bin,
            workspace_dir=ws_str,
            git_evidence=collect_git_evidence(ws_str),
            job_id=job_id,
            plan_file=resolved_plan_file,
            history_injected=history_injected,
            diff_included=diff_included,
            diff_scope=diff_scope,
            resolved_diff_scope=resolved_diff_scope,
            allow_bash=allow_bash,
            unexpected_mutations=unexpected_mutations,
        )

    after_snapshot = _snapshot_workspace(ws_str)
    unexpected_mutations = _diff_snapshots(before_snapshot, after_snapshot)
    git_ev = collect_git_evidence(ws_str)
    stderr_text = (stderr_raw or "").strip()

    if outcome == "CANCELLED":
        return _verify_error_response(
            "CANCELLED",
            "Claude Code CLI verification was cancelled and its process tree was terminated.",
            verdict="FAIL" if unexpected_mutations else "ERROR",
            model=resolved_model,
            effort=resolved_effort or None,
            claude_bin=claude_bin,
            workspace_dir=ws_str,
            exit_code=rc,
            duration_seconds=elapsed,
            result=(stdout_raw or "").strip(),
            stderr=stderr_text,
            git_evidence=git_ev,
            job_id=job_id,
            plan_file=resolved_plan_file,
            history_injected=history_injected,
            diff_included=diff_included,
            diff_scope=diff_scope,
            resolved_diff_scope=resolved_diff_scope,
            allow_bash=allow_bash,
            unexpected_mutations=unexpected_mutations,
        )

    if outcome == "TIMEOUT":
        return _verify_error_response(
            "TIMEOUT",
            f"Claude Code CLI verification timed out after {resolved_timeout}s and process tree was terminated.",
            verdict="FAIL" if unexpected_mutations else "ERROR",
            model=resolved_model,
            effort=resolved_effort or None,
            claude_bin=claude_bin,
            workspace_dir=ws_str,
            exit_code=rc,
            duration_seconds=elapsed,
            result=(stdout_raw or "").strip(),
            stderr=stderr_text,
            git_evidence=git_ev,
            job_id=job_id,
            plan_file=resolved_plan_file,
            history_injected=history_injected,
            diff_included=diff_included,
            diff_scope=diff_scope,
            resolved_diff_scope=resolved_diff_scope,
            allow_bash=allow_bash,
            unexpected_mutations=unexpected_mutations,
        )

    parsed = parse_claude_output(stdout_raw or "")
    subtype = parsed["subtype"]
    is_error_subtype = isinstance(subtype, str) and subtype.startswith("error_")
    err_msg: Optional[str] = None
    read_only_violation = bool(unexpected_mutations)

    if read_only_violation:
        status = "ERROR"
        verdict = "FAIL"
        err_msg = f"Read-only verifier unexpectedly mutated workspace files: {unexpected_mutations}"
    elif rc != 0 or parsed["is_error"] or is_error_subtype:
        status = "ERROR"
        verdict = "ERROR"
        err_msg = _format_claude_cli_error(
            "Claude Code CLI verifier",
            rc=rc,
            subtype=subtype,
            is_error_subtype=is_error_subtype,
            num_turns=parsed["num_turns"],
            resolved_max_turns=resolved_max_turns,
            result_text=parsed["result"] or "",
            stderr_text=stderr_text,
        )
    else:
        parsed_verdict = parse_verdict(parsed["result"] or "")
        if parsed_verdict is None:
            status = "ERROR"
            verdict = "ERROR"
            err_msg = "Verifier output missing required 'VERDICT: PASS|FAIL|BLOCKED' on line 1."
        else:
            status = parsed_verdict
            verdict = parsed_verdict

    payload: dict[str, Any] = {
        "status": status,
        "verdict": verdict,
        "model": resolved_model,
        "effort": resolved_effort or None,
        "permission_mode": "bypassPermissions",
        "claude_bin": claude_bin,
        "workspace_dir": ws_str,
        "exit_code": rc,
        "duration_seconds": round(elapsed, 3),
        "num_turns": parsed["num_turns"],
        "total_cost_usd": parsed["total_cost_usd"],
        "subtype": subtype,
        "session_id": parsed["session_id"],
        "plan_file": resolved_plan_file,
        "history_injected": history_injected,
        "diff_included": diff_included,
        "diff_scope": diff_scope,
        "resolved_diff_scope": resolved_diff_scope,
        "allow_bash": allow_bash,
        "read_only_violation": read_only_violation,
        "unexpected_mutations": unexpected_mutations,
        "is_git_repo": git_ev["is_git_repo"],
        "changed_files": git_ev["changed_files"],
        "git_diff_stat": git_ev["git_diff_stat"],
        "result": parsed["result"],
        "stderr": stderr_text,
        "error": err_msg,
    }
    if job_id is not None:
        payload["job_id"] = job_id
    # Persist the verifier outcome only after the mutation check has been evaluated and
    # only when continuity state already existed. A clean workspace stays untouched.
    if (
        state_dir_existed
        and not read_only_violation
        and status in ("PASS", "FAIL", "BLOCKED")
    ):
        try:
            _record_verify_outcome(
                ws_str,
                status=status,
                result_text=parsed["result"] or "",
                plan_file=resolved_plan_file,
                resolved_diff_scope=resolved_diff_scope or "workspace",
            )
        except Exception:
            pass
    return payload


def verify_plan(
    workspace_dir: str,
    plan: Optional[str] = None,
    allowed_files: Optional[list[str]] = None,
    verification_commands: Optional[list[str]] = None,
    extra_context: Optional[str] = None,
    model: Optional[str] = None,
    max_turns: Optional[int] = None,
    timeout_seconds: Optional[int] = None,
    *,
    effort: Optional[str] = None,
    plan_file: Optional[str] = None,
    include_history: bool = True,
    include_git_diff: bool = True,
    diff_scope: str = "last_run",
    allow_bash: bool = True,
    enforce_sync_cap: bool = True,
    cancel_event: Optional[threading.Event] = None,
) -> dict[str, Any]:
    """Perform an independent read-only blind verification using Claude Code CLI (default Opus)."""
    prepared, err_resp = _validate_and_prepare_verify(
        workspace_dir=workspace_dir,
        plan=plan,
        allowed_files=allowed_files,
        verification_commands=verification_commands,
        model=model,
        max_turns=max_turns,
        timeout_seconds=timeout_seconds,
        effort=effort,
        plan_file=plan_file,
        include_history=include_history,
        include_git_diff=include_git_diff,
        diff_scope=diff_scope,
        allow_bash=allow_bash,
        enforce_sync_cap=enforce_sync_cap,
    )
    if err_resp is not None or prepared is None:
        assert err_resp is not None
        return err_resp

    job, active_id = JOB_MANAGER.register_job(
        workspace_dir=prepared["ws_str"],
        model=prepared["resolved_model"],
        permission_mode="bypassPermissions",
        max_turns=prepared["resolved_max_turns"],
        timeout_seconds=prepared["resolved_timeout"],
        is_async=False,
        cancel_event=cancel_event,
        job_prefix="verify",
        lock_mode="read",
        effort=prepared["resolved_effort"] or None,
    )
    if job is None:
        return _verify_error_response(
            "BUSY",
            f"Another Claude task ({active_id}) is already running in workspace '{prepared['ws_str']}'. "
            "Wait for it or stop it with claude_execute_cancel before running claude_verify.",
            verdict="ERROR",
            model=prepared["resolved_model"],
            effort=prepared["resolved_effort"] or None,
            claude_bin=prepared["claude_bin"],
            workspace_dir=prepared["ws_str"],
            git_evidence=collect_git_evidence(prepared["ws_str"]),
            active_job_id=active_id,
            plan_file=prepared["resolved_plan_file"],
            diff_scope=prepared.get("diff_scope"),
            allow_bash=prepared["allow_bash"],
        )

    res: Optional[dict[str, Any]] = None
    try:
        res = _run_verify_prepared(
            prepared=prepared,
            allowed_files=allowed_files,
            verification_commands=verification_commands,
            extra_context=extra_context,
            cancel_event=job.cancel_event,
            job_id=job.job_id,
        )
        return res
    finally:
        if res is None:
            res = _verify_error_response(
                "ERROR",
                "Unexpected internal failure while verifying with Claude Code CLI.",
                verdict="ERROR",
                model=prepared["resolved_model"],
                effort=prepared["resolved_effort"] or None,
                claude_bin=prepared["claude_bin"],
                workspace_dir=prepared["ws_str"],
                job_id=job.job_id,
                plan_file=prepared["resolved_plan_file"],
                diff_scope=prepared.get("diff_scope"),
                allow_bash=prepared["allow_bash"],
            )
        JOB_MANAGER.finish_job(job, res)


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Execute or read-only verify an Antigravity-approved plan with local Claude Code CLI."
    )
    parser.add_argument(
        "--healthcheck",
        action="store_true",
        help="Verify local claude CLI binary and auth directory without invoking LLM.",
    )
    parser.add_argument(
        "--handoff",
        action="store_true",
        help="Print a zero-LLM, read-only handoff packet for the next agent session.",
    )
    parser.add_argument(
        "--handoff-mode",
        default="continue",
        help="Handoff packet mode: continue (default), fix_review, or new_plan.",
    )
    parser.add_argument(
        "--search",
        dest="search_query",
        default=None,
        help="Optional case-insensitive substring to search across cached state files.",
    )
    parser.add_argument(
        "--max-bytes",
        type=int,
        default=None,
        help="Maximum handoff packet size in bytes (default: 3072).",
    )
    parser.add_argument(
        "--diff-scope",
        default="last_run",
        help="Verify diff scope: last_run (default) or workspace.",
    )
    parser.add_argument(
        "--rollback",
        action="store_true",
        help="Restore workspace files to the last pre-run tree checkpoint (CLI-only).",
    )
    parser.add_argument(
        "--verify",
        action="store_true",
        help="Run independent read-only blind verification (default CLAUDE_VERIFY_MODEL or opus).",
    )
    parser.add_argument(
        "--no-diff",
        action="store_true",
        help="Do not inject git diff into verify prompt (--verify only).",
    )
    parser.add_argument(
        "--no-bash",
        action="store_true",
        help="Disable Bash tool during verification (--verify only).",
    )
    parser.add_argument(
        "--workspace",
        default=None,
        help="Target workspace directory (defaults to '.' during execution/verification).",
    )
    parser.add_argument("--plan", help="Approved implementation plan text or fix-round instructions.")
    parser.add_argument("--plan-file", help="Path to Markdown/text file containing approved plan.")
    parser.add_argument(
        "--session-key",
        help="Logical session continuity bucket key (defaults to 'workspace').",
    )
    parser.add_argument(
        "--session-mode",
        help="Session policy: auto (default), resume, or fresh.",
    )
    parser.add_argument(
        "--resume-session-id",
        help="Explicit Claude session_id to resume directly.",
    )
    parser.add_argument(
        "--no-history",
        action="store_true",
        help="Disable injecting .agents/state/plan-history.md on fresh/verify runs.",
    )
    parser.add_argument(
        "--model",
        help="Claude model alias or ID (default: CLAUDE_MODEL/sonnet for execute, CLAUDE_VERIFY_MODEL/opus for verify).",
    )
    parser.add_argument(
        "--effort",
        help="Claude CLI reasoning effort: low, medium, high, xhigh, or max (default: CLAUDE_EFFORT/high for execute, CLAUDE_VERIFY_EFFORT/high for verify).",
    )
    parser.add_argument(
        "--permission-mode",
        help="Claude CLI permission mode (default: CLAUDE_PERMISSION_MODE or bypassPermissions).",
    )
    parser.add_argument("--max-turns", type=int, help="Maximum turns (1-100, default: 40 exec / 25 verify).")
    parser.add_argument(
        "--timeout",
        type=int,
        help="Timeout in seconds for standalone CLI execution (1-1800, default: CLAUDE_ASYNC_TIMEOUT_SECONDS or 900).",
    )
    parser.add_argument(
        "--allowed-file",
        action="append",
        dest="allowed_files",
        help="Authorized file path (repeatable).",
    )
    parser.add_argument(
        "--verify-cmd",
        action="append",
        dest="verification_commands",
        help="Required verification command (repeatable).",
    )
    parser.add_argument("--extra-context", help="Optional extra context passed to Claude.")

    args = parser.parse_args(argv)

    if args.healthcheck:
        res = healthcheck(workspace_dir=args.workspace)
        print(json.dumps(res, ensure_ascii=False, indent=2))
        return 0 if res.get("ok") else 1

    if args.handoff:
        max_bytes = (
            args.max_bytes
            if args.max_bytes is not None
            else DEFAULT_HANDOFF_MAX_BYTES
        )
        res = build_handoff_packet(
            workspace_dir=args.workspace or ".",
            mode=args.handoff_mode,
            max_bytes=max_bytes,
            search_query=args.search_query,
        )
        print(json.dumps(res, ensure_ascii=False, indent=2))
        return 0 if res.get("ok") else 1

    if args.rollback:
        res = rollback_last_run(
            args.workspace or ".", session_key=args.session_key
        )
        print(json.dumps(res, ensure_ascii=False, indent=2))
        return 0 if res.get("ok") else 1

    if args.verify:
        res = verify_plan(
            workspace_dir=args.workspace or ".",
            plan=args.plan,
            plan_file=args.plan_file,
            allowed_files=args.allowed_files,
            verification_commands=args.verification_commands,
            extra_context=args.extra_context,
            model=args.model,
            effort=args.effort,
            max_turns=args.max_turns,
            timeout_seconds=args.timeout,
            include_history=not args.no_history,
            include_git_diff=not args.no_diff,
            diff_scope=args.diff_scope,
            allow_bash=not args.no_bash,
            enforce_sync_cap=False,
        )
        print(json.dumps(res, ensure_ascii=False, indent=2))
        status = res.get("status")
        if status == "PASS":
            return 0
        if status == "BLOCKED":
            return 2
        if status == "FAIL":
            return 3
        return 1

    res = execute_plan(
        workspace_dir=args.workspace or ".",
        plan=args.plan,
        plan_file=args.plan_file,
        session_key=args.session_key,
        session_mode=args.session_mode,
        resume_session_id=args.resume_session_id,
        include_history=not args.no_history,
        allowed_files=args.allowed_files,
        verification_commands=args.verification_commands,
        extra_context=args.extra_context,
        model=args.model,
        effort=args.effort,
        max_turns=args.max_turns,
        permission_mode=args.permission_mode,
        timeout_seconds=args.timeout,
        enforce_sync_cap=False,
    )
    print(json.dumps(res, ensure_ascii=False, indent=2))
    status = res.get("status")
    if status == "DONE":
        return 0
    if status == "BLOCKED":
        return 2
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
'@
Write-SafeFile -RelativePath '.agents/plugins/claude-executor/claude_runner.py' -Content $content7

$content8 = @'
#!/usr/bin/env python3
"""Shared headless runner for Antigravity CLI (agy) verification, fallback execution, and on-demand planning."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any, Optional

_PLUGIN_DIR = str(Path(__file__).resolve().parent)
if _PLUGIN_DIR not in sys.path:
    sys.path.insert(0, _PLUGIN_DIR)

import claude_runner  # noqa: E402

DEFAULT_PLANNER_SESSION_KEY = "planner:workspace"
DEFAULT_AGY_EXECUTOR_SESSION_KEY = "agy:workspace"
DEFAULT_AGY_VERIFY_MODEL = "gemini-4-carbon-high"
DEFAULT_AGY_EXECUTE_MODEL = "gemini-4-hydrogen-xhigh"
VALID_AGY_EFFORTS = frozenset({"low", "medium", "high", "xhigh", "max"})
VALID_AGY_PLAN_STATUSES = frozenset({"READY", "NEED_CLARIFICATION", "BLOCKED"})
MAX_AGY_PROMPT_BYTES = 96000

_RESUME_MISSING_RE = re.compile(
    r"(?i)(no conversation found|conversation[^.\n]*not found|session[^.\n]*not found|"
    r"invalid (?:conversation|session)|unknown (?:conversation|session)|"
    r"could not find (?:conversation|session))"
)

AGY_PLAN_INSTRUCTIONS = (
    "## Role & Strict Read-Only Planning Rules (Antigravity CLI Planner)\n\n"
    "You are acting strictly as a read-only software architect and planner in --mode plan.\n"
    "Hard rules:\n"
    "1. NEVER create, edit, overwrite, or delete any file in the workspace, and NEVER run mutating shell or git commands.\n"
    "2. Reuse existing modules, interfaces, and symbols listed in Prior Completed Plans & Existing Artifacts; do not propose duplicating existing helpers.\n"
    "3. Respect External Workspace Changes Since Your Last Turn when present as authoritative workspace state.\n"
    "4. If critical requirements are ambiguous or have high-risk side effects, start line 1 with 'STATUS: NEED_CLARIFICATION' followed by at most 3 targeted questions.\n"
    "5. If essential files, specs, or access needed to plan accurately are missing, start line 1 with 'STATUS: BLOCKED' followed by a missing-items checklist.\n"
    "6. Otherwise, start line 1 with 'STATUS: READY', followed by: Current State & Reusable Interfaces, Scope & Step-by-Step Actions (or a 2-5 line compact delta plan for small updates), Required Verification Commands, and Definition of Done.\n"
    "Keep the STATUS: line in English; match the language used in the user request for narrative text.\n"
)

AGY_VERIFY_INSTRUCTIONS = (
    "## Role & Strict Read-Only Blind Audit Rules (Antigravity CLI Verifier)\n\n"
    "Perform an independent, strictly read-only blind audit of the approved plan, workspace code, git diff, and objective runtime evidence.\n"
    "Hard rules:\n"
    "1. NEVER create, edit, overwrite, or delete any workspace file, NEVER run mutating commands, and NEVER leave __pycache__/.pyc files behind (use PYTHONDONTWRITEBYTECODE=1 python3 -B - and /tmp for temp probes).\n"
    "2. Zero trust: verify directly against workspace files and objective checks; do not assume unverified behavior works.\n"
    "3. Check Prior Completed Plans & Existing Artifacts (when present) for cross-plan contract breaks or code duplication.\n"
    "4. Output line 1 MUST be strictly 'VERDICT: PASS', 'VERDICT: FAIL', or 'VERDICT: BLOCKED', followed by Verified Evidence, Issues (Critical, Important, Minor; write None when empty), Blockers (when BLOCKED), and Next Steps.\n"
    "Keep VERDICT: PASS|FAIL|BLOCKED and Critical|Important|Minor headings in English; match the language used in the plan for narrative explanations.\n"
)


AGY_EXECUTE_INSTRUCTIONS = (
    "## Role & Strict Execution Rules (Antigravity CLI Executor)\n\n"
    "You are acting unattended as the implementation engineer executing an approved plan.\n"
    "Hard rules:\n"
    "1. Only create or modify files authorized by the approved plan (and within Authorized File Scope when specified).\n"
    "2. If Interrupted Run Recovery or External Workspace Changes appear, preserve valid partial work on disk and continue incrementally from the failed step rather than discarding working edits.\n"
    "3. Run all specified verification commands (use PYTHONDONTWRITEBYTECODE=1 python3 -B for Python probes so no __pycache__/.pyc files are left behind).\n"
    "4. If critical specifications, entrypoints, or prerequisites are missing, start line 1 with 'STATUS: BLOCKED' followed by a missing-items checklist.\n"
    "5. Otherwise, start line 1 with 'STATUS: DONE', followed by Modified files, Key symbols/interfaces, Verification commands & real outputs, and Remaining risks.\n"
    "Keep STATUS: tags in English; match the language used in the plan for narrative explanations.\n"
)


def get_default_agy_plan_model() -> str:
    """Return AGY_PLAN_MODEL override or empty string (follow agy CLI settings.json)."""
    return os.environ.get("AGY_PLAN_MODEL", "").strip()


def get_default_agy_verify_model() -> str:
    """Return AGY_VERIFY_MODEL override, DEFAULT_AGY_VERIFY_MODEL when unset, or '' if explicitly empty."""
    if "AGY_VERIFY_MODEL" in os.environ:
        return os.environ["AGY_VERIFY_MODEL"].strip()
    return DEFAULT_AGY_VERIFY_MODEL


def get_default_agy_execute_model() -> str:
    """Return AGY_EXECUTE_MODEL override, DEFAULT_AGY_EXECUTE_MODEL when unset, or '' if explicitly empty."""
    if "AGY_EXECUTE_MODEL" in os.environ:
        return os.environ["AGY_EXECUTE_MODEL"].strip()
    return DEFAULT_AGY_EXECUTE_MODEL


def get_default_agy_effort() -> str:
    raw = os.environ.get("AGY_EFFORT", "").strip().lower()
    if raw in VALID_AGY_EFFORTS:
        return raw
    return ""


def get_agy_sandbox() -> bool:
    raw = os.environ.get("AGY_SANDBOX", "1").strip().lower()
    return raw not in {"0", "false", "no", "off"}


def find_agy_binary() -> tuple[Optional[str], Optional[str]]:
    """Locate the local Antigravity CLI (agy) binary in WSL/POSIX or PATH."""
    override = os.environ.get("AGY_BIN", "").strip()
    if override:
        expanded = os.path.expanduser(override)
        if claude_runner._is_executable_file(expanded):
            return expanded, None
        return None, f"AGY_BIN points to invalid/non-executable file: {expanded}"

    found = shutil.which("agy")
    if found and claude_runner._is_executable_file(found):
        return found, None

    home = str(Path.home())
    candidates = [
        os.path.join(home, ".local", "bin", "agy"),
        os.path.join(home, ".antigravity", "bin", "agy"),
        "/usr/local/bin/agy",
        "/opt/homebrew/bin/agy",
    ]
    for cand in candidates:
        if claude_runner._is_executable_file(cand):
            return cand, None

    return (
        None,
        "Antigravity CLI ('agy') not found in PATH or standard install paths. "
        "Install agy CLI or set AGY_BIN.",
    )


def build_agy_child_env(agy_bin: str) -> dict[str, str]:
    """Prepare child environment with agy binary dir on PATH and bytecode suppressed."""
    env = os.environ.copy()
    env["PYTHONDONTWRITEBYTECODE"] = "1"

    bin_path = Path(agy_bin)
    extra_dirs: list[str] = []
    for candidate_dir in (str(bin_path.parent), str(bin_path.resolve().parent)):
        if candidate_dir and candidate_dir not in extra_dirs:
            extra_dirs.append(candidate_dir)

    existing_path = env.get("PATH", "")
    existing_parts = [p for p in existing_path.split(os.pathsep) if p] if existing_path else []
    merged_parts = extra_dirs + [p for p in existing_parts if p not in extra_dirs]
    env["PATH"] = os.pathsep.join(merged_parts)
    return env


def parse_agy_output(stdout: str) -> dict[str, Any]:
    """Parse JSON output from `agy --output-format json`, with reverse line-scan fallback."""
    stripped = (stdout or "").strip()
    empty_res: dict[str, Any] = {
        "parsed_json": False,
        "response": stripped,
        "raw_status": None,
        "is_error": False,
        "error_detail": "",
        "conversation_id": None,
        "num_turns": None,
        "duration_seconds": None,
        "usage": None,
    }
    if not stripped:
        return empty_res

    obj: Optional[dict[str, Any]] = None
    try:
        loaded = json.loads(stripped)
        if isinstance(loaded, dict):
            obj = loaded
    except json.JSONDecodeError:
        for line in reversed(stripped.splitlines()):
            candidate = line.strip()
            if not candidate.startswith("{"):
                continue
            try:
                loaded = json.loads(candidate)
                if isinstance(loaded, dict):
                    obj = loaded
                    break
            except json.JSONDecodeError:
                continue

    if obj is None:
        return empty_res

    raw_resp = obj.get("response")
    if raw_resp is None:
        for alt_key in ("result", "text", "output"):
            if alt_key in obj and obj[alt_key] is not None:
                raw_resp = obj[alt_key]
                break
    resp_text = (
        raw_resp
        if isinstance(raw_resp, str)
        else ("" if raw_resp is None else json.dumps(raw_resp, ensure_ascii=False))
    )

    raw_status = obj.get("status")
    status_err = (
        isinstance(raw_status, str) and raw_status.strip().upper() != "SUCCESS"
    )
    conv_id = obj.get("conversation_id") or obj.get("session_id")
    err_obj = obj.get("error")
    err_detail = (
        err_obj
        if isinstance(err_obj, str)
        else (json.dumps(err_obj, ensure_ascii=False) if err_obj else "")
    )
    usage = obj.get("usage") if isinstance(obj.get("usage"), dict) else None
    is_error = bool(obj.get("is_error", False)) or status_err or bool(err_detail)

    return {
        "parsed_json": True,
        "response": resp_text,
        "raw_status": raw_status,
        "is_error": is_error,
        "error_detail": err_detail,
        "conversation_id": str(conv_id).strip() if isinstance(conv_id, str) and conv_id.strip() else None,
        "num_turns": obj.get("num_turns"),
        "duration_seconds": claude_runner._safe_float(obj.get("duration_seconds"), 0.0)
        if obj.get("duration_seconds") is not None
        else None,
        "usage": usage,
    }


def parse_plan_status(response_text: str) -> Optional[str]:
    """Extract STATUS: READY|NEED_CLARIFICATION|BLOCKED from line 1; fail closed if missing."""
    for line in (response_text or "").splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        match = re.match(
            r"^\s*(?:\*\*)?STATUS:\s*(READY|NEED_CLARIFICATION|BLOCKED)(?:\*\*)?\b",
            stripped,
        )
        return match.group(1) if match else None
    return None


def _missing_marker_error(
    role: str, marker_msg: str, resp_text: str, stderr_text: str
) -> str:
    if not resp_text.strip() and stderr_text:
        return f"{role} produced empty output; stderr: {stderr_text[:600]}"
    return marker_msg


def _build_agy_cli_args(
    *,
    prompt_text: str,
    timeout_seconds: int,
    model: str = "",
    effort: str = "",
    resume_conv_id: Optional[str] = None,
    mode: str = "plan",
    allow_bash: bool = True,
) -> list[str]:
    # Verified agy 1.5.18 contract:
    # - Never pass --disable-slash-commands with --mode plan (disables plan mode).
    # - Plan/verify passes --mode plan plus --dangerously-skip-permissions (when allow_bash=True)
    #   and --sandbox so headless read-only Bash checks avoid confirmation auto-denial while host
    #   directory snapshots (read_only_violation) strictly enforce workspace immutability.
    # - Execute omits --mode (--mode auto warns on this account) and passes --dangerously-skip-permissions.
    # - Always attach prompt via -p=<prompt> because agy ignores piped stdin.
    # - Ensure prompt never begins with '/' so slash expansion is never triggered.
    safe_prompt = prompt_text.lstrip()
    if not safe_prompt or safe_prompt.startswith("/"):
        safe_prompt = "## Request\n\n" + safe_prompt

    if mode == "execute":
        args: list[str] = [
            "--dangerously-skip-permissions",
            "--output-format",
            "json",
            "--print-timeout",
            f"{int(max(1, timeout_seconds))}s",
        ]
    elif mode == "plan":
        args = ["--mode", "plan"]
        if allow_bash:
            args.append("--dangerously-skip-permissions")
        args.extend([
            "--output-format",
            "json",
            "--print-timeout",
            f"{int(max(1, timeout_seconds))}s",
        ])
    else:
        raise ValueError(f"Unsupported agy CLI mode: {mode!r}")
    if get_agy_sandbox():
        args.append("--sandbox")
    if model:
        args.extend(["--model", model])
    if effort:
        args.extend(["--effort", effort])
    if resume_conv_id:
        args.extend(["--resume", resume_conv_id])
    args.append(f"-p={safe_prompt}")
    return args


def _validate_save_plan_file(
    ws_path: Path, raw_save_plan_file: Any
) -> tuple[Optional[Path], Optional[str], Optional[str]]:
    """Validate optional save_plan_file is strictly inside <workspace>/.agents/plans/."""
    if raw_save_plan_file is None:
        return None, None, None
    if not isinstance(raw_save_plan_file, str) or not raw_save_plan_file.strip():
        return None, None, "save_plan_file must be a non-empty file path string."
    raw_str = raw_save_plan_file.strip()
    if "\n" in raw_str or "\r" in raw_str or "\x00" in raw_str:
        return None, None, "save_plan_file must be a single-line path without control characters."

    try:
        ws_root = ws_path.resolve()
        plans_root = (ws_root / ".agents" / "plans").resolve()
        if plans_root != ws_root and ws_root not in plans_root.parents:
            return None, None, "Target .agents/plans directory resolves outside workspace_dir."
        candidate_raw = Path(raw_str).expanduser()
        target = (
            candidate_raw.resolve()
            if candidate_raw.is_absolute()
            else (ws_root / candidate_raw).resolve()
        )
    except OSError as exc:
        return None, None, f"Invalid save_plan_file '{raw_save_plan_file}': {exc}"

    if target == plans_root or plans_root not in target.parents or ws_root not in target.parents:
        return (
            None,
            None,
            f"save_plan_file must resolve strictly inside '.agents/plans/', got: {raw_save_plan_file}",
        )
    if target.exists() and target.is_dir():
        return None, None, f"save_plan_file points to a directory: {target}"

    rel_posix = target.relative_to(ws_root).as_posix()
    return target, rel_posix, None


def _resolve_model_and_effort(
    model: Optional[str], default_model: str, effort: Optional[str]
) -> tuple[Optional[str], Optional[str], Optional[str]]:
    if model is not None and not isinstance(model, str):
        return None, None, f"model must be a string when provided, got: {model!r}"
    resolved_model = (
        model.strip() if isinstance(model, str) and model.strip() else default_model
    )

    if effort is not None and not isinstance(effort, str):
        return None, None, f"effort must be a string when provided, got: {effort!r}"
    if isinstance(effort, str):
        cleaned_eff = effort.strip().lower()
        if cleaned_eff == "":
            return None, None, "effort must be a non-empty string when explicitly provided."
        if cleaned_eff not in VALID_AGY_EFFORTS:
            return (
                None,
                None,
                f"Invalid effort '{cleaned_eff}'. Allowed: {sorted(VALID_AGY_EFFORTS)}",
            )
        resolved_effort = cleaned_eff
    else:
        resolved_effort = get_default_agy_effort()
    return resolved_model, resolved_effort, None


def _bound_agy_plan_prompt(
    *,
    request: str,
    prior_history: Optional[str],
    external_drift: Optional[str],
    extra_context: Optional[str],
) -> str:
    def _assemble(hist: Optional[str], drift: Optional[str], extra: Optional[str]) -> str:
        sections = [
            f"## User Request for Planning\n\n{request.strip()}\n",
            AGY_PLAN_INSTRUCTIONS,
        ]
        if hist and hist.strip():
            sections.append(
                "## Prior Completed Plans & Existing Artifacts (Reuse Existing Code, Avoid Duplication)\n\n"
                f"{hist.strip()}\n"
            )
        if drift and drift.strip():
            sections.append(
                "## External Workspace Changes Since Your Last Turn (Treat As Authoritative)\n\n"
                f"{drift.strip()}\n"
            )
        if extra and extra.strip():
            sections.append(f"## Additional Planning Context\n\n{extra.strip()}\n")
        return "\n".join(sections)

    prompt = _assemble(prior_history, external_drift, extra_context)
    if len(prompt.encode("utf-8")) <= MAX_AGY_PROMPT_BYTES:
        return prompt

    for drift_cap in (4096, 1024, 0):
        d_val = (
            claude_runner._truncate_utf8(external_drift, drift_cap)
            + "\n...[external drift truncated]"
            if external_drift and drift_cap > 0
            else None
        )
        prompt = _assemble(prior_history, d_val, extra_context)
        if len(prompt.encode("utf-8")) <= MAX_AGY_PROMPT_BYTES:
            return prompt

    for hist_cap in (1024, 0):
        h_val = (
            claude_runner._truncate_utf8(prior_history, hist_cap)
            + "\n...[history truncated]"
            if prior_history and hist_cap > 0
            else None
        )
        prompt = _assemble(h_val, None, extra_context)
        if len(prompt.encode("utf-8")) <= MAX_AGY_PROMPT_BYTES:
            return prompt

    note = "\n\n... [prompt truncated cleanly for CLI argv byte limit]\n"
    return (
        claude_runner._truncate_utf8(prompt, MAX_AGY_PROMPT_BYTES - len(note.encode("utf-8")))
        + note
    )


def _bound_agy_verify_prompt(
    *,
    plan: str,
    allowed_files: Optional[list[str]],
    verification_commands: Optional[list[str]],
    prior_history: Optional[str],
    diff_evidence: Optional[dict[str, Any]],
    extra_context: Optional[str],
    allow_bash: bool,
) -> str:
    bash_note = (
        ""
        if allow_bash
        else "\n\n## Strict Tool Constraint\n\nBash and shell execution are DISABLED for this audit (`allow_bash=false`). Perform static read-only inspection only without invoking shell commands.\n"
    )
    merged_extra = (
        (extra_context.strip() + bash_note)
        if extra_context and extra_context.strip()
        else (bash_note.strip() or None)
    )

    def _assemble(hist: Optional[str], diff_ev: Optional[dict[str, Any]]) -> str:
        body = claude_runner.build_verify_stdin(
            plan=plan,
            allowed_files=allowed_files,
            verification_commands=verification_commands,
            prior_history=hist,
            diff_evidence=diff_ev,
            extra_context=merged_extra,
        )
        return f"{AGY_VERIFY_INSTRUCTIONS}\n{body}"

    prompt = _assemble(prior_history, diff_evidence)
    if len(prompt.encode("utf-8")) <= MAX_AGY_PROMPT_BYTES:
        return prompt

    if diff_evidence and diff_evidence.get("git_diff"):
        for diff_cap in (16384, 8192, 2048, 0):
            shrunk = dict(diff_evidence)
            if diff_cap == 0:
                shrunk["git_diff"] = "... [diff omitted due to CLI prompt limit; inspect files directly]"
            else:
                shrunk["git_diff"] = (
                    claude_runner._truncate_utf8(str(diff_evidence["git_diff"]), diff_cap)
                    + f"\n... [diff truncated at {diff_cap} bytes]"
                )
            prompt = _assemble(prior_history, shrunk)
            if len(prompt.encode("utf-8")) <= MAX_AGY_PROMPT_BYTES:
                return prompt
        diff_evidence = shrunk

    for hist_cap in (1024, 0):
        h_val = (
            claude_runner._truncate_utf8(prior_history, hist_cap)
            if prior_history and hist_cap > 0
            else None
        )
        prompt = _assemble(h_val, diff_evidence)
        if len(prompt.encode("utf-8")) <= MAX_AGY_PROMPT_BYTES:
            return prompt

    note = "\n\n... [prompt truncated cleanly for CLI argv byte limit]\n"
    return (
        claude_runner._truncate_utf8(prompt, MAX_AGY_PROMPT_BYTES - len(note.encode("utf-8")))
        + note
    )


def _bound_agy_execute_prompt(
    *,
    plan: str,
    allowed_files: Optional[list[str]],
    verification_commands: Optional[list[str]],
    prior_history: Optional[str],
    external_drift: Optional[str],
    extra_context: Optional[str],
) -> str:
    def _assemble(hist: Optional[str], drift: Optional[str]) -> str:
        body = claude_runner.build_plan_stdin(
            plan=plan,
            allowed_files=allowed_files,
            verification_commands=verification_commands,
            extra_context=extra_context,
            prior_history=hist,
            external_drift=drift,
        )
        return f"{AGY_EXECUTE_INSTRUCTIONS}\n{body}"

    prompt = _assemble(prior_history, external_drift)
    if len(prompt.encode("utf-8")) <= MAX_AGY_PROMPT_BYTES:
        return prompt

    for drift_cap in (4096, 1024, 0):
        d_val = (
            claude_runner._truncate_utf8(external_drift, drift_cap)
            + "\n...[external drift truncated]"
            if external_drift and drift_cap > 0
            else None
        )
        prompt = _assemble(prior_history, d_val)
        if len(prompt.encode("utf-8")) <= MAX_AGY_PROMPT_BYTES:
            return prompt

    for hist_cap in (1024, 0):
        h_val = (
            claude_runner._truncate_utf8(prior_history, hist_cap)
            + "\n...[history truncated]"
            if prior_history and hist_cap > 0
            else None
        )
        prompt = _assemble(h_val, None)
        if len(prompt.encode("utf-8")) <= MAX_AGY_PROMPT_BYTES:
            return prompt

    note = "\n\n... [prompt truncated cleanly for CLI argv byte limit]\n"
    return (
        claude_runner._truncate_utf8(prompt, MAX_AGY_PROMPT_BYTES - len(note.encode("utf-8")))
        + note
    )


def _execute_error_response(
    status: str,
    error: str,
    *,
    model: Optional[str] = None,
    effort: Optional[str] = None,
    agy_bin: Optional[str] = None,
    workspace_dir: str = "",
    exit_code: Optional[int] = None,
    duration_seconds: float = 0.0,
    result: str = "",
    stderr: str = "",
    git_evidence: Optional[dict[str, Any]] = None,
    job_id: Optional[str] = None,
    active_job_id: Optional[str] = None,
    session_key: Optional[str] = None,
    session_mode: Optional[str] = None,
    session_action: Optional[str] = None,
    session_fallback: Optional[bool] = None,
    plan_file: Optional[str] = None,
    run_changed_files: Optional[list[str]] = None,
) -> dict[str, Any]:
    ev = git_evidence if git_evidence is not None else {
        "is_git_repo": False,
        "changed_files": [],
        "git_diff_stat": "",
    }
    payload: dict[str, Any] = {
        "status": status,
        "model": model or None,
        "effort": effort or None,
        "agy_bin": agy_bin,
        "workspace_dir": workspace_dir,
        "exit_code": exit_code,
        "duration_seconds": round(duration_seconds, 3),
        "cli_duration_seconds": None,
        "num_turns": None,
        "usage": None,
        "conversation_id": None,
        "is_git_repo": ev["is_git_repo"],
        "changed_files": ev["changed_files"],
        "git_diff_stat": ev["git_diff_stat"],
        "run_changed_files": run_changed_files if run_changed_files is not None else [],
        "result": result,
        "stderr": stderr,
        "error": error,
    }
    if job_id is not None:
        payload["job_id"] = job_id
    if active_job_id is not None:
        payload["active_job_id"] = active_job_id
    if session_key is not None:
        payload["session_key"] = session_key
    if session_mode is not None:
        payload["session_mode"] = session_mode
    if session_action is not None:
        payload["session_action"] = session_action
    if session_fallback is not None:
        payload["session_fallback"] = session_fallback
    if plan_file is not None:
        payload["plan_file"] = plan_file
    return payload


def _plan_error_response(
    status: str,
    error: str,
    *,
    model: Optional[str] = None,
    effort: Optional[str] = None,
    agy_bin: Optional[str] = None,
    workspace_dir: str = "",
    exit_code: Optional[int] = None,
    duration_seconds: float = 0.0,
    result: str = "",
    stderr: str = "",
    git_evidence: Optional[dict[str, Any]] = None,
    job_id: Optional[str] = None,
    active_job_id: Optional[str] = None,
    session_key: Optional[str] = None,
    session_mode: Optional[str] = None,
    session_action: Optional[str] = None,
    session_fallback: Optional[bool] = None,
    saved_plan_file: Optional[str] = None,
    unexpected_mutations: Optional[list[str]] = None,
) -> dict[str, Any]:
    ev = git_evidence if git_evidence is not None else {
        "is_git_repo": False,
        "changed_files": [],
        "git_diff_stat": "",
    }
    mutations = list(unexpected_mutations) if unexpected_mutations else []
    payload: dict[str, Any] = {
        "status": status,
        "model": model or None,
        "effort": effort or None,
        "agy_bin": agy_bin,
        "workspace_dir": workspace_dir,
        "exit_code": exit_code,
        "duration_seconds": round(duration_seconds, 3),
        "cli_duration_seconds": None,
        "num_turns": None,
        "usage": None,
        "conversation_id": None,
        "saved_plan_file": saved_plan_file,
        "history_injected": False,
        "external_drift_injected": False,
        "external_drift_files": [],
        "read_only_violation": bool(mutations),
        "unexpected_mutations": mutations,
        "is_git_repo": ev["is_git_repo"],
        "changed_files": ev["changed_files"],
        "result": result,
        "stderr": stderr,
        "error": error,
    }
    if job_id is not None:
        payload["job_id"] = job_id
    if active_job_id is not None:
        payload["active_job_id"] = active_job_id
    if session_key is not None:
        payload["session_key"] = session_key
    if session_mode is not None:
        payload["session_mode"] = session_mode
    if session_action is not None:
        payload["session_action"] = session_action
    if session_fallback is not None:
        payload["session_fallback"] = session_fallback
    return payload


def _verify_error_response(
    status: str,
    error: str,
    *,
    verdict: str = "ERROR",
    model: Optional[str] = None,
    effort: Optional[str] = None,
    agy_bin: Optional[str] = None,
    workspace_dir: str = "",
    exit_code: Optional[int] = None,
    duration_seconds: float = 0.0,
    result: str = "",
    stderr: str = "",
    git_evidence: Optional[dict[str, Any]] = None,
    job_id: Optional[str] = None,
    active_job_id: Optional[str] = None,
    plan_file: Optional[str] = None,
    history_injected: bool = False,
    diff_included: bool = False,
    diff_scope: Optional[str] = None,
    resolved_diff_scope: Optional[str] = None,
    allow_bash: bool = True,
    unexpected_mutations: Optional[list[str]] = None,
) -> dict[str, Any]:
    ev = git_evidence if git_evidence is not None else {
        "is_git_repo": False,
        "changed_files": [],
        "git_diff_stat": "",
    }
    mutations = list(unexpected_mutations) if unexpected_mutations else []
    payload: dict[str, Any] = {
        "status": status,
        "verdict": verdict,
        "model": model or None,
        "effort": effort or None,
        "agy_bin": agy_bin,
        "workspace_dir": workspace_dir,
        "exit_code": exit_code,
        "duration_seconds": round(duration_seconds, 3),
        "cli_duration_seconds": None,
        "num_turns": None,
        "usage": None,
        "conversation_id": None,
        "plan_file": plan_file,
        "history_injected": history_injected,
        "diff_included": diff_included,
        "diff_scope": diff_scope,
        "resolved_diff_scope": resolved_diff_scope,
        "allow_bash": allow_bash,
        "read_only_violation": bool(mutations),
        "unexpected_mutations": mutations,
        "is_git_repo": ev["is_git_repo"],
        "changed_files": ev["changed_files"],
        "git_diff_stat": ev["git_diff_stat"],
        "result": result,
        "stderr": stderr,
        "error": error,
    }
    if job_id is not None:
        payload["job_id"] = job_id
    if active_job_id is not None:
        payload["active_job_id"] = active_job_id
    return payload


def agy_healthcheck(workspace_dir: Optional[str] = None) -> dict[str, Any]:
    """Zero-LLM readiness check for local Antigravity CLI (agy) and workspace state."""
    agy_bin, err = find_agy_binary()
    settings_path = Path.home() / ".gemini" / "antigravity-cli" / "settings.json"
    settings_exists = settings_path.is_file()

    version_str: Optional[str] = None
    version_rc: Optional[int] = None
    if agy_bin:
        try:
            proc = subprocess.run(
                [agy_bin, "--version"],
                env=build_agy_child_env(agy_bin),
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=15,
            )
            version_rc = proc.returncode
            out = (proc.stdout or proc.stderr or "").strip()
            version_str = out or None
            if proc.returncode != 0:
                err = f"'agy --version' exited with code {proc.returncode}: {out}"
        except subprocess.TimeoutExpired:
            err = "'agy --version' timed out after 15s"
        except OSError as exc:
            err = f"Failed to execute '{agy_bin} --version': {exc}"

    ws_ok, ws_state, ws_err = claude_runner._collect_workspace_state_summary(workspace_dir)
    if ws_err and err is None:
        err = ws_err

    sync_to = claude_runner.get_default_timeout_seconds(sync=True)
    res: dict[str, Any] = {
        "ok": bool(agy_bin and version_rc == 0 and ws_ok),
        "agy_bin": agy_bin,
        "version": version_str,
        "settings_path": str(settings_path),
        "settings_exists": settings_exists,
        "default_plan_model": get_default_agy_plan_model() or None,
        "default_verify_model": get_default_agy_verify_model() or None,
        "default_execute_model": get_default_agy_execute_model() or None,
        "default_effort": get_default_agy_effort() or None,
        "sandbox_enabled": get_agy_sandbox(),
        "default_sync_timeout_seconds": sync_to,
        "default_async_timeout_seconds": claude_runner.get_default_timeout_seconds(sync=False),
        "active_jobs": claude_runner.JOB_MANAGER.active_count(),
        "error": err,
    }
    if ws_state is not None:
        res["workspace_state"] = ws_state
    return res


def _validate_and_prepare_plan(
    workspace_dir: str,
    request: str,
    *,
    save_plan_file: Optional[str] = None,
    session_key: Optional[str] = None,
    session_mode: Optional[str] = None,
    resume_conversation_id: Optional[str] = None,
    include_history: bool = True,
    model: Optional[str] = None,
    effort: Optional[str] = None,
    timeout_seconds: Optional[int] = None,
    async_mode: bool = False,
    enforce_sync_cap: bool = True,
) -> tuple[Optional[dict[str, Any]], Optional[dict[str, Any]]]:
    if not isinstance(async_mode, bool):
        return None, _plan_error_response("ERROR", f"async_mode must be a boolean, got: {async_mode!r}")

    if not isinstance(workspace_dir, str) or not workspace_dir.strip():
        return None, _plan_error_response("ERROR", "workspace_dir is required and must be a non-empty path.")
    try:
        ws_path = Path(workspace_dir).expanduser().resolve()
    except OSError as exc:
        return None, _plan_error_response("ERROR", f"Invalid workspace_dir '{workspace_dir}': {exc}")
    if not ws_path.is_dir():
        return None, _plan_error_response(
            "ERROR",
            f"workspace_dir does not exist or is not a directory: {ws_path}",
            workspace_dir=str(ws_path),
        )
    ws_str = str(ws_path)

    resolved_model, resolved_effort, me_err = _resolve_model_and_effort(
        model, get_default_agy_plan_model(), effort
    )
    if me_err:
        return None, _plan_error_response(
            "ERROR", me_err, workspace_dir=ws_str, git_evidence=claude_runner.collect_git_evidence(ws_str)
        )
    assert resolved_model is not None and resolved_effort is not None

    def _p_err(status: str, msg: str, **kw: Any) -> dict[str, Any]:
        return _plan_error_response(
            status,
            msg,
            model=resolved_model,
            effort=resolved_effort,
            workspace_dir=ws_str,
            git_evidence=claude_runner.collect_git_evidence(ws_str),
            **kw,
        )

    if not isinstance(request, str) or not request.strip():
        return None, _p_err("ERROR", "request is required and must be a non-empty string.")
    if not isinstance(include_history, bool):
        return None, _p_err("ERROR", f"include_history must be a boolean, got: {include_history!r}")

    save_target, save_rel, save_err = _validate_save_plan_file(ws_path, save_plan_file)
    if save_err:
        return None, _p_err("ERROR", save_err)

    if session_mode is not None and not isinstance(session_mode, str):
        return None, _p_err("ERROR", f"session_mode must be a string, got: {session_mode!r}")
    resolved_session_mode = (
        session_mode.strip() if isinstance(session_mode, str) and session_mode.strip() else "auto"
    )
    if resolved_session_mode not in claude_runner.VALID_SESSION_MODES:
        return None, _p_err(
            "ERROR",
            f"Invalid session_mode '{resolved_session_mode}'. Allowed: {sorted(claude_runner.VALID_SESSION_MODES)}",
        )

    resolved_resume_cid: Optional[str] = None
    if resume_conversation_id is not None:
        if (
            not isinstance(resume_conversation_id, str)
            or not resume_conversation_id.strip()
            or "\n" in resume_conversation_id
            or "\r" in resume_conversation_id
        ):
            return None, _p_err(
                "ERROR",
                "resume_conversation_id must be a single-line non-empty string.",
                session_mode=resolved_session_mode,
            )
        if resolved_session_mode == "fresh":
            return None, _p_err(
                "ERROR",
                "Cannot combine resume_conversation_id with session_mode='fresh'.",
                session_mode=resolved_session_mode,
            )
        resolved_resume_cid = resume_conversation_id.strip()

    if session_key is not None:
        if not isinstance(session_key, str) or not session_key.strip():
            return None, _p_err("ERROR", "session_key must be a non-empty string.")
        cleaned_key = session_key.strip()
        if not re.fullmatch(r"[A-Za-z0-9._:/-]{1,200}", cleaned_key):
            return None, _p_err(
                "ERROR",
                "session_key may only contain ASCII letters, digits, and . _ : / - (1-200 chars).",
            )
        resolved_session_key = cleaned_key
    else:
        resolved_session_key = DEFAULT_PLANNER_SESSION_KEY

    sync_cap = enforce_sync_cap and (not async_mode)
    max_allowed = (
        claude_runner.SYNC_MAX_TIMEOUT_SECONDS
        if sync_cap
        else claude_runner.ASYNC_MAX_TIMEOUT_SECONDS
    )
    if timeout_seconds is None:
        resolved_timeout = claude_runner.get_default_timeout_seconds(sync=sync_cap)
    elif isinstance(timeout_seconds, bool) or not isinstance(timeout_seconds, int) or timeout_seconds < 1:
        return None, _p_err(
            "ERROR",
            f"timeout_seconds must be an integer between 1 and {max_allowed}, got: {timeout_seconds!r}",
        )
    elif sync_cap and timeout_seconds > claude_runner.SYNC_MAX_TIMEOUT_SECONDS:
        return None, _p_err(
            "ERROR",
            f"Synchronous agy_plan caps timeout_seconds at {claude_runner.SYNC_MAX_TIMEOUT_SECONDS}s "
            "(or pass async_mode=true).",
        )
    elif timeout_seconds > max_allowed:
        return None, _p_err(
            "ERROR",
            f"timeout_seconds must be an integer between 1 and {max_allowed}, got: {timeout_seconds!r}",
        )
    else:
        resolved_timeout = timeout_seconds

    request_sha256 = hashlib.sha256(request.strip().encode("utf-8")).hexdigest()
    if resolved_session_mode == "resume" and not resolved_resume_cid:
        _, _, resume_err = claude_runner._resolve_session_plan(
            ws_str,
            session_key=resolved_session_key,
            session_mode=resolved_session_mode,
            resume_session_id=None,
            plan_sha256=request_sha256,
            session_max_turns=claude_runner.get_default_session_max_turns(),
            session_ttl_seconds=claude_runner.get_default_session_ttl_seconds(),
        )
        if resume_err:
            return None, _p_err(
                "ERROR",
                resume_err,
                session_key=resolved_session_key,
                session_mode=resolved_session_mode,
            )

    agy_bin, bin_err = find_agy_binary()
    if not agy_bin:
        return None, _p_err(
            "BLOCKED",
            bin_err or "Antigravity CLI ('agy') not found.",
            session_key=resolved_session_key,
            session_mode=resolved_session_mode,
        )

    return {
        "ws_path": ws_path,
        "ws_str": ws_str,
        "request": request,
        "request_sha256": request_sha256,
        "save_target": save_target,
        "save_rel": save_rel,
        "resolved_session_key": resolved_session_key,
        "resolved_session_mode": resolved_session_mode,
        "resolved_resume_cid": resolved_resume_cid,
        "include_history": include_history,
        "resolved_model": resolved_model,
        "resolved_effort": resolved_effort,
        "resolved_timeout": resolved_timeout,
        "async_mode": async_mode,
        "agy_bin": agy_bin,
    }, None


def _run_agy_plan_prepared(
    prepared: dict[str, Any],
    extra_context: Optional[str],
    *,
    cancel_event: Optional[threading.Event] = None,
    job_id: Optional[str] = None,
) -> dict[str, Any]:
    ws_path: Path = prepared["ws_path"]
    ws_str: str = prepared["ws_str"]
    request_text: str = prepared["request"]
    request_sha256: str = prepared["request_sha256"]
    save_target: Optional[Path] = prepared["save_target"]
    save_rel: Optional[str] = prepared["save_rel"]
    session_key: str = prepared["resolved_session_key"]
    session_mode: str = prepared["resolved_session_mode"]
    resume_cid_arg: Optional[str] = prepared["resolved_resume_cid"]
    include_history: bool = prepared["include_history"]
    resolved_model: str = prepared["resolved_model"]
    resolved_effort: str = prepared["resolved_effort"]
    resolved_timeout: int = prepared["resolved_timeout"]
    agy_bin: str = prepared["agy_bin"]

    pre_run_tree = claude_runner._capture_git_tree(ws_str)
    before_snapshot = claude_runner._snapshot_workspace(ws_str)

    target_conv_id, session_action, resolve_err = claude_runner._resolve_session_plan(
        ws_str,
        session_key=session_key,
        session_mode=session_mode,
        resume_session_id=resume_cid_arg,
        plan_sha256=request_sha256,
        session_max_turns=claude_runner.get_default_session_max_turns(),
        session_ttl_seconds=claude_runner.get_default_session_ttl_seconds(),
    )
    if resolve_err:
        return _plan_error_response(
            "ERROR",
            resolve_err,
            model=resolved_model,
            effort=resolved_effort,
            agy_bin=agy_bin,
            workspace_dir=ws_str,
            git_evidence=claude_runner.collect_git_evidence(ws_str),
            job_id=job_id,
            session_key=session_key,
            session_mode=session_mode,
            session_action=session_action,
        )

    external_drift_injected = False
    external_drift_files: list[str] = []
    drift_text: Optional[str] = None
    if target_conv_id is not None:
        with claude_runner._state_lock:
            cached_entry = claude_runner.load_session_index(ws_str)["sessions"].get(session_key)
        cached_post = (
            cached_entry.get("post_run_tree") if isinstance(cached_entry, dict) else None
        )
        drift_info = claude_runner.collect_external_drift(
            ws_str, cached_post, current_tree=pre_run_tree
        )
        if drift_info["has_drift"]:
            drift_list = list(drift_info["drift_files"])
            drift_text = (
                "Files changed outside your session: "
                + ", ".join(drift_list)
                + "\n\n```diff\n"
                + str(drift_info["drift_diff"]).rstrip()
                + "\n```\n"
            )
            external_drift_injected = True
            external_drift_files = drift_list

    def _run_attempt(
        active_conv_id: Optional[str],
        use_history: bool,
        timeout_budget: float,
        attempt_drift: Optional[str],
    ) -> tuple[str, Optional[int], str, str, bool]:
        prior_hist = (
            claude_runner.build_continuity_injection(ws_str)
            if (use_history and include_history)
            else ""
        )
        budget_secs = int(max(1, round(timeout_budget)))
        prompt_text = _bound_agy_plan_prompt(
            request=request_text,
            prior_history=prior_hist or None,
            external_drift=attempt_drift,
            extra_context=extra_context,
        )
        cli_args = _build_agy_cli_args(
            prompt_text=prompt_text,
            timeout_seconds=budget_secs,
            model=resolved_model,
            effort=resolved_effort,
            resume_conv_id=active_conv_id,
        )
        outcome_val, rc_val, out_raw, err_raw, _ = claude_runner._run_popen_cancellable(
            cmd=[agy_bin, *cli_args],
            stdin_payload="",
            cwd=ws_str,
            env=build_agy_child_env(agy_bin),
            timeout_seconds=budget_secs,
            cancel_event=cancel_event,
        )
        return outcome_val, rc_val, out_raw, err_raw, bool(prior_hist)

    run_started = time.monotonic()
    try:
        outcome, rc, stdout_raw, stderr_raw, history_injected = _run_attempt(
            target_conv_id,
            target_conv_id is None,
            float(resolved_timeout),
            drift_text,
        )
    except OSError as exc:
        after_snapshot = claude_runner._snapshot_workspace(ws_str)
        unexpected_mutations = claude_runner._diff_snapshots(before_snapshot, after_snapshot)
        return _plan_error_response(
            "ERROR",
            f"Failed to launch agy CLI '{agy_bin}': {exc}",
            model=resolved_model,
            effort=resolved_effort,
            agy_bin=agy_bin,
            workspace_dir=ws_str,
            git_evidence=claude_runner.collect_git_evidence(ws_str),
            job_id=job_id,
            session_key=session_key,
            session_mode=session_mode,
            session_action=session_action,
            session_fallback=False,
            unexpected_mutations=unexpected_mutations,
        )

    session_fallback = False
    parsed = parse_agy_output(stdout_raw or "") if outcome == "EXITED" else parse_agy_output("")
    attempt_failed = outcome == "EXITED" and (rc != 0 or parsed["is_error"])
    combined_err = f"{parsed['response'] or ''}\n{parsed['error_detail'] or ''}\n{stderr_raw or ''}"

    if (
        target_conv_id is not None
        and attempt_failed
        and _RESUME_MISSING_RE.search(combined_err)
    ):
        claude_runner._delete_session_if_matches(ws_str, session_key, target_conv_id)
        remaining_budget = resolved_timeout - (time.monotonic() - run_started)
        if cancel_event is not None and cancel_event.is_set():
            outcome = "CANCELLED"
        elif remaining_budget < 1.0:
            outcome = "TIMEOUT"
        else:
            session_fallback = True
            session_action = "fallback_fresh"
            external_drift_injected = False
            external_drift_files = []
            target_conv_id = None
            try:
                outcome, rc, stdout_raw, stderr_raw, history_injected = _run_attempt(
                    None,
                    True,
                    remaining_budget,
                    None,
                )
            except OSError as exc:
                after_snapshot = claude_runner._snapshot_workspace(ws_str)
                unexpected_mutations = claude_runner._diff_snapshots(
                    before_snapshot, after_snapshot
                )
                return _plan_error_response(
                    "ERROR",
                    f"Failed to launch fallback agy CLI '{agy_bin}': {exc}",
                    model=resolved_model,
                    effort=resolved_effort,
                    agy_bin=agy_bin,
                    workspace_dir=ws_str,
                    git_evidence=claude_runner.collect_git_evidence(ws_str),
                    job_id=job_id,
                    session_key=session_key,
                    session_mode=session_mode,
                    session_action=session_action,
                    session_fallback=True,
                    unexpected_mutations=unexpected_mutations,
                )
            if outcome == "EXITED":
                parsed = parse_agy_output(stdout_raw or "")

    total_elapsed = time.monotonic() - run_started
    after_snapshot = claude_runner._snapshot_workspace(ws_str)
    unexpected_mutations = claude_runner._diff_snapshots(before_snapshot, after_snapshot)
    read_only_violation = bool(unexpected_mutations)
    git_ev = claude_runner.collect_git_evidence(ws_str)
    stderr_text = (stderr_raw or "").strip()

    if outcome == "CANCELLED":
        return _plan_error_response(
            "CANCELLED",
            "agy CLI planning was cancelled and its process tree was terminated.",
            model=resolved_model,
            effort=resolved_effort,
            agy_bin=agy_bin,
            workspace_dir=ws_str,
            exit_code=rc,
            duration_seconds=total_elapsed,
            result=(stdout_raw or "").strip(),
            stderr=stderr_text,
            git_evidence=git_ev,
            job_id=job_id,
            session_key=session_key,
            session_mode=session_mode,
            session_action=session_action,
            session_fallback=session_fallback,
            unexpected_mutations=unexpected_mutations,
        )

    if outcome == "TIMEOUT":
        return _plan_error_response(
            "TIMEOUT",
            f"agy CLI planning timed out after {resolved_timeout}s and process tree was terminated.",
            model=resolved_model,
            effort=resolved_effort,
            agy_bin=agy_bin,
            workspace_dir=ws_str,
            exit_code=rc,
            duration_seconds=total_elapsed,
            result=(stdout_raw or "").strip(),
            stderr=stderr_text,
            git_evidence=git_ev,
            job_id=job_id,
            session_key=session_key,
            session_mode=session_mode,
            session_action=session_action,
            session_fallback=session_fallback,
            unexpected_mutations=unexpected_mutations,
        )

    err_msg: Optional[str] = None
    resp_text = parsed["response"] or ""
    if read_only_violation:
        status = "ERROR"
        err_msg = f"Read-only agy planner unexpectedly mutated workspace files: {unexpected_mutations}"
    elif rc != 0 or parsed["is_error"]:
        status = "ERROR"
        err_msg = (
            parsed["error_detail"]
            or resp_text
            or stderr_text
            or f"agy CLI planner exited with code {rc}"
        )
    else:
        plan_status = parse_plan_status(resp_text)
        if plan_status is None:
            status = "ERROR"
            err_msg = _missing_marker_error(
                "Planner",
                "Planner output missing required "
                "'STATUS: READY|NEED_CLARIFICATION|BLOCKED' on line 1.",
                resp_text,
                stderr_text,
            )
        else:
            status = plan_status

    final_conv_id = parsed["conversation_id"] or target_conv_id
    saved_plan_file: Optional[str] = None
    if not read_only_violation and status in VALID_AGY_PLAN_STATUSES:
        if final_conv_id:
            claude_runner._record_session_completion(
                ws_str,
                session_key=session_key,
                session_id=final_conv_id,
                target_session_id=target_conv_id,
                session_action=session_action,
                session_fallback=session_fallback,
                plan_sha256=request_sha256,
                status=status,
                resolved_plan_file=save_rel,
                run_changed_files=[],
                num_turns=parsed["num_turns"],
                pre_run_tree=pre_run_tree,
                post_run_tree=pre_run_tree,
            )
        if status == "READY" and save_target is not None:
            rechecked_target, rechecked_rel, recheck_err = _validate_save_plan_file(
                ws_path, save_rel
            )
            if recheck_err or rechecked_target is None:
                status = "ERROR"
                err_msg = recheck_err or "save_plan_file safety check failed."
            else:
                claude_runner._atomic_write_text(
                    rechecked_target, resp_text.rstrip() + "\n"
                )
                saved_plan_file = rechecked_rel

    payload: dict[str, Any] = {
        "status": status,
        "model": resolved_model or None,
        "effort": resolved_effort or None,
        "agy_bin": agy_bin,
        "workspace_dir": ws_str,
        "exit_code": rc,
        "duration_seconds": round(total_elapsed, 3),
        "cli_duration_seconds": parsed["duration_seconds"],
        "num_turns": parsed["num_turns"],
        "usage": parsed["usage"],
        "conversation_id": final_conv_id,
        "session_key": session_key,
        "session_mode": session_mode,
        "session_action": session_action,
        "session_fallback": session_fallback,
        "saved_plan_file": saved_plan_file,
        "history_injected": history_injected,
        "external_drift_injected": external_drift_injected,
        "external_drift_files": external_drift_files,
        "read_only_violation": read_only_violation,
        "unexpected_mutations": unexpected_mutations,
        "is_git_repo": git_ev["is_git_repo"],
        "changed_files": git_ev["changed_files"],
        "result": resp_text,
        "stderr": stderr_text,
        "error": err_msg,
    }
    if job_id is not None:
        payload["job_id"] = job_id
    return payload


def agy_plan(
    workspace_dir: str,
    request: str,
    *,
    save_plan_file: Optional[str] = None,
    session_key: Optional[str] = None,
    session_mode: Optional[str] = None,
    resume_conversation_id: Optional[str] = None,
    include_history: bool = True,
    extra_context: Optional[str] = None,
    model: Optional[str] = None,
    effort: Optional[str] = None,
    timeout_seconds: Optional[int] = None,
    async_mode: bool = False,
    enforce_sync_cap: bool = True,
    cancel_event: Optional[threading.Event] = None,
) -> dict[str, Any]:
    """Run read-only planning via Antigravity CLI (agy --mode plan) with clarification/resume."""
    prepared, err_resp = _validate_and_prepare_plan(
        workspace_dir=workspace_dir,
        request=request,
        save_plan_file=save_plan_file,
        session_key=session_key,
        session_mode=session_mode,
        resume_conversation_id=resume_conversation_id,
        include_history=include_history,
        model=model,
        effort=effort,
        timeout_seconds=timeout_seconds,
        async_mode=async_mode,
        enforce_sync_cap=enforce_sync_cap,
    )
    if err_resp is not None or prepared is None:
        assert err_resp is not None
        return err_resp

    job, active_id = claude_runner.JOB_MANAGER.register_job(
        workspace_dir=prepared["ws_str"],
        model=prepared["resolved_model"] or "agy-default",
        permission_mode="plan",
        max_turns=0,
        timeout_seconds=prepared["resolved_timeout"],
        is_async=prepared["async_mode"],
        cancel_event=cancel_event,
        job_prefix="agy-plan",
        lock_mode="read",
    )
    if job is None:
        return _plan_error_response(
            "BUSY",
            f"A write job ({active_id}) is already running in workspace '{prepared['ws_str']}'. "
            "Poll it with claude_execute_status or stop it with claude_execute_cancel before running agy_plan.",
            model=prepared["resolved_model"],
            effort=prepared["resolved_effort"],
            agy_bin=prepared["agy_bin"],
            workspace_dir=prepared["ws_str"],
            git_evidence=claude_runner.collect_git_evidence(prepared["ws_str"]),
            active_job_id=active_id,
            session_key=prepared["resolved_session_key"],
            session_mode=prepared["resolved_session_mode"],
        )

    if prepared["async_mode"]:

        def _worker() -> None:
            res: Optional[dict[str, Any]] = None
            try:
                res = _run_agy_plan_prepared(
                    prepared=prepared,
                    extra_context=extra_context,
                    cancel_event=job.cancel_event,
                    job_id=job.job_id,
                )
            except Exception as exc:
                res = _plan_error_response(
                    "ERROR",
                    f"Background agy_plan worker failed: {exc}",
                    model=prepared["resolved_model"],
                    effort=prepared["resolved_effort"],
                    agy_bin=prepared["agy_bin"],
                    workspace_dir=prepared["ws_str"],
                    job_id=job.job_id,
                    session_key=prepared["resolved_session_key"],
                    session_mode=prepared["resolved_session_mode"],
                )
            finally:
                if res is None:
                    res = _plan_error_response(
                        "ERROR",
                        "Background agy_plan worker exited without result.",
                        model=prepared["resolved_model"],
                        effort=prepared["resolved_effort"],
                        agy_bin=prepared["agy_bin"],
                        workspace_dir=prepared["ws_str"],
                        job_id=job.job_id,
                        session_key=prepared["resolved_session_key"],
                        session_mode=prepared["resolved_session_mode"],
                    )
                claude_runner.JOB_MANAGER.finish_job(job, res)

        threading.Thread(target=_worker, daemon=True).start()
        return {
            "status": "STARTED",
            "job_id": job.job_id,
            "workspace_dir": prepared["ws_str"],
            "model": prepared["resolved_model"] or None,
            "effort": prepared["resolved_effort"] or None,
            "timeout_seconds": prepared["resolved_timeout"],
            "agy_bin": prepared["agy_bin"],
            "session_key": prepared["resolved_session_key"],
            "session_mode": prepared["resolved_session_mode"],
            "save_plan_file": prepared["save_rel"],
            "error": None,
        }

    res: Optional[dict[str, Any]] = None
    try:
        res = _run_agy_plan_prepared(
            prepared=prepared,
            extra_context=extra_context,
            cancel_event=job.cancel_event,
            job_id=job.job_id,
        )
        return res
    finally:
        if res is None:
            res = _plan_error_response(
                "ERROR",
                "Unexpected internal failure while planning with agy CLI.",
                model=prepared["resolved_model"],
                effort=prepared["resolved_effort"],
                agy_bin=prepared["agy_bin"],
                workspace_dir=prepared["ws_str"],
                job_id=job.job_id,
                session_key=prepared["resolved_session_key"],
                session_mode=prepared["resolved_session_mode"],
            )
        claude_runner.JOB_MANAGER.finish_job(job, res)


def _validate_and_prepare_agy_verify(
    workspace_dir: str,
    plan: Optional[str],
    allowed_files: Optional[list[str]],
    verification_commands: Optional[list[str]],
    model: Optional[str],
    effort: Optional[str],
    timeout_seconds: Optional[int],
    *,
    plan_file: Optional[str] = None,
    include_history: bool = True,
    include_git_diff: bool = True,
    diff_scope: str = "last_run",
    allow_bash: bool = True,
    async_mode: bool = False,
    enforce_sync_cap: bool = True,
) -> tuple[Optional[dict[str, Any]], Optional[dict[str, Any]]]:
    if not isinstance(async_mode, bool):
        return None, _verify_error_response("ERROR", f"async_mode must be a boolean, got: {async_mode!r}")

    def _av_err(status: str, msg: str, **kw: Any) -> dict[str, Any]:
        scope_kw = (
            diff_scope.strip()
            if isinstance(diff_scope, str) and diff_scope.strip() in claude_runner.VALID_DIFF_SCOPES
            else None
        )
        kw.setdefault("diff_scope", scope_kw)
        if "claude_bin" in kw:
            kw["agy_bin"] = kw.pop("claude_bin")
        return _verify_error_response(
            status,
            msg,
            verdict=("BLOCKED" if status == "BLOCKED" else "ERROR"),
            allow_bash=allow_bash if isinstance(allow_bash, bool) else True,
            **kw,
        )

    if not isinstance(include_git_diff, bool):
        return None, _av_err("ERROR", f"include_git_diff must be a boolean, got: {include_git_diff!r}")
    if not isinstance(allow_bash, bool):
        return None, _av_err("ERROR", f"allow_bash must be a boolean, got: {allow_bash!r}")
    if not isinstance(diff_scope, str) or diff_scope.strip() not in claude_runner.VALID_DIFF_SCOPES:
        return None, _verify_error_response(
            "ERROR",
            f"diff_scope must be one of {sorted(claude_runner.VALID_DIFF_SCOPES)}, got: {diff_scope!r}",
            verdict="ERROR",
            allow_bash=allow_bash if isinstance(allow_bash, bool) else True,
        )

    resolved_model, resolved_effort, me_err = _resolve_model_and_effort(
        model, get_default_agy_verify_model(), effort
    )
    if me_err:
        return None, _av_err("ERROR", me_err)
    assert resolved_model is not None and resolved_effort is not None

    sync_cap = enforce_sync_cap and (not async_mode)
    base, err_resp = claude_runner._validate_base_execution_inputs(
        workspace_dir=workspace_dir,
        plan=plan,
        plan_file=plan_file,
        allowed_files=allowed_files,
        verification_commands=verification_commands,
        model=resolved_model,
        max_turns=None,
        timeout_seconds=timeout_seconds,
        include_history=include_history,
        default_model=get_default_agy_verify_model(),
        default_max_turns=15,
        enforce_sync_cap=sync_cap,
        sync_cap_hint="agy_verify",
        err_fn=_av_err,
        find_binary_fn=find_agy_binary,
        missing_bin_msg="Antigravity CLI ('agy') not found.",
    )
    if err_resp is not None or base is None:
        return None, err_resp

    return {
        **base,
        "agy_bin": base["claude_bin"],
        "resolved_model": resolved_model,
        "resolved_effort": resolved_effort,
        "include_git_diff": include_git_diff,
        "diff_scope": diff_scope.strip(),
        "allow_bash": allow_bash,
        "async_mode": async_mode,
    }, None


def _run_agy_verify_prepared(
    prepared: dict[str, Any],
    allowed_files: Optional[list[str]],
    verification_commands: Optional[list[str]],
    extra_context: Optional[str],
    *,
    cancel_event: Optional[threading.Event] = None,
    job_id: Optional[str] = None,
) -> dict[str, Any]:
    ws_str = prepared["ws_str"]
    effective_plan = prepared["effective_plan"]
    resolved_plan_file = prepared["resolved_plan_file"]
    include_history = prepared["include_history"]
    include_git_diff = prepared["include_git_diff"]
    diff_scope = prepared["diff_scope"]
    allow_bash = prepared["allow_bash"]
    resolved_model = prepared["resolved_model"]
    resolved_effort = prepared["resolved_effort"]
    resolved_timeout = prepared["resolved_timeout"]
    agy_bin = prepared["agy_bin"]

    # Record state dir existence BEFORE any reads; never create .agents/state/ on a clean workspace.
    state_dir_existed = claude_runner._state_dir_path(ws_str).is_dir()
    prior_hist = claude_runner.build_continuity_injection(ws_str) if include_history else ""
    history_injected = bool(prior_hist)
    diff_evidence = (
        claude_runner.collect_verify_diff(ws_str, diff_scope=diff_scope)
        if include_git_diff
        else None
    )
    diff_included = bool(
        include_git_diff and diff_evidence is not None and diff_evidence.get("is_git_repo")
    )
    resolved_diff_scope = (
        diff_evidence.get("resolved_diff_scope") if isinstance(diff_evidence, dict) else None
    )

    prompt_text = _bound_agy_verify_prompt(
        plan=effective_plan,
        allowed_files=allowed_files,
        verification_commands=verification_commands,
        prior_history=prior_hist or None,
        diff_evidence=diff_evidence,
        extra_context=extra_context,
        allow_bash=allow_bash,
    )
    cli_args = _build_agy_cli_args(
        prompt_text=prompt_text,
        timeout_seconds=resolved_timeout,
        model=resolved_model,
        effort=resolved_effort,
        resume_conv_id=None,
        allow_bash=allow_bash,
    )
    child_env = build_agy_child_env(agy_bin)

    before_snapshot = claude_runner._snapshot_workspace(ws_str)
    try:
        outcome, rc, stdout_raw, stderr_raw, elapsed = claude_runner._run_popen_cancellable(
            cmd=[agy_bin, *cli_args],
            stdin_payload="",
            cwd=ws_str,
            env=child_env,
            timeout_seconds=resolved_timeout,
            cancel_event=cancel_event,
        )
    except OSError as exc:
        after_snapshot = claude_runner._snapshot_workspace(ws_str)
        unexpected_mutations = claude_runner._diff_snapshots(before_snapshot, after_snapshot)
        return _verify_error_response(
            "ERROR",
            f"Failed to launch agy CLI '{agy_bin}': {exc}",
            verdict="FAIL" if unexpected_mutations else "ERROR",
            model=resolved_model,
            effort=resolved_effort,
            agy_bin=agy_bin,
            workspace_dir=ws_str,
            git_evidence=claude_runner.collect_git_evidence(ws_str),
            job_id=job_id,
            plan_file=resolved_plan_file,
            history_injected=history_injected,
            diff_included=diff_included,
            diff_scope=diff_scope,
            resolved_diff_scope=resolved_diff_scope,
            allow_bash=allow_bash,
            unexpected_mutations=unexpected_mutations,
        )

    after_snapshot = claude_runner._snapshot_workspace(ws_str)
    unexpected_mutations = claude_runner._diff_snapshots(before_snapshot, after_snapshot)
    git_ev = claude_runner.collect_git_evidence(ws_str)
    stderr_text = (stderr_raw or "").strip()

    if outcome == "CANCELLED":
        return _verify_error_response(
            "CANCELLED",
            "agy CLI verification was cancelled and its process tree was terminated.",
            verdict="FAIL" if unexpected_mutations else "ERROR",
            model=resolved_model,
            effort=resolved_effort,
            agy_bin=agy_bin,
            workspace_dir=ws_str,
            exit_code=rc,
            duration_seconds=elapsed,
            result=(stdout_raw or "").strip(),
            stderr=stderr_text,
            git_evidence=git_ev,
            job_id=job_id,
            plan_file=resolved_plan_file,
            history_injected=history_injected,
            diff_included=diff_included,
            diff_scope=diff_scope,
            resolved_diff_scope=resolved_diff_scope,
            allow_bash=allow_bash,
            unexpected_mutations=unexpected_mutations,
        )

    if outcome == "TIMEOUT":
        return _verify_error_response(
            "TIMEOUT",
            f"agy CLI verification timed out after {resolved_timeout}s and process tree was terminated.",
            verdict="FAIL" if unexpected_mutations else "ERROR",
            model=resolved_model,
            effort=resolved_effort,
            agy_bin=agy_bin,
            workspace_dir=ws_str,
            exit_code=rc,
            duration_seconds=elapsed,
            result=(stdout_raw or "").strip(),
            stderr=stderr_text,
            git_evidence=git_ev,
            job_id=job_id,
            plan_file=resolved_plan_file,
            history_injected=history_injected,
            diff_included=diff_included,
            diff_scope=diff_scope,
            resolved_diff_scope=resolved_diff_scope,
            allow_bash=allow_bash,
            unexpected_mutations=unexpected_mutations,
        )

    parsed = parse_agy_output(stdout_raw or "")
    read_only_violation = bool(unexpected_mutations)
    err_msg: Optional[str] = None
    resp_text = parsed["response"] or ""

    if read_only_violation:
        status = "ERROR"
        verdict = "FAIL"
        err_msg = f"Read-only agy verifier unexpectedly mutated workspace files: {unexpected_mutations}"
    elif rc != 0 or parsed["is_error"]:
        status = "ERROR"
        verdict = "ERROR"
        err_msg = (
            parsed["error_detail"]
            or resp_text
            or stderr_text
            or f"agy CLI verifier exited with code {rc}"
        )
    else:
        parsed_verdict = claude_runner.parse_verdict(resp_text)
        if parsed_verdict is None:
            status = "ERROR"
            verdict = "ERROR"
            err_msg = _missing_marker_error(
                "Verifier",
                "Verifier output missing required 'VERDICT: PASS|FAIL|BLOCKED' on line 1.",
                resp_text,
                stderr_text,
            )
        else:
            status = parsed_verdict
            verdict = parsed_verdict

    payload: dict[str, Any] = {
        "status": status,
        "verdict": verdict,
        "model": resolved_model or None,
        "effort": resolved_effort or None,
        "agy_bin": agy_bin,
        "workspace_dir": ws_str,
        "exit_code": rc,
        "duration_seconds": round(elapsed, 3),
        "cli_duration_seconds": parsed["duration_seconds"],
        "num_turns": parsed["num_turns"],
        "usage": parsed["usage"],
        "conversation_id": parsed["conversation_id"],
        "plan_file": resolved_plan_file,
        "history_injected": history_injected,
        "diff_included": diff_included,
        "diff_scope": diff_scope,
        "resolved_diff_scope": resolved_diff_scope,
        "allow_bash": allow_bash,
        "read_only_violation": read_only_violation,
        "unexpected_mutations": unexpected_mutations,
        "is_git_repo": git_ev["is_git_repo"],
        "changed_files": git_ev["changed_files"],
        "git_diff_stat": git_ev["git_diff_stat"],
        "result": resp_text,
        "stderr": stderr_text,
        "error": err_msg,
    }
    if job_id is not None:
        payload["job_id"] = job_id

    if (
        state_dir_existed
        and not read_only_violation
        and status in ("PASS", "FAIL", "BLOCKED")
    ):
        try:
            claude_runner._record_verify_outcome(
                ws_str,
                status=status,
                result_text=resp_text,
                plan_file=resolved_plan_file,
                resolved_diff_scope=resolved_diff_scope or "workspace",
                source="agy",
            )
        except Exception:
            pass
    return payload


def agy_verify(
    workspace_dir: str,
    plan: Optional[str] = None,
    allowed_files: Optional[list[str]] = None,
    verification_commands: Optional[list[str]] = None,
    extra_context: Optional[str] = None,
    model: Optional[str] = None,
    effort: Optional[str] = None,
    timeout_seconds: Optional[int] = None,
    *,
    plan_file: Optional[str] = None,
    include_history: bool = True,
    include_git_diff: bool = True,
    diff_scope: str = "last_run",
    allow_bash: bool = True,
    async_mode: bool = False,
    enforce_sync_cap: bool = True,
    cancel_event: Optional[threading.Event] = None,
) -> dict[str, Any]:
    """Perform an independent read-only blind audit via local Antigravity CLI (agy)."""
    prepared, err_resp = _validate_and_prepare_agy_verify(
        workspace_dir=workspace_dir,
        plan=plan,
        allowed_files=allowed_files,
        verification_commands=verification_commands,
        model=model,
        effort=effort,
        timeout_seconds=timeout_seconds,
        plan_file=plan_file,
        include_history=include_history,
        include_git_diff=include_git_diff,
        diff_scope=diff_scope,
        allow_bash=allow_bash,
        async_mode=async_mode,
        enforce_sync_cap=enforce_sync_cap,
    )
    if err_resp is not None or prepared is None:
        assert err_resp is not None
        return err_resp

    job, active_id = claude_runner.JOB_MANAGER.register_job(
        workspace_dir=prepared["ws_str"],
        model=prepared["resolved_model"] or "agy-default",
        permission_mode="plan",
        max_turns=0,
        timeout_seconds=prepared["resolved_timeout"],
        is_async=prepared["async_mode"],
        cancel_event=cancel_event,
        job_prefix="agy-verify",
        lock_mode="read",
    )
    if job is None:
        return _verify_error_response(
            "BUSY",
            f"A write job ({active_id}) is already running in workspace '{prepared['ws_str']}'. "
            "Poll it with claude_execute_status or stop it with claude_execute_cancel before running agy_verify.",
            verdict="ERROR",
            model=prepared["resolved_model"],
            effort=prepared["resolved_effort"],
            agy_bin=prepared["agy_bin"],
            workspace_dir=prepared["ws_str"],
            git_evidence=claude_runner.collect_git_evidence(prepared["ws_str"]),
            active_job_id=active_id,
            plan_file=prepared["resolved_plan_file"],
            diff_scope=prepared.get("diff_scope"),
            allow_bash=prepared["allow_bash"],
        )

    if prepared["async_mode"]:

        def _worker() -> None:
            res: Optional[dict[str, Any]] = None
            try:
                res = _run_agy_verify_prepared(
                    prepared=prepared,
                    allowed_files=allowed_files,
                    verification_commands=verification_commands,
                    extra_context=extra_context,
                    cancel_event=job.cancel_event,
                    job_id=job.job_id,
                )
            except Exception as exc:
                res = _verify_error_response(
                    "ERROR",
                    f"Background agy_verify worker failed: {exc}",
                    verdict="ERROR",
                    model=prepared["resolved_model"],
                    effort=prepared["resolved_effort"],
                    agy_bin=prepared["agy_bin"],
                    workspace_dir=prepared["ws_str"],
                    job_id=job.job_id,
                    plan_file=prepared["resolved_plan_file"],
                    diff_scope=prepared.get("diff_scope"),
                    allow_bash=prepared["allow_bash"],
                )
            finally:
                if res is None:
                    res = _verify_error_response(
                        "ERROR",
                        "Background agy_verify worker exited without result.",
                        verdict="ERROR",
                        model=prepared["resolved_model"],
                        effort=prepared["resolved_effort"],
                        agy_bin=prepared["agy_bin"],
                        workspace_dir=prepared["ws_str"],
                        job_id=job.job_id,
                        plan_file=prepared["resolved_plan_file"],
                        diff_scope=prepared.get("diff_scope"),
                        allow_bash=prepared["allow_bash"],
                    )
                claude_runner.JOB_MANAGER.finish_job(job, res)

        threading.Thread(target=_worker, daemon=True).start()
        return {
            "status": "STARTED",
            "job_id": job.job_id,
            "workspace_dir": prepared["ws_str"],
            "model": prepared["resolved_model"] or None,
            "effort": prepared["resolved_effort"] or None,
            "timeout_seconds": prepared["resolved_timeout"],
            "agy_bin": prepared["agy_bin"],
            "plan_file": prepared["resolved_plan_file"],
            "diff_scope": prepared["diff_scope"],
            "error": None,
        }

    res: Optional[dict[str, Any]] = None
    try:
        res = _run_agy_verify_prepared(
            prepared=prepared,
            allowed_files=allowed_files,
            verification_commands=verification_commands,
            extra_context=extra_context,
            cancel_event=job.cancel_event,
            job_id=job.job_id,
        )
        return res
    finally:
        if res is None:
            res = _verify_error_response(
                "ERROR",
                "Unexpected internal failure while verifying with agy CLI.",
                verdict="ERROR",
                model=prepared["resolved_model"],
                effort=prepared["resolved_effort"],
                agy_bin=prepared["agy_bin"],
                workspace_dir=prepared["ws_str"],
                job_id=job.job_id,
                plan_file=prepared["resolved_plan_file"],
                diff_scope=prepared.get("diff_scope"),
                allow_bash=prepared["allow_bash"],
            )
        claude_runner.JOB_MANAGER.finish_job(job, res)


def _validate_and_prepare_agy_execute(
    workspace_dir: str,
    plan: Optional[str],
    allowed_files: Optional[list[str]],
    verification_commands: Optional[list[str]],
    model: Optional[str],
    effort: Optional[str],
    timeout_seconds: Optional[int],
    *,
    plan_file: Optional[str] = None,
    session_key: Optional[str] = None,
    session_mode: Optional[str] = None,
    resume_conversation_id: Optional[str] = None,
    include_history: bool = True,
    async_mode: bool = False,
    enforce_sync_cap: bool = True,
) -> tuple[Optional[dict[str, Any]], Optional[dict[str, Any]]]:
    if not isinstance(async_mode, bool):
        return None, _execute_error_response("ERROR", f"async_mode must be a boolean, got: {async_mode!r}")

    resolved_model, resolved_effort, me_err = _resolve_model_and_effort(
        model, get_default_agy_execute_model(), effort
    )

    def _ae_err(status: str, msg: str, **kw: Any) -> dict[str, Any]:
        if "claude_bin" in kw:
            kw["agy_bin"] = kw.pop("claude_bin")
        kw.setdefault("effort", resolved_effort)
        return _execute_error_response(status, msg, **kw)

    if me_err:
        ws_norm = workspace_dir
        try:
            ws_norm = str(Path(workspace_dir).expanduser().resolve()) if isinstance(workspace_dir, str) and workspace_dir.strip() else ""
        except OSError:
            ws_norm = ""
        return None, _execute_error_response("ERROR", me_err, workspace_dir=ws_norm)
    assert resolved_model is not None and resolved_effort is not None

    sync_cap = enforce_sync_cap and (not async_mode)
    base, err_resp = claude_runner._validate_base_execution_inputs(
        workspace_dir=workspace_dir,
        plan=plan,
        plan_file=plan_file,
        allowed_files=allowed_files,
        verification_commands=verification_commands,
        model=resolved_model,
        max_turns=None,
        timeout_seconds=timeout_seconds,
        include_history=include_history,
        default_model=get_default_agy_execute_model(),
        default_max_turns=25,
        enforce_sync_cap=sync_cap,
        sync_cap_hint="agy_execute",
        err_fn=_ae_err,
        find_binary_fn=find_agy_binary,
        missing_bin_msg="Antigravity CLI ('agy') not found.",
    )
    if err_resp is not None or base is None:
        return None, err_resp

    ws_str = base["ws_str"]
    resolved_pf = base["resolved_plan_file"]

    if session_mode is not None and not isinstance(session_mode, str):
        return None, _ae_err("ERROR", f"session_mode must be a string, got: {session_mode!r}", workspace_dir=ws_str, plan_file=resolved_pf)
    resolved_session_mode = (
        session_mode.strip() if isinstance(session_mode, str) and session_mode.strip() else "auto"
    )
    if resolved_session_mode not in claude_runner.VALID_SESSION_MODES:
        return None, _ae_err(
            "ERROR",
            f"Invalid session_mode '{resolved_session_mode}'. Allowed: {sorted(claude_runner.VALID_SESSION_MODES)}",
            workspace_dir=ws_str,
            plan_file=resolved_pf,
        )

    resolved_resume_cid: Optional[str] = None
    if resume_conversation_id is not None:
        if (
            not isinstance(resume_conversation_id, str)
            or not resume_conversation_id.strip()
            or "\n" in resume_conversation_id
            or "\r" in resume_conversation_id
        ):
            return None, _ae_err(
                "ERROR",
                "resume_conversation_id must be a single-line non-empty string.",
                workspace_dir=ws_str,
                session_mode=resolved_session_mode,
                plan_file=resolved_pf,
            )
        if resolved_session_mode == "fresh":
            return None, _ae_err(
                "ERROR",
                "Cannot combine resume_conversation_id with session_mode='fresh'.",
                workspace_dir=ws_str,
                session_mode=resolved_session_mode,
                plan_file=resolved_pf,
            )
        resolved_resume_cid = resume_conversation_id.strip()

    if session_key is not None:
        if not isinstance(session_key, str) or not session_key.strip():
            return None, _ae_err("ERROR", "session_key must be a non-empty string.", workspace_dir=ws_str, plan_file=resolved_pf)
        cleaned_key = session_key.strip()
        if not re.fullmatch(r"[A-Za-z0-9._:/-]{1,200}", cleaned_key):
            return None, _ae_err(
                "ERROR",
                "session_key may only contain ASCII letters, digits, and . _ : / - (1-200 chars).",
                workspace_dir=ws_str,
                plan_file=resolved_pf,
            )
        resolved_session_key = cleaned_key
    else:
        resolved_session_key = DEFAULT_AGY_EXECUTOR_SESSION_KEY

    plan_sha256 = hashlib.sha256(base["effective_plan"].strip().encode("utf-8")).hexdigest()
    if resolved_session_mode == "resume" and not resolved_resume_cid:
        _, _, resume_err = claude_runner._resolve_session_plan(
            ws_str,
            session_key=resolved_session_key,
            session_mode=resolved_session_mode,
            resume_session_id=None,
            plan_sha256=plan_sha256,
            session_max_turns=claude_runner.get_default_session_max_turns(),
            session_ttl_seconds=claude_runner.get_default_session_ttl_seconds(),
        )
        if resume_err:
            return None, _ae_err(
                "ERROR",
                resume_err,
                workspace_dir=ws_str,
                session_key=resolved_session_key,
                session_mode=resolved_session_mode,
                plan_file=resolved_pf,
            )

    return {
        **base,
        "agy_bin": base["claude_bin"],
        "resolved_model": resolved_model,
        "resolved_effort": resolved_effort,
        "plan_sha256": plan_sha256,
        "resolved_session_key": resolved_session_key,
        "resolved_session_mode": resolved_session_mode,
        "resolved_resume_cid": resolved_resume_cid,
        "async_mode": async_mode,
    }, None


def _run_agy_execute_prepared(
    prepared: dict[str, Any],
    allowed_files: Optional[list[str]],
    verification_commands: Optional[list[str]],
    extra_context: Optional[str],
    *,
    cancel_event: Optional[threading.Event] = None,
    job_id: Optional[str] = None,
) -> dict[str, Any]:
    ws_str = prepared["ws_str"]
    effective_plan = prepared["effective_plan"]
    resolved_plan_file = prepared["resolved_plan_file"]
    plan_sha256 = prepared["plan_sha256"]
    session_key = prepared["resolved_session_key"]
    session_mode = prepared["resolved_session_mode"]
    resume_cid_arg = prepared["resolved_resume_cid"]
    include_history = prepared["include_history"]
    resolved_model = prepared["resolved_model"]
    resolved_effort = prepared["resolved_effort"]
    resolved_timeout = prepared["resolved_timeout"]
    agy_bin = prepared["agy_bin"]

    state_dir_existed = claude_runner._state_dir_path(ws_str).is_dir()
    pre_run_tree = claude_runner._capture_git_tree(ws_str)
    before_snapshot = claude_runner._snapshot_workspace(ws_str)

    target_conv_id, session_action, resolve_err = claude_runner._resolve_session_plan(
        ws_str,
        session_key=session_key,
        session_mode=session_mode,
        resume_session_id=resume_cid_arg,
        plan_sha256=plan_sha256,
        session_max_turns=claude_runner.get_default_session_max_turns(),
        session_ttl_seconds=claude_runner.get_default_session_ttl_seconds(),
    )
    if resolve_err:
        return _execute_error_response(
            "ERROR",
            resolve_err,
            model=resolved_model,
            effort=resolved_effort,
            agy_bin=agy_bin,
            workspace_dir=ws_str,
            git_evidence=claude_runner.collect_git_evidence(ws_str),
            job_id=job_id,
            session_key=session_key,
            session_mode=session_mode,
            session_action=session_action,
            plan_file=resolved_plan_file,
        )

    external_drift_injected = False
    external_drift_files: list[str] = []
    drift_text: Optional[str] = None
    if target_conv_id is not None:
        with claude_runner._state_lock:
            cached_entry = claude_runner.load_session_index(ws_str)["sessions"].get(session_key)
        cached_post = cached_entry.get("post_run_tree") if isinstance(cached_entry, dict) else None
        drift_info = claude_runner.collect_external_drift(ws_str, cached_post, current_tree=pre_run_tree)
        if drift_info["has_drift"]:
            drift_list = list(drift_info["drift_files"])
            drift_text = (
                "Files changed outside your session: "
                + ", ".join(drift_list)
                + "\n\n```diff\n"
                + str(drift_info["drift_diff"]).rstrip()
                + "\n```\n"
            )
            external_drift_injected = True
            external_drift_files = drift_list

    interrupted_note = ""
    if state_dir_existed and include_history:
        ws_state = claude_runner.load_workspace_state(ws_str)
        raw_err = ws_state.get("last_error")
        if isinstance(raw_err, dict) and raw_err:
            touched = ", ".join(str(x) for x in (raw_err.get("run_changed_files") or [])[:15] if str(x).strip()) or "none"
            interrupted_note = (
                "## Interrupted Prior Executor Recovery\n\n"
                f"- Previous executor: {raw_err.get('executor') or 'unknown'}\n"
                f"- Partial files already on disk: {touched}\n"
                f"- Previous failure: {raw_err.get('error') or 'unknown'}\n"
            )

    def _run_attempt(
        active_conv_id: Optional[str],
        use_history: bool,
        timeout_budget: float,
        attempt_drift: Optional[str],
    ) -> tuple[str, Optional[int], str, str, bool]:
        if use_history and include_history:
            prior_hist = claude_runner.build_continuity_injection(ws_str)
        elif include_history and interrupted_note:
            prior_hist = interrupted_note
        else:
            prior_hist = ""
        budget_secs = int(max(1, round(timeout_budget)))
        prompt_text = _bound_agy_execute_prompt(
            plan=effective_plan,
            allowed_files=allowed_files,
            verification_commands=verification_commands,
            prior_history=prior_hist or None,
            external_drift=attempt_drift,
            extra_context=extra_context,
        )
        cli_args = _build_agy_cli_args(
            prompt_text=prompt_text,
            timeout_seconds=budget_secs,
            model=resolved_model,
            effort=resolved_effort,
            resume_conv_id=active_conv_id,
            mode="execute",
        )
        outcome_val, rc_val, out_raw, err_raw, _ = claude_runner._run_popen_cancellable(
            cmd=[agy_bin, *cli_args],
            stdin_payload="",
            cwd=ws_str,
            env=build_agy_child_env(agy_bin),
            timeout_seconds=budget_secs,
            cancel_event=cancel_event,
        )
        return outcome_val, rc_val, out_raw, err_raw, bool(prior_hist)

    run_started = time.monotonic()
    try:
        outcome, rc, stdout_raw, stderr_raw, history_injected = _run_attempt(
            target_conv_id,
            target_conv_id is None,
            float(resolved_timeout),
            drift_text,
        )
    except OSError as exc:
        after_snapshot = claude_runner._snapshot_workspace(ws_str)
        run_changed_files = claude_runner._diff_snapshots(before_snapshot, after_snapshot)
        return _execute_error_response(
            "ERROR",
            f"Failed to launch agy CLI '{agy_bin}': {exc}",
            model=resolved_model,
            effort=resolved_effort,
            agy_bin=agy_bin,
            workspace_dir=ws_str,
            git_evidence=claude_runner.collect_git_evidence(ws_str),
            job_id=job_id,
            session_key=session_key,
            session_mode=session_mode,
            session_action=session_action,
            session_fallback=False,
            plan_file=resolved_plan_file,
            run_changed_files=run_changed_files,
        )

    session_fallback = False
    parsed = parse_agy_output(stdout_raw or "") if outcome == "EXITED" else parse_agy_output("")
    attempt_failed = outcome == "EXITED" and (rc != 0 or parsed["is_error"])
    combined_err = f"{parsed['response'] or ''}\n{parsed['error_detail'] or ''}\n{stderr_raw or ''}"

    if target_conv_id is not None and attempt_failed and _RESUME_MISSING_RE.search(combined_err):
        claude_runner._delete_session_if_matches(ws_str, session_key, target_conv_id)
        remaining_budget = resolved_timeout - (time.monotonic() - run_started)
        if cancel_event is not None and cancel_event.is_set():
            outcome = "CANCELLED"
        elif remaining_budget < 1.0:
            outcome = "TIMEOUT"
        else:
            session_fallback = True
            session_action = "fallback_fresh"
            external_drift_injected = False
            external_drift_files = []
            target_conv_id = None
            try:
                outcome, rc, stdout_raw, stderr_raw, history_injected = _run_attempt(
                    None,
                    True,
                    remaining_budget,
                    None,
                )
            except OSError as exc:
                after_snapshot = claude_runner._snapshot_workspace(ws_str)
                run_changed_files = claude_runner._diff_snapshots(before_snapshot, after_snapshot)
                return _execute_error_response(
                    "ERROR",
                    f"Failed to launch fallback agy CLI '{agy_bin}': {exc}",
                    model=resolved_model,
                    effort=resolved_effort,
                    agy_bin=agy_bin,
                    workspace_dir=ws_str,
                    git_evidence=claude_runner.collect_git_evidence(ws_str),
                    job_id=job_id,
                    session_key=session_key,
                    session_mode=session_mode,
                    session_action=session_action,
                    session_fallback=True,
                    plan_file=resolved_plan_file,
                    run_changed_files=run_changed_files,
                )
            if outcome == "EXITED":
                parsed = parse_agy_output(stdout_raw or "")

    total_elapsed = time.monotonic() - run_started
    after_snapshot = claude_runner._snapshot_workspace(ws_str)
    run_changed_files = claude_runner._diff_snapshots(before_snapshot, after_snapshot)
    git_ev = claude_runner.collect_git_evidence(ws_str)
    stderr_text = (stderr_raw or "").strip()

    if outcome == "CANCELLED":
        return _execute_error_response(
            "CANCELLED",
            "agy CLI execution was cancelled and its process tree was terminated.",
            model=resolved_model,
            effort=resolved_effort,
            agy_bin=agy_bin,
            workspace_dir=ws_str,
            exit_code=rc,
            duration_seconds=total_elapsed,
            result=(stdout_raw or "").strip(),
            stderr=stderr_text,
            git_evidence=git_ev,
            job_id=job_id,
            session_key=session_key,
            session_mode=session_mode,
            session_action=session_action,
            session_fallback=session_fallback,
            plan_file=resolved_plan_file,
            run_changed_files=run_changed_files,
        )

    if outcome == "TIMEOUT":
        return _execute_error_response(
            "TIMEOUT",
            f"agy CLI execution timed out after {resolved_timeout}s and process tree was terminated.",
            model=resolved_model,
            effort=resolved_effort,
            agy_bin=agy_bin,
            workspace_dir=ws_str,
            exit_code=rc,
            duration_seconds=total_elapsed,
            result=(stdout_raw or "").strip(),
            stderr=stderr_text,
            git_evidence=git_ev,
            job_id=job_id,
            session_key=session_key,
            session_mode=session_mode,
            session_action=session_action,
            session_fallback=session_fallback,
            plan_file=resolved_plan_file,
            run_changed_files=run_changed_files,
        )

    err_msg: Optional[str] = None
    resp_text = parsed["response"] or ""
    if rc != 0 or parsed["is_error"]:
        status = "ERROR"
        err_msg = (
            parsed["error_detail"]
            or resp_text
            or stderr_text
            or f"agy CLI execution exited with code {rc}"
        )
    elif re.search(r"(?m)^\s*(?:\*\*)?STATUS:\s*BLOCKED(?:\*\*)?\b", resp_text):
        status = "BLOCKED"
    else:
        status = "DONE"

    final_conv_id = parsed["conversation_id"] or target_conv_id
    post_run_tree: Optional[str] = None
    run_id: Optional[str] = None
    if status in ("DONE", "BLOCKED"):
        claude_runner._ensure_state_dir(ws_str)
        post_run_tree = claude_runner._capture_git_tree(ws_str)
        if final_conv_id:
            claude_runner._record_session_completion(
                ws_str,
                session_key=session_key,
                session_id=final_conv_id,
                target_session_id=target_conv_id,
                session_action=session_action,
                session_fallback=session_fallback,
                plan_sha256=plan_sha256,
                status=status,
                resolved_plan_file=resolved_plan_file,
                run_changed_files=run_changed_files,
                num_turns=parsed["num_turns"],
                pre_run_tree=pre_run_tree,
                post_run_tree=post_run_tree,
            )
        state_result = claude_runner._update_state_after_execute(
            ws_str,
            status=status,
            plan_text=effective_plan,
            plan_file=resolved_plan_file,
            session_key=session_key,
            session_id=final_conv_id,
            session_action=session_action,
            run_changed_files=run_changed_files,
            result_text=resp_text,
            num_turns=parsed["num_turns"],
            pre_run_tree=pre_run_tree,
            post_run_tree=post_run_tree,
            run_id_prefix="exec-agy",
        )
        run_id = state_result.get("run_id")
    elif status == "ERROR" and (state_dir_existed or run_changed_files):
        claude_runner._ensure_state_dir(ws_str)
        claude_runner._record_failed_execute_state(
            ws_str,
            executor="agy",
            plan_text=effective_plan,
            plan_file=resolved_plan_file,
            run_changed_files=run_changed_files,
            error_msg=err_msg,
            pre_run_tree=pre_run_tree,
        )

    payload: dict[str, Any] = {
        "status": status,
        "model": resolved_model or None,
        "effort": resolved_effort or None,
        "agy_bin": agy_bin,
        "workspace_dir": ws_str,
        "exit_code": rc,
        "duration_seconds": round(total_elapsed, 3),
        "cli_duration_seconds": parsed["duration_seconds"],
        "num_turns": parsed["num_turns"],
        "usage": parsed["usage"],
        "conversation_id": final_conv_id,
        "session_key": session_key,
        "session_mode": session_mode,
        "session_action": session_action,
        "session_fallback": session_fallback,
        "plan_file": resolved_plan_file,
        "history_injected": history_injected,
        "is_git_repo": git_ev["is_git_repo"],
        "changed_files": git_ev["changed_files"],
        "run_changed_files": run_changed_files,
        "git_diff_stat": git_ev["git_diff_stat"],
        "result": resp_text,
        "stderr": stderr_text,
        "error": err_msg,
        "pre_run_tree": pre_run_tree,
        "post_run_tree": post_run_tree,
        "external_drift_injected": external_drift_injected,
        "external_drift_files": external_drift_files,
        "run_id": run_id,
    }
    if job_id is not None:
        payload["job_id"] = job_id
    return payload


def agy_execute(
    workspace_dir: str,
    plan: Optional[str] = None,
    allowed_files: Optional[list[str]] = None,
    verification_commands: Optional[list[str]] = None,
    extra_context: Optional[str] = None,
    model: Optional[str] = None,
    effort: Optional[str] = None,
    timeout_seconds: Optional[int] = None,
    *,
    plan_file: Optional[str] = None,
    session_key: Optional[str] = None,
    session_mode: Optional[str] = None,
    resume_conversation_id: Optional[str] = None,
    include_history: bool = True,
    async_mode: bool = False,
    enforce_sync_cap: bool = True,
    cancel_event: Optional[threading.Event] = None,
) -> dict[str, Any]:
    """Execute an approved or interrupted plan via Account B Antigravity CLI (default gemini-4-hydrogen-xhigh)."""
    prepared, err_resp = _validate_and_prepare_agy_execute(
        workspace_dir=workspace_dir,
        plan=plan,
        allowed_files=allowed_files,
        verification_commands=verification_commands,
        model=model,
        effort=effort,
        timeout_seconds=timeout_seconds,
        plan_file=plan_file,
        session_key=session_key,
        session_mode=session_mode,
        resume_conversation_id=resume_conversation_id,
        include_history=include_history,
        async_mode=async_mode,
        enforce_sync_cap=enforce_sync_cap,
    )
    if err_resp is not None or prepared is None:
        assert err_resp is not None
        return err_resp

    job, active_id = claude_runner.JOB_MANAGER.register_job(
        workspace_dir=prepared["ws_str"],
        model=prepared["resolved_model"] or "agy-default",
        permission_mode="execute",
        max_turns=0,
        timeout_seconds=prepared["resolved_timeout"],
        is_async=prepared["async_mode"],
        cancel_event=cancel_event,
        job_prefix="agy-exec",
        lock_mode="write",
    )
    if job is None:
        return _execute_error_response(
            "BUSY",
            f"Another job ({active_id}) is already running in workspace '{prepared['ws_str']}'. "
            "Poll it with claude_execute_status or stop it with claude_execute_cancel before running agy_execute.",
            model=prepared["resolved_model"],
            effort=prepared["resolved_effort"],
            agy_bin=prepared["agy_bin"],
            workspace_dir=prepared["ws_str"],
            git_evidence=claude_runner.collect_git_evidence(prepared["ws_str"]),
            active_job_id=active_id,
            session_key=prepared["resolved_session_key"],
            session_mode=prepared["resolved_session_mode"],
            plan_file=prepared["resolved_plan_file"],
        )

    if prepared["async_mode"]:

        def _worker() -> None:
            res: Optional[dict[str, Any]] = None
            try:
                res = _run_agy_execute_prepared(
                    prepared=prepared,
                    allowed_files=allowed_files,
                    verification_commands=verification_commands,
                    extra_context=extra_context,
                    cancel_event=job.cancel_event,
                    job_id=job.job_id,
                )
            except Exception as exc:
                res = _execute_error_response(
                    "ERROR",
                    f"Background agy_execute worker failed: {exc}",
                    model=prepared["resolved_model"],
                    effort=prepared["resolved_effort"],
                    agy_bin=prepared["agy_bin"],
                    workspace_dir=prepared["ws_str"],
                    job_id=job.job_id,
                    session_key=prepared["resolved_session_key"],
                    session_mode=prepared["resolved_session_mode"],
                    plan_file=prepared["resolved_plan_file"],
                )
            finally:
                if res is None:
                    res = _execute_error_response(
                        "ERROR",
                        "Background agy_execute worker exited without result.",
                        model=prepared["resolved_model"],
                        effort=prepared["resolved_effort"],
                        agy_bin=prepared["agy_bin"],
                        workspace_dir=prepared["ws_str"],
                        job_id=job.job_id,
                        session_key=prepared["resolved_session_key"],
                        session_mode=prepared["resolved_session_mode"],
                        plan_file=prepared["resolved_plan_file"],
                    )
                claude_runner.JOB_MANAGER.finish_job(job, res)

        threading.Thread(target=_worker, daemon=True).start()
        return {
            "status": "STARTED",
            "job_id": job.job_id,
            "workspace_dir": prepared["ws_str"],
            "model": prepared["resolved_model"] or None,
            "effort": prepared["resolved_effort"] or None,
            "timeout_seconds": prepared["resolved_timeout"],
            "agy_bin": prepared["agy_bin"],
            "session_key": prepared["resolved_session_key"],
            "session_mode": prepared["resolved_session_mode"],
            "plan_file": prepared["resolved_plan_file"],
            "error": None,
        }

    res: Optional[dict[str, Any]] = None
    try:
        res = _run_agy_execute_prepared(
            prepared=prepared,
            allowed_files=allowed_files,
            verification_commands=verification_commands,
            extra_context=extra_context,
            cancel_event=job.cancel_event,
            job_id=job.job_id,
        )
        return res
    finally:
        if res is None:
            res = _execute_error_response(
                "ERROR",
                "Unexpected internal failure while executing with agy CLI.",
                model=prepared["resolved_model"],
                effort=prepared["resolved_effort"],
                agy_bin=prepared["agy_bin"],
                workspace_dir=prepared["ws_str"],
                job_id=job.job_id,
                session_key=prepared["resolved_session_key"],
                session_mode=prepared["resolved_session_mode"],
                plan_file=prepared["resolved_plan_file"],
            )
        claude_runner.JOB_MANAGER.finish_job(job, res)


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Run read-only blind verification, fallback execution, or on-demand planning with local Antigravity CLI (agy)."
    )
    parser.add_argument(
        "--healthcheck",
        action="store_true",
        help="Verify local agy CLI binary and settings path without invoking LLM.",
    )
    parser.add_argument(
        "--plan",
        action="store_true",
        dest="plan_mode",
        help="Run read-only planning (STATUS: READY|NEED_CLARIFICATION|BLOCKED).",
    )
    parser.add_argument(
        "--execute",
        action="store_true",
        dest="execute_mode",
        help="Run unattended execution via Account B agy CLI (STATUS: DONE|BLOCKED; default model: gemini-4-hydrogen-xhigh).",
    )
    parser.add_argument(
        "--verify",
        action="store_true",
        help="Run independent read-only blind verification (VERDICT: PASS|FAIL|BLOCKED).",
    )
    parser.add_argument(
        "--workspace",
        default=None,
        help="Target workspace directory (defaults to '.' for --plan/--execute/--verify).",
    )
    parser.add_argument(
        "--request",
        help="User task description or clarification answers (--plan mode).",
    )
    parser.add_argument(
        "--save-plan-file",
        help="Optional path strictly under .agents/plans/ to save STATUS: READY plan.",
    )
    parser.add_argument(
        "--plan-text",
        help="Approved plan text to execute or audit (--execute/--verify modes).",
    )
    parser.add_argument(
        "--plan-file",
        help="Path to Markdown/text file containing approved plan (--execute/--verify modes).",
    )
    parser.add_argument(
        "--session-key",
        help="Session continuity key (defaults to 'planner:workspace' for --plan and 'agy:workspace' for --execute).",
    )
    parser.add_argument(
        "--session-mode",
        help="Session policy for --plan/--execute: auto (default), resume, or fresh.",
    )
    parser.add_argument(
        "--resume-conversation-id",
        help="Explicit agy conversation_id to resume directly via --resume.",
    )
    parser.add_argument(
        "--no-history",
        action="store_true",
        help="Disable injecting L1/L2 continuity context.",
    )
    parser.add_argument(
        "--no-diff",
        action="store_true",
        help="Disable injecting git diff into verify prompt (--verify only).",
    )
    parser.add_argument(
        "--diff-scope",
        default="last_run",
        help="Verify diff scope: 'last_run' (default) or 'workspace'.",
    )
    parser.add_argument(
        "--no-bash",
        action="store_true",
        help="Restrict verify audit to static inspection without shell commands.",
    )
    parser.add_argument(
        "--model",
        help=(
            "Optional agy model slug (defaults: --verify gemini-4-carbon-high, "
            "--execute gemini-4-hydrogen-xhigh, --plan agy settings.json; "
            "set env var to '' to follow settings.json)."
        ),
    )
    parser.add_argument(
        "--effort",
        help="Optional reasoning effort: low, medium, high, xhigh, or max.",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        help="Timeout in seconds for standalone CLI execution (1-1800, default: 900).",
    )
    parser.add_argument(
        "--allowed-file",
        action="append",
        dest="allowed_files",
        help="Authorized file path for --execute or --verify (repeatable).",
    )
    parser.add_argument(
        "--verify-cmd",
        action="append",
        dest="verification_commands",
        help="Verification command to run (--execute/--verify, repeatable).",
    )
    parser.add_argument(
        "--extra-context",
        help="Optional supplementary context passed to agy CLI.",
    )

    args = parser.parse_args(argv)

    if args.healthcheck:
        res = agy_healthcheck(workspace_dir=args.workspace)
        print(json.dumps(res, ensure_ascii=False, indent=2))
        return 0 if res.get("ok") else 1

    if args.execute_mode:
        res = agy_execute(
            workspace_dir=args.workspace or ".",
            plan=args.plan_text,
            plan_file=args.plan_file,
            allowed_files=args.allowed_files,
            verification_commands=args.verification_commands,
            extra_context=args.extra_context,
            model=args.model,
            effort=args.effort,
            timeout_seconds=args.timeout,
            session_key=args.session_key,
            session_mode=args.session_mode,
            resume_conversation_id=args.resume_conversation_id,
            include_history=not args.no_history,
            enforce_sync_cap=False,
        )
        print(json.dumps(res, ensure_ascii=False, indent=2))
        status = res.get("status")
        if status == "DONE":
            return 0
        if status == "BLOCKED":
            return 2
        return 1

    if args.verify:
        res = agy_verify(
            workspace_dir=args.workspace or ".",
            plan=args.plan_text,
            plan_file=args.plan_file,
            allowed_files=args.allowed_files,
            verification_commands=args.verification_commands,
            extra_context=args.extra_context,
            model=args.model,
            effort=args.effort,
            timeout_seconds=args.timeout,
            include_history=not args.no_history,
            include_git_diff=not args.no_diff,
            diff_scope=args.diff_scope,
            allow_bash=not args.no_bash,
            enforce_sync_cap=False,
        )
        print(json.dumps(res, ensure_ascii=False, indent=2))
        status = res.get("status")
        if status == "PASS":
            return 0
        if status == "BLOCKED":
            return 2
        if status == "FAIL":
            return 3
        return 1

    if args.plan_mode:
        res = agy_plan(
            workspace_dir=args.workspace or ".",
            request=args.request or "",
            save_plan_file=args.save_plan_file,
            session_key=args.session_key,
            session_mode=args.session_mode,
            resume_conversation_id=args.resume_conversation_id,
            include_history=not args.no_history,
            extra_context=args.extra_context,
            model=args.model,
            effort=args.effort,
            timeout_seconds=args.timeout,
            enforce_sync_cap=False,
        )
        print(json.dumps(res, ensure_ascii=False, indent=2))
        status = res.get("status")
        if status == "READY":
            return 0
        if status in ("NEED_CLARIFICATION", "BLOCKED"):
            return 2
        return 1

    parser.print_help()
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
'@
Write-SafeFile -RelativePath '.agents/plugins/claude-executor/agy_runner.py' -Content $content8

$content9 = @'
#!/usr/bin/env python3
"""Zero-dependency non-blocking JSON-RPC 2.0 MCP stdio server for claude_runner."""

from __future__ import annotations

import json
import sys
import threading
import time
from pathlib import Path
from typing import Any, Optional

_PLUGIN_DIR = str(Path(__file__).resolve().parent)
if _PLUGIN_DIR not in sys.path:
    sys.path.insert(0, _PLUGIN_DIR)

import claude_runner  # noqa: E402
import agy_runner  # noqa: E402

SERVER_INFO = {
    "name": "claude-executor",
    "version": "2.5.2",
}

DEFAULT_PROTOCOL_VERSION = "2024-11-05"

_EXEC_COMMON_PROPERTIES: dict[str, Any] = {
    "workspace_dir": {
        "type": "string",
        "description": "Absolute path to the target project workspace directory.",
    },
    "plan": {
        "type": "string",
        "description": (
            "Complete approved implementation plan or fix-round instructions "
            "(optional when plan_file is provided)."
        ),
    },
    "plan_file": {
        "type": "string",
        "description": (
            "Path to the approved plan file (relative to workspace_dir or absolute). "
            "It identifies the plan content but does NOT change the warm session."
        ),
    },
    "session_key": {
        "type": "string",
        "description": (
            "Continuity bucket in .agents/state/session-index.json (default: 'workspace'), "
            "so sequential small updates and new plan files stay on one warm session. "
            "Pass a custom key only for unrelated subsystems."
        ),
    },
    "session_mode": {
        "type": "string",
        "enum": sorted(claude_runner.VALID_SESSION_MODES),
        "description": (
            "'auto' (default): resume the warm workspace session within TTL 3600s / 30 turns "
            "and inject a compact External Workspace Changes diff when files were edited outside "
            "the session, rotate otherwise; 'resume' to force resuming; 'fresh' to force a new session."
        ),
    },
    "resume_session_id": {
        "type": "string",
        "description": "Explicit Claude CLI session_id to resume directly via --resume.",
    },
    "include_history": {
        "type": "boolean",
        "description": (
            "Inject bounded L1 .agents/state/workspace-brief.md plus the latest 2 L2 plan-history "
            "entries on fresh/rotated/fallback runs (default: true)."
        ),
    },
    "allowed_files": {
        "type": "array",
        "items": {"type": "string"},
        "description": "Authorized file paths Claude is permitted to create or modify.",
    },
    "verification_commands": {
        "type": "array",
        "items": {"type": "string"},
        "description": "Commands Claude must execute to collect objective runtime evidence.",
    },
    "extra_context": {
        "type": "string",
        "description": "Optional supplementary context or constraints for the execution.",
    },
    "model": {
        "type": "string",
        "description": (
            "Claude model alias or ID (default: sonnet -> Sonnet 5.5; "
            "e.g. claude-sonnet-5-5, sonnet[1m])."
        ),
    },
    "effort": {
        "type": "string",
        "enum": sorted(claude_runner.VALID_EFFORTS),
        "description": (
            "Claude CLI reasoning effort: low, medium, high, xhigh, or max "
            f"(default: CLAUDE_EFFORT or {claude_runner.DEFAULT_EFFORT})."
        ),
    },
    "max_turns": {
        "type": "integer",
        "minimum": 1,
        "maximum": 100,
        "description": f"Maximum Claude CLI agentic turns (default: {claude_runner.DEFAULT_MAX_TURNS}).",
    },
    "permission_mode": {
        "type": "string",
        "enum": sorted(claude_runner.VALID_PERMISSION_MODES),
        "description": "Claude CLI permission mode (default: bypassPermissions).",
    },
}

TOOLS: list[dict[str, Any]] = [
    {
        "name": "claude_healthcheck",
        "description": (
            "Zero-cost readiness check for local Claude Code CLI. "
            "Verifies binary discovery, claude --version, ~/.claude auth directory, "
            "model/effort defaults, strict MCP mode, active jobs, timeout/session settings, and optional workspace "
            ".agents/state continuity status (including workspace-brief presence and open issues "
            "counts) without invoking any LLM."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "workspace_dir": {
                    "type": "string",
                    "description": (
                        "Optional workspace directory to inspect .agents/state/plan-history.md "
                        "and session-index.json (read-only)."
                    ),
                },
            },
            "additionalProperties": False,
        },
    },
    {
        "name": "claude_execute",
        "description": (
            "Synchronous fast path (capped at 165s, strictly under Antigravity's 180s MCP limit) "
            "to execute small/medium approved plans unattended via local Claude Code CLI (Sonnet 5.5) "
            "with automatic local continuity cache (.agents/state/plan-history.md and session-index.json). "
            "Returns BUSY immediately if another job is already running in the same workspace. "
            "For large tasks (>2 min, bulk file generation, terraform init, npm install), "
            "use claude_execute_start + claude_execute_status instead."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                **_EXEC_COMMON_PROPERTIES,
                "timeout_seconds": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": claude_runner.SYNC_MAX_TIMEOUT_SECONDS,
                    "description": (
                        f"Sync timeout in seconds (default: {claude_runner.SYNC_DEFAULT_TIMEOUT_SECONDS}, "
                        f"max: {claude_runner.SYNC_MAX_TIMEOUT_SECONDS})."
                    ),
                },
            },
            "required": ["workspace_dir"],
            "additionalProperties": False,
        },
    },
    {
        "name": "claude_execute_start",
        "description": (
            "Start a long-running approved plan asynchronously via local Claude Code CLI (Sonnet 5.5) "
            "with local continuity cache (.agents/state/plan-history.md and session-index.json) "
            "and immediately return a job_id without hitting the 180s MCP timeout. "
            "Poll completion with claude_execute_status or stop it with claude_execute_cancel."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                **_EXEC_COMMON_PROPERTIES,
                "timeout_seconds": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": claude_runner.ASYNC_MAX_TIMEOUT_SECONDS,
                    "description": (
                        f"Async background timeout in seconds (default: {claude_runner.ASYNC_DEFAULT_TIMEOUT_SECONDS}, "
                        f"max: {claude_runner.ASYNC_MAX_TIMEOUT_SECONDS})."
                    ),
                },
            },
            "required": ["workspace_dir"],
            "additionalProperties": False,
        },
    },
    {
        "name": "claude_execute_status",
        "description": (
            "Long-poll the status or final result of an async job started with claude_execute_start "
            "(or agy_plan / agy_execute / agy_verify with async_mode=true). "
            "Waits up to wait_seconds (default 30s, max 120s) for completion before returning RUNNING or final result."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "job_id": {
                    "type": "string",
                    "description": "Job ID returned by an async start call (or active_job_id from BUSY).",
                },
                "wait_seconds": {
                    "type": "integer",
                    "minimum": 0,
                    "maximum": claude_runner.STATUS_MAX_WAIT_SECONDS,
                    "description": (
                        f"Maximum seconds to wait for job completion before returning RUNNING "
                        f"(default: {claude_runner.STATUS_DEFAULT_WAIT_SECONDS}, max: {claude_runner.STATUS_MAX_WAIT_SECONDS})."
                    ),
                },
            },
            "required": ["job_id"],
            "additionalProperties": False,
        },
    },
    {
        "name": "claude_execute_cancel",
        "description": (
            "Cancel an active Claude or Agy execution/planning/verification job, terminate its "
            "entire child process tree, and release the workspace RWLock slot."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "job_id": {
                    "type": "string",
                    "description": "Active job ID to terminate.",
                },
            },
            "required": ["job_id"],
            "additionalProperties": False,
        },
    },
    {
        "name": "claude_verify",
        "description": (
            "Run an independent read-only blind audit via local Claude Code CLI (default Opus 5.5, "
            "--model opus) in a fresh no-persistence context without executor self-reports. "
            "Serves as the parallel secondary double-blind auditor alongside agy_verify for "
            "major/milestone/high-risk changes and automatic fallback when agy CLI is unavailable. "
            "Blocks write/edit/mutating tools, checks directory snapshots for read_only_violation, "
            "audits a turn-scoped or full-workspace git diff plus .agents/state/plan-history.md, "
            "and enforces VERDICT: PASS|FAIL|BLOCKED."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "workspace_dir": _EXEC_COMMON_PROPERTIES["workspace_dir"],
                "plan": _EXEC_COMMON_PROPERTIES["plan"],
                "plan_file": {
                    "type": "string",
                    "description": (
                        "Optional path to Markdown/text file containing the approved plan "
                        "(relative to workspace_dir or absolute)."
                    ),
                },
                "allowed_files": _EXEC_COMMON_PROPERTIES["allowed_files"],
                "verification_commands": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Read-only verification commands the verifier should run to collect objective runtime evidence.",
                },
                "extra_context": {
                    "type": "string",
                    "description": "Optional additional focus areas or disputed findings (do not feed executor self-reports for normal blind audits).",
                },
                "model": {
                    "type": "string",
                    "description": (
                        "Claude verifier model alias or ID (default: opus -> Opus 5.5; "
                        "e.g. claude-opus-5-5, opus[1m])."
                    ),
                },
                "effort": {
                    "type": "string",
                    "enum": sorted(claude_runner.VALID_EFFORTS),
                    "description": (
                        "Claude CLI verifier reasoning effort: low, medium, high, xhigh, or max "
                        f"(default: CLAUDE_VERIFY_EFFORT or {claude_runner.DEFAULT_VERIFY_EFFORT})."
                    ),
                },
                "max_turns": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 100,
                    "description": f"Maximum Claude CLI verifier turns (default: {claude_runner.DEFAULT_VERIFY_MAX_TURNS}).",
                },
                "timeout_seconds": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": claude_runner.SYNC_MAX_TIMEOUT_SECONDS,
                    "description": (
                        f"Sync verify timeout in seconds (default: {claude_runner.SYNC_DEFAULT_TIMEOUT_SECONDS}, "
                        f"max: {claude_runner.SYNC_MAX_TIMEOUT_SECONDS})."
                    ),
                },
                "include_history": {
                    "type": "boolean",
                    "description": "Read-only inject .agents/state/plan-history.md to verify cross-plan compatibility and anti-duplication (default: true).",
                },
                "include_git_diff": {
                    "type": "boolean",
                    "description": "Inject bounded current git diff and status into the audit prompt (default: true).",
                },
                "diff_scope": {
                    "type": "string",
                    "enum": sorted(claude_runner.VALID_DIFF_SCOPES),
                    "description": (
                        "'last_run' (default): diff only the changes since the last executor run "
                        "checkpoint pre_run_tree (new files included), falling back to 'workspace' "
                        "when unavailable; 'workspace': full uncommitted workspace diff "
                        "(milestones / pre-commit / pre-PR)."
                    ),
                },
                "allow_bash": {
                    "type": "boolean",
                    "description": "Allow non-mutating Bash commands (tests, typechecks, linters) during read-only audit (default: true).",
                },
            },
            "required": ["workspace_dir"],
            "additionalProperties": False,
        },
    },
    {
        "name": "claude_handoff",
        "description": (
            "Zero-LLM-cost portable handoff packet from local .agents/state "
            "(L1 workspace-brief + L2 plan-history + L3 run archives): current checkpoint, "
            "active artifact and interface map, open verification issues, git status. "
            "Read-only; never creates .agents/state. Use when switching agents or planning a new update."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "workspace_dir": {
                    "type": "string",
                    "description": "Absolute path to the target project workspace directory.",
                },
                "mode": {
                    "type": "string",
                    "enum": sorted(claude_runner.VALID_HANDOFF_MODES),
                    "description": (
                        "Handoff intent: 'continue' (default: resume the current work), "
                        "'fix_review' (focus on open verification issues), or "
                        "'new_plan' (plan a follow-up update without duplicating prior work)."
                    ),
                },
                "max_bytes": {
                    "type": "integer",
                    "minimum": claude_runner.MIN_HANDOFF_MAX_BYTES,
                    "maximum": claude_runner.MAX_HANDOFF_MAX_BYTES,
                    "description": (
                        f"Maximum packet size in bytes "
                        f"(default: {claude_runner.DEFAULT_HANDOFF_MAX_BYTES})."
                    ),
                },
                "search_query": {
                    "type": "string",
                    "description": "Optional case-insensitive local search across state files to include matching excerpts.",
                },
            },
            "required": ["workspace_dir"],
            "additionalProperties": False,
        },
    },
    {
        "name": "agy_healthcheck",
        "description": (
            "Zero-LLM readiness check for local Antigravity CLI (agy, e.g. Account B). "
            "Verifies binary discovery, agy --version, ~/.gemini/antigravity-cli/settings.json, "
            "model/effort/sandbox defaults, active jobs, and optional workspace .agents/state status."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "workspace_dir": {
                    "type": "string",
                    "description": (
                        "Optional workspace directory to inspect .agents/state continuity status "
                        "(read-only)."
                    ),
                },
            },
            "additionalProperties": False,
        },
    },
    {
        "name": "agy_plan",
        "description": (
            "Optional on-demand Account B read-only planning offload via local Antigravity CLI "
            "(agy --mode plan) for huge repo scans or conserving Account A quota. "
            "Reuses warm planner session (default session_key='planner:workspace') with external "
            "drift detection and enforces Line 1 STATUS: READY | NEED_CLARIFICATION | BLOCKED. "
            "Only writes optional save_plan_file (strictly under .agents/plans/) from host Python "
            "when STATUS: READY and no workspace mutation occurred. Supports async_mode=true."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "workspace_dir": _EXEC_COMMON_PROPERTIES["workspace_dir"],
                "request": {
                    "type": "string",
                    "description": "Feature/bugfix request or clarification answers for the planner.",
                },
                "save_plan_file": {
                    "type": "string",
                    "description": (
                        "Optional target file strictly under .agents/plans/ to save approved plan text "
                        "when STATUS: READY (written by host Python after read-only check)."
                    ),
                },
                "session_key": {
                    "type": "string",
                    "description": (
                        "Planner continuity bucket in session-index.json (default: 'planner:workspace')."
                    ),
                },
                "session_mode": {
                    "type": "string",
                    "enum": sorted(claude_runner.VALID_SESSION_MODES),
                    "description": "'auto' (default), 'resume' (after NEED_CLARIFICATION), or 'fresh'.",
                },
                "resume_conversation_id": {
                    "type": "string",
                    "description": "Explicit agy conversation_id to resume directly via --resume.",
                },
                "include_history": _EXEC_COMMON_PROPERTIES["include_history"],
                "extra_context": {
                    "type": "string",
                    "description": "Optional supplementary constraints or context for planning.",
                },
                "model": {
                    "type": "string",
                    "description": "Optional agy model slug (omit to use Account B agy settings.json default).",
                },
                "effort": {
                    "type": "string",
                    "enum": sorted(agy_runner.VALID_AGY_EFFORTS),
                    "description": "Optional reasoning effort: low, medium, high, xhigh, or max.",
                },
                "timeout_seconds": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": claude_runner.ASYNC_MAX_TIMEOUT_SECONDS,
                    "description": (
                        f"Timeout in seconds (sync cap {claude_runner.SYNC_MAX_TIMEOUT_SECONDS}s, "
                        f"async max {claude_runner.ASYNC_MAX_TIMEOUT_SECONDS}s)."
                    ),
                },
                "async_mode": {
                    "type": "boolean",
                    "description": (
                        "If true, return job_id immediately for long repository scans; "
                        "poll with claude_execute_status (default: false)."
                    ),
                },
            },
            "required": ["workspace_dir", "request"],
            "additionalProperties": False,
        },
    },
    {
        "name": "agy_verify",
        "description": (
            "Run an independent read-only primary cross-vendor blind audit via local Antigravity CLI "
            "(agy --mode plan, default gemini-4-carbon-high) in a fresh context without --resume or "
            "executor self-reports. Acquires a shared read lock (runs in parallel with claude_verify "
            "for double-blind checks on major changes), checks directory snapshots, enforces "
            "VERDICT: PASS|FAIL|BLOCKED, and supports async_mode=true."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "workspace_dir": _EXEC_COMMON_PROPERTIES["workspace_dir"],
                "plan": _EXEC_COMMON_PROPERTIES["plan"],
                "plan_file": {
                    "type": "string",
                    "description": (
                        "Optional path to Markdown/text file containing the approved plan "
                        "(relative to workspace_dir or absolute)."
                    ),
                },
                "allowed_files": _EXEC_COMMON_PROPERTIES["allowed_files"],
                "verification_commands": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Read-only verification commands agy should run when allow_bash is true.",
                },
                "extra_context": {
                    "type": "string",
                    "description": "Optional audit focus or disputed finding for targeted arbitration.",
                },
                "model": {
                    "type": "string",
                    "description": (
                        "Optional agy verifier model slug (default: gemini-4-carbon-high; override e.g. "
                        "gemini-4-neon-xhigh, or set AGY_VERIFY_MODEL='' to follow agy settings.json)."
                    ),
                },
                "effort": {
                    "type": "string",
                    "enum": sorted(agy_runner.VALID_AGY_EFFORTS),
                    "description": "Optional reasoning effort: low, medium, high, xhigh, or max.",
                },
                "timeout_seconds": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": claude_runner.ASYNC_MAX_TIMEOUT_SECONDS,
                    "description": (
                        f"Timeout in seconds (sync cap {claude_runner.SYNC_MAX_TIMEOUT_SECONDS}s, "
                        f"async max {claude_runner.ASYNC_MAX_TIMEOUT_SECONDS}s)."
                    ),
                },
                "include_history": _EXEC_COMMON_PROPERTIES["include_history"],
                "include_git_diff": {
                    "type": "boolean",
                    "description": "Inject bounded current git diff and status into the audit prompt (default: true).",
                },
                "diff_scope": {
                    "type": "string",
                    "enum": sorted(claude_runner.VALID_DIFF_SCOPES),
                    "description": "'last_run' (default, changes since pre_run_tree) or 'workspace'.",
                },
                "allow_bash": {
                    "type": "boolean",
                    "description": "Allow read-only verification shell checks during audit (default: true).",
                },
                "async_mode": {
                    "type": "boolean",
                    "description": (
                        "If true, return job_id immediately for long full-workspace audits; "
                        "poll with claude_execute_status (default: false)."
                    ),
                },
            },
            "required": ["workspace_dir"],
            "additionalProperties": False,
        },
    },
    {
        "name": "agy_execute",
        "description": (
            "Execute an approved plan or incrementally continue an interrupted Claude run via Account B "
            "local Antigravity CLI (default gemini-4-hydrogen-xhigh). Acquires an exclusive write lock, "
            "shares .agents/state/ L1/L2/L3 continuity + Interrupted Run Recovery context, captures git "
            "tree checkpoints (pre_run_tree/post_run_tree), and supports async_mode=true."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "workspace_dir": _EXEC_COMMON_PROPERTIES["workspace_dir"],
                "plan": _EXEC_COMMON_PROPERTIES["plan"],
                "plan_file": _EXEC_COMMON_PROPERTIES["plan_file"],
                "session_key": {
                    "type": "string",
                    "description": (
                        "Continuity bucket in .agents/state/session-index.json (default: 'agy:workspace')."
                    ),
                },
                "session_mode": _EXEC_COMMON_PROPERTIES["session_mode"],
                "resume_conversation_id": {
                    "type": "string",
                    "description": "Explicit agy conversation_id to resume directly via --resume.",
                },
                "include_history": _EXEC_COMMON_PROPERTIES["include_history"],
                "allowed_files": _EXEC_COMMON_PROPERTIES["allowed_files"],
                "verification_commands": _EXEC_COMMON_PROPERTIES["verification_commands"],
                "extra_context": _EXEC_COMMON_PROPERTIES["extra_context"],
                "model": {
                    "type": "string",
                    "description": (
                        "Optional agy executor model slug (default: gemini-4-hydrogen-xhigh; override e.g. "
                        "claude-sonnet-5-5-high, or set AGY_EXECUTE_MODEL='' to follow agy settings.json)."
                    ),
                },
                "effort": {
                    "type": "string",
                    "enum": sorted(agy_runner.VALID_AGY_EFFORTS),
                    "description": "Optional reasoning effort: low, medium, high, xhigh, or max.",
                },
                "timeout_seconds": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": claude_runner.ASYNC_MAX_TIMEOUT_SECONDS,
                    "description": (
                        f"Timeout in seconds (sync cap {claude_runner.SYNC_MAX_TIMEOUT_SECONDS}s, "
                        f"async max {claude_runner.ASYNC_MAX_TIMEOUT_SECONDS}s)."
                    ),
                },
                "async_mode": {
                    "type": "boolean",
                    "description": (
                        "If true, return job_id immediately for long fallback executions; "
                        "poll with claude_execute_status (default: false)."
                    ),
                },
            },
            "required": ["workspace_dir"],
            "additionalProperties": False,
        },
    },
]

_VALID_TOOL_NAMES = {t["name"] for t in TOOLS}

_write_lock = threading.Lock()
_log_lock = threading.Lock()
_inflight_lock = threading.Lock()
_inflight_cancels: dict[Any, threading.Event] = {}
_worker_threads: set[threading.Thread] = set()
_shutting_down = threading.Event()


def _configure_stdio() -> None:
    for stream in (sys.stdin, sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if callable(reconfigure):
            try:
                reconfigure(encoding="utf-8", errors="replace")
            except Exception:
                pass


def _log_stderr(msg: str) -> None:
    with _log_lock:
        try:
            sys.stderr.write(f"[claude-executor mcp_server] {msg}\n")
            sys.stderr.flush()
        except Exception:
            pass


def _write_message(payload: dict[str, Any]) -> None:
    line = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    with _write_lock:
        if _shutting_down.is_set():
            return
        try:
            sys.stdout.write(line + "\n")
            sys.stdout.flush()
        except (BrokenPipeError, OSError, ValueError):
            pass


def _jsonrpc_result(req_id: Any, result: dict[str, Any]) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": req_id, "result": result}


def _jsonrpc_error(
    req_id: Any, code: int, message: str, data: Optional[Any] = None
) -> dict[str, Any]:
    err: dict[str, Any] = {"code": code, "message": message}
    if data is not None:
        err["data"] = data
    return {"jsonrpc": "2.0", "id": req_id, "error": err}


def _common_exec_kwargs(arguments: dict[str, Any]) -> dict[str, Any]:
    include_hist = arguments.get("include_history")
    return {
        "workspace_dir": arguments.get("workspace_dir", ""),
        "plan": arguments.get("plan"),
        "plan_file": arguments.get("plan_file"),
        "session_key": arguments.get("session_key"),
        "session_mode": arguments.get("session_mode"),
        "resume_session_id": arguments.get("resume_session_id"),
        "include_history": True if include_hist is None else include_hist,
        "allowed_files": arguments.get("allowed_files"),
        "verification_commands": arguments.get("verification_commands"),
        "extra_context": arguments.get("extra_context"),
        "model": arguments.get("model"),
        "effort": arguments.get("effort"),
        "max_turns": arguments.get("max_turns"),
        "permission_mode": arguments.get("permission_mode"),
        "timeout_seconds": arguments.get("timeout_seconds"),
    }


def _execute_tool(
    tool_name: str, arguments: dict[str, Any], req_cancel_event: threading.Event
) -> tuple[dict[str, Any], bool]:
    if tool_name == "claude_healthcheck":
        res = claude_runner.healthcheck(workspace_dir=arguments.get("workspace_dir"))
        return res, (not bool(res.get("ok")))

    if tool_name == "claude_execute":
        res = claude_runner.execute_plan(
            **_common_exec_kwargs(arguments),
            enforce_sync_cap=True,
            cancel_event=req_cancel_event,
        )
        return res, (res.get("status") in ("ERROR", "TIMEOUT", "BUSY"))

    if tool_name == "claude_execute_start":
        res = claude_runner.start_async_plan(**_common_exec_kwargs(arguments))
        return res, (res.get("status") in ("ERROR", "TIMEOUT", "BUSY"))

    if tool_name == "claude_execute_status":
        res = claude_runner.get_async_job_status(
            job_id=arguments.get("job_id", ""),
            wait_seconds=arguments.get("wait_seconds"),
            poll_cancel_event=req_cancel_event,
        )
        return res, (res.get("status") in ("ERROR", "TIMEOUT", "BUSY"))

    if tool_name == "claude_execute_cancel":
        res = claude_runner.cancel_async_job(job_id=arguments.get("job_id", ""))
        return res, (res.get("status") in ("ERROR", "TIMEOUT", "BUSY"))

    if tool_name == "claude_verify":
        inc_hist = arguments.get("include_history")
        inc_diff = arguments.get("include_git_diff")
        diff_scope_arg = arguments.get("diff_scope")
        al_bash = arguments.get("allow_bash")
        res = claude_runner.verify_plan(
            workspace_dir=arguments.get("workspace_dir", ""),
            plan=arguments.get("plan"),
            plan_file=arguments.get("plan_file"),
            allowed_files=arguments.get("allowed_files"),
            verification_commands=arguments.get("verification_commands"),
            extra_context=arguments.get("extra_context"),
            model=arguments.get("model"),
            effort=arguments.get("effort"),
            max_turns=arguments.get("max_turns"),
            timeout_seconds=arguments.get("timeout_seconds"),
            include_history=True if inc_hist is None else inc_hist,
            include_git_diff=True if inc_diff is None else inc_diff,
            diff_scope="last_run" if diff_scope_arg is None else diff_scope_arg,
            allow_bash=True if al_bash is None else al_bash,
            enforce_sync_cap=True,
            cancel_event=req_cancel_event,
        )
        return res, (res.get("status") in ("ERROR", "TIMEOUT", "BUSY"))

    if tool_name == "claude_handoff":
        max_bytes = arguments.get("max_bytes")
        mode_arg = arguments.get("mode")
        res = claude_runner.build_handoff_packet(
            workspace_dir=arguments.get("workspace_dir", ""),
            mode="continue" if mode_arg is None else mode_arg,
            max_bytes=(
                max_bytes
                if max_bytes is not None
                else claude_runner.DEFAULT_HANDOFF_MAX_BYTES
            ),
            search_query=arguments.get("search_query"),
        )
        return res, (not bool(res.get("ok")))

    if tool_name == "agy_healthcheck":
        res = agy_runner.agy_healthcheck(workspace_dir=arguments.get("workspace_dir"))
        return res, (not bool(res.get("ok")))

    if tool_name == "agy_plan":
        inc_hist = arguments.get("include_history")
        async_arg = arguments.get("async_mode")
        async_flag = False if async_arg is None else async_arg
        res = agy_runner.agy_plan(
            workspace_dir=arguments.get("workspace_dir", ""),
            request=arguments.get("request", ""),
            save_plan_file=arguments.get("save_plan_file"),
            session_key=arguments.get("session_key"),
            session_mode=arguments.get("session_mode"),
            resume_conversation_id=arguments.get("resume_conversation_id"),
            include_history=True if inc_hist is None else inc_hist,
            extra_context=arguments.get("extra_context"),
            model=arguments.get("model"),
            effort=arguments.get("effort"),
            timeout_seconds=arguments.get("timeout_seconds"),
            async_mode=async_flag,
            enforce_sync_cap=not bool(async_flag),
            cancel_event=None if async_flag else req_cancel_event,
        )
        return res, (res.get("status") in ("ERROR", "TIMEOUT", "BUSY"))

    if tool_name == "agy_verify":
        inc_hist = arguments.get("include_history")
        inc_diff = arguments.get("include_git_diff")
        diff_scope_arg = arguments.get("diff_scope")
        al_bash = arguments.get("allow_bash")
        async_arg = arguments.get("async_mode")
        async_flag = False if async_arg is None else async_arg
        res = agy_runner.agy_verify(
            workspace_dir=arguments.get("workspace_dir", ""),
            plan=arguments.get("plan"),
            plan_file=arguments.get("plan_file"),
            allowed_files=arguments.get("allowed_files"),
            verification_commands=arguments.get("verification_commands"),
            extra_context=arguments.get("extra_context"),
            model=arguments.get("model"),
            effort=arguments.get("effort"),
            timeout_seconds=arguments.get("timeout_seconds"),
            include_history=True if inc_hist is None else inc_hist,
            include_git_diff=True if inc_diff is None else inc_diff,
            diff_scope="last_run" if diff_scope_arg is None else diff_scope_arg,
            allow_bash=True if al_bash is None else al_bash,
            async_mode=async_flag,
            enforce_sync_cap=not bool(async_flag),
            cancel_event=None if async_flag else req_cancel_event,
        )
        return res, (res.get("status") in ("ERROR", "TIMEOUT", "BUSY"))

    if tool_name == "agy_execute":
        inc_hist = arguments.get("include_history")
        async_arg = arguments.get("async_mode")
        async_flag = False if async_arg is None else async_arg
        res = agy_runner.agy_execute(
            workspace_dir=arguments.get("workspace_dir", ""),
            plan=arguments.get("plan"),
            plan_file=arguments.get("plan_file"),
            allowed_files=arguments.get("allowed_files"),
            verification_commands=arguments.get("verification_commands"),
            extra_context=arguments.get("extra_context"),
            model=arguments.get("model"),
            effort=arguments.get("effort"),
            timeout_seconds=arguments.get("timeout_seconds"),
            session_key=arguments.get("session_key"),
            session_mode=arguments.get("session_mode"),
            resume_conversation_id=arguments.get("resume_conversation_id"),
            include_history=True if inc_hist is None else inc_hist,
            async_mode=async_flag,
            enforce_sync_cap=not bool(async_flag),
            cancel_event=None if async_flag else req_cancel_event,
        )
        return res, (res.get("status") in ("ERROR", "TIMEOUT", "BUSY"))

    raise ValueError(f"Unsupported tool: {tool_name}")


def _dispatch_tools_call(req_id: Any, params: Any) -> None:
    if not isinstance(params, dict):
        _write_message(_jsonrpc_error(req_id, -32602, "Invalid params: expected object."))
        return

    tool_name = params.get("name")
    arguments = params.get("arguments")
    if arguments is None:
        arguments = {}
    if not isinstance(arguments, dict):
        _write_message(
            _jsonrpc_error(req_id, -32602, "Invalid params: 'arguments' must be an object.")
        )
        return

    if not isinstance(tool_name, str) or tool_name not in _VALID_TOOL_NAMES:
        _write_message(_jsonrpc_error(req_id, -32602, f"Unknown tool: {tool_name!r}"))
        return

    req_cancel_event = threading.Event()
    with _inflight_lock:
        _inflight_cancels[req_id] = req_cancel_event

    def _run_call() -> None:
        current_thread = threading.current_thread()
        is_sync_cancellable = (
            tool_name in ("claude_execute", "claude_verify")
            or (tool_name in ("agy_plan", "agy_execute", "agy_verify") and not arguments.get("async_mode"))
        )
        try:
            res, is_err = _execute_tool(tool_name, arguments, req_cancel_event)
            with _inflight_lock:
                _inflight_cancels.pop(req_id, None)
            if req_cancel_event.is_set() and is_sync_cancellable:
                _log_stderr(f"suppressed stale response for cancelled {tool_name} id={req_id!r}")
                return
            _write_message(
                _jsonrpc_result(
                    req_id,
                    {
                        "content": [
                            {
                                "type": "text",
                                "text": json.dumps(res, ensure_ascii=False, indent=2),
                            }
                        ],
                        "isError": is_err,
                    },
                )
            )
        except Exception as exc:
            _log_stderr(f"tool {tool_name} id={req_id!r} unhandled error: {exc}")
            with _inflight_lock:
                _inflight_cancels.pop(req_id, None)
            if not (req_cancel_event.is_set() and is_sync_cancellable):
                _write_message(_jsonrpc_error(req_id, -32603, f"Internal error: {exc}"))
        finally:
            with _inflight_lock:
                _worker_threads.discard(current_thread)

    worker = threading.Thread(target=_run_call, daemon=True)
    with _inflight_lock:
        _worker_threads.add(worker)
    worker.start()


def _handle_notification(method: str, params: Any) -> None:
    if method == "notifications/cancelled" and isinstance(params, dict) and "requestId" in params:
        target_id = params.get("requestId")
        with _inflight_lock:
            cancel_ev = _inflight_cancels.get(target_id)
        if cancel_ev is not None:
            cancel_ev.set()


def handle_message(message: dict[str, Any]) -> None:
    """Process one parsed JSON-RPC 2.0 message without blocking stdin reads."""
    has_id = "id" in message
    req_id = message.get("id")
    method = message.get("method")
    params = message.get("params")

    if not isinstance(method, str):
        if has_id:
            _write_message(
                _jsonrpc_error(req_id, -32600, "Invalid Request: missing string 'method'.")
            )
        return

    # JSON-RPC notifications (no "id" field) must not produce any response.
    if not has_id:
        _handle_notification(method, params)
        return

    if method == "initialize":
        client_version = (
            params.get("protocolVersion")
            if isinstance(params, dict) and isinstance(params.get("protocolVersion"), str)
            else DEFAULT_PROTOCOL_VERSION
        )
        _write_message(
            _jsonrpc_result(
                req_id,
                {
                    "protocolVersion": client_version,
                    "capabilities": {"tools": {"listChanged": False}},
                    "serverInfo": SERVER_INFO,
                },
            )
        )
        return

    if method == "ping":
        _write_message(_jsonrpc_result(req_id, {}))
        return

    if method == "tools/list":
        _write_message(_jsonrpc_result(req_id, {"tools": TOOLS}))
        return

    if method == "tools/call":
        _dispatch_tools_call(req_id, params)
        return

    _write_message(_jsonrpc_error(req_id, -32601, f"Method not found: {method}"))


def _shutdown_cleanup() -> None:
    _shutting_down.set()
    with _inflight_lock:
        for ev in _inflight_cancels.values():
            ev.set()
        threads = list(_worker_threads)

    claude_runner.cancel_all_jobs(wait_seconds=3.0)

    deadline = time.monotonic() + 3.0
    for th in threads:
        remaining = deadline - time.monotonic()
        if remaining > 0:
            th.join(timeout=remaining)


def main() -> int:
    _configure_stdio()
    try:
        while True:
            raw_line = sys.stdin.readline()
            if not raw_line:
                break
            line = raw_line.strip()
            if not line:
                continue
            try:
                parsed = json.loads(line)
            except json.JSONDecodeError as exc:
                _write_message(_jsonrpc_error(None, -32700, f"Parse error: {exc}"))
                continue

            if not isinstance(parsed, dict):
                _write_message(
                    _jsonrpc_error(None, -32600, "Invalid Request: expected JSON object.")
                )
                continue

            try:
                handle_message(parsed)
            except Exception as exc:
                _log_stderr(f"unhandled dispatch error: {exc}")
                if "id" in parsed:
                    _write_message(
                        _jsonrpc_error(parsed.get("id"), -32603, f"Internal error: {exc}")
                    )
    finally:
        _shutdown_cleanup()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
'@
Write-SafeFile -RelativePath '.agents/plugins/claude-executor/mcp_server.py' -Content $content9

$content10 = @'
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
'@
Write-SafeFile -RelativePath '.agents/scripts/claude-exec.ps1' -Content $content10 -Utf8Bom

Ensure-GitIgnore
Ensure-GitRepo

if ($Force) {
  foreach ($retiredRel in @(
    ".agents/agents/argon-verifier.md",
    ".agents/agents/neon-planner.md",
    "scripts/claude-exec.ps1"
  )) {
    $retiredPath = Join-Path $resolvedTarget $retiredRel
    if (Test-Path -LiteralPath $retiredPath -PathType Leaf) {
      Remove-Item -LiteralPath $retiredPath -Force
      Write-Host "[CLEANUP] Removed retired/relocated file: $retiredPath" -ForegroundColor Yellow
    }
  }
  $legacyScriptsDir = Join-Path $resolvedTarget "scripts"
  if (Test-Path -LiteralPath $legacyScriptsDir -PathType Container) {
    if ((Get-ChildItem -LiteralPath $legacyScriptsDir -Force).Count -eq 0) {
      Remove-Item -LiteralPath $legacyScriptsDir -Force
      Write-Host "[CLEANUP] Removed empty legacy dir: $legacyScriptsDir" -ForegroundColor Yellow
    }
  }
}

Write-Host "Summary: wrote $($script:Written) file(s), skipped $($script:Skipped) existing file(s) (target: $resolvedTarget)" -ForegroundColor Cyan
