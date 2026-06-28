# Gemini Window

A tiny native macOS background app that pops **Gemini into a small, frosted-glass,
voice-first window** via a global hotkey — no Chrome tab, no API key. It's a real WebKit
browser window, so you just **sign in with your Google account** (the one with Gemini Pro)
and it stays signed in.

It's designed as a Siri replacement: a translucent **"Talk to Gemini" pill** in the
corner. Press **⌘⌥G** and it's **instantly listening** — no buttons. You speak, it shows
a **live transcript** in the pill, **auto-detects when you stop**, sends your words to
Gemini, then **shows and speaks the answer** and listens again (conversation mode).

## How it works

- **Speech-to-text is native** — macOS on-device Speech recognition gives instant
  listening, a live transcript, and silence-based auto-submit. No API key.
- **The answer comes from Gemini** — your finalized text is fed into a hidden, logged-in
  Gemini web session (your Google account), and the streamed reply is read back.
- **Replies are spoken** with native text-to-speech.

## Features

- **Instant listening** — ⌘⌥G starts listening immediately; press again to stop/dismiss.
- **No buttons** — automatic end-of-speech detection submits for you; no send button.
- **Live transcript** — shown right in the pill, which grows vertically for long text but
  never becomes a big browser window.
- **Conversation mode** — after answering it listens again for a follow-up.
- **Siri-style pill** — gradient Gemini spark logo + status, translucent glass, B&W.
- **Background app** — no Dock icon, auto-starts at login, menu-bar ✦ icon for controls.

## First-run setup (one time)

1. **Allow Microphone** and **Speech Recognition** when macOS prompts.
2. From the menu-bar ✦ icon, choose **"Sign in to Google…"**, sign in to your Gemini
   account in the panel, then choose **"Done signing in."** (Needed once so the hidden
   session can answer; it persists afterward.)
3. Press **⌘⌥G** and start talking.

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
