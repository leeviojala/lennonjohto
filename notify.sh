#!/usr/bin/env bash
# Työpöytäilmoitus. Suora kutsu: notify.sh "otsikko" "viesti"
# Claude Coden Notification-hookina: lukee JSONin stdinistä.
if [ $# -ge 1 ]; then
  title="$1"; msg="${2:-}"
else
  input=$(cat)
  title="Claude Code"
  msg=$(printf '%s' "$input" | jq -r '.message // .title // "tarvitsee sinua"' 2>/dev/null)
fi
if command -v osascript >/dev/null 2>&1; then
  osascript -e "display notification \"${msg//\"/\\\"}\" with title \"${title//\"/\\\"}\" sound name \"Glass\""
elif command -v notify-send >/dev/null 2>&1; then
  notify-send "$title" "$msg"
else
  printf '[%s] %s\n' "$title" "$msg" >&2
fi
