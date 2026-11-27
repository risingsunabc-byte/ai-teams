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
