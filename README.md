<p align="center">
  <img width="100" height="100" alt="Blinker Fluid" src="https://github.com/user-attachments/assets/67a507ac-e528-4720-abd8-23930b242dc0" />
</p>

<h1 align="center">Blinker Fluid</h1>

<p align="center">
  <strong>An experimental Chromium Blink + V8 browser for iOS.</strong><br>
  Runs without Apple's WebKit engine.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/version-v0.3.1-blue">
  <img src="https://img.shields.io/badge/iOS-12%20%26%2014%2B-lightgrey">
  <img src="https://img.shields.io/badge/Chromium-M149-blue">
  <img src="https://img.shields.io/badge/status-Experimental-orange">
  <img src="https://img.shields.io/badge/license-GPL--3.0-blue">
</p>

<p align="center">
  <strong>Experimental browser.</strong> Expect bugs and crashes.
</p>

## About

Blinker Fluid is an experimental privacy-focused browser that ports Chromium's **Blink** rendering engine and **V8** JavaScript engine to iOS, allowing websites to run without relying on Apple's built-in **WebKit** engine.

The project primarily targets jailbroken and TrollStore-capable devices, bringing a Chromium-based browser to older iOS versions where the bundled version of WebKit may struggle with some modern websites.

## Why?

I started Blinker Fluid because **Ungoogled Chromium** is my primary desktop browser (not counting Tor), and I wanted to see if Chromium's Blink engine could run on jailbroken iOS.

Another reason was that many modern websites no longer work correctly with older versions of WebKit bundled with older iOS releases, which many jailbroken users are unable or unwilling to update from.

## Requirements

### Recommended

- arm64e device
- iOS 15.4, iOS 17.2.1, or iOS 12.5.7
- TrollStore or a jailbreak

These configurations have been personally tested.

### Compatibility

Blinker Fluid should theoretically work on iOS 11 and iOS 14, but these versions have not yet been personally tested.

Blinker Fluid may also work on other iOS versions through [LiveContainer](https://github.com/LiveContainer/LiveContainer). The JIT build may also be usable with tools such as StikDebug.

Not every LiveContainer configuration has been personally tested, so results may vary.

| Device | iOS version | Status |
| --- | --- | --- |
| iPhone 13 Pro | iOS 15.4 | â |
| iPhone 14 Pro Max | iOS 17.2.1 | â |
| iPhone 6+ | iOS 12.5.7 | â |
| iPad 7th Generation | iOS 17.5.1 | â |
| Unknown Device | iOS 15.2 | â |
| Unknown Device | iOS 16.0.2 | â |
| iPhone 11 | iOS 26.2 [LiveContainer](https://github.com/LiveContainer/LiveContainer) | â |
| Unknown Device | iOS 26.1 [LiveContainer](https://github.com/LiveContainer/LiveContainer) | â |

If you successfully test Blinker Fluid on another iOS version or device, **please open an issue so compatibility can be documented**.

## Features

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
- Built-in content/ad blocking
- Optional SOCKS5 / Tor proxy support
- Dark mode support

## Installation

### TrollStore

1. Download the latest IPA from [**Releases/Tags**](https://github.com/Nodesclock/Blinker-Fluid/tags).
2. Import it into TrollStore.
3. Tap **Install**.
4. Launch Blinker Fluid.

### Other signing tools

Other signing methods such as ESign or GBox may work, but they have not been officially tested.

## JIT Compilation

Blinker Fluid is available in both **JITless** and **JIT** builds.

The JIT version is now more stable, though if you encounter issues, consider trying the JITless build.

JITless builds may feel slower and can have issues loading certain websites because V8 cannot use its normal JIT compilation path.

## Screenshots

*Screenshots from an iPhone 13 Pro running iOS 15.4.*

| ChatGPT | Reddit | Blinker Fluid | Gemini | GitHub |
| --- | --- | --- | --- | --- |
| <img width="250" alt="ChatGPT" src="https://github.com/user-attachments/assets/4fcb4b9e-35bc-4ede-82d0-6a39943929ff" /> | <img width="250" alt="Reddit" src="https://github.com/user-attachments/assets/49b20585-2736-419c-930c-07d7e30628ae" /> | <img width="250" alt="Blinker Fluid" src="https://github.com/user-attachments/assets/c015af7f-712d-40da-af6f-8c1f116ad841" /> | <img width="250" alt="Gemini" src="https://github.com/user-attachments/assets/58090529-1e27-417c-a740-9aa77c63a6c2" /> | <img width="250" alt="GitHub" src="https://github.com/user-attachments/assets/2138d0d2-086c-4833-85f3-70634b96dec3" /> |

## What is being worked on or may be added in the future

- [x] Better iOS version compatibility  
  iOS 12 support was added in Blinker Fluid v0.3.1.

- [x] JIT support  
  Officially supported since v0.2.1 and continuing to receive stability and performance improvements.

- [x] Built-in ad/content blocker

- [ ] Website compatibility improvements  
  Continuously being improved with each release.

- [ ] Further Private Mode / browsing privacy improvements

## Features that will most likely never be added

- [ ] Extension support  
  Implementing full Chromium extension support on iOS would be extremely complex and time-consuming, so it is not currently planned.

- [ ] Built-in password manager  
  This would also require significant additional work. Use iCloud Keychain, [Aurora](https://github.com/Luki120/AuroraC), or another password manager instead.

- [ ] Reader mode

> [!IMPORTANT]
> AI was used as an assistant during the creation of Blinker Fluid. It was used to assist with development in these areas:
>
> - Research on porting Blink and V8 to iOS.
> - Assisting with some parts of development.
> - Helping me diagnose and fix smaller bugs.
> - Helping me with translating things to English. (Apologies if README sounds AI generated)

## Source Code

Yes! Blinker Fluid is fully open source.

The Chromium source overlay and main build configuration are available directly in this repository.

Blinker Fluid is based on Chromium **M149** at a pinned Chromium revision. The repository does not contain the entire Chromium source tree; instead, the `src/` directory contains the files modified by Blinker Fluid and is intended to be applied over a normal Chromium checkout.

## Building v0.3.1

The repository contains a Chromium source overlay. The commands below cover the standard iOS 14+ app and its JIT variant. The full packaging recipe for the uploaded iOS 11/12 builds is not yet documented.

### Requirements

- macOS with Xcode and its command-line tools selected.
- Chromium's [depot_tools](https://chromium.googlesource.com/chromium/tools/depot_tools.git/+/HEAD/README.md) installed and available in `PATH`.
- Git, Python 3, rsync, and enough free space for a full Chromium checkout and build.

The uploaded standard v0.3.1 IPA records Xcode 16.2 and the iOS 18.2 SDK.

### Get the source

Run these commands in a directory where you want to keep both repositories:

```sh
git clone https://github.com/Nodesclock/Blinker-Fluid.git
BF_SRC="$(pwd)/Blinker-Fluid"

mkdir chromium
cd chromium
gclient config --unmanaged https://chromium.googlesource.com/chromium/src.git
cat >> .gclient <<'EOF'
target_os = ["ios"]
target_os_only = True
EOF

gclient sync --nohooks -r src@31dce68b925c2b8efc93df832a86a7c0d03e3fa2
rsync -a "$BF_SRC/src/" src/
gclient runhooks
cd src
```

The pinned Chromium revision also pins the V8 revision listed in `BASE_COMMIT.txt`. Apply the overlay after syncing; syncing again can overwrite changes in dependency checkouts.

### Build the standard and JIT apps

Set the app version to match v0.3.1:

```sh
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 0.3.1' content/shell/app/ios/ios-app.plist
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 0.3.1' content/shell/app/ios/ios-app.plist
```

Standard edition:

```sh
mkdir -p out/blink14
cp "$BF_SRC/build_args.gn" out/blink14/args.gn
gn gen out/blink14
autoninja -C out/blink14 content_shell
```

JIT edition:

```sh
mkdir -p out/blink14-jit
sed 's/com.nodesclock.blinkerfluid/com.nodesclock.blinkerfluid.jit/'   "$BF_SRC/build_args.gn" > out/blink14-jit/args.gn
gn gen out/blink14-jit
autoninja -C out/blink14-jit content_shell
```

The bundle identifier selects the JIT edition. Actual JIT availability also depends on the installation environment and runtime checks.

### IPA packaging and legacy builds

The commands above build app bundles with code signing disabled. The project also defines a `content_shell_ipa` packaging target. The release signing/entitlements and final packaging steps still need to be documented before this is a complete recipe for the uploaded IPA/TIPA files.

The uploaded iOS 11/12 editions require their own build settings and resource packaging. The supplied `build_args.gn` targets iOS 14.0; lowering that value alone is not a verified legacy-build recipe.

These instructions have not been validated with a clean rebuild. Older releases require their corresponding source and configuration; this section covers v0.3.1 only.

## Credits

- [Reynard Browser](https://github.com/minh-ton/reynard-browser) by [Minh Ton](https://github.com/minh-ton) for heavily inspiring the creation of Blinker Fluid.
- [TrollStore](https://github.com/opa334/TrollStore) by [opa334](https://github.com/opa334) and all contributors.
- [Chromium](https://github.com/chromium/chromium) and [Ungoogled Chromium](https://github.com/ungoogled-software/ungoogled-chromium).
- [@Waguriii_draws](https://www.instagram.com/waguriii_draws/) on Instagram for creating the Blinker Fluid app icons. Great friend and an amazing artist!