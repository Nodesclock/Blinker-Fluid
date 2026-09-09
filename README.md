<p align="center">
  <img width="100" height="100" alt="New Project 20  0B9169A" src="https://github.com/user-attachments/assets/67a507ac-e528-4720-abd8-23930b242dc0" />
</p>

<h1 align="center">Blinker Fluid</h1>

<p align="center">
  <strong>An experimental Chromium Blink + V8 browser for iOS.</strong><br>
  Runs without Apple's WebKit engine.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/version-v.0.3.1-blue">
  <img src="https://img.shields.io/badge/iOS-12 & 15%2B-lightgrey">
  <img src="https://img.shields.io/badge/Chromium-M149-blue">
  <img src="https://img.shields.io/badge/status-Experimental-orange">
  <img src="https://img.shields.io/badge/license-GPL--3.0-blue">
</p>

<p align="center">
  <strong>Experimental browser.</strong> Expect bugs and crashes.
</p>

## About:

Blinker Fluid is an experimental privacy-focused browser that ports Chromium's **Blink** rendering engine and **V8** JavaScript engine to iOS, allowing modern websites to run without relying on Apple's built-in outdated **WebKit** engine.

The project mainly targets jailbroken devices and TrollStore capable devices, bringing a Chromium browser to older jailbroken iOS versions.

## Why?

I started Blinker Fluid because **Ungoogled Chromium** is my primary desktop browser (Not counting Tor), and I wanted to see if Chromium's Blink engine could run on jailbroken iOS 15. Another reason was that many modern websites no longer work correctly with the outdated version of WebKit on older iOS which many jailbroken users are stuck on.

## Requirements:

### Recommended:

- arm64e device
- iOS 15.4/iOS 17.2.1/iOS 12.5.7 (All three versions have been tested by me)
- TrollStore or a jailbreak

### Compatibility:

Blinker Fluid should theoretically work on iOS 11 and 14, but has NOT been tested on those versions yet. Blinker Fluid should also be able to function on certain iOS version using LiveContainer with the ability to also use JIT version with StikDebug, I have NOT personally tested those versions or LiveContainer with Blinker Fluid, but you're free to try!

| Device | iOS version | Status |
| --- | --- | --- |
| iPhone 13 Pro | iOS 15.4 | ✅ |
| iPhone 14 Pro Max | iOS 17.2.1 | ✅ |
| iPhone 6+ |  iOS 12.5.7 | ✅ |
| iPad 7th Generation | iOS 17.5.1 | ✅ |
| Unknown Device |  iOS 15.2 | ✅ |
| Unknown Device | iOS 16.0.2 | ✅|
| iPhone 11 | iOS 26.2 [LiveContainer](https://github.com/LiveContainer/LiveContainer)| ✅ |
| Unknown Device | iOS 26.1 [LiveContainer](https://github.com/LiveContainer/LiveContainer)| ✅ |

If you successfully test Blinker Fluid on another iOS version or device, **please open an issue so compatibility can be documented**.

## Features:

- Chromium Blink rendering engine
- V8 JavaScript engine
- Modern website compatibility
- Tab manager
- Bookmarks
- Browsing history
- Multiple search engines
- Desktop & mobile browsing
- Video playback
- Face ID / Passcode app lock
- Private Mode
- Optional SOCKS5 / Tor proxy support
- Dark mode support

## Installation:

### TrollStore:

1. Download the latest IPA from [**Releases/Tags**](https://github.com/Nodesclock/Blinker-Fluid/tags).
2. Import it into TrollStore.
3. Tap **Install**.
4. Launch Blinker Fluid.

### Other signing tools:

Apps such as Esign or GBox may work, but they have not been officially tested.

## JIT compilation?

Blinker Fluid is available in both **JITless** and **JIT** builds.

JIT version is now more stable, though if encountering issues, consider trying out the JITless version. JITless versions may feel slower and can have issues loading certain sites.

## Screenshots:

*Screenshots from an iPhone 13 Pro running iOS 15.4.*

| ChatGPT | Reddit | Blinker Fluid | Gemini | GitHub |
|---|---|---|---|---|
| <img width="250" alt="6B50EA54-FB5C-4D68-9D53-729D1868A3AD" src="https://github.com/user-attachments/assets/4fcb4b9e-35bc-4ede-82d0-6a39943929ff" /> | <img width="250" alt="3BAB4D30-B6DA-416A-8A5C-1FE0880831F4" src="https://github.com/user-attachments/assets/49b20585-2736-419c-930c-07d7e30628ae" /> | <img width="250" alt="252089EF-EB18-4656-9C99-C924B69C050C" src="https://github.com/user-attachments/assets/c015af7f-712d-40da-af6f-8c1f116ad841" /> | <img width="250" alt="384DA744-2E67-4589-BD25-A41D4E3A8AC5" src="https://github.com/user-attachments/assets/58090529-1e27-417c-a740-9aa77c63a6c2" /> | <img width="250" alt="20B6DE56-5C44-4404-9AF0-13DCEF723C3B" src="https://github.com/user-attachments/assets/2138d0d2-086c-4833-85f3-70634b96dec3" /> |

# What is being worked on or will be added in the future:

- [x] Better iOS version compatibility (iOS 12 support has been added as of Blinker Fluid v.0.3.1 and newer)
- [x] JIT support (Officially supported since v.0.2.1 and will continue receiving stability and performance improvements.)
- [x] Built-in ad blocker
- [x] Incognito mode (Currently researching a possible implementation. Planned for a future release.)
- [ ] Website compatibility improvements (Continuously being improved with every release.)

# Features that will most likely never be added:

- [ ] Extension support (Implementing Chromium extension support on iOS is extremely complex and time-consuming, so it is not planned at the moment.)
- [ ] Built-in password manager (Also very time consuming and complicated to implement. Use iCloud Keychain, [Aurora](https://github.com/Luki120/AuroraC), or other password managers.)
- [ ] Reader mode 
- [x] Browsing history (Added in v.0.2.1. and newer.)

> [!IMPORTANT]
> AI was used as a development assistant during the creation of Blinker Fluid. It was used to assist with development in these areas:
>
> - Research on porting Blink and V8 to iOS.
> - Assisting with parts of development.
> - Helping diagnose and fix some smaller bugs.

## Source Code?
Yes! Blinker Fluid is fully open source, and all of the source code is available in this repository.

# Credits:
- [Reynard Browser](https://github.com/minh-ton/reynard-browser) by [Minh Ton](https://github.com/minh-ton) for heavily inspiring the creation of Blinker Fluid.
- [TrollStore](https://github.com/opa334/TrollStore) by [opa334](https://github.com/opa334) and all contributors.
- [Chromium](https://github.com/chromium/chromium) and [Ungoogled Chromium](https://github.com/ungoogled-software/ungoogled-chromium).
- [@Waguriii_draws](https://www.instagram.com/waguriii_draws/) on Instagram for creating the Blinker Fluid app icons. (Great friend and an amazing artist!)
