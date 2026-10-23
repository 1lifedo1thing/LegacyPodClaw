---
title: "LegacyPodClawMCP"
description: "Mac-side MCP tools for iOS 6 development"
weight: 5
---

LegacyPodClawMCP is a Python MCP server for development. It runs on the Mac. It gives an AI assistant tools for the device, class dumps, iOS 6 headers and Theos builds. The same directory has the music proxy.

## Setup

```bash
pip3 install mcp==1.30.0
brew install sshpass libimobiledevice
python3 LegacyPodClawMCP/server.py
```

`mcp` 2.x removed `FastMCP`. Keep the 1.x pin until the server is ported.

When the device address is a loopback address, the server starts `iproxy` for the USB SSH tunnel.

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `CLAWPOD_DEVICE_IP` | `127.0.0.1` | Device SSH host |
| `CLAWPOD_SSH_PORT` | `2222` | SSH port (through iproxy) |
| `CLAWPOD_SSH_USER` | `root` | SSH user |
| `CLAWPOD_SSH_PASS` | `alpine` | SSH password |
| `THEOS` | `~/theos` | Theos path |
| `IOS6_HEADERS` | `~/iOS-6-Headers` | iOS 6 headers path |
| `CLAWPOD_PROJECT` | `~/openclaw-ios6` | LegacyPodClaw project directory |
| `CLAWPOD_WORKDIR` | `~/.legacypodclaw-mcp` | Downloads, class dumps and `known_hosts` (mode 0700) |

## Safety rules

- Local processes always run from an argument list, never through a shell.
- Each tool argument that goes to the device shell is quoted. `device_ssh` is the one exception: it runs the command that you give it.
- Tools write local files only in `CLAWPOD_WORKDIR`. They read local files only in `CLAWPOD_WORKDIR` or `CLAWPOD_PROJECT`.
- `theos_*` tools build only in `CLAWPOD_PROJECT`, because `make` runs any code.
- The SSH password goes to `sshpass -e` in the environment, so it is not in the process list. Tool results do not show it.
- The server pins the device host key on first use in `CLAWPOD_WORKDIR/known_hosts`. If you change the device on the same port, delete that file.

## Claude Code integration

Add the server to your Claude Code MCP settings:

```json
{
  "mcpServers": {
    "clawpod": {
      "command": "python3",
      "args": ["/path/to/LegacyPodClawMCP/server.py"]
    }
  }
}
```

## Tools

### Device

| Tool | Description |
|---|---|
| `device_info` | Device model, iOS version and UDID |
| `device_ssh` | Runs a shell command on the device |
| `device_scp_get` | Copies a file from the device |
| `device_scp_put` | Copies a file to the device |
| `device_install_deb` | Installs a `.deb` and restarts SpringBoard |
| `device_respring` | Restarts SpringBoard |
| `device_logs` | Reads the syslog, with an optional filter |
| `device_crash_reports` | Lists recent crash reports |
| `device_read_crash` | Reads one crash report |
| `device_processes` | Lists running processes |
| `device_packages` | Lists installed dpkg packages |
| `device_filesystem` | Lists a directory |
| `device_read_file` | Reads a text file |
| `device_disk_usage` | Shows disk space |
| `device_memory` | Shows memory use |

### Class dump

| Tool | Description |
|---|---|
| `class_dump` | Copies a binary from the device and class-dumps it into the work directory |
| `class_dump_list_headers` | Lists the headers from a dump |
| `class_dump_read_header` | Reads one dumped header |

### iOS 6 headers

| Tool | Description |
|---|---|
| `ios_headers_search` | Searches the private headers for a word |
| `ios_headers_read` | Reads a header file |
| `ios_headers_list_classes` | Lists the classes in a framework |

### Theos build

| Tool | Description |
|---|---|
| `theos_build` | Builds the project |
| `theos_package` | Makes a `.deb` |
| `theos_install` | Builds, packages and installs on the device |

### Status

| Tool | Description |
|---|---|
| `clawpod_status` | Checks the LegacyPodClaw installation |

## Music proxy

`music_proxy.py` runs yt-dlp and ffmpeg for the device. See [Music Downloads](/guide/music/).
