# LegacyPodClaw - Build and Install

## Overview

LegacyPodClaw is a native AI assistant for jailbroken iOS 6 devices.

- **Target:** iOS 6.0 to 6.1.6, ARMv7, 256 MB RAM (iPod touch 4, iPhone 3GS, 4 and 4S, iPad 2, 3 and mini).
- **Memory budget:** about 80 MB for the app.
- **Memory management:** manual retain and release. Every target builds with `-fno-objc-arc`.
- **TLS:** wolfSSL 5.9.4 (`Vendor/`), because SecureTransport on iOS 6 lacks the ciphers that many servers now require.

## Prerequisites

The build runs on macOS only.

1. **Xcode** with command-line tools.
2. **Theos** at `~/theos`. Set `THEOS=~/theos`.
3. **The iPhoneOS 14.5 SDK** at `$THEOS/sdks/iPhoneOS14.5.sdk`. The deployment target stays 6.0, so check that each API you use exists on iOS 6.
4. **ldid** on `PATH`.

`Vendor/libwolfssl.a` and its headers are committed. To rebuild them, run `THEOS=~/theos Vendor/build-wolfssl.sh`.

## Build

```bash
make clean
make package FINALPACKAGE=1
```

The package is `packages/pro.matthesketh.legacypodclaw_<version>_iphoneos-arm.deb`. It holds the app, the SpringBoard tweak, the Settings bundle, the Notification Center widget and `clawpodd`.

## Test

The host tests run on macOS with the system SDK, under AddressSanitizer and UBSan:

```bash
make test
```

They cover the HTTP response parser, the file guardrails and the tool input checks. They do not need a device or Theos.

## Install

- **SSH:** `make package install THEOS_DEVICE_IP=<device-ip>`
- **Cydia or Filza:** copy the `.deb` to the device and install it. Cydia then offers to restart SpringBoard.

`postinst` loads `clawpodd`, creates `/var/mobile/Library/LegacyPodClaw` (mode 0700) and `/Library/LegacyPodClaw/Plugins` (root, mode 0755), and makes the settings plist mode 0600.

## Configuration

Configure everything in **Settings > LegacyPodClaw** or in the app's Settings screen.

- **Provider and model:** choose a provider, a model and its API key in the app's Settings screen. The default model is `claude-sonnet-5-5`. The Settings app has only the Anthropic key.
- **Secrets:** API keys and tokens go to the keychain through `clawpodd`, never to the settings plist.
- **Gateway server:** each client of the on-device gateway needs the access token. Find it in the app under Gateway Server > Access Token.
- **Channels:** each channel needs its token and a sender allow list. An empty list ignores everyone.

## Layout

```
Classes/                 app delegate, UI, services
Frameworks/
  Agent/                 agent loop, MCP client, built-in tools
  Channels/              Telegram, Discord, Slack, IRC, webhook, router
  Chat/                  sessions and messages
  Gateway/               gateway client
  Media/                 text to speech, transcription, link reading (not used by the app yet)
  Memory/                memory pool and pressure monitor
  Plugin/                plugin loader
  Providers/             Anthropic and OpenAI-compatible providers
  Server/                on-device HTTP and WebSocket gateway
  Store/                 SQLite wrapper
  System/                TLS client, fetch helper, secret store, clawpodd client
  Tools/                 tool dispatcher, guardrails, device tools
  WebSocket/             WebSocket client
LegacyPodClawDaemon/     clawpodd: read-only system info and the keychain secret service
LegacyPodClawTweak/      SpringBoard overlay, widget injection, lock screen hooks
LegacyPodClawPrefs/      Settings bundle
LegacyPodClawNC/         Notification Center widget
LegacyPodClawMCP/        Mac-side MCP server and music proxy
Tests/                   macOS host tests
Vendor/                  wolfSSL build, headers and library
layout/                  files copied into the package, and the maintainer scripts
```

See `SECURITY.md` for the security model and `README.md` for the features.
