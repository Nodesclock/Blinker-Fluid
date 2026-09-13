<p align="center">
  <img width="100" height="100" alt="Blinker Fluid" src="https://github.com/user-attachments/assets/67a507ac-e528-4720-abd8-23930b242dc0" />
</p>

<h1 align="center">Blinker Fluid</h1>

<p align="center">
  <strong>An experimental Chromium Blink + V8 browser for iOS.</strong><br>
  Runs without Apple's WebKit engine.
</p>

<p align="center">
  <img alt="Version" src="https://img.shields.io/badge/version-v.0.3.1-blue">
  <img alt="iOS" src="https://img.shields.io/badge/iOS-12%20%26%2014%2B-lightgrey">
  <img alt="Chromium" src="https://img.shields.io/badge/Chromium-M149-blue">
  <img alt="Status" src="https://img.shields.io/badge/status-Experimental-orange">
  <img alt="License" src="https://img.shields.io/badge/license-GPL--3.0-blue">
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
| iPhone 13 Pro | iOS 15.4 | ✅ |
| iPhone 14 Pro Max | iOS 17.2.1 | ✅ |
| iPhone 6+ | iOS 12.5.7 | ✅ |
| iPad 7th Generation | iOS 17.5.1 | ✅ |
| Unknown Device | iOS 15.2 | ✅ |
| iPhone 12 Pro Max| iOS 14.1 | ✅ |
| Unknown Device | iOS 16.0.2 | ✅ |
| iPad Air 1 | iOS 12.5.8 | ✅ |
| iPhone 11 | iOS 26.2 — [LiveContainer](https://github.com/LiveContainer/LiveContainer) | ✅ |
| Unknown Device | iOS 26.1 — [LiveContainer](https://github.com/LiveContainer/LiveContainer) | ✅ |

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
  iOS 12 support was added in Blinker Fluid v.0.3.1.

- [x] JIT support  
  Officially supported since v.0.2.1 and continuing to receive stability and performance improvements.

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
> - Helping me with translating things to English. (Apologies if README sounds AI generated.)

## Source Code

Yes! Blinker Fluid is fully open source.

The Chromium source overlay and main build configuration are available directly in this repository.

Blinker Fluid is based on Chromium **M149** at a pinned Chromium revision. The repository does not contain the entire Chromium source tree; instead, the `src/` directory contains the files modified by Blinker Fluid and is intended to be applied over a normal Chromium checkout.

## Building v.0.3.1

Run these commands from the complete, extracted Blinker Fluid source folder. New packages are created in a separate build folder; existing downloaded IPAs are not changed.

### 1. Download Chromium and apply the source overlay

```sh
export SRC="$PWD"
export BLINKER_WORK="$(mktemp -d "$HOME/blinker-build.XXXXXX")"
cd "$BLINKER_WORK"

gclient config --spec='solutions = [{"name": "src", "url": "https://chromium.googlesource.com/chromium/src.git", "managed": False, "custom_deps": {}, "custom_vars": {}}]; target_os = ["ios"]; target_os_only = True'
gclient sync --nohooks --revision src@31dce68b925c2b8efc93df832a86a7c0d03e3fa2

rsync -a "$SRC/src/" src/
cd src
gclient runhooks
```

### 2. Select one package family

**Main release:**

```sh
OUT=blink15
ARGS=build_args.gn
MIN_OS=14.0
BUNDLE_ID=com.nodesclock.blinkerfluid
```

**Legacy release — the current download named `iOS.12.11`:**

```sh
OUT=blink12
ARGS=build_args.ios12.gn
MIN_OS=12.0
BUNDLE_ID=com.nodesclock.blinkerfluid.ios12
```

> [!NOTE]
> Despite its download filename, the current legacy package targets iOS 12.0 and later, not iOS 11.

### 3. Build

```sh
mkdir -p "out/$OUT"
cp "$SRC/$ARGS" "out/$OUT/args.gn"
gn gen "out/$OUT"
autoninja -C "out/$OUT" -j 2 content_shell
```

Wait for each command to finish successfully. Build one family at a time.

### 4. Package the build

Copy the packaging script:

```sh
cp "$SRC/sign_blinker.sh" "$BLINKER_WORK/sign_blinker.local.sh"
```

In that copy, replace its `APP`, `LDID`, `ENT`, and `ASSETS` assignments with:

```sh
APP="$BLINKER_WORK/src/out/${BLINKER_OUT:-blink15}/content_shell.app"
LDID="$(command -v ldid)"
ENT="$SRC/packaging/minimal.ent"
ASSETS="$SRC/packaging/blinker_assets"
```

Then run:

```sh
BLINKER_OUT="$OUT" \
BLINKER_MIN_OS="$MIN_OS" \
BLINKER_BUNDLE_ID="$BUNDLE_ID" \
BLINKER_NAME_SUFFIX="" \
zsh "$BLINKER_WORK/sign_blinker.local.sh" \
  0.3.1 "$BLINKER_WORK/packages/$OUT"
```

The normal and JIT IPAs, plus their TIPA copies, are in:

```text
$BLINKER_WORK/packages/<selected OUT>/
```

Package filenames retain the `v.` prefix, for example:

```text
Blinker Fluid v.0.3.1.ipa
Blinker Fluid v.0.3.1 JIT.ipa
```

## Credits

- [Reynard Browser](https://github.com/minh-ton/reynard-browser) by [Minh Ton](https://github.com/minh-ton) for heavily inspiring the creation of Blinker Fluid.
- [TrollStore](https://github.com/opa334/TrollStore) by [opa334](https://github.com/opa334) and all contributors.
- [Chromium](https://github.com/chromium/chromium) and [Ungoogled Chromium](https://github.com/ungoogled-software/ungoogled-chromium).
- [@Waguriii_draws](https://www.instagram.com/waguriii_draws/) on Instagram for creating the Blinker Fluid app icons. Great friend and an amazing artist!
