---
title: "Music Downloads"
description: "Search YouTube and add songs to the Music app"
weight: 6
---

LegacyPodClaw can search YouTube and add songs to the iOS Music app.

## How it works

- **Search** runs on the device. It uses YouTube's InnerTube API and needs no proxy.
- **Download** needs the music proxy, `music_proxy.py`, on a computer on your network. YouTube now needs JavaScript signature deciphering, and iOS 6 cannot do it.
- The proxy uses yt-dlp and ffmpeg. It converts the audio to MP3 (192 kbit/s, 44.1 kHz, stereo), because the iOS 6 Music app needs MP3.
- The app adds the song to the Music library. If the library write fails, the app rolls it back.

## Set up the proxy

On a computer on the same network as the device, run:

```bash
pip3 install yt-dlp==2026.8.19
brew install ffmpeg
python3 LegacyPodClawMCP/music_proxy.py --host 0.0.0.0
```

- The proxy listens on port 18790. Change it with `--port` or `MUSIC_PROXY_PORT`.
- By default, the proxy listens only on `127.0.0.1`. Use `--host` or `MUSIC_PROXY_HOST` to serve the LAN.
- On a LAN address, the proxy needs a token. It makes the token on the first run and keeps it in `~/.config/legacypodclaw/music_proxy.token` (mode 0600).

## Set the device

Go to **Settings > LegacyPodClaw > Local Agent > Music Proxy URL** and enter the URL with the token:

```
http://YOUR_COMPUTER_IP:18790/t/TOKEN
```

## Use it

Ask the assistant in the app, for example:

- "Search YouTube for Bohemian Rhapsody"
- "Download the first result"
- "Which songs by Queen are on this iPod?"

The assistant uses the `search_music`, `download_music` and `list_music` tools.

## Proxy limits

- The proxy accepts only 11-character YouTube video IDs.
- It runs at most two jobs at a time.
- It refuses audio longer than one hour or larger than 100 MB.
