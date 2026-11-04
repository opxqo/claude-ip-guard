#!/bin/zsh
# Builds ~/Applications/Claude (IP Guard).app from ClaudeIPGuard.swift.
set -e
cd "${0:A:h}"
APP="$HOME/Applications/Claude (IP Guard).app"
swiftc -O -swift-version 5 -target arm64-apple-macos14 -o ClaudeIPGuard ClaudeIPGuard.swift
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv ClaudeIPGuard "$APP/Contents/MacOS/"
cp AppIcon.icns AppIcon.png "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Claude (IP Guard)</string>
  <key>CFBundleDisplayName</key><string>Claude (IP Guard)</string>
  <key>CFBundleIdentifier</key><string>local.claude-ip-guard</string>
  <key>CFBundleExecutable</key><string>ClaudeIPGuard</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PL
codesign --force -s - "$APP"
touch "$APP"
echo "built: $APP"
