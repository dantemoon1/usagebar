# UsageBar

A tiny macOS menu bar app that shows your Claude and Codex API quota usage at a glance.

I got tired of getting rate limited and not knowing how close I was to the limit, so I made this. It reads your existing auth tokens and polls the usage APIs every few minutes.

## Features

- Shows quota usage as small colored bars right in your menu bar
- Supports both Claude and Codex (or just one)
- Click to see a dashboard with detailed usage, reset times, and extra credits
- Usage notifications at 50%, 75%, 90%, 95%, 99% thresholds
- Color or monochrome mode
- Launch at login
- No external dependencies — just Swift and SwiftUI

## Install

```bash
./build-app.sh
cp -r UsageBar.app /Applications/
```

Requires macOS 14+ and Swift 6.2.

## Setup

### Claude

UsageBar uses a two-tier auth approach:

1. **OAuth token (automatic)** — reads from `~/.claude/.credentials.json` or Keychain (set by Claude Code). No setup needed.
2. **Browser cookie (fallback)** — if the OAuth token is expired or unavailable, UsageBar falls back to a browser cookie. Go to Settings > Claude Cookie > paste your cookie from `claude.ai/settings/usage` (DevTools > Network > copy Cookie header).

### Codex

- Uses `~/.codex/auth.json` — just run `codex --login` and UsageBar picks it up.

## Screenshots

![Menu bar](screenshots/menubar.png)

![Dashboard](screenshots/dashboard.png)
