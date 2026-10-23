---
title: "Architecture"
description: "How the LegacyPodClaw components fit together"
weight: 1
---

LegacyPodClaw has five built parts and one vendored library. Theos builds all of them for iOS 6 on ARMv7.

## Components

| Component | Runs in | What it does |
|---|---|---|
| **LegacyPodClaw.app** | Its own process, as `mobile` | Chat UI, agent loop, tools, model providers, chat channels, gateway server, plugins |
| **LegacyPodClawTweak** | SpringBoard | Overlay, Spotlight dashboard, lock screen, app switcher page, Notification Center widget loader |
| **LegacyPodClawNC** | SpringBoard | Notification Center widget (`BBWeeAppController`) |
| **LegacyPodClawPrefs** | Settings app | Preference bundle |
| **clawpodd** (`LegacyPodClawDaemon`) | launchd, as `mobile` after start | Fixed read-only system information and the keychain secret service |
| **wolfSSL 5.9.4** | Linked into the app and the tweak | TLS 1.2 or later. The iOS 6 TLS stack cannot reach modern servers safely. |

## Size

| Metric | Value |
|---|---|
| Objective-C source files (`.m`, `.h`, `.xm`, without `Vendor/` and `Tests/`) | 103 |
| Lines of Objective-C | about 22,000 |
| Target | ARMv7, iOS 6.0 or later |

## Framework layout

The `Frameworks/` directory holds the app's subsystems:

| Directory | What it holds |
|---|---|
| `Agent/` | `OCAgent` loop, `OCMCPClient`, built-in tools |
| `Channels/` | Telegram, Discord, Slack, IRC and webhook channels, `OCChannelManager`, `OCChannelRouter`, `OCTLSWebSocket` |
| `Chat/` | Sessions and messages for the in-app chat |
| `Gateway/` | Client for a remote OpenClaw gateway (protocol v3) |
| `Media/` | Image, text-to-speech, transcription and link helpers. The app does not use them yet. |
| `Memory/` | `OCMemoryMonitor`, `OCLRUCache`, `OCBufferPool` |
| `Plugin/` | `OCPluginManager` and the `OCPlugin` protocol |
| `Providers/` | `OCProviderInfo` catalogue and `OCProviderClient` with the Anthropic and OpenAI-compatible formats |
| `Server/` | HTTP server, server WebSocket, gateway server, access token |
| `Store/` | SQLite wrapper with WAL mode and a statement cache |
| `System/` | `CPTLSClient`, `CPFetch`, HTTP response parser, `CPSecretStore`, `clawpodd` client |
| `Tools/` | `OCToolDispatcher`, guardrails, input checks, device, notes, reminders, messages and music tools |
| `WebSocket/` | RFC 6455 WebSocket client for the remote gateway |

## Three rules

1. **HTTPS** goes through `CPTLSClient` (`Frameworks/System/TLSClient.h`). `CPFetch` sends a one-shot request and refuses each scheme other than `http` and `https`. The remote gateway client is the only exception: it uses the system TLS stack with a certificate pin.
2. **Secrets** go through `CPSecretStore` (`Frameworks/System/SecretStore.h`). It reads and writes the keychain through `clawpodd`.
3. **Tool calls** go through `OCToolDispatcher` (`Frameworks/Tools/ToolDispatcher.h`). Nothing calls a tool handler directly.

## Inter-process communication

| From | To | Mechanism |
|---|---|---|
| App, Settings, tweak, widget | `clawpodd` secret service | Mach messages to `pro.matthesketh.legacypodclaw.secrets`. `clawpodd` checks the caller's uid and executable path. |
| Any client | `clawpodd` information service | `CPDistributedMessagingCenter`, service `pro.matthesketh.legacypodclaw.daemon`. The client class is `CPDaemonClient`. The app does not call it yet. |
| Settings, tweak | App | Darwin notifications (`notify_post`), for example `pro.matthesketh.legacypodclaw/prefsChanged` |
| App | SpringBoard | Darwin notifications and files in `/var/mobile/Library/LegacyPodClaw` (mode 0700) |
| Tweak overlay | App | Writes to the app's SQLite database (the **Quick Ask** session) |
| Dashboard | App | The `openclaw://gateway` URL |

## clawpodd

`clawpodd` answers only these questions: `ping`, `status`, `battery`, `processes`, `crashes` and an allow-listed `sysctl`. It has no command or file-read operation. It registers its mach services as root, then drops to `mobile`.

The secret service lets SpringBoard read secrets. The app and the Settings app can read and write them. It refuses all other callers.
