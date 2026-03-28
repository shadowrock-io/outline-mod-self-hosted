# Outline Desktop App — Self-Hosted Mod

[![CI](https://github.com/shadowrock-io/outline-mod-self-hosted/actions/workflows/ci.yml/badge.svg)](https://github.com/shadowrock-io/outline-mod-self-hosted/actions/workflows/ci.yml)
[![ShellCheck](https://img.shields.io/badge/ShellCheck-passing-brightgreen)](https://www.shellcheck.net/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![No Dependencies](https://img.shields.io/badge/dependencies-0-brightgreen)]()

Patch the [Outline](https://www.getoutline.com/) desktop app to connect to your self-hosted instance instead of `app.getoutline.com`.

One script. One string change. Fully reversible. Cleans up after itself.

## Quick Start

**macOS / Linux:**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/shadowrock-io/outline-mod-self-hosted/main/outline-mod.sh)
```

**Windows (PowerShell):**

```powershell
irm https://raw.githubusercontent.com/shadowrock-io/outline-mod-self-hosted/main/outline-mod.ps1 -OutFile outline-mod.ps1
.\outline-mod.ps1
```

Or clone and run:

```bash
git clone https://github.com/shadowrock-io/outline-mod-self-hosted.git
cd outline-mod-self-hosted
./outline-mod.sh            # macOS / Linux
.\outline-mod.ps1           # Windows
```

The script prompts for your Outline URL, validates it, patches the app, and configures it for self-hosted use.

## Usage

**macOS / Linux (Bash):**

```
./outline-mod.sh                                    # Interactive prompt
./outline-mod.sh https://docs.example.com           # Direct URL
./outline-mod.sh --dry-run https://docs.example.com # Preview actions
./outline-mod.sh --rollback                         # Restore original
./outline-mod.sh --status                           # Inspect state + checksums
./outline-mod.sh --app-path ~/custom/Outline.app    # Custom install location
./outline-mod.sh --verbose                          # Debug output
./outline-mod.sh --help
```

**Windows (PowerShell):**

```powershell
.\outline-mod.ps1 https://docs.example.com
.\outline-mod.ps1 -DryRun https://docs.example.com
.\outline-mod.ps1 -Rollback
.\outline-mod.ps1 -Status
.\outline-mod.ps1 -AppPath "D:\Programs\Outline"
.\outline-mod.ps1 -Help
```

## Requirements

| Platform | App | Other |
|---|---|---|
| macOS | Outline.app (auto-detected in `/Applications` or `~/Applications`) | Node.js / `npx` |
| Linux | Outline (auto-detected in `/opt`, `/usr/lib`, `~/.local`) | Node.js / `npx` |
| Windows | Outline (auto-detected in `%LOCALAPPDATA%\Programs` or `%PROGRAMFILES%`) | Node.js / `npx` |

`npx` downloads `@electron/asar` temporarily during the mod. The script **removes it from the npx cache when done** — no leftover dependencies.

## How It Works

The Outline desktop app is an Electron wrapper around the Outline web UI. Every server URL reference traces back to a single getter in `build/env.js` inside the app's ASAR archive:

```javascript
static get host() {
    return this.isDevelopment
        ? "https://local.outline.dev:3000"
        : `https://app.getoutline.com`;   // <-- this line
}
```

The ASAR archive contents are identical across macOS, Linux, and Windows builds. The patching logic is the same on all platforms.

The script:

1. **Backs up** the original `app.asar` with a SHA256 checksum
2. **Extracts** the ASAR archive to a temp directory
3. **Patches** the single URL string in `build/env.js`
4. **Repacks** to a temporary ASAR and **verifies** (URL presence, file count match)
5. **Atomically swaps** the temp ASAR into place (the original is untouched until this point)
6. **Re-signs** the app (macOS only, ad-hoc for local use)
7. **Disables auto-updates** so the patch survives
8. **Cleans up** all temp files and cached `@electron/asar`

## Safety Features

| Feature | Detail |
|---|---|
| `--dry-run` | Preview every action with exact commands before modifying anything |
| `--status` | Inspect current URL, SHA256 checksums, backup integrity, code signature |
| Atomic swap | Repacks to a `.tmp` file, verifies, then `mv` into place. If verification fails, the original ASAR is untouched. |
| SHA256 checksums | Original ASAR hash stored alongside backup. Rollback verifies the hash matches. |
| File count check | Compares file count in repacked ASAR against the original. Catches corrupt repacks. |
| Backup preservation | Never overwrites an existing backup. Safe to re-run against a different URL. |
| Permission check | Detects missing write permissions and advises `sudo` instead of failing with opaque errors. |
| Process detection | Detects running Outline and offers to quit it gracefully before patching. |
| Self-cleanup | Removes all temp files and `@electron/asar` from the npx cache on exit. |
| Single file | Each script is one file. Read it before running. |

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

Validation checks: HTTPS required, FQDN (must contain a dot), valid port (1-65535), no invalid characters, reachability test (with bypass for VPN/internal hosts), rejects `app.getoutline.com`.

## Permissions

| Platform | Typical install | Needs elevation? |
|---|---|---|
| macOS | `/Applications/Outline.app` | No (user-writable) |
| macOS | `~/Applications/Outline.app` | No |
| Linux | `/opt/Outline/` | Yes (`sudo`) |
| Linux | `~/.local/share/outline/` | No |
| Windows | `%LOCALAPPDATA%\Programs\Outline` | No (per-user) |
| Windows | `%PROGRAMFILES%\Outline` | Yes (Run as Administrator) |

The script checks write permissions before modifying anything and tells you if elevation is needed.

**Linux note:** Snap and Flatpak packages are read-only and cannot be patched. The script detects these and explains the alternative (install via `.deb` or direct download).

## Authentication

After patching, the auth flow works through Outline's existing `outline://` URL scheme:

1. App loads your self-hosted URL
2. You click through your normal OAuth/SAML login
3. Your server redirects to `outline://your-host/auth/callback?token=...`
4. Your OS routes that back to the desktop app
5. You're logged in

**Fallback**: If the redirect fails, log in via your browser, copy the `accessToken` cookie from DevTools, and paste it into the desktop app's DevTools (View > Toggle Developer Tools > Application > Cookies).

## Rollback

```bash
./outline-mod.sh --rollback     # macOS / Linux
.\outline-mod.ps1 -Rollback     # Windows
```

Restores the original ASAR from backup, verifies the SHA256 checksum, re-signs (macOS), and re-enables auto-updates. You can also reinstall Outline from scratch.

## Tested With

- Outline Desktop v1.5.1 (Electron 29.3.0)
- macOS Sequoia 15.x

The ASAR patching approach has been verified on macOS. Linux and Windows use the same ASAR contents and the same extract/patch/repack flow, with platform-specific wrappers for process detection, signing, and auto-update configuration.

## License

MIT
