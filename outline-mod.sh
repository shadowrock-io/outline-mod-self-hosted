#!/usr/bin/env bash
# outline-mod.sh — Patch the Outline desktop app to connect to a self-hosted instance.
#
# Usage:
#   ./outline-mod.sh              Interactive: prompts for your Outline URL
#   ./outline-mod.sh <url>        Non-interactive: uses the provided URL
#   ./outline-mod.sh --rollback   Restore the original (unmodified) app
#   ./outline-mod.sh --status     Show current mod state
#   ./outline-mod.sh --help       Print usage
#
# Requirements: macOS, Outline.app in /Applications, Node.js (npx)

set -euo pipefail

readonly APP_PATH="/Applications/Outline.app"
readonly RESOURCES="${APP_PATH}/Contents/Resources"
readonly ASAR="${RESOURCES}/app.asar"
readonly BACKUP="${RESOURCES}/app-original.asar"
readonly PLIST_DOMAIN="com.generaloutline.outline"
readonly EXTRACT_DIR="$(mktemp -d)/outline-mod"
readonly ORIGINAL_HOST="https://app.getoutline.com"

# ── Colors ──────────────────────────────────────────────────────────────────

red()    { printf '\033[0;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }

# ── Helpers ─────────────────────────────────────────────────────────────────

die() { red "Error: $*" >&2; exit 1; }

cleanup() {
  local parent
  parent="$(dirname "$EXTRACT_DIR")"
  if [[ -d "$parent" && "$parent" == /tmp/* ]]; then
    rm -rf "$parent"
  fi
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Outline Desktop App — Self-Hosted Mod

Usage:
  outline-mod.sh              Prompt for your self-hosted URL, then patch
  outline-mod.sh <url>        Patch using the provided URL (non-interactive)
  outline-mod.sh --rollback   Restore the original unmodified app
  outline-mod.sh --status     Show whether the app is modded and to which URL
  outline-mod.sh --help       Show this message

Requirements:
  - macOS
  - Outline.app installed in /Applications
  - Node.js / npx available (for @electron/asar)

Examples:
  outline-mod.sh https://docs.example.com
  outline-mod.sh https://outline.company.io:8443
  outline-mod.sh --rollback
EOF
  exit 0
}

# ── Preflight Checks ───────────────────────────────────────────────────────

check_macos() {
  [[ "$(uname -s)" == "Darwin" ]] || die "This script only runs on macOS."
}

check_app_installed() {
  [[ -d "$APP_PATH" ]] || die "Outline.app not found at ${APP_PATH}. Install it first."
  [[ -f "$ASAR" ]] || die "app.asar not found at ${ASAR}. The Outline.app installation may be corrupt."
}

check_npx() {
  command -v npx >/dev/null 2>&1 || die "npx not found. Install Node.js first (https://nodejs.org or 'brew install node')."
}

check_not_running() {
  if pgrep -xq "Outline"; then
    die "Outline.app is running. Quit it first (Cmd+Q), then re-run this script."
  fi
}

# ── URL Validation ──────────────────────────────────────────────────────────

normalize_url() {
  local url="$1"

  # Strip whitespace
  url="$(echo "$url" | xargs)"

  # Lowercase the scheme and host
  # Extract scheme
  local scheme host_and_rest
  if [[ "$url" =~ ^([a-zA-Z]+)://(.*) ]]; then
    scheme="$(echo "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')"
    host_and_rest="${BASH_REMATCH[2]}"
  else
    # No scheme provided — prepend https://
    scheme="https"
    host_and_rest="$url"
  fi

  # Split host from path at the first /
  local host path
  if [[ "$host_and_rest" == */* ]]; then
    host="${host_and_rest%%/*}"
    path="${host_and_rest#*/}"
  else
    host="$host_and_rest"
    path=""
  fi

  # Lowercase the host portion (preserves port)
  host="$(echo "$host" | tr '[:upper:]' '[:lower:]')"

  # Strip any trailing path — we only need scheme://host[:port]
  # Reconstruct
  url="${scheme}://${host}"

  # Remove trailing slash
  url="${url%/}"

  echo "$url"
}

validate_url() {
  local url="$1"

  # Must be https
  if [[ ! "$url" =~ ^https:// ]]; then
    die "URL must use HTTPS. Outline requires HTTPS for authentication. Got: ${url}"
  fi

  # Extract host (without scheme, without port)
  local hostport="${url#https://}"
  local host="${hostport%%:*}"

  # Must have a dot (not localhost without a dot, not bare words)
  if [[ "$host" != *.* ]]; then
    die "URL host must be a fully qualified domain (e.g., docs.example.com). Got: ${host}"
  fi

  # No spaces or invalid characters in host
  if [[ "$host" =~ [[:space:]] || "$host" =~ [^a-zA-Z0-9._-] ]]; then
    die "URL host contains invalid characters. Got: ${host}"
  fi

  # If there's a port, validate it
  if [[ "$hostport" == *:* ]]; then
    local port="${hostport##*:}"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
      die "Invalid port number: ${port}"
    fi
  fi

  # Must not be the original Outline cloud URL
  if [[ "$url" == "$ORIGINAL_HOST" ]]; then
    die "That's the default Outline cloud URL. Provide your self-hosted instance URL instead."
  fi

  # Reachability check (5-second timeout, follow redirects)
  yellow "Checking reachability of ${url} ..."
  local http_code
  http_code="$(curl -s -o /dev/null -w '%{http_code}' -L --connect-timeout 5 --max-time 10 "$url" 2>/dev/null || true)"

  if [[ -z "$http_code" || "$http_code" == "000" ]]; then
    yellow "Warning: Could not reach ${url}. The server may be down or behind a VPN."
    printf "Continue anyway? [y/N] "
    read -r confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || die "Aborted."
  else
    green "Reachable (HTTP ${http_code})."
  fi
}

# ── Core Operations ─────────────────────────────────────────────────────────

prompt_url() {
  echo ""
  bold "Outline Desktop App — Self-Hosted Mod"
  echo ""
  echo "Enter the root URL of your self-hosted Outline instance."
  echo "Examples: https://docs.example.com, https://outline.company.io:8443"
  echo ""
  printf "Outline URL: "
  read -r url_input

  [[ -n "$url_input" ]] || die "No URL provided."
  echo "$url_input"
}

do_patch() {
  local target_url="$1"

  bold "Step 1/5: Backing up original ASAR"
  if [[ -f "$BACKUP" ]]; then
    yellow "Backup already exists at ${BACKUP} — skipping."
  else
    cp "$ASAR" "$BACKUP"
    green "Backup saved to ${BACKUP}"
  fi

  bold "Step 2/5: Extracting ASAR archive"
  npx --yes @electron/asar extract "$ASAR" "$EXTRACT_DIR" 2>/dev/null
  [[ -f "${EXTRACT_DIR}/build/env.js" ]] || die "Extracted archive missing build/env.js — unexpected app structure."
  green "Extracted to ${EXTRACT_DIR}"

  bold "Step 3/5: Patching build/env.js"
  # Verify the target string exists (either original or a previous mod)
  local env_js="${EXTRACT_DIR}/build/env.js"
  local current_host
  current_host="$(grep -oE 'https://[a-zA-Z0-9._:/-]+getoutline\.com' "$env_js" 2>/dev/null || true)"

  if [[ -z "$current_host" ]]; then
    # Might already be modded to a different URL — find whatever URL is in the host getter
    current_host="$(grep -oE '`https://[^`]+`' "$env_js" | tr -d '`' | head -1)"
    if [[ -z "$current_host" ]]; then
      die "Could not locate the host URL in build/env.js. The app structure may have changed."
    fi
    yellow "App appears already modded to: ${current_host}"
  fi

  if [[ "$current_host" == "$target_url" ]]; then
    green "Already patched to ${target_url} — nothing to change."
    rm -rf "$EXTRACT_DIR"
    return 0
  fi

  # Escape special characters for sed (slashes, dots, colons)
  local escaped_current escaped_target
  escaped_current="$(printf '%s' "$current_host" | sed 's/[&/\]/\\&/g')"
  escaped_target="$(printf '%s' "$target_url" | sed 's/[&/\]/\\&/g')"

  sed -i '' "s|${current_host}|${target_url}|g" "$env_js"

  # Verify the patch took effect
  if ! grep -q "$target_url" "$env_js"; then
    die "Patch failed — ${target_url} not found in env.js after sed."
  fi
  green "Patched: ${current_host} → ${target_url}"

  bold "Step 4/5: Repacking ASAR archive"
  npx --yes @electron/asar pack "$EXTRACT_DIR" "$ASAR" 2>/dev/null
  green "Repacked."

  # Verify repacked archive contains the patch
  local verify_dir
  verify_dir="$(mktemp -d)/outline-verify"
  npx --yes @electron/asar extract "$ASAR" "$verify_dir" 2>/dev/null
  if ! grep -q "$target_url" "${verify_dir}/build/env.js"; then
    die "Verification failed — repacked ASAR does not contain the patched URL."
  fi
  rm -rf "$verify_dir"
  green "Verified: repacked ASAR contains ${target_url}"

  bold "Step 5/5: Re-signing and configuring"
  codesign --force --deep --sign - "$APP_PATH" 2>/dev/null
  green "Ad-hoc code signature applied."

  # Clear quarantine flag if present
  xattr -cr "$APP_PATH" 2>/dev/null || true

  # Disable auto-updates
  defaults write "$PLIST_DOMAIN" AutoUpdateDisabled -bool YES
  green "Auto-updates disabled."

  echo ""
  green "Done. Outline.app now points to ${target_url}"
  echo ""
  echo "Next steps:"
  echo "  1. Launch Outline.app"
  echo "  2. Log in through your self-hosted instance's auth flow"
  echo "  3. If auth redirect fails, see: outline-mod.sh --help"
  echo ""
  echo "To undo: outline-mod.sh --rollback"
}

do_rollback() {
  bold "Rolling back to original Outline.app"

  [[ -f "$BACKUP" ]] || die "No backup found at ${BACKUP}. Nothing to roll back."

  cp "$BACKUP" "$ASAR"
  green "Original ASAR restored."

  codesign --force --deep --sign - "$APP_PATH" 2>/dev/null
  green "Code signature reapplied."

  xattr -cr "$APP_PATH" 2>/dev/null || true

  defaults delete "$PLIST_DOMAIN" AutoUpdateDisabled 2>/dev/null || true
  green "Auto-updates re-enabled."

  echo ""
  green "Rollback complete. Outline.app is back to app.getoutline.com."
}

do_status() {
  bold "Outline Mod Status"
  echo ""

  if [[ ! -d "$APP_PATH" ]]; then
    red "Outline.app not installed."
    return
  fi

  if [[ ! -f "$ASAR" ]]; then
    red "app.asar not found — installation may be corrupt."
    return
  fi

  local tmp_status
  tmp_status="$(mktemp -d)/outline-status"
  npx --yes @electron/asar extract "$ASAR" "$tmp_status" 2>/dev/null

  local current_url
  current_url="$(grep -oE '`https://[^`]+`' "${tmp_status}/build/env.js" | tr -d '`' | head -1)"
  rm -rf "$tmp_status"

  if [[ "$current_url" == "$ORIGINAL_HOST" ]]; then
    echo "  App target:    ${current_url} (stock, unmodified)"
  else
    echo "  App target:    ${current_url} (modded)"
  fi

  if [[ -f "$BACKUP" ]]; then
    echo "  Backup:        Present (${BACKUP})"
  else
    echo "  Backup:        None"
  fi

  local autoupdate
  autoupdate="$(defaults read "$PLIST_DOMAIN" AutoUpdateDisabled 2>/dev/null || echo "not set")"
  echo "  Auto-updates:  AutoUpdateDisabled=${autoupdate}"
  echo ""
}

# ── Main ────────────────────────────────────────────────────────────────────

main() {
  # Handle flags
  case "${1:-}" in
    --help|-h)    usage ;;
    --rollback)
      check_macos
      check_app_installed
      check_not_running
      do_rollback
      exit 0
      ;;
    --status)
      check_macos
      check_app_installed
      check_npx
      do_status
      exit 0
      ;;
  esac

  # Preflight
  check_macos
  check_app_installed
  check_npx
  check_not_running

  # Get the URL (from argument or interactive prompt)
  local raw_url
  if [[ -n "${1:-}" ]]; then
    raw_url="$1"
  else
    raw_url="$(prompt_url)"
  fi

  # Normalize and validate
  local target_url
  target_url="$(normalize_url "$raw_url")"
  validate_url "$target_url"

  # Confirm
  echo ""
  bold "Will patch Outline.app to connect to: ${target_url}"
  printf "Proceed? [Y/n] "
  read -r confirm
  if [[ "$confirm" =~ ^[Nn]$ ]]; then
    die "Aborted."
  fi
  echo ""

  # Patch
  do_patch "$target_url"
}

main "$@"
