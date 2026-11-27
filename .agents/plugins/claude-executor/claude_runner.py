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
