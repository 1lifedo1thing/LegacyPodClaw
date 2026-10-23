---
title: "Gestures and Entry Points"
description: "All the ways to open LegacyPodClaw"
weight: 1
---

The LegacyPodClaw tweak is a MobileSubstrate tweak. Its filter loads it only into SpringBoard (`com.apple.springboard`). It does not load into other apps.

The overlay and the Notification Center widget use the provider and model that you set in the app. See [Configuration](/getting-started/configuration/).

## Home-button hold

**Replaces:** Voice Control, or Siri on the iPhone 4S.

Hold the home button to open the overlay. Type a question and tap **Send**. To close the overlay, press the home button or tap the close button.

- On most devices, the tweak hooks the Voice Control path (`SBVoiceControlController`).
- On the iPhone 4S, the tweak hooks the Siri path (`SBAssistantController`).
- On the lock screen, the hold keeps Apple's behaviour. The overlay never opens while the device is locked.

## Headset button

A hold on the headset button also opens the overlay when the device is unlocked. This includes a Bluetooth headset that starts Voice Control or Siri.

## Spotlight page: dashboard

Swipe left from the first home screen page. The LegacyPodClaw dashboard shows in place of Spotlight. It has three parts:

- **Status:** the gateway host, or **Direct API Mode**, and the model.
- **Quick Actions:** **Ask AI**, **Open App**, **Gateway**, **Settings**, **Respring**, **Wi-Fi**, **Bright+** and **Bright-**.
- **Device:** the battery, the brightness, the SpringBoard memory and the iOS version.

{{< screenshot src="img/screens/dashboard.png" caption="The dashboard on the Spotlight page" >}}

The **Gateway** button opens the app. The app then asks before it starts the gateway server.

To get Spotlight back, turn off **Settings > LegacyPodClaw > Dashboard on Spotlight Page**. With the dashboard off, a Spotlight search of three or more characters also opens the overlay.

## Notification Center widget

Pull down Notification Center. The LegacyPodClaw widget shows the status, a question field and an **Ask** button. The reply shows in the widget.

{{< screenshot src="img/screens/nc-widget.png" caption="The quick-ask widget in Notification Center" >}}

- Tap the title area to open the app.
- The widget does not run while the device is locked with a passcode.
- The widget sends HTTPS through the tweak's wolfSSL client.

## Lock screen

- A small label below the date bar shows the status. It shows on each lock and on the passcode keypad.
  - **LegacyPodClaw - Connected** when a gateway host is set. The label never shows the host name.
  - **LegacyPodClaw - Ready** when the provider that you chose in the app is set up.
  - **LegacyPodClaw** in all other conditions.
- With no passcode, the camera grabber shows the LegacyPodClaw icon. Tap the grabber to unlock the device and open the overlay. A drag up on the grabber does nothing.
- With a passcode, the camera grabber shows Apple's camera icon. The camera gesture opens Apple's camera, so the gesture cannot skip the passcode.

## App switcher

Double-click the home button and swipe right to the music controls. LegacyPodClaw adds a page to the left of them. The page shows the status, whether an API key is set and the SpringBoard memory use. Its **Open** button opens the app.

## Shake

Shake the device on the home screen to open the overlay. The tweak runs only in SpringBoard, so a shake in another app does nothing.
