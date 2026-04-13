#!/usr/bin/env bash
set -euo pipefail

service_name="opencode-web-auth-batch"
auth_folder="${HOME}/OneDrive/services/opencode-auths"
port_start="8061"
hostname="0.0.0.0"
mode=""
service_prefix=""

usage() {
  cat <<'EOF'
Usage: install-systemd-batch-service.sh [options]

Options:
  --folder PATH            Auth folder to manage. Default: ~/OneDrive/services/opencode-auths
  --port-start PORT        Starting port for start-folder. Default: 8061
  --service-name NAME      systemd user unit base name. Default: opencode-web-auth-batch
  --hostname HOST          Hostname passed to start-folder. Default: 0.0.0.0
  --mode MODE              Optional mode passed to start-folder (web or serve)
  --prefix PREFIX          Optional batch prefix passed to start-folder
  -h, --help               Show this help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --folder)
      auth_folder="$2"
      shift 2
      ;;
    --folder=*)
      auth_folder="${1#*=}"
      shift
      ;;
    --port-start)
      port_start="$2"
      shift 2
      ;;
    --port-start=*)
      port_start="${1#*=}"
      shift
      ;;
    --service-name)
      service_name="$2"
      shift 2
      ;;
    --service-name=*)
      service_name="${1#*=}"
      shift
      ;;
    --hostname)
      hostname="$2"
      shift 2
      ;;
    --hostname=*)
      hostname="${1#*=}"
      shift
      ;;
    --mode)
      mode="$2"
      shift 2
      ;;
    --mode=*)
      mode="${1#*=}"
      shift
      ;;
    --prefix)
      service_prefix="$2"
      shift 2
      ;;
    --prefix=*)
      service_prefix="${1#*=}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if ! [[ "$port_start" =~ ^[0-9]+$ ]]; then
  echo "Invalid --port-start: $port_start" >&2
  exit 1
fi

auth_folder="$(readlink -f "$auth_folder")"
if [ ! -d "$auth_folder" ]; then
  echo "Auth folder not found: $auth_folder" >&2
  exit 1
fi

opencode_web_auth_cmd="${OPENCODE_WEB_AUTH_CMD:-$(command -v opencode-web-auth || true)}"
if [ -z "$opencode_web_auth_cmd" ]; then
  echo "opencode-web-auth command not found in PATH" >&2
  exit 1
fi

opencode_cmd="${OPENCODE_CMD:-$(command -v opencode || true)}"
if [ -z "$opencode_cmd" ]; then
  echo "opencode command not found in PATH" >&2
  exit 1
fi

unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
path_unit="${unit_dir}/${service_name}.path"
service_unit="${unit_dir}/${service_name}.service"
refresh_unit="${unit_dir}/${service_name}-refresh.service"

mkdir -p "$unit_dir"

declare -a path_entries=(
  "$(dirname "$opencode_web_auth_cmd")"
  "$(dirname "$opencode_cmd")"
  /usr/local/sbin
  /usr/local/bin
  /usr/sbin
  /usr/bin
  /sbin
  /bin
  /snap/bin
)

unit_path=""
for entry in "${path_entries[@]}"; do
  if [ -z "$entry" ] || [ ! -d "$entry" ]; then
    continue
  fi
  case ":$unit_path:" in
    *":$entry:"*)
      ;;
    *)
      if [ -n "$unit_path" ]; then
        unit_path="${unit_path}:$entry"
      else
        unit_path="$entry"
      fi
      ;;
  esac
done

start_args=(
  "$opencode_web_auth_cmd" start-folder "$auth_folder" --port-start "$port_start"
)
stop_args=(
  "$opencode_web_auth_cmd" stop-folder "$auth_folder"
)

if [ -n "$hostname" ]; then
  start_args+=(--hostname "$hostname")
fi
if [ -n "$mode" ]; then
  start_args+=(--mode "$mode")
fi
if [ -n "$service_prefix" ]; then
  start_args+=(--prefix "$service_prefix")
  stop_args+=(--prefix "$service_prefix")
fi

quote_args() {
  printf '%q ' "$@"
}

start_cmd="$(quote_args "${start_args[@]}")"
stop_cmd="$(quote_args "${stop_args[@]}")"

cat > "$service_unit" <<EOF
[Unit]
Description=OpenCode auth batch service for ${auth_folder}
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${HOME}
Environment=HOME=${HOME}
Environment=PATH=${unit_path}
ExecStart=${start_cmd}
ExecReload=${start_cmd}
ExecStop=${stop_cmd}

[Install]
WantedBy=default.target
EOF

cat > "$refresh_unit" <<EOF
[Unit]
Description=Refresh ${service_name}

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl --user reload ${service_name}.service
EOF

cat > "$path_unit" <<EOF
[Unit]
Description=Watch ${auth_folder} for OpenCode auth changes

[Path]
PathModified=${auth_folder}
PathChanged=${auth_folder}
Unit=${service_name}-refresh.service

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable "${service_name}.service" "${service_name}.path"
systemctl --user restart "${service_name}.service"
systemctl --user restart "${service_name}.path"

echo "Installed:"
echo "  $service_unit"
echo "  $refresh_unit"
echo "  $path_unit"
echo
systemctl --user --no-pager --full status "${service_name}.service" "${service_name}.path"
