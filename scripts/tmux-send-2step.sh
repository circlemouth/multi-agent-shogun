#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  tmux-send-2step.sh msg   [options] <target> <message...>
  tmux-send-2step.sh enter [options] <target> [options]
  tmux-send-2step.sh notify [options] <target> <message...>

Target:
  - A fully qualified pane target: <session>:<window>.<pane>  (example: multiagent:0.0)
  - A pane id: %<number>
  - An agent id (resolved via pane option @agent_id): karo | shogun | ashigaruN
  - An agent id prefixed with "@": @karo | @ashigaru8

Examples:
  # Standard (MUST): two separate bash invocations:
  tmux-send-2step.sh msg multiagent:0.0 'report ready'
  tmux-send-2step.sh enter multiagent:0.0 --check --tail 30
  # Resolve by @agent_id (recommended for robustness):
  tmux-send-2step.sh msg @karo 'report ready'
  tmux-send-2step.sh enter @karo

  # Non-standard (emergency only): one call does msg -> Enter, sequentially (no parallelism).
  tmux-send-2step.sh notify @karo 'report ready'

Notes:
  - Standard is 2 bash invocations (msg then enter).
  - notify is supported, but non-standard (emergency only).
  - Always send message first, then Enter. Never run msg/Enter in parallel.
  - Use single quotes around <message> to preserve spaces.
  - Message must not include newline characters (\\n / \\r).

Options:
  --check               After sending, capture the target pane tail (debug/evidence).
  --tail N              Tail lines for --check (default: 20).
  --retry N             (enter mode) resend Enter up to N additional times (default: 2).
  --retry-enter N       (notify mode) alias of --retry (additional Enter retries; default: 2).
  --lock-timeout-ms N   Wait up to N ms to acquire per-target lock (default: 1500).
  --stale-sec N         Pending msg state TTL in seconds (default: 30).
  --force               (msg mode) allow overriding a non-stale pending state.
  --force-exit-copy-mode  If target pane is in copy-mode (pane_in_mode=1), send 'q' once to exit and continue.
                          Default is to refuse sending keys when pane_in_mode=1 (safer; avoids "send-keys did nothing").
USAGE
}

if [[ ${#} -lt 2 ]]; then
  usage
  exit 1
fi

MODE="$1"
shift 1

DO_CHECK=0
TAIL_LINES=20
ENTER_RETRY=2
LOCK_TIMEOUT_MS=1500
STALE_SEC=30
FORCE=0
FORCE_EXIT_COPY_MODE=0
OWNED_LOCK_DIR=""

die() {
  echo "ERROR: $*" >&2
  exit 1
}

cleanup_owned_lock() {
  if [[ -n "${OWNED_LOCK_DIR}" ]]; then
    rm -rf "${OWNED_LOCK_DIR}" 2>/dev/null || true
    OWNED_LOCK_DIR=""
  fi
}
trap cleanup_owned_lock EXIT INT TERM

now_epoch() {
  date +%s
}

stat_mtime_epoch() {
  local path="$1"
  if stat -f %m "$path" >/dev/null 2>&1; then
    stat -f %m "$path"
  else
    # GNU stat
    stat -c %Y "$path"
  fi
}

sanitize_key() {
  # For filenames. Keep it stable and ascii.
  echo "$1" | tr -c 'A-Za-z0-9._-@' '_'
}

ensure_tmux() {
  command -v tmux >/dev/null 2>&1 || die "tmux not found in PATH"
  tmux list-sessions >/dev/null 2>&1 || die "tmux server not running (no sessions)"
}

resolve_target() {
  local raw="$1"
  ensure_tmux

  local agent=""
  if [[ "$raw" =~ ^@.+$ ]]; then
    agent="${raw#@}"
  elif [[ "$raw" =~ ^(shogun|karo|ashigaru[0-9]+)$ ]]; then
    agent="$raw"
  fi

  if [[ -n "$agent" ]]; then
    # Resolve via pane user option @agent_id.
    local matches
    matches="$(tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{@agent_id} #{pane_id}' | awk -v a="$agent" '$2==a {print $1}')"
    local count
    count="$(printf "%s\n" "$matches" | sed '/^$/d' | wc -l | tr -d ' ')"
    if [[ "$count" -eq 0 ]]; then
      die "no pane found for @agent_id='$agent'"
    fi
    if [[ "$count" -ne 1 ]]; then
      die "multiple panes found for @agent_id='$agent' (ambiguous): $(printf "%s" "$matches" | tr '\n' ' ')"
    fi
    echo "$matches"
    return 0
  fi

  # pane_id (%n) or fully qualified target
  local ids
  ids="$(tmux list-panes -a -F '#{pane_id} #{session_name}:#{window_index}.#{pane_index}' | awk -v t="$raw" '$1==t {print $2}')"
  if [[ -n "$ids" ]]; then
    echo "$raw"
    return 0
  fi

  # Validate the target resolves to exactly one pane.
  local full
  if ! full="$(tmux display-message -p -t "$raw" '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null)"; then
    die "invalid target: '$raw' (expected <session>:<window>.<pane>, %<pane_id>, or @agent_id)"
  fi
  if [[ "$raw" != "$full" ]]; then
    die "target '$raw' resolved to '$full' (not a specific pane). Use <session>:<window>.<pane>."
  fi
  echo "$full"
}

with_lock() {
  local target_key="$1"
  shift

  local lock_base="${TMPDIR:-/tmp}/tmux-send-2step-locks"
  mkdir -p "$lock_base"

  local lock_name
  lock_name="$(sanitize_key "$target_key")"
  local lock_dir="$lock_base/$lock_name.lock"

  local start
  start="$(now_epoch)"
  local timeout_s
  timeout_s="$(awk -v ms="$LOCK_TIMEOUT_MS" 'BEGIN{print (ms/1000.0)}')"

  while true; do
    if mkdir "$lock_dir" 2>/dev/null; then
      # Write owner info for debugging.
      printf "pid=%s\ntime=%s\n" "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$lock_dir/owner" 2>/dev/null || true
      OWNED_LOCK_DIR="$lock_dir"
      "$@"
      cleanup_owned_lock
      return 0
    fi

    # Handle stale lock (crash, etc.)
    local mtime
    mtime="$(stat_mtime_epoch "$lock_dir" 2>/dev/null || echo 0)"
    local now
    now="$(now_epoch)"
    if [[ "$mtime" -gt 0 ]] && [[ $((now - mtime)) -gt 30 ]]; then
      rm -rf "$lock_dir" 2>/dev/null || true
      continue
    fi

    # Bounded wait (no unbounded polling).
    if awk -v now="$now" -v start="$start" -v to="$timeout_s" 'BEGIN{exit !((now-start) >= to)}'; then
      die "could not acquire lock for target '$target_key' within ${LOCK_TIMEOUT_MS}ms"
    fi
    sleep 0.05
  done
}

state_paths() {
  local target_key="$1"
  local state_base="${TMPDIR:-/tmp}/tmux-send-2step-state"
  mkdir -p "$state_base"
  local state_name
  state_name="$(sanitize_key "$target_key")"
  echo "$state_base/$state_name.pending"
}

validate_message() {
  local msg="$1"
  if [[ "$msg" == *$'\n'* ]]; then
    die "message contains newline (\\n); forbidden"
  fi
  if [[ "$msg" == *$'\r'* ]]; then
    die "message contains carriage return (\\r); forbidden"
  fi
}

guard_target_pane() {
  local target="$1"

  # tmux copy-mode (pane_in_mode=1) swallows keystrokes; sending a whole command while in this mode can appear to "hang"
  # (no visible effect) and is easy to misdiagnose as agent failure. Fail fast by default.
  local pane_dead pane_in_mode
  if ! pane_dead="$(tmux display-message -p -t "$target" '#{pane_dead}' 2>/dev/null)"; then
    die "failed to inspect target pane '$target' (tmux display-message failed)"
  fi
  if ! pane_in_mode="$(tmux display-message -p -t "$target" '#{pane_in_mode}' 2>/dev/null)"; then
    die "failed to inspect target pane '$target' (tmux display-message failed)"
  fi

  if [[ "$pane_dead" == "1" ]]; then
    die "target pane '$target' is dead (pane_dead=1)"
  fi

  if [[ "$pane_in_mode" == "1" ]]; then
    if [[ "$FORCE_EXIT_COPY_MODE" -eq 1 ]]; then
      echo "WARN: target pane '$target' is in copy-mode (pane_in_mode=1); attempting to exit with 'q' (--force-exit-copy-mode)" >&2
      tmux send-keys -t "$target" q
      sleep 0.05
      local pane_in_mode_after
      pane_in_mode_after="$(tmux display-message -p -t "$target" '#{pane_in_mode}' 2>/dev/null || echo 1)"
      if [[ "$pane_in_mode_after" == "1" ]]; then
        die "target pane '$target' is still in mode (pane_in_mode=1) after 'q'. Exit copy-mode manually and retry."
      fi
      return 0
    fi

    die "target pane '$target' is in copy-mode (pane_in_mode=1); refusing to send keys. Exit copy-mode and retry. Hint: focus the pane and press 'q', or: tmux send-keys -t '$target' q"
  fi
}

send_msg() {
  local target="$1"
  shift
  local message="$*"

  validate_message "$message"
  guard_target_pane "$target"

  local pending
  pending="$(state_paths "$target")"
  if [[ -f "$pending" ]]; then
    local now
    now="$(now_epoch)"
    local sent
    sent="$(awk -F= '$1=="sent_at_epoch"{print $2}' "$pending" 2>/dev/null || echo 0)"
    local age=$((now - sent))
    if [[ "$FORCE" -ne 1 ]] && [[ "$sent" -gt 0 ]] && [[ "$age" -le "$STALE_SEC" ]]; then
      die "pending state exists for target '$target' (age=${age}s). Run enter, wait for stale (${STALE_SEC}s), or use --force."
    fi
    if [[ "$age" -gt "$STALE_SEC" ]]; then
      rm -f "$pending" 2>/dev/null || true
    fi
  fi

  # Use -l to ensure the message is sent literally (robust for unicode/brackets).
  tmux send-keys -t "$target" -l "$message"
  {
    printf "sent_at_epoch=%s\n" "$(now_epoch)"
    printf "pid=%s\n" "$$"
  } >"$pending"
}

send_enter() {
  local target="$1"

  guard_target_pane "$target"

  local pending
  pending="$(state_paths "$target")"
  if [[ -f "$pending" ]]; then
    local now sent age
    now="$(now_epoch)"
    sent="$(awk -F= '$1=="sent_at_epoch"{print $2}' "$pending" 2>/dev/null || echo 0)"
    age=$((now - sent))
    if [[ "$sent" -gt 0 ]] && [[ "$age" -gt "$STALE_SEC" ]]; then
      # Stale pending; allow enter anyway but clean state to avoid blocking future msg.
      rm -f "$pending" 2>/dev/null || true
    fi
  fi

  local tries=$((ENTER_RETRY + 1))
  local i=1
  while [[ "$i" -le "$tries" ]]; do
    tmux send-keys -t "$target" Enter
    i=$((i + 1))
    if [[ "$i" -le "$tries" ]]; then
      sleep 0.05
    fi
  done

  # Best-effort: clear pending after Enter burst.
  rm -f "$pending" 2>/dev/null || true
}

send_notify() {
  local target="$1"
  shift
  local message_args=("$@")

  # Keep pending state + lock semantics consistent:
  # - send_msg writes pending
  # - send_enter clears pending
  send_msg "$target" "${message_args[@]}"
  # Small gap between msg and Enter to avoid timing edge cases in fast panes.
  sleep 0.03
  send_enter "$target"
}

case "$MODE" in
  msg)
    # Options are supported BEFORE <target>. After <target>, everything is treated as message.
    while [[ ${#} -gt 0 ]]; do
      case "$1" in
        --check)
          DO_CHECK=1
          shift
          ;;
        --tail)
          shift
          [[ ${#} -gt 0 ]] || die "--tail requires a number"
          TAIL_LINES="$1"
          shift
          ;;
        --lock-timeout-ms)
          shift
          [[ ${#} -gt 0 ]] || die "--lock-timeout-ms requires a number"
          LOCK_TIMEOUT_MS="$1"
          shift
          ;;
        --stale-sec)
          shift
          [[ ${#} -gt 0 ]] || die "--stale-sec requires a number"
          STALE_SEC="$1"
          shift
          ;;
        --force)
          FORCE=1
          shift
          ;;
        --force-exit-copy-mode)
          FORCE_EXIT_COPY_MODE=1
          shift
          ;;
        --retry)
          die "--retry is only valid for enter mode"
          ;;
        -h|--help)
          usage
          exit 0
          ;;
        --)
          shift
          break
          ;;
        *)
          break
          ;;
      esac
    done

    [[ ${#} -ge 2 ]] || { echo "msg requires [options] <target> <message...>" >&2; usage; exit 1; }
    TARGET="$(resolve_target "$1")"
    shift 1
    with_lock "$TARGET" send_msg "$TARGET" "$@"
    ;;
  enter)
    # Options are supported both BEFORE and AFTER <target>.
    while [[ ${#} -gt 0 ]]; do
      case "$1" in
        --check)
          DO_CHECK=1
          shift
          ;;
        --tail)
          shift
          [[ ${#} -gt 0 ]] || die "--tail requires a number"
          TAIL_LINES="$1"
          shift
          ;;
        --retry)
          shift
          [[ ${#} -gt 0 ]] || die "--retry requires a number"
          ENTER_RETRY="$1"
          shift
          ;;
        --lock-timeout-ms)
          shift
          [[ ${#} -gt 0 ]] || die "--lock-timeout-ms requires a number"
          LOCK_TIMEOUT_MS="$1"
          shift
          ;;
        --stale-sec)
          shift
          [[ ${#} -gt 0 ]] || die "--stale-sec requires a number"
          STALE_SEC="$1"
          shift
          ;;
        --force-exit-copy-mode)
          FORCE_EXIT_COPY_MODE=1
          shift
          ;;
        --force)
          die "--force is only valid for msg mode"
          ;;
        -h|--help)
          usage
          exit 0
          ;;
        --)
          shift
          break
          ;;
        *)
          break
          ;;
      esac
    done

    [[ ${#} -ge 1 ]] || { echo "enter requires [options] <target> [options]" >&2; usage; exit 1; }
    TARGET="$(resolve_target "$1")"
    shift 1

    while [[ ${#} -gt 0 ]]; do
      case "$1" in
        --check)
          DO_CHECK=1
          shift
          ;;
        --tail)
          shift
          [[ ${#} -gt 0 ]] || die "--tail requires a number"
          TAIL_LINES="$1"
          shift
          ;;
        --retry)
          shift
          [[ ${#} -gt 0 ]] || die "--retry requires a number"
          ENTER_RETRY="$1"
          shift
          ;;
        --lock-timeout-ms)
          shift
          [[ ${#} -gt 0 ]] || die "--lock-timeout-ms requires a number"
          LOCK_TIMEOUT_MS="$1"
          shift
          ;;
        --stale-sec)
          shift
          [[ ${#} -gt 0 ]] || die "--stale-sec requires a number"
          STALE_SEC="$1"
          shift
          ;;
        --force-exit-copy-mode)
          FORCE_EXIT_COPY_MODE=1
          shift
          ;;
        -h|--help)
          usage
          exit 0
          ;;
        --)
          shift
          break
          ;;
        *)
          die "unexpected arguments after target/options: $*"
          ;;
      esac
    done

    [[ ${#} -eq 0 ]] || die "unexpected arguments after '--': $*"
    with_lock "$TARGET" send_enter "$TARGET"
    ;;
  notify)
    # notify defaults to check+tail=40 to reduce "enter was forgotten" incidents.
    DO_CHECK=1
    if [[ "$TAIL_LINES" -eq 20 ]]; then
      TAIL_LINES=40
    fi

    # Options are supported BEFORE <target>. After <target>, everything is treated as message.
    while [[ ${#} -gt 0 ]]; do
      case "$1" in
        --check)
          DO_CHECK=1
          shift
          ;;
        --tail)
          shift
          [[ ${#} -gt 0 ]] || die "--tail requires a number"
          TAIL_LINES="$1"
          shift
          ;;
        --retry|--retry-enter)
          opt="$1"
          shift
          [[ ${#} -gt 0 ]] || die "$opt requires a number"
          ENTER_RETRY="$1"
          shift
          ;;
        --lock-timeout-ms)
          shift
          [[ ${#} -gt 0 ]] || die "--lock-timeout-ms requires a number"
          LOCK_TIMEOUT_MS="$1"
          shift
          ;;
        --stale-sec)
          shift
          [[ ${#} -gt 0 ]] || die "--stale-sec requires a number"
          STALE_SEC="$1"
          shift
          ;;
        --force)
          FORCE=1
          shift
          ;;
        --force-exit-copy-mode)
          FORCE_EXIT_COPY_MODE=1
          shift
          ;;
        -h|--help)
          usage
          exit 0
          ;;
        --)
          shift
          break
          ;;
        *)
          break
          ;;
      esac
    done

    [[ ${#} -ge 2 ]] || { echo "notify requires [options] <target> <message...>" >&2; usage; exit 1; }
    TARGET="$(resolve_target "$1")"
    shift 1
    with_lock "$TARGET" send_notify "$TARGET" "$@"
    ;;
  *)
    echo "Unknown mode: $MODE" >&2
    usage
    exit 1
    ;;
esac

if [[ "$DO_CHECK" -eq 1 ]]; then
  tmux capture-pane -t "$TARGET" -p | tail -n "$TAIL_LINES"
fi
