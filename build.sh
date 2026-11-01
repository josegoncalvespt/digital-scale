#!/bin/zsh
# Builds a universal (Apple Silicon + Intel) "Digital Scale.app" into ./build
set -e
cd "$(dirname "$0")"
APP="build/Digital Scale.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj
for ARCH in arm64 x86_64; do
  swiftc -O -swift-version 5 -target $ARCH-apple-macos14.0 \
    -framework AppKit -framework SceneKit -framework QuickLookThumbnailing -framework AVFoundation \
    Sources/*.swift -o build/obj/DigitalScale-$ARCH
done
lipo -create build/obj/DigitalScale-arm64 build/obj/DigitalScale-x86_64 -output "$APP/Contents/MacOS/DigitalScale"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
