<img width="100" height="100" alt="New Project 20  0B9169A" src="https://github.com/user-attachments/assets/67a507ac-e528-4720-abd8-23930b242dc0" />

# Blinker Fluid
(WARNING: THIS IS EXPERIMENTAL AND IS PRONE TO CRASHING AND BREAKING)

## Chromium Blink + V8 browser engine ported to iOS 15 with no WebKit.

Blinker Fluid is an experimental browser for jailbroken iPhones that runs a real Chromium rendering engine on iOS without using Apple's WebKit engine.

## Why did I start this project?
I started this project mainly because Ungoogled Chromium is my primary PC browser aside from Tor, so I thought, why not try porting it to iOS? I was also annoyed that many sites require a newer version of WebKit than the one included with iOS 15.

## What are the iOS and device requirements for Blinker Fluid and how do I install it?
 Tested and functional: An arm64e device running iOS 15.4 is recommended. This has only been tested on a jailbroken iPhone 13 Pro running iOS 15.4.
 
 Untested: This should work on any arm64e device running iOS 15 and newer. (Make an issue ticket if another iOS version works that isn't already stated here)

# Features (Current)

- Loads modern websites that the version of WebKit included with iOS 15 does not support
- Real Blink rendering engine
- Real V8 JavaScript engine
- Video playback
- Search / URL bar
- Tab manager 
- Bookmarks 
- Dark mode support  
- Different search engines
- Desktop and mobile site 
- Optional SOCKS5 / Tor proxy support

# Trollstore method:
1. Download the IPA file from releases.
2. Import the IPA file into TrollStore.
3. Tap Install and wait for the installation to finish.
4. Go to your home screen and open the app.
5. Blinker Fluid opens.

### Any other IPA signing tool (Esign, Gbox, etc)
- Blinker Fluid has not been tested with signing tools other than TrollStore, but they may work.

### DISCLAIMER: JIT is currently unstable and will have issues.

## Screenshots of Blinker Fluid Working (iOS 15.4 on an iPhone 13 Pro):

| [Github](https://github.com) | [Pinterest](https://pinterest.com) | [Gemini](https://gemini.google.com) |
|---|---|---|
| <img width="500" height="1000" alt="8252CD69-29BF-42EA-8C7E-41ACCB40BC5D" src="https://github.com/user-attachments/assets/20717283-7353-4880-beaa-413aea0ad65b" />| <img width="500" height="1000" alt="1B3CE020-188F-4FF4-9F52-D6A526BF6E12" src="https://github.com/user-attachments/assets/b03ae5e3-6fd0-475a-8508-63712f4be516" />| <img width="500" height="1000" alt="60853588-4371-4231-B516-78F635F9C1FA" src="https://github.com/user-attachments/assets/da35d2e6-2507-4bf9-af3a-1ed14321ab7d" />

# What is being worked on or will be added in the future:
- ~~Better iOS version compatibility (iOS 15, 16, and 26.1 with LiveContainer currently work, iOS 14 should work, but I haven't tested it)~~ (After v.0.2.1, only iOS 15 and newer will be supported due to iOS 14 and under testing complications)
- ~~Adding JIT support (Main priority at the moment, will probably fix many issues alone)~~ - JIT is now officially supported and will continue receiving updates, though as of v0.2.1, it is not as stable as JITless mode.
- Built-in ad blocker (Planned for a later version)
- Incognito mode (I am working on a possible solution, though will be a feature later on.)
- Website compatibility (Always being worked on with each update)

# What will most likely never be added:
- Extension support (Very time consuming and complicated.)
- Password manager (Same reason, very time consuming and complicated. Will most likely never be added.)
- Reader mode & translation (Translation and built-in browser language option is in the works, though reader mode will continue to be a feature that will never be added)
- ~~Website History (Too complicated for me)~~ Website history has been added to v.0.2.1

# Known issues:
- v0.2.1 JIT version randomly crashes occasionally.
- Some sites crash instantly. (Please create an issue explaining what website and what action caused the crash)
- Weird audio issues.
- Fullscreen video playback may cause a black screen.

## DISCLAIMER: AI WAS USED IN THE PROCESS OF BUILDING THIS!!
### AI was specifically used as assistant as it should in:
- Research about how Blink/V8 could be ported onto iOS.
- Some parts of development.
- Some small quick bug fixes.

## Source code?
Yes, it is all available.

# Credits:
- [Reynard Browser](https://github.com/minh-ton/reynard-browser) by [Minh Ton](https://github.com/minh-ton) heavily inspired the creation of Blinker Fluid
- [Chromium open-source project](https://github.com/chromium/chromium) and [Ungoogled Chromium](https://github.com/ungoogled-software/ungoogled-chromium)
- [@miku_draws_random_stuff](https://www.instagram.com/miku_draws_random_stuff/) on Instagram for the Blinker Fluid app icons! (Great friend, great artist)
