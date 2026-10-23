#!/usr/bin/env python3
"""
LegacyPodClawMCP — Development Tools for iOS 6 Jailbreak
MCP server providing tools to interact with jailbroken iOS devices.

Every local process is started from an argument list (never a shell).
Remote commands run in the device's shell; every value that comes from a
tool argument is quoted with shlex.quote before it reaches that shell,
except for device_ssh, whose whole purpose is to run a caller-supplied
command on the device.

Local files that tools read or write must sit inside CLAWPOD_WORKDIR
(default ~/.legacypodclaw-mcp) or, for reads, inside CLAWPOD_PROJECT.

The SSH password goes to sshpass through the SSHPASS environment variable,
so it never appears in a process list, and every tool result is scrubbed
of it before it goes back to the model.
"""

import functools
import os
import shlex
import shutil
import subprocess
import time
from pathlib import Path

from mcp.server.fastmcp import FastMCP

from device_link import (
    CRASH_DIR, IOS6_HEADERS, MAX_READ_BYTES, PROJECT_DIR, REMOTE_INSTALL_PATH,
    THEOS_PATH, ToolError, check_local, check_remote, clamp, inside, redact,
    safe_name, scp_get, scp_put, ssh, work_dir,
)

mcp = FastMCP("LegacyPodClawMCP")


def _tool(fn):
    """Register fn as a tool and turn every failure into a scrubbed string."""
    @functools.wraps(fn)
    def wrapper(*args, **kwargs):
        try:
            return redact(fn(*args, **kwargs))
        except ToolError as e:
            return redact(f"Error: {e}")
        except Exception as e:
            # argv and env are never part of the message, and redact catches the rest
            return redact(f"Error: {type(e).__name__}: {e}")
    return mcp.tool()(wrapper)


# === Device Tools ===

@_tool
def device_info() -> str:
    """Get connected iOS device information (model, iOS version, name, UDID)."""
    try:
        result = subprocess.run(["idevice_id", "-l"], capture_output=True, text=True, timeout=10)
    except FileNotFoundError:
        raise ToolError("idevice_id not found; install libimobiledevice") from None
    if not result.stdout.strip():
        return "No device connected via USB. Connect device and try again."

    udid = result.stdout.strip().split("\n")[0]
    info_parts = [f"UDID: {udid}"]
    for key in ["DeviceName", "ProductType", "ProductVersion", "BuildVersion",
                "ModelNumber", "SerialNumber", "WiFiAddress"]:
        r = subprocess.run(
            ["ideviceinfo", "-u", udid, "-k", key],
            capture_output=True, text=True, timeout=10,
        )
        if r.returncode == 0:
            info_parts.append(f"{key}: {r.stdout.strip()}")
    return "\n".join(info_parts)


@_tool
def device_ssh(command: str, timeout: int = 30) -> str:
    """Execute a shell command on the device via SSH. Returns stdout+stderr."""
    if not command or "\x00" in command:
        raise ToolError("empty command") from None
    return ssh(command, clamp(timeout, 1, 600))


@_tool
def device_scp_get(remote_path: str, local_path: str = "") -> str:
    """Download a file from the device into the work directory (CLAWPOD_WORKDIR)."""
    if not local_path:
        local_path = os.path.basename(check_remote(remote_path).rstrip("/"))
        safe_name(local_path, "file name")
    dest = check_local(local_path, [work_dir()], must_exist=False)
    scp_get(remote_path, dest)
    return f"Downloaded to {dest}"


@_tool
def device_scp_put(local_path: str, remote_path: str) -> str:
    """Upload a file from the work directory or project directory to the device."""
    src = check_local(local_path, [work_dir(), PROJECT_DIR], must_exist=True)
    scp_put(src, remote_path)
    return f"Uploaded {src} to {remote_path}"


def _install_deb(deb: Path) -> str:
    if deb.suffix != ".deb":
        raise ToolError("file must end in .deb") from None
    scp_put(deb, REMOTE_INSTALL_PATH)
    return ssh(
        f"dpkg -i {REMOTE_INSTALL_PATH} && su mobile -c /usr/bin/uicache && killall SpringBoard",
        timeout=120,
    )


@_tool
def device_install_deb(deb_path: str) -> str:
    """Install a .deb package on the device. Automatically resprings after."""
    deb = check_local(deb_path, [work_dir(), PROJECT_DIR], must_exist=True)
    return _install_deb(deb)


@_tool
def device_respring() -> str:
    """Respring the device (restart SpringBoard)."""
    return ssh("killall SpringBoard")


@_tool
def device_logs(filter: str = "", lines: int = 50) -> str:
    """Read device syslog. Optionally filter by keyword (fixed string)."""
    n = clamp(lines, 1, 2000)
    if filter:
        if "\n" in filter or "\x00" in filter:
            raise ToolError("invalid filter") from None
        return ssh(
            f"grep -i -F -e {shlex.quote(filter)} /var/log/syslog 2>/dev/null | tail -n {n}"
        )
    return ssh(f"tail -n {n} /var/log/syslog 2>/dev/null")


@_tool
def device_crash_reports(count: int = 5) -> str:
    """List recent crash reports from the device."""
    n = clamp(count, 1, 200)
    return ssh(f"ls -lt {CRASH_DIR}/*.plist 2>/dev/null | head -n {n}")


@_tool
def device_read_crash(filename: str) -> str:
    """Read a specific crash report. Use device_crash_reports to find filenames."""
    name = safe_name(filename, "crash report name")
    path = shlex.quote(f"{CRASH_DIR}/{name}")
    return ssh(f"head -n 100 -- {path} 2>/dev/null")


@_tool
def device_processes() -> str:
    """List running processes on the device."""
    return ssh("ps aux 2>/dev/null || ps -ef 2>/dev/null")


@_tool
def device_packages(filter: str = "") -> str:
    """List installed Cydia/dpkg packages. Optionally filter by name (fixed string)."""
    if filter:
        if "\n" in filter or "\x00" in filter:
            raise ToolError("invalid filter") from None
        return ssh(f"dpkg -l | grep -i -F -e {shlex.quote(filter)}")
    return ssh("dpkg -l")


@_tool
def device_filesystem(path: str = "/") -> str:
    """List directory contents on the device."""
    return ssh(f"ls -la -- {shlex.quote(check_remote(path))} 2>/dev/null")


@_tool
def device_read_file(remote_path: str, max_lines: int = 200) -> str:
    """Read a text file from the device."""
    n = clamp(max_lines, 1, 5000)
    return ssh(f"head -n {n} -- {shlex.quote(check_remote(remote_path))} 2>/dev/null")


@_tool
def device_disk_usage() -> str:
    """Show disk usage on the device."""
    return ssh("df -h")


@_tool
def device_memory() -> str:
    """Show memory usage on the device."""
    return ssh(
        "echo '=== Memory ==='; "
        "sysctl hw.memsize 2>/dev/null; "
        "echo '=== Top processes ==='; "
        "top -l 1 -n 10 2>/dev/null || echo 'top not available'"
    )


# === Class Dump ===

def _classdump_dir(binary_name: str) -> Path:
    return work_dir() / f"classdump_{safe_name(binary_name, 'binary name')}"


@_tool
def class_dump(binary_path: str) -> str:
    """
    Class-dump a binary from the device. Downloads the binary into the work
    directory, runs class-dump locally, and lists the headers it wrote.
    """
    name = safe_name(os.path.basename(check_remote(binary_path).rstrip("/")), "binary name")
    local_binary = work_dir() / "binaries" / name
    scp_get(binary_path, local_binary)

    tool = next((t for t in ("class-dump", "classdump", "class_dump") if shutil.which(t)), None)
    if tool is None:
        return (
            "class-dump not found locally. Install with: brew install class-dump\n"
            "Or use ios_headers_search to search pre-dumped iOS 6 headers."
        )

    output_dir = _classdump_dir(name)
    output_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    result = subprocess.run(
        [tool, "-H", "-o", str(output_dir), "--", str(local_binary)],
        capture_output=True, text=True, timeout=300,
    )
    if result.returncode != 0:
        raise ToolError(f"class-dump failed: {result.stderr.strip()[-500:]}") from None
    headers = sorted(os.listdir(output_dir))
    return f"Dumped {len(headers)} headers to {output_dir}\nFiles: {', '.join(headers[:20])}"


@_tool
def class_dump_list_headers(binary_name: str) -> str:
    """List headers from a previous class-dump. Use class_dump first."""
    output_dir = _classdump_dir(binary_name)
    if not output_dir.is_dir():
        return f"No class dump found for {binary_name}. Run class_dump first."
    headers = sorted(os.listdir(output_dir))
    return f"{len(headers)} headers:\n" + "\n".join(headers)


def _read_text(path: Path) -> str:
    with open(path, "rb") as f:
        data = f.read(MAX_READ_BYTES + 1)
    text = data[:MAX_READ_BYTES].decode("utf-8", errors="replace")
    if len(data) > MAX_READ_BYTES:
        text += "\n... (file truncated)"
    return text


@_tool
def class_dump_read_header(binary_name: str, header_name: str) -> str:
    """Read a specific header from a class dump."""
    path = _classdump_dir(binary_name) / safe_name(header_name, "header name")
    if not path.is_file():
        return f"Header not found: {header_name}"
    return _read_text(path)


# === iOS 6 Headers ===

def _headers_root() -> Path:
    root = Path(IOS6_HEADERS).expanduser().resolve()
    if not root.is_dir():
        raise ToolError(
            f"iOS 6 headers not found at {root}. "
            "Clone: git clone https://github.com/pigigaldi/iOS-6-Headers.git"
        )
    return root


@_tool
def ios_headers_search(query: str, path: str = "") -> str:
    """
    Search iOS 6 private headers for a class name, method, or keyword
    (fixed string). path narrows the search to a sub-directory of IOS6_HEADERS.
    """
    if not query or "\n" in query or "\x00" in query:
        raise ToolError("invalid query") from None
    root = _headers_root()
    search_path = root
    if path:
        search_path = (root / path).resolve()
        if not inside(search_path, root) or not search_path.is_dir():
            raise ToolError(f"path must be a directory inside {root}") from None

    try:
        result = subprocess.run(
            ["grep", "-rnF", "--include=*.h", "-e", query, "--", str(search_path)],
            capture_output=True, text=True, timeout=20,
        )
    except subprocess.TimeoutExpired:
        raise ToolError("search timed out; narrow it with path") from None
    lines = [l for l in result.stdout.split("\n") if l]
    if not lines:
        return "No matches found"
    if len(lines) > 50:
        total = len(lines)
        lines = lines[:50] + [f"... ({total} total matches)"]
    return "\n".join(lines)


@_tool
def ios_headers_read(header_name: str) -> str:
    """Read a specific iOS 6 header file (e.g., 'SBUIController.h')."""
    name = safe_name(header_name, "header name")
    root = _headers_root()
    for dirpath, _dirs, files in os.walk(root):
        if name in files:
            path = (Path(dirpath) / name).resolve()
            if inside(path, root):
                return _read_text(path)
    return f"Header '{name}' not found in {root}"


@_tool
def ios_headers_list_classes(framework: str = "SpringBoard") -> str:
    """List all class headers in a framework (default: SpringBoard)."""
    root = _headers_root()
    framework_path = (root / safe_name(framework, "framework name")).resolve()
    if not inside(framework_path, root) or not framework_path.is_dir():
        return f"Framework not found: {framework}"
    headers = sorted(f for f in os.listdir(framework_path) if f.endswith(".h"))
    return f"{len(headers)} headers in {framework}:\n" + "\n".join(headers)


# === Theos Build ===

def _project(project_dir: str) -> Path:
    root = Path(PROJECT_DIR).expanduser().resolve()
    project = root
    if project_dir:
        project = Path(project_dir).expanduser().resolve()
        # make runs arbitrary code, so only build inside the configured project
        if not inside(project, root):
            raise ToolError(f"project_dir must be inside {root}") from None
    if not project.is_dir():
        raise ToolError(f"Project not found: {project}") from None
    return project


def _theos_env() -> dict:
    env = os.environ.copy()
    env["THEOS"] = THEOS_PATH
    env["PATH"] = f"{THEOS_PATH}/bin:{env.get('PATH', '')}"
    env.pop("SSHPASS", None)
    return env


def _make(args: list, timeout: int):
    try:
        return subprocess.run(
            ["make"] + args, capture_output=True, text=True,
            env=_theos_env(), timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        raise ToolError(f"make {' '.join(args[2:]) or 'all'} timed out after {timeout}s") from None


def _build(project: Path):
    """Return (ok, message)."""
    _make(["-C", str(project), "clean"], 120)
    result = _make(["-C", str(project)], 600)
    if result.returncode != 0:
        errors = [l for l in result.stderr.split("\n") if "error" in l.lower()]
        detail = "\n".join(errors[:10]) if errors else result.stderr[-1000:]
        return False, f"Build FAILED:\n{detail}"
    return True, f"Build succeeded.\n{result.stdout[-500:]}"


def _package(project: Path, release: bool):
    """Return (deb_path or None, message)."""
    started = time.time()
    cmd = ["-C", str(project), "package"]
    if release:
        cmd.append("FINALPACKAGE=1")
    result = _make(cmd, 600)
    if result.returncode != 0:
        return None, f"Packaging FAILED:\n{result.stdout[-500:]}\n{result.stderr[-500:]}"
    pkg_dir = project / "packages"
    debs = sorted(pkg_dir.glob("*.deb"), key=os.path.getmtime, reverse=True) if pkg_dir.is_dir() else []
    # only trust a .deb this run produced, not a stale one from before
    if debs and debs[0].stat().st_mtime >= started - 1:
        return debs[0], f"Package built: {debs[0]} ({debs[0].stat().st_size // 1024}KB)"
    return None, f"Packaging produced no new .deb:\n{result.stdout[-500:]}"


@_tool
def theos_build(project_dir: str = "") -> str:
    """Build a Theos project. Uses the LegacyPodClaw project dir by default."""
    return _build(_project(project_dir))[1]


@_tool
def theos_package(project_dir: str = "", release: bool = True) -> str:
    """Package a Theos project into a .deb."""
    return _package(_project(project_dir), bool(release))[1]


@_tool
def theos_install(project_dir: str = "") -> str:
    """Build, package, and install on the connected device."""
    project = _project(project_dir)
    ok, build_msg = _build(project)
    if not ok:
        return build_msg
    deb, pkg_msg = _package(project, True)
    if deb is None:
        return pkg_msg
    return f"{pkg_msg}\n{_install_deb(deb)}"


# === Utility ===

@_tool
def clawpod_status() -> str:
    """Check LegacyPodClaw installation status on the connected device."""
    return ssh(
        "echo '=== Package ==='; "
        "dpkg -s pro.matthesketh.legacypodclaw 2>/dev/null | head -10; "
        "echo '=== App ==='; "
        "ls -la /Applications/LegacyPodClaw.app/ 2>/dev/null; "
        "echo '=== Tweak ==='; "
        "ls -la /Library/MobileSubstrate/DynamicLibraries/LegacyPodClawTweak* 2>/dev/null; "
        "echo '=== Daemon ==='; "
        "launchctl list 2>/dev/null | grep clawpod; "
        "echo '=== Prefs ==='; "
        "cat /var/mobile/Library/Preferences/pro.matthesketh.legacypodclaw.plist 2>/dev/null | head -20"
    )


if __name__ == "__main__":
    mcp.run()
