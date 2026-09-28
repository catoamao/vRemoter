#!/bin/zsh
#
# Build an Intel (x86_64) DMG of vRemoter.
#
# Why this exists: the official vRemoter DMG ships an arm64-only executable, so
# it cannot launch on Intel Macs. There is nothing architecture-specific in the
# source, so rebuilding natively produces a working Intel binary.
#
# Two build adjustments are required compared with package-app.sh:
#   1. -strict-concurrency=minimal
#      The pinned TelemetryDeck dependency enables the StrictConcurrency
#      experimental feature. Under Swift 5.9 / macOS 14 SDK that turns
#      AppKit main-actor notification lookups into hard errors. Relaxing the
#      flag downgrades them to warnings; app behaviour is unchanged.
#   2. VRReleasesURL is repointed at a non-existent manifest.
#      The official update channel only publishes arm64 builds, so an update
#      would silently replace this Intel build with an unusable one. Set
#      KEEP_UPDATES=1 to leave the upstream URL untouched.
#
# Usage:
#   ./build-intel-dmg.sh                # normal run
#   KEEP_UPDATES=1 ./build-intel-dmg.sh # keep the upstream update channel
#
# ---------------------------------------------------------------------------
# Local fork changes on top of upstream v1.1.1
# ---------------------------------------------------------------------------
# 1. Intel build. Upstream only publishes an arm64 executable.
# 2. WeChat Input Method support. The monitored input method is now a setting
#    (automatic / Doubao / WeChat Input Method) instead of a hard-coded Doubao
#    bundle ID, and the trigger follows either a tap-to-toggle or a
#    press-and-hold gesture. See Sources/vRemote/VoiceInputHost.swift.
#
# KNOWN LIMITATION - macOS 14.2 or later is required
#   Host detection reads kAudioProcessPropertyIsRunningInput and
#   kAudioProcessPropertyDevices on the input method's CoreAudio process
#   object. Those properties only exist from macOS 14.2, when Core Audio
#   process objects were introduced. On macOS 13 and earlier the read fails
#   with kAudioHardwareUnknownPropertyError, the snapshot stays `unavailable`,
#   and the session closes itself about one second after the remote voice key
#   is pressed - for Doubao and WeChat Input Method alike.
#   Verified on macOS 13.7.8 (MacBookPro14,3).
#
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
cd "$SCRIPT_DIR"

PLIST="$SCRIPT_DIR/Packaging/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
APP="$SCRIPT_DIR/dist/build/vRemote.app"
CONTENTS="$APP/Contents"
STAGING="$SCRIPT_DIR/dist/dmg-root"
FINAL_DMG="$SCRIPT_DIR/dist/vRemoter-$VERSION-intel.dmg"

print "==> Building vRemote $VERSION (x86_64)"
# VREMOTER_SWIFT_FLAGS exists so the build still works when invoked from a
# sandboxed environment, where SwiftPM cannot apply its own manifest sandbox.
swift build -c release -Xswiftc -strict-concurrency=minimal ${=VREMOTER_SWIFT_FLAGS:-}

print "==> Assembling app bundle"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$SCRIPT_DIR/.build/release/vRemote" "$CONTENTS/MacOS/vRemote"
cp "$PLIST" "$CONTENTS/Info.plist"

for resource_bundle in "$SCRIPT_DIR/.build/release/"*.bundle; do
  [[ -d "$resource_bundle" ]] || continue
  ditto "$resource_bundle" "$CONTENTS/Resources/${resource_bundle:t}"
done
for localization in "$SCRIPT_DIR/Packaging"/*.lproj; do
  [[ -d "$localization" ]] || continue
  ditto "$localization" "$CONTENTS/Resources/${localization:t}"
done

cp "$SCRIPT_DIR/Design/vRemoter-Logo-v1/vRemoter-app-icon-v9.png" \
  "$CONTENTS/Resources/vRemoterLogo.png"

ICONSET="$SCRIPT_DIR/dist/vRemoter.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
LOGO="$CONTENTS/Resources/vRemoterLogo.png"
sips -z 16 16     "$LOGO" --out "$ICONSET/icon_16x16.png"     >/dev/null
sips -z 32 32     "$LOGO" --out "$ICONSET/icon_16x16@2x.png"  >/dev/null
sips -z 32 32     "$LOGO" --out "$ICONSET/icon_32x32.png"     >/dev/null
sips -z 64 64     "$LOGO" --out "$ICONSET/icon_32x32@2x.png"  >/dev/null
sips -z 128 128   "$LOGO" --out "$ICONSET/icon_128x128.png"   >/dev/null
sips -z 256 256   "$LOGO" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "$LOGO" --out "$ICONSET/icon_256x256.png"   >/dev/null
sips -z 512 512   "$LOGO" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "$LOGO" --out "$ICONSET/icon_512x512.png"   >/dev/null
cp "$LOGO" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/vRemoter.icns"
rm -rf "$ICONSET"

for pair in \
  "Resources/PermissionGuides:Resources/PermissionGuides" \
  "Resources/buymeacoffee:Resources/BuyMeACoffee" \
  "Resources/Commerce:Resources/Commerce" \
  "Resources/RemoteImages:Resources/RemoteImages"
do
  source_dir="$SCRIPT_DIR/${pair%%:*}"
  target_dir="$CONTENTS/${pair##*:}"
  [[ -d "$source_dir" ]] || continue
  ditto "$source_dir" "$target_dir"
done

if [[ "${KEEP_UPDATES:-0}" != "1" ]]; then
  print "==> Disabling the arm64-only upstream update channel"
  /usr/libexec/PlistBuddy -c \
    "Set :VRReleasesURL https://updates.vincentstudio.org/vremoter/releases-intel.json" \
    "$CONTENTS/Info.plist"
fi

chmod 755 "$CONTENTS/MacOS/vRemote"
chmod -R u+w "$APP"
xattr -cr "$APP"

print "==> Signing (ad-hoc)"
codesign \
  --force \
  --deep \
  --sign - \
  --timestamp=none \
  --requirements '=designated => identifier "local.simaqingfeng.vRemote"' \
  "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

ARCHS=$(lipo -archs "$CONTENTS/MacOS/vRemote")
print "==> Architectures: $ARCHS"
if [[ "$ARCHS" != *x86_64* ]]; then
  print -u2 "Refusing to package: binary has no Intel slice ($ARCHS)"
  exit 1
fi

print "==> Creating DMG"
rm -rf "$STAGING" "$FINAL_DMG"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/vRemote.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create \
  -volname "vRemoter $VERSION" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$FINAL_DMG"
rm -rf "$STAGING"

print "Built: $FINAL_DMG"
