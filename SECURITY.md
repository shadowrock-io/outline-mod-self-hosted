# Security

## Scope

This project modifies a locally-installed Electron application. It does not run a server, collect data, or communicate with any external service beyond:

1. **Your self-hosted Outline instance** (the URL you provide)
2. **npm registry** (to temporarily download `@electron/asar` via `npx`, then removes it)

## What the script modifies

| Item | Change | Reversible? |
|---|---|---|
| `app.asar` inside Outline.app | One URL string in `build/env.js` | Yes (`--rollback`) |
| `app-original.asar` | Created (backup of unmodified archive) | Delete manually |
| Code signature (macOS) | Ad-hoc re-signed for local use | Yes (reinstall or rollback) |
| `AutoUpdateDisabled` pref (macOS) | Set to `YES` | Yes (`--rollback` or `defaults delete`) |

Nothing else on your system is read, written, or transmitted.

## Verifying the script

Before running, you can:

1. **Read it.** Each script is a single file with no obfuscation.
2. **Run `--dry-run`.** Previews every action with exact commands, modifies nothing.
3. **Run ShellCheck.** `shellcheck outline-mod.sh` produces zero findings.
4. **Check CI.** Every push runs ShellCheck, secret scanning, and URL normalization tests.
5. **Verify the SHA256.** After cloning, compare against the hash shown in the latest CI run.

## Reporting a vulnerability

If you find a security issue, open a [private security advisory](https://github.com/shadowrock-io/outline-mod-self-hosted/security/advisories/new) on this repository.

Do not open a public issue for security vulnerabilities.

## Signed releases

Release tags are signed. Verify with:

```bash
git tag -v v2.0.0
```
