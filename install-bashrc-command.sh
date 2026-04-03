#!/usr/bin/env bash
set -euo pipefail

TARGET_FILE="${1:-$HOME/.bashrc}"
START_MARKER="# >>> opencode-auth-launcher >>>"
END_MARKER="# <<< opencode-auth-launcher <<<"
SELF_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
RUNNER_PATH="$SELF_DIR/run-with-auth.sh"
LINKER_PATH="$SELF_DIR/link-global-auth.sh"
SERVICE_PATH="$SELF_DIR/manage-web-service.sh"

read -r -d '' BLOCK <<EOF || true
# >>> opencode-auth-launcher >>>
opencode-auth() {
  bash "$RUNNER_PATH" "\$@"
}

opencode-auth-link() {
  bash "$LINKER_PATH" "\$@"
}

opencode-web-auth() {
  bash "$SERVICE_PATH" "\$@"
}
# <<< opencode-auth-launcher <<<
EOF

mkdir -p "$(dirname "$TARGET_FILE")"
touch "$TARGET_FILE"
TEMP_FILE="$(mktemp)"

if grep -Fq "$START_MARKER" "$TARGET_FILE" && grep -Fq "$END_MARKER" "$TARGET_FILE"; then
  awk -v start="$START_MARKER" -v end="$END_MARKER" -v block="$BLOCK" '
    BEGIN { skip = 0; replaced = 0 }
    $0 == start {
      if (!replaced) print block
      skip = 1
      replaced = 1
      next
    }
    $0 == end {
      skip = 0
      next
    }
    !skip { print }
    END {
      if (!replaced) print block
    }
  ' "$TARGET_FILE" > "$TEMP_FILE"
else
  cat "$TARGET_FILE" > "$TEMP_FILE"
  if [ -s "$TEMP_FILE" ]; then
    printf '\n' >> "$TEMP_FILE"
  fi
  printf '%s\n' "$BLOCK" >> "$TEMP_FILE"
fi

mv "$TEMP_FILE" "$TARGET_FILE"
echo "Updated $TARGET_FILE"
echo "Reload with: source $TARGET_FILE"
