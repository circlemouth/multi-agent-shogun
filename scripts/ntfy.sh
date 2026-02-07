#!/bin/bash
# SayTask通知 — ntfy.sh経由でスマホにプッシュ通知
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS="$SCRIPT_DIR/config/settings.yaml"
TOPIC=$(grep 'ntfy_topic:' "$SETTINGS" 2>/dev/null | awk '{print $2}' | tr -d '"')
if [ -z "$TOPIC" ]; then
  echo "ntfy_topic not configured in settings.yaml"
  exit 1
fi
curl -s -H "Tags: outbound" -d "$1" "https://ntfy.sh/$TOPIC" > /dev/null
