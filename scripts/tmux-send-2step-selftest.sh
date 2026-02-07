#!/usr/bin/env bash
set -euo pipefail

# Self-test for scripts/tmux-send-2step.sh
# - Proves 3 consecutive notify cycles execute cleanly.
# - Saves evidence (tmux capture-pane etc.) under artifacts/verification/<RUN_ID>/.

repo_root() {
  (cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
}

gen_run_id() {
  # UTC timestamp to match other RUN_ID patterns.
  date -u +%Y%m%dT%H%M%SZ
}

usage() {
  cat <<'USAGE'
Usage:
  tmux-send-2step-selftest.sh <RUN_ID>

Notes:
  - Writes evidence to: artifacts/verification/<RUN_ID>/
  - Requires tmux server to be running.
USAGE
}

if [[ ${#} -ne 1 ]]; then
  usage
  exit 1
fi

RUN_ID="$1"
ROOT="$(repo_root)"
OUT_DIR="$ROOT/artifacts/verification/$RUN_ID"
mkdir -p "$OUT_DIR"

command -v tmux >/dev/null 2>&1 || { echo "tmux not found" >&2; exit 1; }
tmux list-sessions >/dev/null 2>&1 || { echo "tmux server not running (no sessions)" >&2; exit 1; }

SESSION="tmux2step_selftest_$(echo "$RUN_ID" | tr -c 'A-Za-z0-9' '_')"
PANE="$SESSION:0.0"
AGENT_ID="selftest_${RUN_ID}"
TOKEN="$(echo "$RUN_ID" | tr -cd 'A-Za-z0-9' | tail -c 9)"
MARK_BASE="TMUX2STEP_${TOKEN}"

cleanup() {
  tmux kill-session -t "$SESSION" >/dev/null 2>&1 || true
}
trap cleanup EXIT

tmux new-session -d -s "$SESSION" -n test "bash --noprofile --norc"
tmux set-option -t "$PANE" -p @agent_id "$AGENT_ID" >/dev/null 2>&1 || true

tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{pane_id} #{pane_title} #{@agent_id}' >"$OUT_DIR/list-panes.txt"

# Guard check: pane_in_mode=1 (copy-mode) must be detected and refused by default.
tmux copy-mode -t "$PANE"
{
  echo "pane_in_mode=$(tmux display-message -p -t \"$PANE\" '#{pane_in_mode}')"
  set +e
  "$ROOT/scripts/tmux-send-2step.sh" notify "$PANE" "echo __${MARK_BASE}_COPYMODE__" >"$OUT_DIR/copy-mode-guard.stdout.txt" 2>"$OUT_DIR/copy-mode-guard.stderr.txt"
  rc=$?
  set -e
  echo "exit_code=$rc"
  if [[ "$rc" -eq 0 ]]; then
    echo "expected non-zero exit when pane_in_mode=1" >&2
    exit 1
  fi
} >"$OUT_DIR/copy-mode-guard.meta.txt" 2>&1

# Optional escape hatch: explicitly exit copy-mode (one-shot 'q') and proceed.
"$ROOT/scripts/tmux-send-2step.sh" notify --force-exit-copy-mode --force "$PANE" "echo __${MARK_BASE}_COPYMODE_EXIT__" >"$OUT_DIR/copy-mode-exit.stdout.txt" 2>"$OUT_DIR/copy-mode-exit.stderr.txt"

# 3 consecutive notify cycles.
for i in 1 2 3; do
  "$ROOT/scripts/tmux-send-2step.sh" notify --force "$PANE" "echo __${MARK_BASE}_${i}__" >"$OUT_DIR/notify-${i}.stdout.txt" 2>"$OUT_DIR/notify-${i}.stderr.txt"
done

# Also verify @agent_id resolution works (send to @selftest_<RUN_ID>).
"$ROOT/scripts/tmux-send-2step.sh" notify --force "@$AGENT_ID" "echo __${MARK_BASE}_AGENT__" >"$OUT_DIR/notify-agent.stdout.txt" 2>"$OUT_DIR/notify-agent.stderr.txt"

# Verify "bash -u" (nounset) does not break enter mode with only <target>.
# This specifically guards against regressions like "unbound variable" when args are empty.
bash -u "$ROOT/scripts/tmux-send-2step.sh" enter "$PANE" >"$OUT_DIR/strict-enter.stdout.txt" 2>"$OUT_DIR/strict-enter.stderr.txt"

sleep 0.2
tmux capture-pane -t "$PANE" -p >"$OUT_DIR/capture.txt"

ok=1
for i in 1 2 3; do
  if ! rg -n "__${MARK_BASE}_${i}__" "$OUT_DIR/capture.txt" >/dev/null 2>&1; then
    echo "missing marker $i" >&2
    ok=0
  fi
done
if ! rg -n "__${MARK_BASE}_COPYMODE_EXIT__" "$OUT_DIR/capture.txt" >/dev/null 2>&1; then
  echo "missing copy-mode exit marker" >&2
  ok=0
fi
if ! rg -n "__${MARK_BASE}_AGENT__" "$OUT_DIR/capture.txt" >/dev/null 2>&1; then
  echo "missing agent marker" >&2
  ok=0
fi

"$ROOT/scripts/tmux-send-2step.sh" --help >"$OUT_DIR/tmux-send-2step.help.txt" 2>&1 || true

if [[ "$ok" -ne 1 ]]; then
  echo "SELFTEST FAILED (see $OUT_DIR)" >&2
  exit 1
fi

echo "SELFTEST OK: $OUT_DIR"
