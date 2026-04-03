#!/usr/bin/env bash
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
RUNNER_PATH="$SELF_DIR/run-with-auth.sh"
SERVICE_BASE_DIR="$HOME/.opencode-auth-launcher/services"
CONFIG_BASE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode-auth-launcher"
BATCH_STATE_DIR="$CONFIG_BASE_DIR/batches"

declare -a BATCH_AUTH_FILES=()
declare -a MATCHED_SERVICE_NAMES=()
declare -a STATE_SERVICE_NAMES=()
declare -a STATE_AUTH_FILES=()
declare -a STATE_PORTS=()

STATE_EXISTS=0
STATE_BATCH_ID=""
STATE_DIR=""
STATE_META_FILE=""
STATE_MAP_FILE=""
STATE_FOLDER_PATH=""
STATE_PREFIX=""
STATE_PORT_START=""
STATE_HOSTNAME=""
STATE_MODE=""
STATE_MATCH_INDEX=-1
PREFERRED_SERVICE_NAME=""
ACTIVE_SERVICE_PID=""

usage() {
  cat >&2 <<'EOF'
Usage:
  opencode-web-auth start <service-name> <auth-file> --port <port> [--hostname <host>] [--mode web|serve] [-- <extra-opencode-args...>]
  opencode-web-auth start-folder <folder> --port-start <port> [--hostname <host>] [--mode web|serve] [--prefix <service-prefix>] [-- <extra-opencode-args...>]
  opencode-web-auth stop <service-name>
  opencode-web-auth stop-folder <folder> [--prefix <service-prefix>]
  opencode-web-auth status [service-name]
  opencode-web-auth status-folder <folder> [--prefix <service-prefix>]
  opencode-web-auth list
  opencode-web-auth logs <service-name> [line-count]
EOF
  exit 1
}

sanitize_slug() {
  local value="$1"

  printf '%s' "$value" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//; s/-$//'
}

clear_batch_state() {
  STATE_EXISTS=0
  STATE_BATCH_ID=""
  STATE_DIR=""
  STATE_META_FILE=""
  STATE_MAP_FILE=""
  STATE_FOLDER_PATH=""
  STATE_PREFIX=""
  STATE_PORT_START=""
  STATE_HOSTNAME=""
  STATE_MODE=""
  STATE_MATCH_INDEX=-1
  STATE_SERVICE_NAMES=()
  STATE_AUTH_FILES=()
  STATE_PORTS=()
}

set_batch_state_paths() {
  local folder_path="$1"
  local resolved_prefix="$2"
  local prefix_slug
  local batch_hash

  prefix_slug="$(sanitize_slug "$resolved_prefix")"
  batch_hash="$(printf '%s|%s' "$folder_path" "$resolved_prefix" | sha256sum | cut -c1-10)"

  STATE_BATCH_ID="${prefix_slug:-batch}-$batch_hash"
  STATE_DIR="$BATCH_STATE_DIR/$STATE_BATCH_ID"
  STATE_META_FILE="$STATE_DIR/batch.env"
  STATE_MAP_FILE="$STATE_DIR/services.tsv"
}

load_batch_state() {
  local folder_path="$1"
  local resolved_prefix="$2"
  local service_name
  local auth_file
  local port

  clear_batch_state
  set_batch_state_paths "$folder_path" "$resolved_prefix"

  if [ ! -f "$STATE_META_FILE" ] || [ ! -f "$STATE_MAP_FILE" ]; then
    return 1
  fi

  # shellcheck disable=SC1090
  source "$STATE_META_FILE"

  STATE_EXISTS=1
  STATE_FOLDER_PATH="${FOLDER_PATH:-$folder_path}"
  STATE_PREFIX="${SERVICE_PREFIX:-$resolved_prefix}"
  STATE_PORT_START="${PORT_START:-}"
  STATE_HOSTNAME="${HOSTNAME:-}"
  STATE_MODE="${MODE:-}"

  while IFS=$'\t' read -r service_name auth_file port; do
    if [ -z "$service_name" ]; then
      continue
    fi
    STATE_SERVICE_NAMES+=("$service_name")
    STATE_AUTH_FILES+=("$auth_file")
    STATE_PORTS+=("$port")
  done < "$STATE_MAP_FILE"
}

save_batch_state() {
  local folder_path="$1"
  local resolved_prefix="$2"
  local port_start="$3"
  local hostname="$4"
  local mode="$5"
  local updated_at
  local index

  set_batch_state_paths "$folder_path" "$resolved_prefix"
  mkdir -p "$STATE_DIR"
  chmod 700 "$CONFIG_BASE_DIR" "$BATCH_STATE_DIR" "$STATE_DIR" 2>/dev/null || true
  updated_at="$(date -Iseconds)"

  {
    printf 'BATCH_ID=%q\n' "$STATE_BATCH_ID"
    printf 'FOLDER_PATH=%q\n' "$folder_path"
    printf 'SERVICE_PREFIX=%q\n' "$resolved_prefix"
    printf 'PORT_START=%q\n' "$port_start"
    printf 'HOSTNAME=%q\n' "$hostname"
    printf 'MODE=%q\n' "$mode"
    printf 'UPDATED_AT=%q\n' "$updated_at"
  } > "$STATE_META_FILE"

  : > "$STATE_MAP_FILE"
  for index in "${!STATE_SERVICE_NAMES[@]}"; do
    printf '%s\t%s\t%s\n' "${STATE_SERVICE_NAMES[$index]}" "${STATE_AUTH_FILES[$index]}" "${STATE_PORTS[$index]}" >> "$STATE_MAP_FILE"
  done

  chmod 600 "$STATE_META_FILE" "$STATE_MAP_FILE"
  STATE_EXISTS=1
  STATE_FOLDER_PATH="$folder_path"
  STATE_PREFIX="$resolved_prefix"
  STATE_PORT_START="$port_start"
  STATE_HOSTNAME="$hostname"
  STATE_MODE="$mode"
}

find_state_index_by_auth_file() {
  local auth_file="$1"
  local index

  STATE_MATCH_INDEX=-1

  for index in "${!STATE_AUTH_FILES[@]}"; do
    if [ "${STATE_AUTH_FILES[$index]}" = "$auth_file" ]; then
      STATE_MATCH_INDEX="$index"
      return 0
    fi
  done

  return 1
}

auth_is_in_current_folder() {
  local auth_file="$1"
  local current_auth

  for current_auth in "${BATCH_AUTH_FILES[@]}"; do
    if [ "$current_auth" = "$auth_file" ]; then
      return 0
    fi
  done

  return 1
}

append_state_entry() {
  local service_name="$1"
  local auth_file="$2"
  local port="$3"

  STATE_SERVICE_NAMES+=("$service_name")
  STATE_AUTH_FILES+=("$auth_file")
  STATE_PORTS+=("$port")
}

remove_state_entry_by_index() {
  local remove_index="$1"
  local new_service_names=()
  local new_auth_files=()
  local new_ports=()
  local index

  for index in "${!STATE_SERVICE_NAMES[@]}"; do
    if [ "$index" -eq "$remove_index" ]; then
      continue
    fi
    new_service_names+=("${STATE_SERVICE_NAMES[$index]}")
    new_auth_files+=("${STATE_AUTH_FILES[$index]}")
    new_ports+=("${STATE_PORTS[$index]}")
  done

  STATE_SERVICE_NAMES=("${new_service_names[@]}")
  STATE_AUTH_FILES=("${new_auth_files[@]}")
  STATE_PORTS=("${new_ports[@]}")
}

next_batch_port() {
  local port_start="$1"
  local candidate_port
  local port
  local used

  candidate_port="$port_start"

  while :; do
    used=0

    for port in "${STATE_PORTS[@]}"; do
      if [ "$port" = "$candidate_port" ]; then
        used=1
        break
      fi
    done

    if [ "$used" -eq 0 ] && ! listener_is_running_on_port "$candidate_port"; then
      printf '%s' "$candidate_port"
      return
    fi

    candidate_port="$((candidate_port + 1))"
  done
}

ensure_service_name() {
  local service_name="$1"

  if [[ ! "$service_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "Invalid service name: $service_name" >&2
    echo "Allowed pattern: ^[A-Za-z0-9][A-Za-z0-9._-]*$" >&2
    return 1
  fi
}

service_root() {
  printf '%s/%s' "$SERVICE_BASE_DIR" "$1"
}

meta_file() {
  printf '%s/service.env' "$(service_root "$1")"
}

pid_file() {
  printf '%s/service.pid' "$(service_root "$1")"
}

log_file() {
  printf '%s/service.log' "$(service_root "$1")"
}

listener_pid_by_port() {
  local port="$1"
  local output

  output="$(ss -ltnp "( sport = :$port )" 2>/dev/null || true)"
  printf '%s\n' "$output" | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | sed -n '1p'
}

listener_is_running_on_port() {
  local port="$1"
  local pid

  pid="$(listener_pid_by_port "$port")"
  [ -n "$pid" ]
}

refresh_service_pid_file() {
  local service_name="$1"
  local listener_pid

  if ! load_service_meta "$service_name" >/dev/null 2>&1; then
    return 1
  fi

  listener_pid="$(listener_pid_by_port "$PORT")"
  if [ -n "$listener_pid" ]; then
    printf '%s\n' "$listener_pid" > "$PID_FILE"
    chmod 600 "$PID_FILE" 2>/dev/null || true
  fi

  ACTIVE_SERVICE_PID="$listener_pid"
  [ -n "$listener_pid" ]
}

is_pid_running() {
  local pid="$1"

  kill -0 "$pid" >/dev/null 2>&1
}

load_service_meta() {
  local service_name="$1"
  local file

  file="$(meta_file "$service_name")"

  if [ ! -f "$file" ]; then
    echo "Service metadata not found for: $service_name" >&2
    return 1
  fi

  # shellcheck disable=SC1090
  source "$file"
}

service_has_metadata() {
  local service_name="$1"

  [ -f "$(meta_file "$service_name")" ]
}

service_is_running() {
  local service_name="$1"

  if ! service_has_metadata "$service_name"; then
    return 1
  fi

  refresh_service_pid_file "$service_name" >/dev/null 2>&1 || return 1
}

list_all_service_names() {
  local root

  if [ ! -d "$SERVICE_BASE_DIR" ]; then
    return 0
  fi

  for root in "$SERVICE_BASE_DIR"/*; do
    if [ -d "$root" ]; then
      basename "$root"
    fi
  done
}

find_services_by_auth_file() {
  local auth_file="$1"
  local prefix_filter="${2:-}"
  local service_name

  MATCHED_SERVICE_NAMES=()

  while IFS= read -r service_name; do
    if [ -z "$service_name" ]; then
      continue
    fi

    if [ -n "$prefix_filter" ] && [[ "$service_name" != "$prefix_filter"* ]]; then
      continue
    fi

    if load_service_meta "$service_name" >/dev/null 2>&1; then
      if [ "${AUTH_FILE:-}" = "$auth_file" ]; then
        MATCHED_SERVICE_NAMES+=("$service_name")
      fi
    fi
  done < <(list_all_service_names)
}

choose_existing_service_for_auth() {
  local auth_file="$1"
  local prefix_filter="${2:-}"
  local service_name

  PREFERRED_SERVICE_NAME=""

  find_services_by_auth_file "$auth_file" "$prefix_filter"

  for service_name in "${MATCHED_SERVICE_NAMES[@]}"; do
    if service_is_running "$service_name"; then
      PREFERRED_SERVICE_NAME="$service_name"
      return 0
    fi
  done

  if [ "${#MATCHED_SERVICE_NAMES[@]}" -gt 0 ]; then
    PREFERRED_SERVICE_NAME="${MATCHED_SERVICE_NAMES[0]}"
    return 0
  fi

  return 1
}

stop_stale_missing_auth_services_in_folder() {
  local folder_path="$1"
  local service_name

  while IFS= read -r service_name; do
    if [ -z "$service_name" ]; then
      continue
    fi

    if ! load_service_meta "$service_name" >/dev/null 2>&1; then
      continue
    fi

    case "$AUTH_FILE" in
      "$folder_path"/*)
        if [ ! -e "$AUTH_FILE" ]; then
          echo "Stopping stale service whose auth file no longer exists: $service_name ($AUTH_FILE)" >&2
          stop_service "$service_name" >/dev/null 2>&1 || true
        fi
        ;;
    esac
  done < <(list_all_service_names)
}

collect_folder_auth_files() {
  local folder_input="$1"
  local resolved_folder
  local matches=()
  local auth_files=()
  local path

  if [ ! -d "$folder_input" ]; then
    echo "Folder not found: $folder_input" >&2
    return 1
  fi

  resolved_folder="$(readlink -f "$folder_input")"

  shopt -s nullglob
  matches=("$resolved_folder"/auth.json-*)
  shopt -u nullglob

  for path in "${matches[@]}"; do
    if [ -f "$path" ]; then
      auth_files+=("$(readlink -f "$path")")
    fi
  done

  if [ "${#auth_files[@]}" -eq 0 ]; then
    BATCH_AUTH_FILES=()
  else
    mapfile -t BATCH_AUTH_FILES < <(printf '%s\n' "${auth_files[@]}" | sort)
  fi
  BATCH_FOLDER_RESOLVED="$resolved_folder"
}

build_folder_service_prefix() {
  local folder_path="$1"
  local explicit_prefix="${2:-}"
  local folder_basename
  local folder_slug
  local folder_hash
  local prefix_slug

  if [ -n "$explicit_prefix" ]; then
    prefix_slug="$(sanitize_slug "$explicit_prefix")"
    printf '%s' "${prefix_slug:-batch}"
    return
  fi

  folder_basename="$(basename "$folder_path")"
  folder_slug="$(sanitize_slug "$folder_basename")"
  folder_hash="$(printf '%s' "$folder_path" | sha256sum | cut -c1-8)"
  printf 'batch-%s-%s' "${folder_slug:-folder}" "$folder_hash"
}

build_folder_service_name() {
  local service_prefix="$1"
  local auth_file="$2"
  local base_name
  local file_slug

  base_name="$(basename "$auth_file")"
  base_name="${base_name#auth.json-}"
  file_slug="$(sanitize_slug "$base_name")"
  printf '%s-%s' "$service_prefix" "${file_slug:-auth}"
}

print_service_status() {
  local service_name="$1"
  local root

  root="$(service_root "$service_name")"

  if [ ! -d "$root" ]; then
    echo "$service_name: missing"
    return
  fi

  load_service_meta "$service_name"

  if refresh_service_pid_file "$service_name" >/dev/null 2>&1; then
    echo "$SERVICE_NAME: running pid=$ACTIVE_SERVICE_PID mode=$MODE url=http://$HOSTNAME:$PORT auth=$AUTH_FILE"
  else
    echo "$SERVICE_NAME: stopped mode=$MODE url=http://$HOSTNAME:$PORT auth=$AUTH_FILE"
  fi
}

start_service() {
  local service_name="$1"
  local auth_file_input="$2"
  local port=""
  local hostname="127.0.0.1"
  local mode="web"
  local extra_args=()

  shift 2

  ensure_service_name "$service_name"

  if [ ! -f "$auth_file_input" ]; then
    echo "Auth file not found: $auth_file_input" >&2
    return 1
  fi

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --port)
        if [ "$#" -lt 2 ]; then
          echo "Missing value for --port" >&2
          return 1
        fi
        port="$2"
        shift 2
        ;;
      --hostname)
        if [ "$#" -lt 2 ]; then
          echo "Missing value for --hostname" >&2
          return 1
        fi
        hostname="$2"
        shift 2
        ;;
      --mode)
        if [ "$#" -lt 2 ]; then
          echo "Missing value for --mode" >&2
          return 1
        fi
        mode="$2"
        shift 2
        ;;
      --)
        shift
        extra_args=("$@")
        break
        ;;
      *)
        extra_args+=("$1")
        shift
        ;;
    esac
  done

  if [ -z "$port" ]; then
    echo "The start command requires --port so each service has a stable URL." >&2
    return 1
  fi

  if [ "$mode" != "web" ] && [ "$mode" != "serve" ]; then
    echo "Unsupported mode: $mode" >&2
    echo "Supported modes: web, serve" >&2
    return 1
  fi

  mkdir -p "$SERVICE_BASE_DIR"

  local root
  local meta
  local pid_path
  local log_path
  local auth_file
  local started_at
  local extra_args_display
  local pid
  local listener_pid
  local attempt

  root="$(service_root "$service_name")"
  meta="$(meta_file "$service_name")"
  pid_path="$(pid_file "$service_name")"
  log_path="$(log_file "$service_name")"
  auth_file="$(readlink -f "$auth_file_input")"
  started_at="$(date -Iseconds)"
  if [ "${#extra_args[@]}" -gt 0 ]; then
    extra_args_display="$(printf '%q ' "${extra_args[@]}")"
  else
    extra_args_display=""
  fi

  mkdir -p "$root"
  chmod 700 "$root"

  if refresh_service_pid_file "$service_name" >/dev/null 2>&1; then
    echo "Service is already running: $service_name (pid $ACTIVE_SERVICE_PID)" >&2
    return 0
  fi

  listener_pid="$(listener_pid_by_port "$port")"
  if [ -n "$listener_pid" ]; then
    echo "Port $port is already in use by pid $listener_pid; cannot start $service_name" >&2
    return 1
  fi

  : > "$log_path"

  nohup env \
    BROWSER=/bin/true \
    OPENCODE_AUTH_LAUNCHER_PROFILE="$service_name" \
    bash "$RUNNER_PATH" "$auth_file" "$mode" --hostname "$hostname" --port "$port" "${extra_args[@]}" \
    </dev/null >> "$log_path" 2>&1 &
  pid="$!"

  listener_pid=""
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    listener_pid="$(listener_pid_by_port "$port")"
    if [ -n "$listener_pid" ]; then
      break
    fi
    if ! is_pid_running "$pid"; then
      break
    fi
    sleep 1
  done

  if [ -z "$listener_pid" ]; then
    echo "Service failed to start: $service_name" >&2
    echo "Log file: $log_path" >&2
    return 1
  fi

  {
    printf 'SERVICE_NAME=%q\n' "$service_name"
    printf 'AUTH_FILE=%q\n' "$auth_file"
    printf 'PORT=%q\n' "$port"
    printf 'HOSTNAME=%q\n' "$hostname"
    printf 'MODE=%q\n' "$mode"
    printf 'PID=%q\n' "$listener_pid"
    printf 'PID_FILE=%q\n' "$pid_path"
    printf 'LOG_FILE=%q\n' "$log_path"
    printf 'STARTED_AT=%q\n' "$started_at"
    printf 'EXTRA_ARGS=%q\n' "$extra_args_display"
  } > "$meta"
  chmod 600 "$meta"
  printf '%s\n' "$listener_pid" > "$pid_path"
  chmod 600 "$pid_path"

  echo "Started $service_name" >&2
  echo "  pid: $listener_pid" >&2
  echo "  mode: $mode" >&2
  echo "  url: http://$hostname:$port" >&2
  echo "  auth: $auth_file" >&2
  echo "  log: $log_path" >&2
}

stop_service() {
  local service_name="$1"
  local target_pid

  ensure_service_name "$service_name"
  load_service_meta "$service_name"

  target_pid="$(listener_pid_by_port "$PORT")"

  if [ -z "$target_pid" ]; then
    rm -f "$PID_FILE"
    echo "Service was already stopped: $service_name" >&2
    return 0
  fi

  kill "$target_pid"

  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if ! listener_is_running_on_port "$PORT"; then
      rm -f "$PID_FILE"
      echo "Stopped $service_name" >&2
      return 0
    fi
    sleep 1
  done

  echo "Service did not stop within 10 seconds: $service_name (pid $target_pid)" >&2
  echo "You can inspect logs at: $LOG_FILE" >&2
  return 1
}

start_folder_services() {
  local folder_input="$1"
  local port_start=""
  local hostname=""
  local mode=""
  local service_prefix=""
  local extra_args=()
  local resolved_prefix
  local auth_file
  local service_name
  local port
  local started_names=()
  local index
  local state_loaded=0

  shift

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --port-start)
        if [ "$#" -lt 2 ]; then
          echo "Missing value for --port-start" >&2
          return 1
        fi
        port_start="$2"
        shift 2
        ;;
      --hostname)
        if [ "$#" -lt 2 ]; then
          echo "Missing value for --hostname" >&2
          return 1
        fi
        hostname="$2"
        shift 2
        ;;
      --mode)
        if [ "$#" -lt 2 ]; then
          echo "Missing value for --mode" >&2
          return 1
        fi
        mode="$2"
        shift 2
        ;;
      --prefix)
        if [ "$#" -lt 2 ]; then
          echo "Missing value for --prefix" >&2
          return 1
        fi
        service_prefix="$2"
        shift 2
        ;;
      --)
        shift
        extra_args=("$@")
        break
        ;;
      *)
        extra_args+=("$1")
        shift
        ;;
    esac
  done

  collect_folder_auth_files "$folder_input" || return 1
  resolved_prefix="$(build_folder_service_prefix "$BATCH_FOLDER_RESOLVED" "$service_prefix")"

  stop_stale_missing_auth_services_in_folder "$BATCH_FOLDER_RESOLVED"

  if load_batch_state "$BATCH_FOLDER_RESOLVED" "$resolved_prefix"; then
    state_loaded=1
  fi

  if [ "$state_loaded" -eq 1 ]; then
    if [ -z "$port_start" ]; then
      port_start="$STATE_PORT_START"
    elif [ -n "$STATE_PORT_START" ] && [ "$port_start" != "$STATE_PORT_START" ]; then
      echo "Ignoring changed --port-start=$port_start and keeping saved port start $STATE_PORT_START for batch consistency." >&2
      port_start="$STATE_PORT_START"
    fi
  fi

  if [ -z "$port_start" ]; then
    echo "The start-folder command requires --port-start on first use." >&2
    return 1
  fi

  if [ -z "$hostname" ]; then
    hostname="${STATE_HOSTNAME:-127.0.0.1}"
  fi

  if [ -z "$mode" ]; then
    mode="${STATE_MODE:-web}"
  fi

  if [ "$mode" != "web" ] && [ "$mode" != "serve" ]; then
    echo "Unsupported mode: $mode" >&2
    echo "Supported modes: web, serve" >&2
    return 1
  fi

  echo "Starting folder batch from: $BATCH_FOLDER_RESOLVED" >&2
  echo "Batch service prefix: $resolved_prefix" >&2

  for ((index=${#STATE_AUTH_FILES[@]}-1; index>=0; index--)); do
    if ! auth_is_in_current_folder "${STATE_AUTH_FILES[$index]}"; then
      echo "Auth file removed from folder, stopping stale service: ${STATE_SERVICE_NAMES[$index]}" >&2
      if service_has_metadata "${STATE_SERVICE_NAMES[$index]}"; then
        stop_service "${STATE_SERVICE_NAMES[$index]}" || true
      fi
      remove_state_entry_by_index "$index"
    fi
  done

  for auth_file in "${BATCH_AUTH_FILES[@]}"; do
    if find_state_index_by_auth_file "$auth_file"; then
      service_name="${STATE_SERVICE_NAMES[$STATE_MATCH_INDEX]}"
      port="${STATE_PORTS[$STATE_MATCH_INDEX]}"

      if service_is_running "$service_name"; then
        echo "Already running from saved batch state: $service_name" >&2
      else
        if ! start_service "$service_name" "$auth_file" --port "$port" --hostname "$hostname" --mode "$mode" -- "${extra_args[@]}"; then
          echo "Batch start failed at saved service: $service_name" >&2
          echo "Rolling back newly started services from this batch..." >&2
          for service_name in "${started_names[@]}"; do
            stop_service "$service_name" >/dev/null 2>&1 || true
          done
          return 1
        fi
        started_names+=("$service_name")
      fi
    else
      if choose_existing_service_for_auth "$auth_file"; then
        service_name="$PREFERRED_SERVICE_NAME"
        if ! load_service_meta "$service_name"; then
          echo "Failed to load existing service metadata: $service_name" >&2
          return 1
        fi
        port="$PORT"
        append_state_entry "$service_name" "$auth_file" "$port"

        if service_is_running "$service_name"; then
          echo "Adopted existing running service into batch state: $service_name" >&2
        else
          if ! start_service "$service_name" "$auth_file" --port "$port" --hostname "$hostname" --mode "$mode" -- "${extra_args[@]}"; then
            echo "Batch start failed while reusing existing service name: $service_name" >&2
            echo "Rolling back newly started services from this batch..." >&2
            for service_name in "${started_names[@]}"; do
              stop_service "$service_name" >/dev/null 2>&1 || true
            done
            return 1
          fi
          started_names+=("$service_name")
        fi
      else
        port="$(next_batch_port "$port_start")"
        service_name="$(build_folder_service_name "$resolved_prefix" "$auth_file")"

        if service_has_metadata "$service_name" && load_service_meta "$service_name" && [ "$AUTH_FILE" != "$auth_file" ]; then
          service_name="${service_name}-$(printf '%s' "$auth_file" | sha256sum | cut -c1-6)"
        fi

        if ! start_service "$service_name" "$auth_file" --port "$port" --hostname "$hostname" --mode "$mode" -- "${extra_args[@]}"; then
          echo "Batch start failed at service: $service_name" >&2
          echo "Rolling back newly started services from this batch..." >&2
          for service_name in "${started_names[@]}"; do
            stop_service "$service_name" >/dev/null 2>&1 || true
          done
          return 1
        fi
        append_state_entry "$service_name" "$auth_file" "$port"
        started_names+=("$service_name")
      fi
    fi
  done

  if [ "${#BATCH_AUTH_FILES[@]}" -eq 0 ] && [ "$state_loaded" -eq 0 ]; then
    echo "No auth files found in $BATCH_FOLDER_RESOLVED matching auth.json-*" >&2
    return 1
  fi

  save_batch_state "$BATCH_FOLDER_RESOLVED" "$resolved_prefix" "$port_start" "$hostname" "$mode"

  echo "Batch start completed for ${#BATCH_AUTH_FILES[@]} auth files." >&2
}

stop_folder_services() {
  local folder_input="$1"
  local service_prefix=""
  local resolved_prefix
  local auth_file
  local service_name
  local index
  local new_service_names=()
  local new_auth_files=()
  local new_ports=()
  local state_loaded=0

  shift

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --prefix)
        if [ "$#" -lt 2 ]; then
          echo "Missing value for --prefix" >&2
          return 1
        fi
        service_prefix="$2"
        shift 2
        ;;
      *)
        echo "Unknown argument for stop-folder: $1" >&2
        return 1
        ;;
    esac
  done

  collect_folder_auth_files "$folder_input" || return 1
  resolved_prefix="$(build_folder_service_prefix "$BATCH_FOLDER_RESOLVED" "$service_prefix")"

  if load_batch_state "$BATCH_FOLDER_RESOLVED" "$resolved_prefix"; then
    state_loaded=1
  fi

  if [ "$state_loaded" -eq 1 ]; then
    for index in "${!STATE_SERVICE_NAMES[@]}"; do
      stop_service "${STATE_SERVICE_NAMES[$index]}" || true

      if auth_is_in_current_folder "${STATE_AUTH_FILES[$index]}"; then
        new_service_names+=("${STATE_SERVICE_NAMES[$index]}")
        new_auth_files+=("${STATE_AUTH_FILES[$index]}")
        new_ports+=("${STATE_PORTS[$index]}")
      else
        echo "Removing deleted auth from saved batch state: ${STATE_AUTH_FILES[$index]}" >&2
      fi
    done

    STATE_SERVICE_NAMES=("${new_service_names[@]}")
    STATE_AUTH_FILES=("${new_auth_files[@]}")
    STATE_PORTS=("${new_ports[@]}")
    save_batch_state "$BATCH_FOLDER_RESOLVED" "$resolved_prefix" "${STATE_PORT_START:-}" "${STATE_HOSTNAME:-127.0.0.1}" "${STATE_MODE:-web}"
    return 0
  fi

  for auth_file in "${BATCH_AUTH_FILES[@]}"; do
    find_services_by_auth_file "$auth_file"

    if [ "${#MATCHED_SERVICE_NAMES[@]}" -eq 0 ]; then
      service_name="$(build_folder_service_name "$resolved_prefix" "$auth_file")"
      echo "No service metadata found for auth: $auth_file (expected batch name: $service_name)" >&2
      continue
    fi

    for service_name in "${MATCHED_SERVICE_NAMES[@]}"; do
      stop_service "$service_name" || true
    done
  done
}

status_folder_services() {
  local folder_input="$1"
  local service_prefix=""
  local resolved_prefix
  local auth_file
  local service_name
  local index
  local state_loaded=0

  shift

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --prefix)
        if [ "$#" -lt 2 ]; then
          echo "Missing value for --prefix" >&2
          return 1
        fi
        service_prefix="$2"
        shift 2
        ;;
      *)
        echo "Unknown argument for status-folder: $1" >&2
        return 1
        ;;
    esac
  done

  collect_folder_auth_files "$folder_input" || return 1
  resolved_prefix="$(build_folder_service_prefix "$BATCH_FOLDER_RESOLVED" "$service_prefix")"

  if load_batch_state "$BATCH_FOLDER_RESOLVED" "$resolved_prefix"; then
    state_loaded=1
  fi

  for auth_file in "${BATCH_AUTH_FILES[@]}"; do
    if [ "$state_loaded" -eq 1 ] && find_state_index_by_auth_file "$auth_file"; then
      print_service_status "${STATE_SERVICE_NAMES[$STATE_MATCH_INDEX]}"
      continue
    fi

    find_services_by_auth_file "$auth_file"
    if [ "${#MATCHED_SERVICE_NAMES[@]}" -gt 0 ]; then
      for service_name in "${MATCHED_SERVICE_NAMES[@]}"; do
        print_service_status "$service_name"
      done
    else
      service_name="$(build_folder_service_name "$resolved_prefix" "$auth_file")"
      echo "$service_name: missing auth=$auth_file"
    fi
  done

  if [ "$state_loaded" -eq 1 ]; then
    for index in "${!STATE_AUTH_FILES[@]}"; do
      if auth_is_in_current_folder "${STATE_AUTH_FILES[$index]}"; then
        continue
      fi

      if service_has_metadata "${STATE_SERVICE_NAMES[$index]}"; then
        load_service_meta "${STATE_SERVICE_NAMES[$index]}" >/dev/null 2>&1 || true
        if [ -f "${PID_FILE:-/nonexistent}" ] && is_pid_running "${PID:-0}"; then
          echo "${STATE_SERVICE_NAMES[$index]}: running pid=$PID mode=$MODE url=http://$HOSTNAME:$PORT auth=${STATE_AUTH_FILES[$index]} folder_file=missing"
        else
          echo "${STATE_SERVICE_NAMES[$index]}: stopped auth=${STATE_AUTH_FILES[$index]} folder_file=missing"
        fi
      else
        echo "${STATE_SERVICE_NAMES[$index]}: missing auth=${STATE_AUTH_FILES[$index]} folder_file=missing"
      fi
    done
  fi
}

status_services() {
  if [ "$#" -eq 0 ]; then
    list_services
    return
  fi

  ensure_service_name "$1"
  print_service_status "$1"
}

list_services() {
  if [ ! -d "$SERVICE_BASE_DIR" ]; then
    echo "No services found."
    return
  fi

  local found=0
  local root

  for root in "$SERVICE_BASE_DIR"/*; do
    if [ ! -d "$root" ]; then
      continue
    fi

    found=1
    print_service_status "$(basename "$root")"
  done

  if [ "$found" -eq 0 ]; then
    echo "No services found."
  fi
}

show_logs() {
  local service_name="$1"
  local lines="${2:-50}"

  ensure_service_name "$service_name"
  load_service_meta "$service_name"

  if [ ! -f "$LOG_FILE" ]; then
    echo "Log file not found for: $service_name" >&2
    return 1
  fi

  tail -n "$lines" "$LOG_FILE"
}

if [ "$#" -lt 1 ]; then
  usage
fi

COMMAND="$1"
shift || true

case "$COMMAND" in
  start)
    if [ "$#" -lt 2 ]; then
      usage
    fi
    start_service "$@"
    ;;
  start-folder)
    if [ "$#" -lt 1 ]; then
      usage
    fi
    start_folder_services "$@"
    ;;
  stop)
    if [ "$#" -ne 1 ]; then
      usage
    fi
    stop_service "$1"
    ;;
  stop-folder)
    if [ "$#" -lt 1 ]; then
      usage
    fi
    stop_folder_services "$@"
    ;;
  status)
    status_services "$@"
    ;;
  status-folder)
    if [ "$#" -lt 1 ]; then
      usage
    fi
    status_folder_services "$@"
    ;;
  list)
    if [ "$#" -ne 0 ]; then
      usage
    fi
    list_services
    ;;
  logs)
    if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
      usage
    fi
    show_logs "$@"
    ;;
  *)
    usage
    ;;
esac
