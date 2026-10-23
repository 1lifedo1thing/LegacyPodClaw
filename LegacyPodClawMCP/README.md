# LegacyPodClawMCP

MCP (Model Context Protocol) development tools for LegacyPodClaw / iOS 6 jailbreak development.

## Tools

### Device
| Tool | Description |
|------|-------------|
| `device_info` | Get device model, iOS version, UDID |
| `device_ssh` | Execute shell command on device |
| `device_scp_get` | Download file from device |
| `device_scp_put` | Upload file to device |
| `device_install_deb` | Install .deb package + respring |
| `device_respring` | Restart SpringBoard |
| `device_logs` | Read syslog (with optional filter) |
| `device_crash_reports` | List recent crash reports |
| `device_read_crash` | Read a specific crash report |
| `device_processes` | List running processes |
| `device_packages` | List installed dpkg packages |
| `device_filesystem` | List directory contents |
| `device_read_file` | Read a text file |
| `device_disk_usage` | Show disk space |
| `device_memory` | Show memory usage |

### Class Dump
| Tool | Description |
|------|-------------|
| `class_dump` | Download binary from device and class-dump it into the work directory |
| `class_dump_list_headers` | List headers from a previous dump |
| `class_dump_read_header` | Read a specific dumped header |

### iOS 6 Headers
| Tool | Description |
|------|-------------|
| `ios_headers_search` | Search iOS 6 private headers by keyword |
| `ios_headers_read` | Read a specific header file |
| `ios_headers_list_classes` | List all classes in a framework |

### Theos Build
| Tool | Description |
|------|-------------|
| `theos_build` | Build a Theos project |
| `theos_package` | Package into .deb |
| `theos_install` | Build + package + install on device |

### LegacyPodClaw
| Tool | Description |
|------|-------------|
| `clawpod_status` | Check LegacyPodClaw installation status |

## Setup

```bash
pip3 install mcp==1.30.0
brew install sshpass libimobiledevice
```

`mcp` 2.x removed `FastMCP`, so keep the 1.x pin until the server is ported.

### Safety rules

- Local processes always run from an argument list, never through a shell.
- Every tool argument that reaches the device shell is quoted. `device_ssh` is the one exception: it runs the command you give it on the device.
- Local files that tools write must be inside `CLAWPOD_WORKDIR`. Local files that tools read must be inside `CLAWPOD_WORKDIR` or `CLAWPOD_PROJECT`.
- `theos_*` tools build only inside `CLAWPOD_PROJECT`, because `make` runs arbitrary code.
- The SSH password goes to `sshpass -e` in the environment, so it is not in the process list. Tool results are scrubbed of it.
- The device host key is pinned on first use in `CLAWPOD_WORKDIR/known_hosts`. If you swap devices on the same port, delete that file.

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAWPOD_DEVICE_IP` | `127.0.0.1` | Device SSH host |
| `CLAWPOD_SSH_PORT` | `2222` | SSH port (via iproxy) |
| `CLAWPOD_SSH_USER` | `root` | SSH user |
| `CLAWPOD_SSH_PASS` | `alpine` | SSH password |
| `THEOS` | `~/theos` | Theos installation path |
| `IOS6_HEADERS` | `~/iOS-6-Headers` | iOS 6 headers path |
| `CLAWPOD_PROJECT` | `~/openclaw-ios6` | LegacyPodClaw project directory |
| `CLAWPOD_WORKDIR` | `~/.legacypodclaw-mcp` | Downloads, class dumps and known_hosts (mode 0700) |

## Usage with Claude Code

Add to your Claude Code MCP settings:

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

Then ask Claude to interact with your device:
- "What's the device info?"
- "Search iOS 6 headers for SBAwayLockBar"
- "Build and install LegacyPodClaw on the device"
- "Class-dump SpringBoard and find camera-related methods"
- "Read the crash log from the latest crash"

## Music proxy

`music_proxy.py` runs yt-dlp and ffmpeg for the iPod.

```bash
pip3 install yt-dlp==2026.8.19
brew install ffmpeg
python3 music_proxy.py --host 0.0.0.0
```

- The proxy binds `127.0.0.1` by default. Use `--host` or `MUSIC_PROXY_HOST` to serve the LAN.
- On a non-loopback address the proxy requires a token. It makes the token on first run and keeps it in `~/.config/legacypodclaw/music_proxy.token` (mode 0600). Set `MUSIC_PROXY_CONFIG_DIR` to move it.
- Set the Music Proxy URL on the iPod to `http://YOUR_IP:18790/t/TOKEN`. Other clients can send `Authorization: Bearer TOKEN`.
- The proxy accepts only 11-character YouTube video IDs, runs at most two jobs at a time, and refuses audio longer than one hour or larger than 100 MB.
