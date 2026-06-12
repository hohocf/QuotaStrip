#!/bin/bash
# Build QuotaStrip.app as a universal binary (x86_64 + arm64).
# Covers both Intel Touch Bar Macs and the Apple Silicon 13" MacBook Pro (M1 2020 / M2 2022),
# which also have a Touch Bar.
#
#   ./build.sh            # build into ./QuotaStrip.app
#   ./build.sh --run      # build, then (re)launch the app
set -e
cd "$(dirname "$0")"

APP=QuotaStrip.app
CONTENTS="$APP/Contents"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp Sources/Info.plist "$CONTENTS/Info.plist"
cp Resources/quota.py Resources/claude-logo.png Resources/codex-logo.png \
   Resources/codex_notify.sh Resources/AppIcon.icns "$CONTENTS/Resources/"
chmod +x "$CONTENTS/Resources/codex_notify.sh"

# Compile one slice per architecture, then merge with lipo.
SLICES=()
for arch in x86_64 arm64; do
    out="/tmp/quotastrip-$arch"
    echo "compiling $arch ..."
    swiftc -O -swift-version 5 -target "$arch-apple-macosx11.0" \
        Sources/main.swift -o "$out" \
        -framework AppKit -framework ServiceManagement \
        -F /System/Library/PrivateFrameworks -framework DFRFoundation
    SLICES+=("$out")
done

lipo -create "${SLICES[@]}" -output "$CONTENTS/MacOS/QuotaStrip"
rm -f "${SLICES[@]}"

# Ad-hoc signature (no paid Apple Developer account). Users bypass Gatekeeper on first open.
codesign --force --deep -s - "$APP"

echo "built $APP ($(lipo -archs "$CONTENTS/MacOS/QuotaStrip"))"

if [ "$1" = "--run" ]; then
    pkill -x QuotaStrip 2>/dev/null || true
    sleep 1
    open "$APP"
fi
