#!/bin/bash
# Builds GeminiWindow.app — a background macOS app that opens Gemini in a
# floating window via a global hotkey (⌘⌥G).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="GeminiWindow"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
BUNDLE_ID="com.geminiwindow.app"

echo "==> Cleaning previous build"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Writing Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>     <string>Gemini Window</string>
    <key>CFBundleExecutable</key>      <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>         <string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSMicrophoneUsageDescription</key><string>Gemini uses your microphone for voice mode.</string>
</dict>
</plist>
PLIST

echo "==> Compiling Swift"
swiftc -O \
    "$ROOT/Sources/main.swift" \
    -o "$APP/Contents/MacOS/$APP_NAME" \
    -framework Cocoa -framework WebKit -framework Carbon \
    -target arm64-apple-macos13.0

echo "==> Ad-hoc code signing"
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || \
    codesign --force --sign - "$APP"

echo "==> Built: $APP"
