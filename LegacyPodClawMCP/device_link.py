"""
Shared configuration, input checks and the SSH link to the device for
server.py. No tool output leaves this module without the caller passing it
through redact().
"""

import ipaddress
import os
import re
import shlex
import shutil
import subprocess
import time
from pathlib import Path


# Configuration
DEVICE_IP = os.environ.get("CLAWPOD_DEVICE_IP", "127.0.0.1")
DEVICE_PORT = int(os.environ.get("CLAWPOD_SSH_PORT", "2222"))
DEVICE_USER = os.environ.get("CLAWPOD_SSH_USER", "root")
DEVICE_PASS = os.environ.get("CLAWPOD_SSH_PASS", "alpine")
THEOS_PATH = os.environ.get("THEOS", os.path.expanduser("~/theos"))
IOS6_HEADERS = os.environ.get("IOS6_HEADERS", os.path.expanduser("~/iOS-6-Headers"))
PROJECT_DIR = os.environ.get("CLAWPOD_PROJECT", os.path.expanduser("~/openclaw-ios6"))
WORK_DIR = os.environ.get("CLAWPOD_WORKDIR", os.path.expanduser("~/.legacypodclaw-mcp"))

MAX_READ_BYTES = 512 * 1024
MAX_OUTPUT_CHARS = 64 * 1024
# root home, so a mobile-user process cannot swap the package before dpkg runs
REMOTE_INSTALL_PATH = "/var/root/legacypodclaw-install.deb"
CRASH_DIR = "/var/mobile/Library/Logs/CrashReporter"

_SAFE_NAME = re.compile(r"^[A-Za-z0-9._+-]{1,128}$")
_SAFE_HOST = re.compile(r"^[A-Za-z0-9.:-]{1,253}$")
_SAFE_USER = re.compile(r"^[A-Za-z0-9._-]{1,32}$")


class ToolError(Exception):
    """A failure whose message is safe to return to the caller."""


def redact(text: str) -> str:
    # the password must never reach the model, even if the device echoes it
    if DEVICE_PASS and len(DEVICE_PASS) >= 3:
        text = text.replace(DEVICE_PASS, "[redacted]")
    if len(text) > MAX_OUTPUT_CHARS:
        text = text[:MAX_OUTPUT_CHARS] + "\n... (output truncated)"
    return text


def clamp(value: int, low: int, high: int) -> int:
    try:
        value = int(value)
    except (TypeError, ValueError):
        raise ToolError("expected an integer") from None
    return max(low, min(high, value))


def safe_name(value: str, what: str) -> str:
    if not value or not _SAFE_NAME.match(value) or value in (".", ".."):
        raise ToolError(f"invalid {what}: use letters, digits, '.', '_', '+' or '-' only") from None
    return value


def work_dir() -> Path:
    path = Path(WORK_DIR).expanduser()
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    return path.resolve()


def inside(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def check_local(value: str, roots, must_exist: bool) -> Path:
    """Resolve a local path and require it to sit inside one of roots."""
    if not value or "\x00" in value:
        raise ToolError("empty or invalid local path") from None
    raw = Path(value).expanduser()
    if not raw.is_absolute():
        raw = work_dir() / raw
    resolved = raw.resolve()
    allowed = [Path(r).expanduser().resolve() for r in roots]
    if not any(inside(resolved, r) for r in allowed):
        names = ", ".join(str(r) for r in allowed)
        raise ToolError(f"local path must be inside: {names}") from None
    if must_exist and not resolved.is_file():
        raise ToolError(f"file not found: {resolved}") from None
    return resolved


def check_remote(value: str) -> str:
    if not value or "\x00" in value or "\n" in value:
        raise ToolError("empty or invalid remote path") from None
    if not value.startswith("/"):
        raise ToolError("remote path must be absolute") from None
    return value


def _is_loopback(host: str) -> bool:
    if host == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def _ssh_base() -> list:
    if not _SAFE_HOST.match(DEVICE_IP) or DEVICE_IP.startswith("-"):
        raise ToolError("CLAWPOD_DEVICE_IP is not a valid host") from None
    if not _SAFE_USER.match(DEVICE_USER) or DEVICE_USER.startswith("-"):
        raise ToolError("CLAWPOD_SSH_USER is not a valid user name") from None
    known_hosts = work_dir() / "known_hosts"
    return [
        "sshpass", "-e",
        "ssh",
        # pin the device key on first use instead of trusting every key
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", f"UserKnownHostsFile={known_hosts}",
        "-o", "HostKeyAlgorithms=+ssh-rsa",
        "-o", "KexAlgorithms=+diffie-hellman-group14-sha1",
        "-o", "ConnectTimeout=10",
        "-p", str(DEVICE_PORT),
        # stop option parsing so a command can never become an ssh option
        "--",
        f"{DEVICE_USER}@{DEVICE_IP}",
    ]


def _ssh_env() -> dict:
    env = os.environ.copy()
    env["SSHPASS"] = DEVICE_PASS
    return env


def _ensure_iproxy():
    """Start iproxy for the USB SSH tunnel when the device is on loopback."""
    if not _is_loopback(DEVICE_IP):
        return
    try:
        result = subprocess.run(
            ["pgrep", "-f", f"iproxy {DEVICE_PORT}"],
            capture_output=True, timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired):
        return
    if result.returncode == 0:
        return
    if shutil.which("iproxy") is None:
        raise ToolError("iproxy not found; install libimobiledevice") from None
    subprocess.Popen(
        ["iproxy", f"{DEVICE_PORT}:22"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    time.sleep(2)


def run_ssh(remote_command: str, timeout: int = 30, stdin=None, stdout=None):
    """Run one command on the device. Returns the CompletedProcess."""
    if shutil.which("sshpass") is None:
        raise ToolError("sshpass not found; install it with: brew install sshpass") from None
    _ensure_iproxy()
    argv = _ssh_base() + [remote_command]
    try:
        return subprocess.run(
            argv,
            stdin=stdin if stdin is not None else subprocess.DEVNULL,
            stdout=stdout if stdout is not None else subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=_ssh_env(),
            timeout=timeout,
            shell=False,
        )
    except subprocess.TimeoutExpired:
        raise ToolError(f"command timed out after {timeout}s") from None
    except OSError as e:
        raise ToolError(f"could not start ssh: {e.strerror}") from None


def decode(data) -> str:
    if not data:
        return ""
    return data.decode("utf-8", errors="replace")


def ssh(remote_command: str, timeout: int = 30) -> str:
    result = run_ssh(remote_command, timeout)
    return (decode(result.stdout) + decode(result.stderr)).strip()


def scp_get(remote_path: str, local_path: Path) -> None:
    """Copy a device file to local_path through ssh and cat."""
    remote = shlex.quote(check_remote(remote_path))
    local_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    tmp = local_path.with_name(local_path.name + ".part")
    try:
        with open(tmp, "wb") as out:
            result = run_ssh(f"cat -- {remote}", timeout=120, stdout=out)
        if result.returncode != 0:
            raise ToolError(f"download failed: {decode(result.stderr).strip()}") from None
        os.replace(tmp, local_path)
    finally:
        if tmp.exists():
            tmp.unlink()


def scp_put(local_path: Path, remote_path: str) -> None:
    """Copy a local file to the device through ssh and cat."""
    remote = shlex.quote(check_remote(remote_path))
    with open(local_path, "rb") as src:
        result = run_ssh(f"cat > {remote}", timeout=120, stdin=src)
    if result.returncode != 0:
        raise ToolError(f"upload failed: {decode(result.stderr).strip()}") from None
