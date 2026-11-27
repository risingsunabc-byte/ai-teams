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
