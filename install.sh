#!/bin/bash
# Installs GeminiWindow.app to ~/Applications and sets it to auto-start at login,
# so the global hotkey (⌘⌥G) is always available.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="GeminiWindow"
SRC="$ROOT/build/$APP_NAME.app"
DEST_DIR="$HOME/Applications"
DEST="$DEST_DIR/$APP_NAME.app"
LABEL="com.geminiwindow.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ ! -d "$SRC" ]; then
    echo "Build first: ./build.sh"; exit 1
fi

echo "==> Installing to $DEST"
mkdir -p "$DEST_DIR"
# Stop any running copy
pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -rf "$DEST"
cp -R "$SRC" "$DEST"

echo "==> Writing LaunchAgent $PLIST"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>            <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$DEST/Contents/MacOS/$APP_NAME</string>
    </array>
    <key>RunAtLoad</key>        <true/>
    <key>KeepAlive</key>        <true/>
    <key>ProcessType</key>      <string>Interactive</string>
</dict>
</plist>
PLISTEOF

echo "==> Loading LaunchAgent (starts the app now + at every login)"
launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load "$PLIST"

echo "==> Done. Gemini Window is running. Press ⌘⌥G to toggle."
