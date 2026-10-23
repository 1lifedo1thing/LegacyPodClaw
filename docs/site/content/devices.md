---
title: "Supported Devices"
description: "Device compatibility matrix"
weight: 4
---

LegacyPodClaw runs on all iOS 6 devices. The app declares iPhone, iPod touch and iPad support.

| Device | RAM | iOS version | Notes |
|--------|-----|-------------|-------|
| iPod touch 4th gen | 256 MB | 6.0 to 6.1.6 | |
| iPhone 3GS | 256 MB | 6.0 to 6.1.6 | |
| iPhone 4 | 512 MB | 6.0 to 6.1.3 | |
| iPhone 4S | 512 MB | 6.0 to 6.1.3 | The home-button hold opens the overlay, not Siri |
| iPad 2 | 512 MB | 6.0 to 6.1.3 | |
| iPad 3rd gen | 1 GB | 6.0 to 6.1.3 | |
| iPad mini 1st gen | 512 MB | 6.0 to 6.1.3 | |

## RAM

The app has a memory budget of 80 MB. The budget is the same on all devices.

- On a 256 MB device (iPod touch 4, iPhone 3GS), close background apps if the device is slow.
- A device with 512 MB or more keeps more memory free for other apps.

See [Memory Management](/developer/memory/) for the details.

## iPhone 4S

On the iPhone 4S, a home-button hold starts Siri. The tweak hooks `SBAssistantController`, so the hold opens the LegacyPodClaw overlay. If Siri opens after you install the package, restart SpringBoard or the device.

## iPad

The `UIDeviceFamily` key in the app's `Info.plist` includes iPad (value 2). The app thus runs as a native iPad app.
