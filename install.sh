#!/bin/zsh
# Installs Claude IP Guard into ~/.claude (scripts, launcher app, mod). Does NOT edit settings.json or your shell rc.
set -e
cd "${0:A:h}"
C="$HOME/.claude"
mkdir -p "$C/bin" "$C/launcher" "$C/local-mods"

cp bin/claude[-_]* "$C/bin/"
chmod +x "$C"/bin/claude-guard "$C"/bin/claude-desktop-guard "$C"/bin/claude-ip-check "$C"/bin/claude-ip-override "$C"/bin/claude-ip-watch
echo "scripts   -> $C/bin"

# Console app (needs Xcode command line tools: swiftc). AppIcon.png is read at runtime from ~/.claude/launcher.
rm -rf "$C/launcher/Sources"
cp -R launcher/Sources launcher/build.sh launcher/AppIcon.icns launcher/AppIcon.png "$C/launcher/"
cp docs/NETWORK-GUARD.md "$C/launcher/"
rm -f "$C/launcher/ClaudeIPGuard.swift"
"$C/launcher/build.sh"

# The separate menu bar app from 1.x is now part of the console.
pkill -x ClaudeNetBar 2>/dev/null || true
rm -rf "$HOME/Applications/Claude Net Monitor.app" "$C/launcher/ClaudeNetBar.swift" "$C/launcher/build-netbar.sh"
rm -f "$HOME/Library/LaunchAgents/local.claude-netbar.plist"

# Threshold config: never overwrite an existing one.
[[ -f "$C/ip-guard.conf" ]] || cp config/ip-guard.conf.example "$C/ip-guard.conf"

# Mod: __HOME__ in the source is replaced with your home directory.
rm -rf "$C/local-mods/cleanip"
cp -R mod/cleanip "$C/local-mods/cleanip"
sed -i '' "s#__HOME__#$HOME#g" "$C/local-mods/cleanip/hooks/register.tsx"
echo "mod       -> $C/local-mods/cleanip"

cat <<MSG

Next steps (manual):
  1. Register and enable the mod:
       claude plugin marketplace add $C/local-mods/cleanip
       claude plugin install cleanip@local-mods
  2. Optional: make the terminal go through the gate, add to ~/.zshrc:
       alias claude="$C/bin/claude-guard"
  3. Open "Claude (IP Guard).app" in ~/Applications: it checks the exit IP, starts the monitor,
     then lets you open Claude Desktop, the CLI, or nothing. ⌃⌥⌘K closes every Claude process.
  4. Thresholds and policy: the console's settings, or $C/ip-guard.conf.
MSG
