# OpenCode Auth Launcher

This toolset lets you use multiple OpenCode auth files without copying them.

It supports two modes:

1. **Global auth link switch** for one active default profile.
2. **Isolated per-auth launcher** for running multiple OpenCode instances at the same time.

## Why there are two modes

OpenCode reads credentials from `auth.json` under its data directory.

- The default location is usually `~/.local/share/opencode/auth.json`.
- That single global path can only point to **one** auth file at a time.
- If you want multiple `opencode web` instances with different auth files at the same time, you need separate data roots.

This launcher solves that by using:

- `opencode-auth-link` → relinks the global `auth.json`
- `opencode-auth` → runs OpenCode with an isolated `XDG_DATA_HOME`
- `opencode-web-auth` → manages background `web`/`serve` services with isolated data roots
- `opencode-web-auth start-folder/stop-folder` → starts or stops every `auth.json-*` file in a folder

## No-copy guarantee

The launcher never copies your auth file.

- Global mode creates a symlink at `~/.local/share/opencode/auth.json`
- Isolated mode creates a symlink at `~/.opencode-auth-launcher/profiles/<profile>/xdg-data/opencode/auth.json`

Your source auth file remains the single source of truth, so token refreshes stay centralized.

## Install local commands

```bash
bash ~/IdeaProjects/opencode-auth-launcher/install-bashrc-command.sh
source ~/.bashrc
```

The installer copies the runtime scripts into `~/.local/share/opencode-auth-launcher`
and installs standalone command files into `~/.local/bin`.
It replaces any older `opencode-auth-launcher` shell-function block in your rc file with a minimal PATH block.
The copied commands continue to work even if the original repository directory is removed later.
Re-run the installer after updating the repository when you want to refresh the copied command files.

## Commands

### 1) Switch the global auth link

```bash
opencode-auth-link ~/auth.json-openai@example.com
```

This rewires the default OpenCode auth path.

Use this when you only want one active default auth at a time.

### 2) Run OpenCode with an isolated auth link

```bash
opencode-auth ~/auth.json-z.ai
opencode-auth ~/auth.json-z.ai web --port 4101
opencode-auth ~/auth.json-openai-tinywind0@gmail.com web --port 4102
```

Each auth file gets its own isolated data directory, so multiple instances can run at the same time.

### 3) Manage background services

```bash
opencode-web-auth start z-ai ~/auth.json-z.ai --port 4101
opencode-web-auth start openai ~/auth.json-openai-tinywind0@gmail.com --port 4102

opencode-web-auth list
opencode-web-auth status z-ai
opencode-web-auth logs z-ai
opencode-web-auth stop z-ai
```

By default, the service command runs `opencode web`.

If you want a headless background service instead, use `--mode serve`:

```bash
opencode-web-auth start z-ai ~/auth.json-z.ai --mode serve --port 4201
```

### 4) Start or stop a whole auth folder at once

Only files whose names start with `auth.json-` are included.

```bash
opencode-web-auth start-folder ~/auth-files --port-start 4311 --hostname 0.0.0.0
opencode-web-auth status-folder ~/auth-files
opencode-web-auth stop-folder ~/auth-files
```

Batch service names are deterministic, so the same folder can be started and stopped later without manually listing each auth file.

`status-folder` and `stop-folder` also match existing services by the source auth file path, so they can detect services that were started earlier with custom service names.

Folder batches keep persistent state under:

```text
~/.config/opencode-auth-launcher/batches/
```

That state stores the batch identity, folder path, service prefix, stable port assignments, and auth-to-service mapping.
This lets the batch commands reflect file additions, deletions, and renames over time instead of recomputing everything from scratch.

If you want a custom batch prefix instead of the auto-generated one:

```bash
opencode-web-auth start-folder ~/auth-files --port-start 4311 --hostname 0.0.0.0 --prefix team-a
opencode-web-auth stop-folder ~/auth-files --prefix team-a
```

## Service command syntax

```bash
opencode-web-auth start <service-name> <auth-file> --port <port> [--hostname <host>] [--mode web|serve] [-- <extra-opencode-args...>]
opencode-web-auth start-folder <folder> --port-start <port> [--hostname <host>] [--mode web|serve] [--prefix <service-prefix>] [-- <extra-opencode-args...>]
opencode-web-auth stop <service-name>
opencode-web-auth stop-folder <folder> [--prefix <service-prefix>]
opencode-web-auth status [service-name]
opencode-web-auth status-folder <folder> [--prefix <service-prefix>]
opencode-web-auth list
opencode-web-auth logs <service-name> [line-count]
```

Examples:

```bash
opencode-web-auth start z-ai ~/auth.json-z.ai --port 4101
opencode-web-auth start openai ~/auth.json-openai-user@example.com --port 4102 --hostname 127.0.0.1
opencode-web-auth logs openai 100
opencode-web-auth start-folder ~/auth-files --port-start 4311 --hostname 0.0.0.0
```

## Files created by the launcher

```text
~/.opencode-auth-launcher/
├── profiles/
│   └── <profile>/
│       ├── profile.json
│       ├── xdg-cache/
│       ├── xdg-data/
│       │   └── opencode/
│       │       └── auth.json -> /path/to/your/auth.json
│       └── xdg-state/
└── services/
    └── <service-name>/
        ├── service.env
        ├── service.log
        └── service.pid

~/.local/share/opencode-auth-launcher/
├── run-with-auth.sh
├── link-global-auth.sh
└── manage-web-service.sh

~/.local/bin/
├── opencode-auth
├── opencode-auth-link
└── opencode-web-auth
```

## Notes

- The global symlink mode is intentionally single-target.
- Multi-service mode uses isolated `XDG_DATA_HOME` directories because one global `auth.json` path cannot serve different auth files simultaneously.
- The service launcher records logs and PIDs under `~/.opencode-auth-launcher/services/`.
- The installer copies standalone commands into the user-local command path instead of relying on shell function wrappers.
- Folder batch mode only targets files matching `auth.json-*`.
- Folder batch state is stored under `~/.config/opencode-auth-launcher/batches/`.
