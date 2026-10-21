#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="$PWD/build/スリープしない君.app"
mkdir -p "$APP/Contents/MacOS" "$PWD/build/module-cache"
xcrun swiftc Sources/*.swift -target "$(uname -m)-apple-macosx13.0" -o "$APP/Contents/MacOS/LidAwake" -module-cache-path "$PWD/build/module-cache" -framework Cocoa -framework SwiftUI -framework IOKit -framework CoreImage -O
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns Resources/MenuIcon.png "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LidAwake</string>
<key>CFBundleIdentifier</key><string>local.lidawake.app</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleName</key><string>スリープしない君</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.3</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --options runtime --sign - "$APP"
echo "$APP"
