#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# inbox_write.sh — agent inbox にメッセージを書き込む（永続・排他）
#
# Usage:
#   bash scripts/inbox_write.sh <target_agent> "<message>" <type> <from>
#
# Notes:
# - メッセージ本体はファイル（YAML）に書く。tmux send-keys は watcher 側のみ。
# - flock（util-linux）がある前提。無い場合はベストエフォートで書く。
# - YAMLは inbox_watcher.sh の PyYAML で parse される形式に合わせる。
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TARGET_AGENT="${1:-}"
MESSAGE="${2:-}"
MSG_TYPE="${3:-message}"
MSG_FROM="${4:-system}"

if [ -z "$TARGET_AGENT" ] || [ -z "$MESSAGE" ]; then
  echo "Usage: inbox_write.sh <target_agent> \"<message>\" <type> <from>" >&2
  exit 1
fi

INBOX_DIR="$SCRIPT_DIR/queue/inbox"
INBOX_FILE="$INBOX_DIR/${TARGET_AGENT}.yaml"
LOCKFILE="${INBOX_FILE}.lock"

mkdir -p "$INBOX_DIR"

if [ ! -f "$INBOX_FILE" ]; then
  echo "messages:" > "$INBOX_FILE"
fi

# Convert "messages: []" to "messages:" so we can append list items safely.
perl -pi -e 's/^messages:\s*\[\s*\]\s*$/messages:/g' "$INBOX_FILE" 2>/dev/null || true

MSG_ID="$(python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null || date +%s)"
TIMESTAMP="$(
  python3 -c 'import datetime; print(datetime.datetime.now().astimezone().replace(microsecond=0).isoformat())' 2>/dev/null \
  || date "+%Y-%m-%dT%H:%M:%S%z"
)"

append_entry() {
  {
    printf "  - id: \"%s\"\n" "$MSG_ID"
    printf "    timestamp: \"%s\"\n" "$TIMESTAMP"
    printf "    type: \"%s\"\n" "$MSG_TYPE"
    printf "    from: \"%s\"\n" "$MSG_FROM"
    printf "    content: |-\n"
    # Indent message lines by 6 spaces to fit under "content: |-"
    while IFS= read -r line; do
      printf "      %s\n" "$line"
    done <<< "$MESSAGE"
    printf "    read: false\n"
  } >> "$INBOX_FILE"
}

if command -v flock &>/dev/null; then
  exec 9>"$LOCKFILE"
  flock -x 9
  append_entry
  flock -u 9
else
  # Fallback: no flock available
  append_entry
fi
