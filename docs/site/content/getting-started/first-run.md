---
title: "First Run"
description: "What happens when you first use LegacyPodClaw"
weight: 3
---

## Open LegacyPodClaw

After you install the package and set an API key, use one of these entry points:

| Action | Result |
|---|---|
| Hold the home button | The overlay opens. It replaces Voice Control, or Siri on the iPhone 4S. |
| Swipe left from the first home screen page | The dashboard opens in place of Spotlight |
| Pull down Notification Center | The quick-ask widget shows |
| Tap the LegacyPodClaw icon | The full app opens |

See [Gestures and Entry Points](/guide/gestures/) for all entry points.

## The overlay

The overlay is a quick text chat.

1. Hold the home button. The overlay opens.
2. Type a question and tap **Send**. The reply streams into the overlay.
3. To close the overlay, press the home button or tap the close button.

The overlay has no tools. It always uses Anthropic. It keeps the last 10 messages and saves them in the app's **Quick Ask** session. It does not open while the device is locked.

## The app

The app has the full chat with tools.

1. Open the app.
2. Tap the gear button and set a provider and its API key. See [Configuration](/getting-started/configuration/).
3. Type a message. The reply streams into the chat.

The model can call tools, for example to read the battery state or to make a note. Some tools need your approval. The app then shows an **Allow Tool?** alert with **Allow** and **Deny**. If you do nothing for 60 seconds, the app denies the call. See [Tools](/guide/tools/).

If the app is connected to a remote gateway, the chat goes through that gateway. If not, the app sends the chat to the provider that you selected.

## Memory limits

LegacyPodClaw is made for devices with 256 MB to 1 GB of RAM:

- The app has a memory budget of 80 MB.
- Each chat session keeps at most 50 messages in RAM. All messages stay in SQLite.
- The app checks its memory use every 5 seconds. At a high level, it trims the message windows and clears caches.
- When a conversation is longer than the context budget, the app drops the oldest messages from the request.

This work is automatic. If the device is slow, close background apps.
