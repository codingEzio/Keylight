#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
work=$(mktemp -d "${TMPDIR:-/tmp}/keylight-launch-build.XXXXXX")
cleanup() { status=$?; if [ "$status" -eq 0 ]; then rm -rf "$work"; else printf 'Retained diagnostic fixture: %s\n' "$work" >&2; fi; }
trap cleanup EXIT
mkdir -p "$work/Fixture Calculator.app/Contents/MacOS"
cat > "$work/app.swift" <<'SWIFT'
import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
DispatchQueue.main.asyncAfter(deadline: .now() + 2) { app.terminate(nil) }
app.run()
SWIFT
cat > "$work/Fixture Calculator.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>test.keylight.learningfixture</string>
<key>CFBundleName</key><string>Fixture Calculator</string>
<key>CFBundleExecutable</key><string>fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
swiftc -module-cache-path "$work/module-cache" "$work/app.swift" -o "$work/Fixture Calculator.app/Contents/MacOS/fixture"
swiftc -D KEYLIGHT_FIXTURE -module-cache-path "$work/module-cache" Sources/*.swift Tests/SearchLaunchSmoke.swift -o "$work/check"
"$work/check" "$work"
