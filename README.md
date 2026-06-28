# Gemini Window

A tiny native macOS background app that pops **Gemini into a small, frosted-glass,
voice-first window** via a global hotkey — no Chrome tab, no API key. It's a real WebKit
browser window, so you just **sign in with your Google account** (the one with Gemini Pro)
and it stays signed in.

It's designed as a fast, Siri-style voice assistant: a notification-sized translucent
black-and-white panel that opens straight into Gemini's voice mode with a fresh chat.

## Features

- **Global hotkey** — ⌘⌥G toggles the window from anywhere (no Accessibility permission needed).
- **Voice-first** — opens a fresh chat and auto-starts Gemini's microphone each time.
- **Minimal UI** — model selector, side menu, attach button, text box, and greeting are
  stripped away for a clean voice surface.
- **Liquid-glass look** — translucent, see-through, forced black & white.
- **Background app** — no Dock icon, auto-starts at login, menu-bar ✦ icon for controls.

## Usage

- **Toggle the window:** press **⌘ + ⌥ + G** (Command + Option + G) anywhere, anytime.
- **Menu bar:** click the ✦ sparkles icon → Open Gemini / Start Voice / Reload / Quit.
- First launch shows the window so you can sign in. Login persists across restarts.
- Each time you open the window it loads a **fresh chat** in voice mode.

## Build / install

```bash
./build.sh      # compiles GeminiWindow.app into ./build
./install.sh    # copies to ~/Applications + sets up auto-start at login
```

## Why ⌘⌥G instead of Fn+F5 / replacing Siri?

`⌘⌥G` is a clean global hotkey that needs **zero special permissions** and works
instantly. macOS does not let an app silently steal the hardware `Fn`/`F5`
(dictation/Siri) key, so binding to it requires a manual one-time setup. If you'd
rather use F5, do this (optional):

1. **System Settings → Keyboard → Dictation** → turn Dictation **off** (frees the F5/mic key).
2. **System Settings → Keyboard → Keyboard Shortcuts → Function Keys** → enable
   "Use F1, F2 … as standard function keys" if you want raw F-keys.
3. To launch on F5 you need a hotkey daemon (e.g. [`skhd`](https://github.com/koekeishiya/skhd))
   with a line like:
   `f5 : open -a ~/Applications/GeminiWindow.app` — but since the app is always
   running, just send it the toggle. The built-in ⌘⌥G is simpler and recommended.

You can also disable Siri entirely in **System Settings → Apple Intelligence & Siri**.

## Changing the hotkey

Edit `hotKeyKeyCode` / `hotKeyModifiers` near the top of `Sources/main.swift`, then
re-run `./build.sh && ./install.sh`.

## Uninstall

```bash
launchctl bootout "gui/$(id -u)/com.geminiwindow.app"
rm -rf ~/Applications/GeminiWindow.app ~/Library/LaunchAgents/com.geminiwindow.app.plist
```
