#!/usr/bin/env bash
set -euo pipefail

TARGET_FILE="${1:-$HOME/.bashrc}"
SELF_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
INSTALL_ROOT="${OPENCODE_AUTH_LAUNCHER_INSTALL_ROOT:-$HOME/.local/share/opencode-auth-launcher}"
BIN_DIR="${OPENCODE_AUTH_LAUNCHER_BIN_DIR:-$HOME/.local/bin}"
LEGACY_BLOCK_START="# >>> opencode-auth-launcher >>>"
LEGACY_BLOCK_END="# <<< opencode-auth-launcher <<<"
PATH_BLOCK_START="# >>> opencode-auth-launcher path >>>"
PATH_BLOCK_END="# <<< opencode-auth-launcher path <<<"

copy_runtime_file() {
  local source_name="$1"
  local mode="$2"

  install -m "$mode" "$SELF_DIR/$source_name" "$INSTALL_ROOT/$source_name"
}

write_wrapper() {
  local wrapper_path="$1"
  local target_script="$2"

  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'exec %q "$@"\n' "$target_script"
  } > "$wrapper_path"

  chmod 755 "$wrapper_path"
}

update_shell_rc() {
  local rc_path="$1"
  local path_block

  path_block=$(cat <<EOF
# >>> opencode-auth-launcher path >>>
if [ -d "$BIN_DIR" ] && [[ ":\$PATH:" != *":$BIN_DIR:"* ]]; then
  export PATH="$BIN_DIR:\$PATH"
fi
# <<< opencode-auth-launcher path <<<
EOF
)

  mkdir -p "$(dirname "$rc_path")"

  TARGET_FILE="$rc_path" \
  LEGACY_BLOCK_START="$LEGACY_BLOCK_START" \
  LEGACY_BLOCK_END="$LEGACY_BLOCK_END" \
  PATH_BLOCK_START="$PATH_BLOCK_START" \
  PATH_BLOCK_END="$PATH_BLOCK_END" \
  PATH_BLOCK="$path_block" \
  python3 - <<'PY'
import os
from pathlib import Path


def strip_block(lines, start_marker, end_marker):
    result = []
    skipping = False

    for line in lines:
        stripped = line.rstrip("\n")
        if not skipping and stripped == start_marker:
            skipping = True
            continue
        if skipping and stripped == end_marker:
            skipping = False
            continue
        if not skipping:
            result.append(line)

    return result


target_path = Path(os.environ["TARGET_FILE"]).expanduser()
if target_path.exists():
    original_lines = target_path.read_text(encoding="utf-8").splitlines(keepends=True)
else:
    original_lines = []

filtered_lines = original_lines
for start_key, end_key in (
    ("LEGACY_BLOCK_START", "LEGACY_BLOCK_END"),
    ("PATH_BLOCK_START", "PATH_BLOCK_END"),
):
    filtered_lines = strip_block(filtered_lines, os.environ[start_key], os.environ[end_key])

content = "".join(filtered_lines).rstrip()
path_block = os.environ["PATH_BLOCK"].rstrip()

if content:
    content = f"{content}\n\n{path_block}\n"
else:
    content = f"{path_block}\n"

target_path.write_text(content, encoding="utf-8")
PY
}

mkdir -p "$INSTALL_ROOT" "$BIN_DIR"

copy_runtime_file "run-with-auth.sh" 755
copy_runtime_file "link-global-auth.sh" 755
copy_runtime_file "manage-web-service.sh" 755

write_wrapper "$BIN_DIR/opencode-auth" "$INSTALL_ROOT/run-with-auth.sh"
write_wrapper "$BIN_DIR/opencode-auth-link" "$INSTALL_ROOT/link-global-auth.sh"
write_wrapper "$BIN_DIR/opencode-web-auth" "$INSTALL_ROOT/manage-web-service.sh"

update_shell_rc "$TARGET_FILE"

echo "Copied launcher runtime to: $INSTALL_ROOT"
echo "Installed command wrappers in: $BIN_DIR"
echo "Updated PATH block in: $TARGET_FILE"
echo "Reload with: source $TARGET_FILE"
