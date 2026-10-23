#!/usr/bin/env python3
"""
LegacyPodClaw Music Proxy - yt-dlp bridge for iPod Touch

Runs on a computer on the same network as the iPod.
Handles YouTube signature deciphering that can't run on iOS 6.

Usage:
    pip3 install yt-dlp==2026.8.19
    python3 music_proxy.py [--port 18790] [--host 127.0.0.1]

The proxy binds 127.0.0.1 by default. To serve the iPod over the LAN, pass
--host 0.0.0.0 (or set MUSIC_PROXY_HOST). On any address that is not
loopback the proxy requires a bearer token. The token is made on first run
and kept in ~/.config/legacypodclaw/music_proxy.token (mode 0600); set
MUSIC_PROXY_CONFIG_DIR to keep it elsewhere.

The iPod client cannot send headers, so put the token in the URL path. In
LegacyPodClaw Settings, set Music Proxy URL to:
    http://YOUR_COMPUTER_IP:18790/t/TOKEN

Other clients may send "Authorization: Bearer TOKEN" instead.

API:
    GET /info?v=VIDEO_ID   -> JSON: {title, artist, duration, thumbnail, album}
    GET /audio?v=VIDEO_ID  -> MP3 audio file
    GET /health            -> {"status":"ok"}
"""

import argparse
import hmac
import ipaddress
import json
import os
import re
import secrets
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

VIDEO_ID_RE = re.compile(r"^[A-Za-z0-9_-]{11}$")
TOKEN_PATH_RE = re.compile(r"^/t/([0-9a-f]{64})(/.*)$")
TOKEN_FILE_NAME = "music_proxy.token"
MAX_DOWNLOAD = "100M"
MAX_DURATION_SECONDS = 3600
MAX_CONCURRENT_JOBS = 2
REQUEST_TIMEOUT_SECONDS = 30

# a long download must not let other requests pile up without bound
_jobs = threading.BoundedSemaphore(MAX_CONCURRENT_JOBS)


def _config_dir():
    default = os.path.join(os.path.expanduser("~"), ".config", "legacypodclaw")
    return os.environ.get("MUSIC_PROXY_CONFIG_DIR", default)


def load_or_create_token():
    """Return the bearer token, creating a 0600 token file on first run."""
    directory = _config_dir()
    os.makedirs(directory, mode=0o700, exist_ok=True)
    path = os.path.join(directory, TOKEN_FILE_NAME)
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        if os.stat(path).st_mode & 0o077:
            os.chmod(path, 0o600)
        with open(path) as f:
            token = f.read().strip()
        if not re.fullmatch(r"[0-9a-f]{64}", token):
            raise SystemExit(f"[MusicProxy] token file {path} is malformed; delete it to make a new one") from None
        return token, path, False
    token = secrets.token_hex(32)
    with os.fdopen(fd, "w") as f:
        f.write(token + "\n")
    return token, path, True


def is_loopback(host):
    if host == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def _yt_url(video_id):
    return f"https://www.youtube.com/watch?v={video_id}"


def _ytdlp_base():
    # never follow playlists or channels, only the one validated video
    return ["yt-dlp", "--no-playlist", "--no-exec", "--max-filesize", MAX_DOWNLOAD]


class MusicProxyHandler(BaseHTTPRequestHandler):
    # drop clients that stall instead of holding a thread for ever
    timeout = REQUEST_TIMEOUT_SECONDS
    token = None

    def do_GET(self):
        path = self._authorised_path()
        if path is None:
            self._json_response({"error": "Unauthorized"}, 401)
            return
        parsed = urlparse(path)
        params = parse_qs(parsed.query)

        if parsed.path == "/health":
            self._json_response({"status": "ok"})
            return

        if parsed.path in ("/info", "/audio"):
            video_id = params.get("v", [""])[0]
            if not VIDEO_ID_RE.match(video_id):
                self._json_response({"error": "Missing or invalid v parameter"}, 400)
                return
            if not _jobs.acquire(blocking=False):
                self._json_response({"error": "Busy, try again"}, 503)
                return
            try:
                if parsed.path == "/info":
                    self._handle_info(video_id)
                else:
                    self._handle_audio(video_id)
            finally:
                _jobs.release()
            return

        self._json_response({"error": "Not found"}, 404)

    def _authorised_path(self):
        """Return the request path without the token prefix, or None if refused."""
        if self.token is None:
            return self.path
        auth = self.headers.get("Authorization", "")
        if auth.startswith("Bearer "):
            supplied = auth[len("Bearer "):].strip()
            if hmac.compare_digest(supplied.encode(), self.token.encode()):
                return self.path
            return None
        match = TOKEN_PATH_RE.match(self.path)
        if match and hmac.compare_digest(match.group(1).encode(), self.token.encode()):
            return match.group(2)
        return None

    def _handle_info(self, video_id):
        """Get video metadata via yt-dlp."""
        try:
            result = subprocess.run(
                _ytdlp_base() + ["--dump-json", "--no-download", "--", _yt_url(video_id)],
                capture_output=True, text=True, timeout=60,
            )
        except subprocess.TimeoutExpired:
            self._json_response({"error": "Timeout getting video info"}, 504)
            return
        if result.returncode != 0:
            self._log_error("yt-dlp info", result.stderr)
            self._json_response({"error": "yt-dlp failed"}, 502)
            return
        try:
            data = json.loads(result.stdout)
        except ValueError:
            self._json_response({"error": "yt-dlp returned bad JSON"}, 502)
            return

        artist = data.get("artist") or data.get("uploader") or "Unknown"
        # youtube music auto channels carry a topic suffix that is not part of the name
        if artist.endswith(" - Topic"):
            artist = artist[:-len(" - Topic")]
        self._json_response({
            "title": data.get("title") or "Unknown",
            "artist": artist,
            "duration": data.get("duration") or 0,
            "thumbnail": data.get("thumbnail") or "",
            "album": data.get("album") or "",
        })

    def _download_mp3(self, video_id, tmpdir):
        """Fetch and convert the audio. Returns the MP3 path or None."""
        output_path = os.path.join(tmpdir, "audio.mp3")
        raw_template = os.path.join(tmpdir, "raw_audio.%(ext)s")
        subprocess.run(
            _ytdlp_base() + [
                "--match-filter", f"duration <= {MAX_DURATION_SECONDS}",
                "-f", "bestaudio", "-o", raw_template, "--", _yt_url(video_id),
            ],
            capture_output=True, text=True, timeout=300,
        )
        raw_file = next(
            (os.path.join(tmpdir, f) for f in os.listdir(tmpdir)
             if f.startswith("raw_audio.") and not f.endswith(".part")),
            None,
        )
        if raw_file:
            # ios 6 music.app needs mp3, id3v2.3, 192kbps cbr, 44.1khz stereo
            result = subprocess.run(
                ["ffmpeg", "-nostdin", "-y", "-i", raw_file,
                 "-t", str(MAX_DURATION_SECONDS),
                 "-codec:a", "libmp3lame", "-b:a", "192k", "-ar", "44100", "-ac", "2",
                 "-id3v2_version", "3", "-write_id3v1", "1", output_path],
                capture_output=True, text=True, timeout=300,
            )
            if result.returncode == 0 and os.path.exists(output_path):
                return output_path
            self._log_error("ffmpeg", result.stderr)

        # fall back to yt-dlp's own conversion when the raw fetch or ffmpeg failed
        result = subprocess.run(
            _ytdlp_base() + [
                "--match-filter", f"duration <= {MAX_DURATION_SECONDS}",
                "--extract-audio", "--audio-format", "mp3", "--audio-quality", "192K",
                "-o", os.path.join(tmpdir, "fallback.%(ext)s"), "--", _yt_url(video_id),
            ],
            capture_output=True, text=True, timeout=300,
        )
        fallback = os.path.join(tmpdir, "fallback.mp3")
        if os.path.exists(fallback):
            return fallback
        self._log_error("yt-dlp audio", result.stderr)
        return None

    def _handle_audio(self, video_id):
        """Download audio and serve the file."""
        with tempfile.TemporaryDirectory() as tmpdir:
            try:
                mp3 = self._download_mp3(video_id, tmpdir)
            except subprocess.TimeoutExpired:
                self._json_response({"error": "Timeout downloading audio"}, 504)
                return
            if mp3 is None:
                self._json_response({"error": "Download failed"}, 502)
                return

            self.send_response(200)
            self.send_header("Content-Type", "audio/mpeg")
            self.send_header("Content-Length", str(os.path.getsize(mp3)))
            self.end_headers()
            try:
                with open(mp3, "rb") as f:
                    while True:
                        chunk = f.read(65536)
                        if not chunk:
                            break
                        self.wfile.write(chunk)
            except (BrokenPipeError, ConnectionResetError):
                # the client left; headers are already sent so there is nothing to report
                pass

    def _json_response(self, data, status=200):
        body = json.dumps(data).encode("utf-8")
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _log_error(self, what, stderr):
        tail = (stderr or "").strip().splitlines()[-3:]
        sys.stderr.write(f"[MusicProxy] {what} failed: {' | '.join(tail)}\n")

    def log_message(self, format, *args):
        # the request line can carry the token in its path, so mask it
        line = format % args
        line = re.sub(r"/t/[0-9a-f]{64}", "/t/[token]", line)
        sys.stderr.write(f"[MusicProxy] {self.address_string()} {line}\n")


def main():
    parser = argparse.ArgumentParser(description="LegacyPodClaw Music Proxy")
    parser.add_argument("--host", default=os.environ.get("MUSIC_PROXY_HOST", "127.0.0.1"),
                        help="Bind address (default 127.0.0.1, env MUSIC_PROXY_HOST)")
    parser.add_argument("--port", type=int, default=int(os.environ.get("MUSIC_PROXY_PORT", "18790")),
                        help="Port number (default 18790, env MUSIC_PROXY_PORT)")
    args = parser.parse_args()

    try:
        result = subprocess.run(["yt-dlp", "--version"], capture_output=True, text=True, timeout=30)
        print(f"[MusicProxy] yt-dlp version: {result.stdout.strip()}")
    except (FileNotFoundError, subprocess.TimeoutExpired):
        print("[MusicProxy] ERROR: yt-dlp not found. Install with: pip3 install yt-dlp==2026.8.19")
        return 1

    if not is_loopback(args.host):
        token, token_path, created = load_or_create_token()
        MusicProxyHandler.token = token
        state = "Created" if created else "Using"
        print(f"[MusicProxy] {state} token file {token_path}")
        print(f"[MusicProxy] Set Music Proxy URL to: http://YOUR_IP:{args.port}/t/<token from that file>")
    else:
        print(f"[MusicProxy] Loopback only; no token needed. URL: http://{args.host}:{args.port}")

    server = ThreadingHTTPServer((args.host, args.port), MusicProxyHandler)
    server.daemon_threads = True
    print(f"[MusicProxy] Listening on {args.host}:{args.port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
