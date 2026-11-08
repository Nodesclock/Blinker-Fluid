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
| iPhone 11 Pro Max | iOS 14.2 | ✅ |
| iPhone Air | iOS 26.0.1 — Sideloaded + Developer certificate| ✅ |
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

Yes! Blinker Fluid is fully open source. Contributions and pull requests are accepted and greatly appreciated as long as the fix for the issue that is being addressed was fully tested and confirmed to be a valid fix.

The Chromium source overlay and main build configuration are available directly in this repository.

Blinker Fluid is based on Chromium **M149** at a pinned Chromium revision. The repository does not contain the entire Chromium source tree; instead, the `src/` directory contains the files modified by Blinker Fluid and is intended to be applied over a normal Chromium checkout.

## Building v.0.3.1

Everything needed to build is in this repository. The packaging steps below create the same two packages as the releases: the normal build and the JIT build. They are the same binary with the same entitlements. The only difference is the bundle identifier: when it ends in `.jit`, Blinker Fluid asks for JIT at runtime, which works on jailbroken devices and with JIT enablers.

### Requirements

- A Mac with **Xcode 16.2** (the releases are built with the iOS 18.2 SDK). If several Xcode versions are installed, select it with `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, using the path of your Xcode 16.2.
- An **iOS Simulator runtime** installed in Xcode (Xcode → Settings → Components). The main build compiles an asset catalog with `actool`, which refuses to run without a simulator runtime, even for a device build.
- [depot_tools](https://chromium.googlesource.com/chromium/tools/depot_tools.git) on your `PATH`.
- [`ldid`](https://github.com/ProcursusTeam/ldid) on your `PATH` (for example `brew install ldid`).
- About **120 GB** of free disk space. The first build takes several hours.

Run the commands from the extracted Blinker Fluid source folder (the folder that contains `src/` and `build_args.gn`). Builds and packages are created in a separate work folder; existing downloaded IPAs are not changed.

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

`BASE_COMMIT.txt` lists the Chromium and V8 revisions the overlay is made for. `gclient sync` checks out the matching V8 automatically.

### 2. Select one package family

**Main release (iOS 14 and later):**

```sh
OUT=blink15
MIN_OS=14.0
BUNDLE_ID=com.nodesclock.blinkerfluid
mkdir -p "out/$OUT"
cp "$SRC/build_args.gn" "out/$OUT/args.gn"
```

**Legacy release (iOS 12 and later), the download named `iOS.12.11`:**

```sh
OUT=blink12
MIN_OS=12.0
BUNDLE_ID=com.nodesclock.blinkerfluid.ios12
mkdir -p "out/$OUT"
cat > "out/$OUT/args.gn" <<'EOF'
target_os = "ios"
target_cpu = "arm64"
target_environment = "device"
use_blink = true
is_debug = false
is_component_build = false
ios_enable_code_signing = false
symbol_level = 0
mac_sdk_min = "14.5"
ios_deployment_target = "12.0"
ios_content_shell_bundle_identifier = "com.nodesclock.blinkerfluid.ios12"
treat_warnings_as_errors = false
v8_enable_sandbox = false
v8_enable_pointer_compression = false
v8_enable_drumbrake = false
cppgc_enable_caged_heap = false
proprietary_codecs = true
ffmpeg_branding = "Chrome"
dcheck_always_on = false
content_shell_version = "149.0.7821.0"
content_shell_major_version = "149"
blinker_legacy_ios_address_space = true
blinker_enable_diagnostics = false
EOF
```

> [!NOTE]
> Despite its download filename, the current legacy package targets iOS 12.0 and later, not iOS 11. It turns off V8 pointer compression and shrinks PartitionAlloc's address-space reservations, because 1 GB devices cannot reserve the address space the main build uses.

### 3. Build

```sh
gn gen "out/$OUT"
autoninja -C "out/$OUT" -j 2 content_shell
```

Wait for each command to finish successfully. Build one family at a time. `-j 2` keeps memory use low; raise it if your Mac has plenty of RAM.

### 4. Package the build

Create the entitlement file used for both packages:

```sh
cat > "$BLINKER_WORK/blinker.ent" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.developer.kernel.extended-virtual-addressing</key>
	<true/>
	<key>com.apple.developer.kernel.increased-memory-limit</key>
	<true/>
	<key>get-task-allow</key>
	<true/>
</dict>
</plist>
ENT
```

Create the home-screen icon and the start-page logo from the artwork in `src/content/shell/app/ios/resources/artwork`:

```sh
ART="$SRC/src/content/shell/app/ios/resources/artwork"
ICONS="$BLINKER_WORK/icons"
mkdir -p "$ICONS"
sips -s format jpeg "$ART/New Project 20 [0B9169A].png" --out "$ICONS/icon.jpg" >/dev/null
sips -s format png -z 120 120 "$ICONS/icon.jpg" --out "$ICONS/AppIcon60x60@2x.png" >/dev/null
sips -s format png -z 180 180 "$ICONS/icon.jpg" --out "$ICONS/AppIcon60x60@3x.png" >/dev/null
sips -s format png -z 152 152 "$ICONS/icon.jpg" --out "$ICONS/AppIcon76x76@2x.png" >/dev/null
sips -z 120 120 "$ART/27367.png" --out "$ICONS/blinker_logo.png" >/dev/null
sips -z 240 240 "$ART/27367.png" --out "$ICONS/blinker_logo@2x.png" >/dev/null
sips -z 360 360 "$ART/27367.png" --out "$ICONS/blinker_logo@3x.png" >/dev/null
rm "$ICONS/icon.jpg"
```

Then package both bundles:

```sh
VERSION=0.3.1
APP="$BLINKER_WORK/src/out/$OUT/content_shell.app"
PKG="$BLINKER_WORK/packages/$OUT"
mkdir -p "$PKG"

package() {
  local bundle_id="$1" name="$2" ipa="$3"
  local work="$(mktemp -d)"
  mkdir -p "$work/Payload"
  cp -R "$APP" "$work/Payload/"
  local app="$work/Payload/content_shell.app"
  cp "$ICONS/"*.png "$app/"
  local plist="$app/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName $name" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $name" "$plist"
  /usr/libexec/PlistBuddy -c "Set :MinimumOSVersion $MIN_OS" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$plist"
  for framework in "$app"/Frameworks/*.framework; do
    local binary="$framework/$(basename "$framework" .framework)"
    [ -f "$binary" ] && ldid -S "$binary"
  done
  ldid -S"$BLINKER_WORK/blinker.ent" "$app/content_shell"
  rm -f "$ipa"
  (cd "$work" && zip -q9 -r "$ipa" Payload)
  rm -rf "$work"
  echo "$ipa"
}

package "$BUNDLE_ID" "Blinker Fluid" "$PKG/Blinker Fluid v.$VERSION.ipa"
package "$BUNDLE_ID.jit" "Blinker Fluid JIT" "$PKG/Blinker Fluid v.$VERSION JIT.ipa"
cp "$PKG/Blinker Fluid v.$VERSION.ipa" "$PKG/Blinker Fluid v.$VERSION TS.tipa"
cp "$PKG/Blinker Fluid v.$VERSION JIT.ipa" "$PKG/Blinker Fluid v.$VERSION JIT TS.tipa"
```

The normal and JIT IPAs, plus their TIPA copies for TrollStore, are in:

```text
$BLINKER_WORK/packages/<selected OUT>/
```

Package filenames retain the `v.` prefix, for example:

```text
Blinker Fluid v.0.3.1.ipa
Blinker Fluid v.0.3.1 JIT.ipa
```

> [!NOTE]
> The app icon and logo artwork in `src/content/shell/app/ios/resources/artwork` is all drawn by [@Waguriii_draws](https://www.instagram.com/waguriii_draws/) and is probably not covered by the GPL license.

## Credits

- [Reynard Browser](https://github.com/minh-ton/reynard-browser) by [Minh Ton](https://github.com/minh-ton) for heavily inspiring the creation of Blinker Fluid.
- [TrollStore](https://github.com/opa334/TrollStore) by [opa334](https://github.com/opa334) and all contributors.
- [Chromium](https://github.com/chromium/chromium) for being most of Blinker Fluid.
- [Ungoogled Chromium](https://github.com/ungoogled-software/ungoogled-chromium) for heavily inspiring the creation of Blinker Fluid too.
- [EasyList and EasyPrivacy](https://easylist.to) by the EasyList creators, used as the built-in ad and tracker blocking lists.
- [@Waguriii_draws](https://www.instagram.com/waguriii_draws/) on Instagram for creating the Blinker Fluid app icons and all Blinker Fluid art. Great friend and an amazing artist!
