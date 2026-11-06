#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ "${KEYLIGHT_SWIFTPM_NO_SANDBOX:-0}" = 1 ]; then
    swift build --disable-sandbox -c release -j 4
else
    swift build -c release -j 4
fi
app="$PWD/dist/Keylight.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/Keylight "$app/Contents/MacOS/Keylight"
cp -R Resources/. "$app/Contents/Resources/"
cp scripts/toggle-dark-mode.sh "$app/Contents/Resources/"
iconset=$(mktemp -d "${TMPDIR:-/tmp}/Keylight.XXXXXX")
trap 'rm -rf "$iconset"' EXIT
mkdir "$iconset/Keylight.iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Assets/Keylight.png --out "$iconset/Keylight.iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" Assets/Keylight.png --out "$iconset/Keylight.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset/Keylight.iconset" -o "$app/Contents/Resources/Keylight.icns"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Keylight</string>
<key>CFBundleDisplayName</key><string>Keylight</string>
<key>CFBundleExecutable</key><string>Keylight</string>
<key>CFBundleIdentifier</key><string>com.alex.Keylight</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.6</string>
<key>CFBundleVersion</key><string>7</string>
<key>CFBundleIconFile</key><string>Keylight</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSUIElement</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSAppleEventsUsageDescription</key><string>Keylight uses System Events only when you run Toggle Dark Mode.</string>
</dict></plist>
PLIST
codesign --force --sign "${KEYLIGHT_SIGN_IDENTITY:--}" "$app"
codesign --verify --strict --verbose=2 "$app"
