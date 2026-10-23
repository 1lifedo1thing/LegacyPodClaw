---
title: "Changelog"
description: "Release history"
weight: 5
---

## v0.4.1

Version 0.4.1 fixes the lock screen.

- The status label shows on each lock. Before, it showed only on the first lock after a respring.
- The status label does not show the gateway host name while the device is locked. It shows **LegacyPodClaw - Connected**. Before, the host name showed on the lock screen and on the passcode keypad.
- The status label is fully below the date bar. Before, it covered the bottom of the date by about 8 pt.
- With a passcode, the camera grabber shows Apple's camera icon, because the gesture opens Apple's camera. With no passcode, the grabber shows the LegacyPodClaw icon and opens the overlay, as before.

## v0.4.0

Version 0.4.0 is a full rewrite of the app's network, secret, tool and package code.

### Network

- All HTTPS goes through `CPTLSClient` on wolfSSL 5.9.4. It uses TLS 1.2 or later, checks the certificate against the bundled Mozilla CA list, checks the host name and sends SNI.
- `CPFetch` sends a one-shot request. It refuses each scheme other than `http` and `https`. Before, `http_fetch` could read `file://` URLs.
- A long-lived wolfSSL connection carries the Discord and Slack WebSockets and IRC over TLS.
- The Notification Center widget sends HTTPS through the tweak's wolfSSL client.
- wolfSSL seeds its random number generator from `/dev/urandom`, and it accepts 4096-bit RSA roots.

### clawpodd and secrets

- `clawpodd` answers only fixed read-only questions: ping, status, battery, processes, crash list and an allow-listed `sysctl`. It has no command or file-read operation.
- `clawpodd` registers its mach services as root, then drops to `mobile`.
- API keys and tokens live in the keychain. `clawpodd` serves them over a mach service and checks the caller. The settings plist holds no secret.
- `dpkg --purge` deletes the secrets from the keychain.

### Tools

- Every tool call goes through `OCToolDispatcher`. It checks the input against the schema, applies the path guardrails, enforces a timeout and asks before a risky tool runs.
- The approval alert has **Allow** and **Deny** buttons. It shows the command, path and URL in full.
- `bash` has no command denylist. You approve each call.
- Reminders use EventKit. Notes writes run in one database transaction.
- `calculate` accepts only arithmetic. `open_url` and `launch_app` need approval.

### Gateway server

- Each request needs a random 256-bit access token. Only `GET /healthz` is public.
- Tool calls through the gateway go through the dispatcher.

### SpringBoard tweak

- The overlay, the Notification Center widget and the dashboard use the provider and model that you set in the app.
- The overlay does not open on the lock screen, and it hides when the device locks.
- With a passcode set, the lock screen camera keeps Apple's behaviour.
- The Notification Center widget does not run while the device is locked with a passcode.
- Files that the app passes to SpringBoard live in a 0700 directory, not in `/tmp`.

### Providers, channels and plugins

- The app has two provider adapters: the Anthropic Messages API and one OpenAI-compatible adapter. The default model is `claude-sonnet-5-5`.
- Chat channels for Telegram, Discord, Slack, IRC and a webhook. Each channel has an allow list.
- Plugins load only from root-owned bundles in `/Library/LegacyPodClaw/Plugins`.

### Build and tests

- A macOS host test target (`make test`) covers the HTTP response parser, the file guardrails and the tool input checks.
- The build no longer hides compiler warnings.

### Fixes from the reviews

- The guardrails resolve each path physically, so a symbolic link or `..` cannot reach a protected path.
- `write_file` enforces its 1 MB limit.
- A failed music download rolls back its MediaLibrary write.
- The Mac MCP server and the music proxy were hardened. The proxy needs a token on a LAN address.
- Self-signed gateway mode needs a SHA-256 certificate pin.

### Removed

- Automatic provider failover. It never ran.
- The native Gemini `generateContent` API. Gemini works through Google's OpenAI-compatible endpoint.
- Slack incoming webhooks and the Slack Events API. Socket Mode replaces them.

## v0.3.0

- **Renamed** from ClawPod to LegacyPodClaw (naming conflict with existing project)
- **Expanded device support** to all iOS 6 devices (iPhone 3GS/4/4S, iPad 2/3/mini, iPod Touch 4)
- **Fixed tweak filter** — no longer loads into every app (was `com.apple.UIKit`, now `com.apple.springboard`). Fixes interference with Camera.app and other apps
- **Fixed uninstall** — resprings on removal so tweak hooks don't persist
- **Added iPhone 4S support** — hooks Siri activation (`SBAssistantController`)
- **Added iPad support** — `UIDeviceFamily` includes iPad, layout adapts to screen size
- **Updated package identifier** to `pro.matthesketh.legacypodclaw`

## v0.2.1

- Complete MediaLibrary integration
- Fixed sort order and audio format for Music.app

## v0.2.0

- Fixed MP3 encoding for iOS 6 playback
- Music download pipeline working end-to-end

## v0.1.0

- Initial release as ClawPod
- Full gateway + local agent
- Chat UI, streaming, sessions
- Tool system with guardrails
- 10 AI provider support
