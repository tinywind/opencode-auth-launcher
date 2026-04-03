#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: opencode-auth <auth-file> [opencode args...]

Examples:
  opencode-auth ~/auth.json-z.ai
  opencode-auth ~/auth.json-z.ai web --port 4101
  opencode-auth ~/auth.json-openai@example.com serve --port 4201
EOF
  exit 1
}

if [ "$#" -lt 1 ]; then
  usage
fi

AUTH_FILE_INPUT="$1"
shift || true

if [ ! -f "$AUTH_FILE_INPUT" ]; then
  echo "Auth file not found: $AUTH_FILE_INPUT" >&2
  exit 1
fi

AUTH_FILE="$(readlink -f "$AUTH_FILE_INPUT")"
REAL_HOME="${HOME:?HOME is required}"
PROFILE_BASE_DIR="$REAL_HOME/.opencode-auth-launcher/profiles"
PROFILE_HINT="${OPENCODE_AUTH_LAUNCHER_PROFILE:-}"

if [ -n "$PROFILE_HINT" ]; then
  PROFILE_SLUG="$(printf '%s' "$PROFILE_HINT" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//; s/-$//')"
  PROFILE_HASH="$(printf '%s|%s' "$AUTH_FILE" "$PROFILE_HINT" | sha256sum | cut -c1-12)"
else
  AUTH_BASENAME="$(basename "$AUTH_FILE")"
  PROFILE_SLUG="$(printf '%s' "$AUTH_BASENAME" | tr '[:upper:]' '[:lower:]' | sed 's/\.[^.]*$//' | tr -cs 'a-z0-9' '-' | sed 's/^-//; s/-$//')"
  PROFILE_HASH="$(printf '%s' "$AUTH_FILE" | sha256sum | cut -c1-12)"
fi

PROFILE_NAME="${PROFILE_SLUG:-auth}-$PROFILE_HASH"
PROFILE_ROOT="$PROFILE_BASE_DIR/$PROFILE_NAME"
PROFILE_DATA_HOME="$PROFILE_ROOT/xdg-data"
PROFILE_CACHE_HOME="$PROFILE_ROOT/xdg-cache"
PROFILE_STATE_HOME="$PROFILE_ROOT/xdg-state"
PROFILE_AUTH_DIR="$PROFILE_DATA_HOME/opencode"
PROFILE_AUTH_FILE="$PROFILE_AUTH_DIR/auth.json"
PROFILE_METADATA_FILE="$PROFILE_ROOT/profile.json"

mkdir -p "$PROFILE_AUTH_DIR" "$PROFILE_CACHE_HOME" "$PROFILE_STATE_HOME"
chmod 700 "$PROFILE_ROOT" "$PROFILE_DATA_HOME" "$PROFILE_CACHE_HOME" "$PROFILE_STATE_HOME" "$PROFILE_AUTH_DIR"

ln -sfn "$AUTH_FILE" "$PROFILE_AUTH_FILE"

cat > "$PROFILE_METADATA_FILE" <<EOF
{
  "profileName": "$PROFILE_NAME",
  "profileHint": "$PROFILE_HINT",
  "authSource": "$AUTH_FILE",
  "xdgDataHome": "$PROFILE_DATA_HOME",
  "xdgCacheHome": "$PROFILE_CACHE_HOME",
  "xdgStateHome": "$PROFILE_STATE_HOME",
  "authLink": "$PROFILE_AUTH_FILE"
}
EOF
chmod 600 "$PROFILE_METADATA_FILE"

echo "Using isolated OpenCode profile: $PROFILE_NAME" >&2
echo "Auth symlink: $PROFILE_AUTH_FILE -> $AUTH_FILE" >&2
echo "XDG_DATA_HOME: $PROFILE_DATA_HOME" >&2

XDG_DATA_HOME="$PROFILE_DATA_HOME" \
XDG_CACHE_HOME="$PROFILE_CACHE_HOME" \
XDG_STATE_HOME="$PROFILE_STATE_HOME" \
command opencode "$@"
