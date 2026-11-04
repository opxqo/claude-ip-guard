#!/bin/zsh
# Installs Claude IP Guard into ~/.claude (scripts, launcher app, mod). Does NOT edit settings.json or your shell rc.
set -e
cd "${0:A:h}"
C="$HOME/.claude"
mkdir -p "$C/bin" "$C/launcher" "$C/local-mods"

cp bin/* "$C/bin/"
chmod +x "$C"/bin/claude-guard "$C"/bin/claude-desktop-guard "$C"/bin/claude-ip-check "$C"/bin/claude-ip-override "$C"/bin/claude-ip-watch
echo "scripts   -> $C/bin"

# Launcher app (needs Xcode command line tools: swiftc). AppIcon.png is read at runtime from ~/.claude/launcher.
cp launcher/ClaudeIPGuard.swift launcher/build.sh launcher/AppIcon.icns launcher/AppIcon.png "$C/launcher/"
"$C/launcher/build.sh"

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
  3. Start Claude Desktop from "Claude (IP Guard).app" in ~/Applications.
  4. Threshold: edit $C/ip-guard.conf (MIN_SCORE).
MSG
