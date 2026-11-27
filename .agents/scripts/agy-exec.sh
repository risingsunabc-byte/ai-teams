#!/usr/bin/env bash
# Standalone WSL / POSIX CLI wrapper to run primary/parallel blind verification (--verify, default gemini-4-carbon-high), fallback execution (--execute, default gemini-4-hydrogen-xhigh), or on-demand read-only planning (--plan) via local agy CLI.
# Delegates directly to .agents/plugins/claude-executor/agy_runner.py.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="${SCRIPT_DIR}/../plugins/claude-executor/agy_runner.py"

if ! command -v python3 >/dev/null 2>&1; then
  echo "[ERROR] python3 not found. Please install Python 3." >&2
  exit 1
fi

if [[ ! -f "$RUNNER" ]]; then
  echo "[ERROR] Runner script not found: $RUNNER" >&2
  exit 1
fi

exec python3 "$RUNNER" "$@"
