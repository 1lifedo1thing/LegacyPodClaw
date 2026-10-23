---
title: "Gateway Server"
description: "Run the device as an OpenClaw-compatible API server"
weight: 4
---

LegacyPodClaw can run a gateway server on the device. Other devices on your network can then use the device as an OpenClaw-compatible API endpoint.

## Overview

The gateway server gives:

- An **HTTP API** on port 18789. Change the port in **Server Port**.
- **WebSocket** sessions that use the OpenClaw protocol v3.
- **Webhook input** for the webhook chat channel.

The server uses the provider, model and API key that you selected in **Model Provider**.

## Start the server

1. Open the LegacyPodClaw app and tap the gear button.
2. Under **Gateway Server**, turn on **Gateway Server**. The server listens on `http://DEVICE_IP:18789`.
3. Tap **Access Token**, then tap **Copy**. Give the token to each client.

The app remembers the switch. When the app starts again, it starts the server again.

The **Gateway** button on the dashboard opens the app. The app then asks before it starts the server.

## Access token

Each request needs the access token, except `GET /healthz`.

- The app makes a random 256-bit token the first time that the server starts.
- Send the token as `Authorization: Bearer <token>`.
- A WebSocket client can also send the token in its first `connect` frame. The server closes a client that does not authenticate in 10 seconds.
- **Regenerate** in the token alert makes a new token and disconnects every client.

The server has no password option.

## HTTP routes

| Route | Purpose |
|---|---|
| `GET /healthz` | Liveness check. It is public and returns no data. |
| `GET /health` | Server status |
| `GET /api/sessions` | Session list |
| `GET /api/sessions/<key>/history?limit=N` | The history of one session. The default is 100 messages. |
| `POST /tools/invoke` | Runs a device tool. The body is `{"tool": "<name>", "args": {...}}`. |
| `POST /webhook/incoming` | Input for the webhook channel |
| `GET /api/cron` | Cron jobs. This route is not complete. |

`POST /tools/invoke` and the gateway agent can use only these tools: `get_datetime`, `device_info`, `clipboard`, `http_fetch`, `calculate` and `set_timer`. Plugin and MCP tools are not available through the gateway. Each call goes through the tool dispatcher. A risky tool or a file access needs approval on the device.

## WebSocket

Connect to `ws://DEVICE_IP:18789/` with the token. These methods are available:

- `connect`, `health`, `gateway.identity.get`, `tools.catalog`
- `sessions.list`, `sessions.create`, `sessions.delete`, `sessions.reset`
- `chat.send` (or `sessions.send`), `chat.history`, `chat.abort` (or `sessions.abort`)
- `sessions.messages.subscribe`, `sessions.messages.unsubscribe`

The server keeps at most 200 messages of history for each session in memory. A WebSocket message can have at most 256 KB.

## Limits

- An HTTP request body can have at most 64 KB. The headers can have at most 8 KB.
- The server accepts at most 8 WebSocket clients and 16 connections in total.
- A request must arrive in 15 seconds.

## Security

- The server uses plain HTTP. Use it only on a network that you trust.
- Every client with the token can see the chat events of every session.
- The server runs only while the app runs.
