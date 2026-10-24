#!/usr/bin/env bash
# Builds SayOpen.app (Apple Silicon + Intel) and packs it into SayOpen.dmg.
set -euo pipefail
cd "$(dirname "$0")"
APP=build/SayOpen.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -swift-version 5 -target "$arch-apple-macos13.0" \
    src/*.swift -o "build/SayOpen-$arch"
done
lipo -create build/SayOpen-arm64 build/SayOpen-x86_64 -output "$APP/Contents/MacOS/SayOpen"
rm build/SayOpen-arm64 build/SayOpen-x86_64

cp Info.plist "$APP/Contents/Info.plist"
[ -f build-cache/AppIcon.icns ] || { mkdir -p build-cache; python3 make_icon.py build-cache/AppIcon.icns; }
cp build-cache/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Signed with a local certificate kept in signing/, not an Apple Developer ID. The identity
# stays the same from build to build, so macOS keeps the mic, speech and Accessibility
# permissions across updates. The keychain joins the search list only for the signing call.
KC="$PWD/signing/sayopen.keychain-db"
if [ -f "$KC" ]; then
  security unlock-keychain -p "$(cat signing/keychain-password)" "$KC"
  ORIG=$(security list-keychains -d user | tr -d '"' | xargs)
  security list-keychains -d user -s $ORIG "$KC"
  trap 'security list-keychains -d user -s $ORIG' EXIT
  ID=$(security find-identity -p codesigning "$KC" | awk '/SayOpen Local Signing/ {print $2; exit}')
  codesign --force --sign "$ID" --options runtime --entitlements entitlements.plist "$APP"
  security list-keychains -d user -s $ORIG
  trap - EXIT
else
  codesign --force --sign - --options runtime --entitlements entitlements.plist "$APP"
fi

STAGE=build/dmg && mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "How to open SayOpen.txt" "$STAGE/"
hdiutil create -volname SayOpen -srcfolder "$STAGE" -ov -format UDZO build/SayOpen.dmg >/dev/null
rm -rf "$STAGE"
echo "built build/SayOpen.dmg ($(du -h build/SayOpen.dmg | cut -f1))"
