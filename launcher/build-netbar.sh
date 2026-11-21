#!/bin/zsh
# Builds ~/Applications/Claude Net Monitor.app (menu bar status for claude-ip-watch) from ClaudeNetBar.swift.
set -e
cd "${0:A:h}"
APP="$HOME/Applications/Claude Net Monitor.app"
swiftc -O -swift-version 5 -target arm64-apple-macos14 -o ClaudeNetBar ClaudeNetBar.swift
./ClaudeNetBar --selftest
pkill -x ClaudeNetBar 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv ClaudeNetBar "$APP/Contents/MacOS/"
cp AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Claude Net Monitor</string>
  <key>CFBundleDisplayName</key><string>Claude Net Monitor</string>
  <key>CFBundleIdentifier</key><string>local.claude-netbar</string>
  <key>CFBundleExecutable</key><string>ClaudeNetBar</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PL
codesign --force -s - "$APP"
touch "$APP"
echo "built: $APP"
