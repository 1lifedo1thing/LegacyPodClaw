---
title: "Configuration"
description: "Set a model provider, connect to a gateway and find every setting"
weight: 2
---

LegacyPodClaw has settings in two places:

- **The app's Settings screen.** Open the app and tap the gear button. This screen has every provider, the chat channels and the gateway server.
- **Settings > LegacyPodClaw** in the iOS Settings app. This screen has the Anthropic key, the token limits, the music proxy, the MCP servers and the Spotlight dashboard switch.

Both screens write the same settings file. The app loads a change immediately.

## Set a model provider

Do these steps in the app:

1. Open the LegacyPodClaw app and tap the gear button.
2. Under **Model Provider**, tap **Provider** and select a provider.
3. Tap **API Key** and enter the key for that provider.
4. Optional: tap **Model** and enter a model ID. An empty field uses the provider's default model.
5. Optional: tap **Base URL** to use a different server. Ollama and **Custom (OpenAI-compatible)** need a base URL.

When you change the provider, the app clears the model ID.

For Anthropic only, you can also use the Settings app: **Settings > LegacyPodClaw > Local Agent**. Enter the key in **Anthropic Key**. The **Provider** list there also selects the provider, but the key and base URL for other providers are only in the app.

{{< alert type="note" title="Overlay and widget" >}}
The home-button overlay and the Notification Center widget always use Anthropic and the Anthropic key. They use the **Model** setting only when the provider is Anthropic. Otherwise they use `claude-sonnet-5-5`.
{{< /alert >}}

See [AI Providers](/guide/providers/) for the list of providers.

## Connect to a remote gateway

The app can connect to an [OpenClaw](https://openclaw.ai) gateway (protocol v3) on your network. When the app is connected, the in-app chat goes through that gateway.

1. In the app's Settings screen, under **Gateway Connection**, set **Host** and **Port**. The default port is 18789.
2. Turn on **Use TLS** if the gateway uses TLS.
3. Under **Authentication**, enter the gateway **Token** or **Password**.
4. Tap **Connect to Gateway**.

The same fields are in **Settings > LegacyPodClaw**, with a **Connect** button.

### Self-signed certificate

If the gateway uses a self-signed certificate, do these steps:

1. Turn on **Self-Signed Certs**.
2. Get the certificate's SHA-256 fingerprint on the gateway host:

   ```
   openssl x509 -noout -fingerprint -sha256 -in cert.pem
   ```

3. Enter the fingerprint in **Cert SHA-256**.

With **Self-Signed Certs** on and no fingerprint, the app refuses the connection.

## All settings

### App: Settings screen

| Section | Setting | What it does |
|---|---|---|
| Gateway Connection | Host, Port | The remote gateway address |
| Gateway Connection | Use TLS | Connects to the gateway over TLS |
| Gateway Connection | Self-Signed Certs, Cert SHA-256 | Trusts one pinned self-signed certificate |
| Authentication | Token, Password | The gateway credentials, kept in the keychain |
| Model Provider | Provider, Model, API Key, Base URL | The provider for the in-app chat, the chat channels and the gateway server |
| Chat Channels | Telegram, Discord, Slack, IRC, Webhook | Opens the settings for each channel. See [Chat Channels](/guide/channels/). |
| Chat Channels | Tools in Chats | Gives tools to channel conversations. Off by default. |
| Chat Channels | Start on Boot | Starts the channels and the gateway server after SpringBoard boots, if the app runs |
| Gateway Server | Gateway Server | Starts or stops the on-device server. See [Gateway Server](/guide/gateway/). |
| Gateway Server | Server Port | The server port. The default is 18789. |
| Gateway Server | Status | Shows **Running** with the client count, or **Stopped** |
| Gateway Server | Access Token | Shows, copies or regenerates the access token |
| (no title) | Connect to Gateway, Reset All Settings | Connects or disconnects. Resets all settings and deletes all keys and tokens. |

### Settings app: Settings > LegacyPodClaw

| Section | Setting | What it does |
|---|---|---|
| Home Screen | Dashboard on Spotlight Page | Shows the dashboard in place of Spotlight. On by default. |
| Gateway Connection | Host, Port, Use TLS, Allow Self-Signed Certs, Cert SHA-256 | The same settings as in the app |
| Authentication | Auth Token, Password | The same settings as in the app |
| Connection | Connect, Disconnect | Tells the app to connect or disconnect |
| Connection | Test Connection | Shows the host and port. It does not test the connection. |
| Configuration | Local Agent | Opens the Local Agent screen (see below) |
| Configuration | Diagnostics | Shows fixed information about the memory budget and the frameworks |
| (no title) | Reset All Settings | Deletes the settings file and all keys and tokens |
| (no title) | Developer Options | Test buttons for the banner, Messages, vibration, the lock screen label, the overlay, brightness and the badge |

### Settings app: Local Agent

| Setting | Default | What it does |
|---|---|---|
| Provider | Anthropic | Selects the provider |
| Anthropic Key | | The Anthropic API key |
| Model ID | `claude-sonnet-5-5` | The model ID |
| Custom URL | | The base URL for **Custom (OpenAI-compatible)** |
| Max Context Tokens | 2048 | The context budget, from 512 to 8192 |
| Max Response Tokens | 512 | The reply limit, from 128 to 4096 |
| Music Proxy URL | | The URL of `music_proxy.py`. See [Music Downloads](/guide/music/). |
| Server 1, Server 2 | | URLs of MCP servers that add tools |

The app sends at least 4096 response tokens to the Claude generation 5 models, because these models use part of the limit to think.

## Where the settings live

- The settings file is `/var/mobile/Library/Preferences/pro.matthesketh.legacypodclaw.plist`, mode 0600.
- API keys, gateway credentials and channel tokens are in the keychain. `clawpodd` stores them. They are never in the settings file.
- If a key does not save, the app shows **Not Saved**. Unlock the device and make sure that `clawpodd` runs.
