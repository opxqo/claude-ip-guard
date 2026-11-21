#!/bin/zsh
# Builds ~/Applications/Claude (IP Guard).app (the network guard console) from Sources/*.swift.
set -e
cd "${0:A:h}"
APP="$HOME/Applications/Claude (IP Guard).app"
swiftc -O -swift-version 5 -target arm64-apple-macos14 -o ClaudeIPGuard Sources/*.swift
./ClaudeIPGuard --selftest > /dev/null || { ./ClaudeIPGuard --selftest | grep FAIL; rm -f ClaudeIPGuard; exit 1; }
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
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>在 Terminal 中打开 Claude Code CLI。</string>
</dict></plist>
PL
codesign --force -s - "$APP"
touch "$APP"
echo "built: $APP"
if pgrep -xq ClaudeIPGuard; then
  echo "note: a console is still running the previous build; quit it from its menu and open the app again."
fi
