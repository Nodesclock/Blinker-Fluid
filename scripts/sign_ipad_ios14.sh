#!/bin/zsh
# Sign + package the iOS-14-compatible content_shell build.
# Minimal entitlements (get-task-allow + increased-memory-limit); JIT/EVA
# entitlements trigger an AMFI exec-kill on this configuration.
set -e
APP=~/chromium_ios/src/out/blink15/content_shell.app
ENT=/tmp/minimal.ent
OUT=~/Desktop/Blinker_Fluid.ipa
LDID=~/bin/ldid
ICONS=~/Desktop/Ungoogled-Blink-iOS/appicons

# The build regenerates content_shell.app with no app icon, so re-apply the
# loose AppIcon PNGs each package (referenced from ios-app.plist).
echo "== applying app icons + in-app logo =="
# AppIcon*: home-screen icon (loose PNGs via CFBundleIconFiles).
# blinker_logo*: the start-page logo loaded by -[UIImage imageNamed:] in
# shell_platform_delegate_ios.mm, supplied as loose bundle PNGs.
for ic in "AppIcon60x60@2x.png" "AppIcon60x60@3x.png" "AppIcon76x76@2x.png" \
          "blinker_logo.png" "blinker_logo@2x.png" "blinker_logo@3x.png"; do
  if [ -f "$ICONS/$ic" ]; then
    cp "$ICONS/$ic" "$APP/$ic"
    echo "  applied $ic"
  fi
done

echo "== signing framework binaries (adhoc) =="
for fw in "$APP"/Frameworks/*.framework; do
  bin="$fw/$(basename "$fw" .framework)"
  if [ -f "$bin" ]; then
    "$LDID" -S "$bin"
    echo "  signed $bin"
  fi
done

echo "== signing main executable with minimal entitlements =="
"$LDID" -S"$ENT" "$APP/content_shell"

echo "== packaging IPA =="
WORK=$(mktemp -d)
mkdir -p "$WORK/Payload"
cp -R "$APP" "$WORK/Payload/"
( cd "$WORK" && zip -q9 -r "$OUT" Payload )
rm -rf "$WORK"

cd "$(dirname "$OUT")"
shasum -a 256 "$(basename "$OUT")" > "$(basename "$OUT").sha256"
echo "== done =="
ls -la "$OUT" "$OUT.sha256"
echo "== sha256 =="; cat "$OUT.sha256"
