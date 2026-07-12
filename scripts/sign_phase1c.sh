#!/bin/zsh
# Phase 1c: sign + package the instrumented (boot-trace) content_shell for iOS 15.4.
set -e
APP=~/chromium_ios/src/out/blink15/content_shell.app
ENT=~/Desktop/Ungoogled-Blink-iOS/artifacts/entitlements/content_shell_host.entitlements
OUT=~/Desktop/Ungoogled-Blink-iOS/artifacts/PORT_phase1c_boottrace_ios15_arm64.ipa
LDID=~/bin/ldid

echo "== signing framework binaries =="
for fw in "$APP"/Frameworks/*.framework; do
  bin="$fw/$(basename "$fw" .framework)"
  if [ -f "$bin" ]; then
    "$LDID" -S "$bin"
    echo "  signed $bin"
  fi
done

echo "== signing main executable with host entitlements (JIT/EVA) =="
"$LDID" -S"$ENT" "$APP/content_shell"

echo "== packaging IPA =="
WORK=$(mktemp -d)
mkdir -p "$WORK/Payload"
cp -R "$APP" "$WORK/Payload/"
( cd "$WORK" && zip -q9 -r "$OUT" Payload )
rm -rf "$WORK"
echo "== done: $OUT =="
ls -la "$OUT"
echo "== verify weak-link still intact =="
otool -l "$APP"/Frameworks/content_shell_framework.framework/content_shell_framework 2>/dev/null | grep -iA1 BrowserEngine | head
