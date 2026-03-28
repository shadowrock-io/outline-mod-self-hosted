# Outline Desktop App — Self-Hosted Mod

[![CI](https://github.com/shadowrock-io/outline-mod-self-hosted/actions/workflows/ci.yml/badge.svg)](https://github.com/shadowrock-io/outline-mod-self-hosted/actions/workflows/ci.yml)
[![ShellCheck](https://img.shields.io/badge/ShellCheck-passing-brightgreen)](https://www.shellcheck.net/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![No Dependencies](https://img.shields.io/badge/dependencies-0-brightgreen)]()

The [Outline](https://www.getoutline.com/) desktop app hardcodes its server URL to `app.getoutline.com`. No setting, preference, or config file lets you change it. If you self-host Outline via Docker, Kubernetes, or bare metal, the official desktop app refuses to connect to your server.

This script swaps that URL for yours inside the app's Electron archive and keeps a backup for rollback.

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

The script prompts for your Outline URL, validates it, patches the app, and disables auto-updates.

## Usage

**macOS / Linux (Bash):**

```
./outline-mod.sh                                           # Interactive prompt
./outline-mod.sh https://outline.your-domain.com           # Direct URL
./outline-mod.sh --dry-run https://outline.your-domain.com # Preview actions
./outline-mod.sh --rollback                                # Restore original
./outline-mod.sh --status                                  # Inspect state + checksums
./outline-mod.sh --app-path ~/custom/Outline.app           # Custom install location
./outline-mod.sh --verbose                                 # Debug output
./outline-mod.sh --help
```

**Windows (PowerShell):**

```powershell
.\outline-mod.ps1 https://outline.your-domain.com
.\outline-mod.ps1 -DryRun https://outline.your-domain.com
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

`npx` downloads `@electron/asar` for the patch and removes it from the cache afterward.

## How It Works

The Outline desktop app is an Electron shell around the web UI. The server URL lives in a single getter in `build/env.js` inside the app's ASAR archive:

```javascript
static get host() {
    return this.isDevelopment
        ? "https://local.outline.dev:3000"
        : `https://app.getoutline.com`;   // <-- this line
}
```

The ASAR archive contents are identical across macOS, Linux, and Windows builds.

The script:

1. **Backs up** the original `app.asar` with a SHA256 checksum
2. **Extracts** the ASAR archive to a temp directory
3. **Patches** the URL string in `build/env.js`
4. **Repacks** to a temporary ASAR and **verifies** (URL presence, file count match)
5. **Atomically swaps** the temp ASAR into place (the original stays untouched until this step)
6. **Re-signs** the app (macOS only, ad-hoc for local use)
7. **Disables auto-updates** so the patch survives
8. **Cleans up** temp files and cached `@electron/asar`

## Safety

| Feature | Detail |
|---|---|
| `--dry-run` | Shows every action with exact commands before modifying anything |
| `--status` | Reports current URL, SHA256 checksums, backup integrity, code signature |
| Atomic swap | Repacks to a `.tmp` file, verifies, then moves into place. If verification fails, the original ASAR stays untouched. |
| SHA256 checksums | Original ASAR hash stored alongside backup. Rollback verifies the hash matches. |
| File count check | Compares file count in repacked ASAR against the original to flag corrupt repacks |
| Backup preservation | You can re-run with a different URL without losing the original backup |
| Permission check | Detects missing write permissions and tells you to use `sudo` |
| Process detection | Detects running Outline and offers to quit it before patching |
| Self-cleanup | Removes temp files and `@electron/asar` from the npx cache on exit |
| Single file | Each script is one auditable file |

## URL Validation

The script normalizes URL formats before patching:

| Input | Normalized To |
|---|---|
| `https://outline.your-domain.com` | `https://outline.your-domain.com` |
| `https://outline.your-domain.com/` | `https://outline.your-domain.com` |
| `https://OUTLINE.Your-Domain.COM` | `https://outline.your-domain.com` |
| `HTTPS://outline.your-domain.com` | `https://outline.your-domain.com` |
| `https://outline.your-domain.com:8443` | `https://outline.your-domain.com:8443` |
| `https://outline.your-domain.com/path/stuff` | `https://outline.your-domain.com` |
| `outline.your-domain.com` | `https://outline.your-domain.com` |

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

**Linux note:** Snap and Flatpak packages are read-only and cannot be patched. The script detects these and points you to `.deb` or direct download as alternatives.

## Authentication

After patching, auth uses Outline's existing `outline://` URL scheme:

1. App loads your self-hosted URL
2. You click through your OAuth/SAML login
3. Your server redirects to `outline://your-host/auth/callback?token=...`
4. Your OS routes that back to the desktop app
5. The app loads the callback URL and you're authenticated

**Fallback**: If the redirect fails, log in via your browser, copy the `accessToken` cookie from DevTools, and paste it into the desktop app's DevTools (View > Toggle Developer Tools > Application > Cookies).

## Rollback

```bash
./outline-mod.sh --rollback     # macOS / Linux
.\outline-mod.ps1 -Rollback     # Windows
```

Restores the original ASAR from backup, verifies the SHA256 checksum, re-signs (macOS), and re-enables auto-updates. You can also reinstall Outline from scratch.

## FAQ

**Can I switch to a different self-hosted URL later?**
Run the script again with the new URL. It detects the existing mod and swaps the URL. The original backup is preserved.

**Does the patch survive Outline updates?**
The script disables auto-updates on macOS. On Linux and Windows, re-run the script after a manual update.

**Does this work with Outline on Docker/Kubernetes?**
Yes. This tool patches the desktop client. Your server can run on Docker, Kubernetes, bare metal, or any other host. The script needs the HTTPS URL where your Outline instance is reachable.

**Does this phone home or collect telemetry?**
No. The script runs locally and modifies a local file. It contacts your self-hosted URL (reachability check) and the npm registry (`@electron/asar` download). Both are visible in `--dry-run` output.

## Tested With

- Outline Desktop v1.5.1 (Electron 29.3.0)
- macOS Sequoia 15.x

The ASAR patching approach has been verified on macOS. Linux and Windows use the same ASAR contents and the same extract/patch/repack flow, with platform-specific wrappers for process detection, signing, and auto-update configuration.

## Disclaimer

This project is not affiliated with, endorsed by, or associated with [Outline](https://www.getoutline.com/) or General Outline, Inc. "Outline" is a trademark of its respective owner.

This software is provided **as-is, without warranty of any kind**. Use it at your own risk. The authors accept no liability for damage, data loss, or other consequences from its use. You are responsible for verifying that this tool is appropriate for your environment before running it.

Modifying third-party applications may violate their terms of service. Review Outline's license and terms before proceeding.

See [LICENSE](LICENSE) for full terms (MIT).

## License

MIT
