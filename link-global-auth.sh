#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: opencode-auth-link <auth-file>

Examples:
  opencode-auth-link ~/auth.json-z.ai
  opencode-auth-link ~/auth.json-openai@example.com
EOF
  exit 1
}

if [ "$#" -ne 1 ]; then
  usage
fi

AUTH_FILE_INPUT="$1"

if [ ! -f "$AUTH_FILE_INPUT" ]; then
  echo "Auth file not found: $AUTH_FILE_INPUT" >&2
  exit 1
fi

AUTH_FILE="$(readlink -f "$AUTH_FILE_INPUT")"
GLOBAL_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
GLOBAL_AUTH_DIR="$GLOBAL_DATA_HOME/opencode"
GLOBAL_AUTH_FILE="$GLOBAL_AUTH_DIR/auth.json"

mkdir -p "$GLOBAL_AUTH_DIR"
chmod 700 "$GLOBAL_AUTH_DIR"

if [ -e "$GLOBAL_AUTH_FILE" ] && [ ! -L "$GLOBAL_AUTH_FILE" ]; then
  BACKUP_PATH="$GLOBAL_AUTH_FILE.backup.$(date +%Y%m%d%H%M%S)"
  mv "$GLOBAL_AUTH_FILE" "$BACKUP_PATH"
  echo "Backed up existing auth file to: $BACKUP_PATH" >&2
fi

ln -sfn "$AUTH_FILE" "$GLOBAL_AUTH_FILE"

echo "Linked global auth file:" >&2
echo "  $GLOBAL_AUTH_FILE -> $AUTH_FILE" >&2
echo "Only one global auth link can be active at a time." >&2
echo "For simultaneous multi-auth services, use opencode-auth or opencode-web-auth." >&2
