# Outline Desktop App — Self-Hosted Mod

Patch the [Outline](https://www.getoutline.com/) desktop app to connect to your self-hosted instance instead of `app.getoutline.com`.

One script. One string change. Fully reversible.

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/shadowrock-io/outline-mod-self-hosted/main/outline-mod.sh | bash
```

Or clone and run:

```bash
git clone https://github.com/shadowrock-io/outline-mod-self-hosted.git
cd outline-mod-self-hosted
./outline-mod.sh
```

The script prompts for your Outline URL, validates it, patches the app, re-signs it, and disables auto-updates.

## Usage

```
./outline-mod.sh                          # Interactive prompt
./outline-mod.sh https://docs.example.com # Direct URL
./outline-mod.sh --rollback               # Restore original app
./outline-mod.sh --status                 # Check current mod state
./outline-mod.sh --help                   # Usage info
```

## Requirements

- macOS
- [Outline.app](https://www.getoutline.com/download) installed in `/Applications`
- Node.js / `npx` (for `@electron/asar` — auto-installed on first run)

## How It Works

The Outline desktop app is an Electron wrapper around the Outline web UI. Every server URL reference traces back to a single getter in `build/env.js` inside the app's ASAR archive:

```javascript
static get host() {
    return this.isDevelopment
        ? "https://local.outline.dev:3000"
        : `https://app.getoutline.com`;   // <-- this line
}
```

The script:

1. **Backs up** the original `app.asar`
2. **Extracts** the ASAR archive
3. **Patches** the single URL string in `build/env.js`
4. **Repacks** and **verifies** the archive
5. **Re-signs** the app (ad-hoc, for local use)
6. **Disables auto-updates** using the app's built-in preference key

## URL Validation

The script accepts a variety of URL formats:

| Input | Normalized To |
|---|---|
| `https://docs.example.com` | `https://docs.example.com` |
| `https://docs.example.com/` | `https://docs.example.com` |
| `https://DOCS.Example.COM` | `https://docs.example.com` |
| `HTTPS://docs.example.com` | `https://docs.example.com` |
| `https://outline.company.io:8443` | `https://outline.company.io:8443` |
| `https://docs.example.com/path/stuff` | `https://docs.example.com` |
| `docs.example.com` | `https://docs.example.com` |

Validation checks:
- HTTPS required (Outline's auth flow needs it)
- Fully qualified domain name (must contain a dot)
- Valid port number if specified (1-65535)
- No invalid characters
- Reachability test with option to continue if unreachable (VPN/internal hosts)
- Rejects `app.getoutline.com` (that's the default you're replacing)

## Authentication

After patching, the auth flow works through Outline's existing `outline://` URL scheme:

1. App loads your self-hosted URL
2. You click through your normal OAuth/SAML login
3. Your server redirects to `outline://your-host/auth/callback?token=...`
4. macOS routes that back to the desktop app
5. You're logged in

**Fallback**: If the redirect fails, log in via Safari, copy the `accessToken` cookie from DevTools, and paste it into the desktop app's DevTools (View > Toggle Developer Tools > Application > Cookies).

## Rollback

```bash
./outline-mod.sh --rollback
```

This restores the original ASAR from backup, re-signs the app, and re-enables auto-updates. You can also reinstall Outline from scratch (`brew install --cask outline` or download from getoutline.com).

## Tested With

- Outline Desktop v1.5.1 (Electron 29.3.0)
- macOS Sequoia 15.x

## License

MIT
