#!/usr/bin/env bash
# outline-mod.sh — Patch the Outline desktop app to connect to a self-hosted instance.
#
# Supports macOS and Linux. For Windows, use outline-mod.ps1 (PowerShell).
#
# Usage:
#   ./outline-mod.sh [options] [url]
#   ./outline-mod.sh --rollback [options]
#   ./outline-mod.sh --status [options]
#
# Run ./outline-mod.sh --help for full usage.

set -euo pipefail

# ── Constants ───────────────────────────────────────────────────────────────

readonly VERSION="2.0.0"
readonly ORIGINAL_HOST="https://app.getoutline.com"
readonly PLIST_DOMAIN="com.generaloutline.outline"

# ── State (set during init) ────────────────────────────────────────────────

OS=""              # "macos" or "linux"
ASAR=""            # Path to app.asar
BACKUP=""          # Path to app-original.asar
RESOURCES_DIR=""   # Parent dir of app.asar
APP_ROOT=""        # Top-level app dir (e.g., /Applications/Outline.app)

COMMAND="patch"
TARGET_URL=""
DRY_RUN=false
VERBOSE=false
APP_PATH_OVERRIDE=""

CLEANUP_PATHS=()
NPX_ASAR_PREEXISTED=false   # Track if @electron/asar was already cached before we ran

# ── Output ──────────────────────────────────────────────────────────────────

red()    { printf '\033[0;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }
dim()    { printf '\033[2m%s\033[0m\n' "$*"; }

die() { red "Error: $*" >&2; exit 1; }

step() {
  local num="$1" total="$2" msg="$3"
  bold "[${num}/${total}] ${msg}"
}

debug() {
  if $VERBOSE; then
    dim "  [debug] $*"
  fi
}

# ── Usage ───────────────────────────────────────────────────────────────────

usage() {
  cat <<'EOF'
Outline Desktop App — Self-Hosted Mod (v2.0.0)

Patches the Outline desktop app (Electron) to connect to your self-hosted
instance instead of app.getoutline.com. Works on macOS and Linux.
For Windows, use outline-mod.ps1 (PowerShell).

USAGE
  outline-mod.sh [options] [url]      Patch (interactive if no url given)
  outline-mod.sh --rollback [options] Restore original unmodified app
  outline-mod.sh --status [options]   Show current mod state and integrity

OPTIONS
  --dry-run           Show what would happen without changing anything
  --app-path <path>   Override auto-detected app location
  --verbose, -v       Show debug output
  --help, -h          Show this message
  --version           Show version

EXAMPLES
  outline-mod.sh                              # interactive prompt
  outline-mod.sh https://docs.example.com     # direct URL
  outline-mod.sh --dry-run https://docs.example.com
  outline-mod.sh --app-path ~/custom/Outline.app https://docs.example.com
  outline-mod.sh --rollback
  outline-mod.sh --status

WHAT IT DOES
  1. Backs up the original app.asar (with SHA256 checksum)
  2. Extracts the ASAR archive
  3. Replaces one URL string in build/env.js
  4. Repacks to a temporary file, verifies integrity, then atomically swaps
  5. Re-signs the app (macOS only, ad-hoc for local use)
  6. Disables auto-updates so the patch survives

PERMISSIONS
  macOS:  Usually no sudo needed (/Applications is user-writable).
  Linux:  sudo required for /opt or /usr paths. Script detects and advises.

AUDITING
  This script is a single file. Read it before running.
  Use --dry-run to preview all actions without modifying anything.
  Use --status to inspect the current state and verify checksums.
EOF
  exit 0
}

# ── Cleanup ─────────────────────────────────────────────────────────────────

cleanup() {
  # Remove temp directories and files
  if (( ${#CLEANUP_PATHS[@]} )); then
    for p in "${CLEANUP_PATHS[@]}"; do
      [[ -e "$p" ]] && rm -rf "$p"
    done
  fi
  # Remove @electron/asar from npx cache if we brought it in
  if ! $NPX_ASAR_PREEXISTED; then
    clean_npx_cache
  fi
}
trap cleanup EXIT

register_cleanup() {
  CLEANUP_PATHS+=("$1")
}

snapshot_npx_cache() {
  # Record whether @electron/asar already exists in npx cache
  local npm_cache
  npm_cache="$(npm config get cache 2>/dev/null || true)"
  if [[ -n "$npm_cache" && -d "${npm_cache}/_npx" ]]; then
    for dir in "${npm_cache}/_npx"/*/; do
      if [[ -d "${dir}node_modules/@electron/asar" ]]; then
        NPX_ASAR_PREEXISTED=true
        debug "@electron/asar already in npx cache — will preserve it."
        return
      fi
    done
  fi
}

clean_npx_cache() {
  # Don't touch it if globally installed (user intentionally has it)
  if npm list -g @electron/asar 2>/dev/null | grep -q "@electron/asar"; then
    return
  fi
  local npm_cache
  npm_cache="$(npm config get cache 2>/dev/null || true)"
  if [[ -n "$npm_cache" && -d "${npm_cache}/_npx" ]]; then
    for dir in "${npm_cache}/_npx"/*/; do
      if [[ -d "${dir}node_modules/@electron/asar" ]]; then
        rm -rf "$dir" 2>/dev/null || true
        debug "Cleaned @electron/asar from npx cache."
      fi
    done
  fi
}

# ── Argument Parsing ────────────────────────────────────────────────────────

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h)     usage ;;
      --version)     echo "outline-mod v${VERSION}"; exit 0 ;;
      --rollback)    COMMAND="rollback" ;;
      --status)      COMMAND="status" ;;
      --dry-run)     DRY_RUN=true ;;
      --verbose|-v)  VERBOSE=true ;;
      --app-path)
        [[ -n "${2:-}" ]] || die "--app-path requires a value."
        APP_PATH_OVERRIDE="$2"; shift
        ;;
      --app-path=*)  APP_PATH_OVERRIDE="${1#*=}" ;;
      -*)            die "Unknown option: $1. Run with --help for usage." ;;
      *)             TARGET_URL="$1" ;;
    esac
    shift
  done
}

# ── OS Detection ────────────────────────────────────────────────────────────

detect_os() {
  case "$(uname -s)" in
    Darwin)               OS="macos" ;;
    Linux)                OS="linux" ;;
    MINGW*|MSYS*|CYGWIN*) die "On Windows, use outline-mod.ps1 (PowerShell) instead of this script." ;;
    *)                    die "Unsupported OS: $(uname -s). This script supports macOS and Linux." ;;
  esac
  debug "OS: ${OS}"
}

# ── App Discovery ───────────────────────────────────────────────────────────

resolve_asar_from_path() {
  local p="$1"

  # Direct path to an .asar file
  if [[ -f "$p" && "$p" == *.asar ]]; then
    echo "$p"; return 0
  fi

  # Directory: try common sub-paths
  if [[ -d "$p" ]]; then
    local candidates=(
      "$p/Contents/Resources/app.asar"   # macOS .app bundle
      "$p/resources/app.asar"            # Electron app dir (Linux/Windows)
      "$p/app.asar"                      # Resources dir directly
    )
    for c in "${candidates[@]}"; do
      if [[ -f "$c" ]]; then
        echo "$c"; return 0
      fi
    done
  fi

  return 1
}

find_app() {
  # If user provided --app-path, use it
  if [[ -n "$APP_PATH_OVERRIDE" ]]; then
    ASAR="$(resolve_asar_from_path "$APP_PATH_OVERRIDE")" \
      || die "Could not find app.asar at: ${APP_PATH_OVERRIDE}
Use --app-path with the Outline app directory, resources directory, or direct path to app.asar."
    debug "Using --app-path override: ${ASAR}"
  else
    # Auto-detect based on OS
    local search_paths=()
    case "$OS" in
      macos)
        search_paths=(
          "/Applications/Outline.app/Contents/Resources/app.asar"
          "$HOME/Applications/Outline.app/Contents/Resources/app.asar"
        )
        ;;
      linux)
        # Check for snap first (read-only squashfs, cannot be patched)
        if [[ -f "/snap/outline/current/resources/app.asar" ]]; then
          die "Outline is installed as a snap package. Snap packages are read-only and cannot be patched in place.
Install Outline via .deb or direct download, then re-run this script."
        fi
        # Check for flatpak
        local flatpak_dir
        flatpak_dir="$(find "$HOME/.var/app" -maxdepth 3 -name "app.asar" -path "*[Oo]utline*" 2>/dev/null | head -1 || true)"
        if [[ -n "$flatpak_dir" ]]; then
          die "Outline appears installed via Flatpak at: ${flatpak_dir}
Flatpak sandboxing may prevent patching. Install via .deb or direct download instead,
or use --app-path to try patching at that location."
        fi

        search_paths=(
          "/opt/Outline/resources/app.asar"
          "/opt/outline/resources/app.asar"
          "/usr/lib/outline/resources/app.asar"
          "/usr/lib/outline-desktop/resources/app.asar"
          "/usr/share/outline/resources/app.asar"
          "$HOME/.local/share/outline/resources/app.asar"
          "$HOME/.local/lib/outline/resources/app.asar"
        )
        ;;
    esac

    for path in "${search_paths[@]}"; do
      if [[ -f "$path" ]]; then
        ASAR="$path"
        break
      fi
    done

    if [[ -z "$ASAR" ]]; then
      red "Outline not found in standard locations."
      echo "  Searched:"
      for p in "${search_paths[@]}"; do
        echo "    ${p}"
      done
      echo ""
      echo "  Use --app-path to specify a custom location:"
      echo "    ./outline-mod.sh --app-path /path/to/Outline https://your-url.com"
      exit 1
    fi
  fi

  RESOURCES_DIR="$(dirname "$ASAR")"
  BACKUP="${ASAR%.asar}-original.asar"

  # Derive APP_ROOT (for code signing on macOS)
  case "$OS" in
    macos)
      # Walk up from Resources/ to the .app bundle
      APP_ROOT="${RESOURCES_DIR}"
      while [[ "$APP_ROOT" != "/" && "$APP_ROOT" != *.app ]]; do
        APP_ROOT="$(dirname "$APP_ROOT")"
      done
      [[ "$APP_ROOT" == *.app ]] || APP_ROOT=""
      ;;
    linux)
      APP_ROOT="$(dirname "$RESOURCES_DIR")"
      ;;
  esac

  debug "ASAR:          ${ASAR}"
  debug "Backup:        ${BACKUP}"
  debug "Resources dir: ${RESOURCES_DIR}"
  debug "App root:      ${APP_ROOT:-<not resolved>}"
}

# ── Preflight Checks ───────────────────────────────────────────────────────

check_npx() {
  command -v npx >/dev/null 2>&1 \
    || die "npx not found. Install Node.js (https://nodejs.org or 'brew install node')."
  # Snapshot the npx cache so we can clean up only what we added
  snapshot_npx_cache
}

check_permissions() {
  if [[ ! -w "$RESOURCES_DIR" ]]; then
    red "No write permission for: ${RESOURCES_DIR}"
    echo ""
    if [[ "$EUID" -eq 0 ]]; then
      die "Already running as root but still no write permission. Check filesystem or mount flags."
    fi
    echo "  Re-run with sudo:"
    echo "    sudo $0 $*"
    exit 1
  fi
  debug "Write permission OK for ${RESOURCES_DIR}"
}

check_process() {
  local running=false

  case "$OS" in
    macos)
      pgrep -xq "Outline" 2>/dev/null && running=true
      ;;
    linux)
      pgrep -xiq "outline" 2>/dev/null && running=true
      ;;
  esac

  if ! $running; then
    debug "Outline is not running."
    return 0
  fi

  yellow "Outline is currently running."
  printf "  Quit Outline and continue? [Y/n] "

  if [[ ! -t 0 ]]; then
    # Non-interactive (piped input) — cannot prompt
    die "Outline is running. Quit it first, then re-run."
  fi

  read -r confirm
  if [[ "$confirm" =~ ^[Nn]$ ]]; then
    die "Aborted. Quit Outline first, then re-run."
  fi

  # Graceful quit
  case "$OS" in
    macos)
      osascript -e 'tell application "Outline" to quit' 2>/dev/null || true
      ;;
    linux)
      pkill -TERM -xi "outline" 2>/dev/null || true
      ;;
  esac

  # Wait up to 5 seconds
  local waited=0
  while (( waited < 10 )); do
    sleep 0.5
    waited=$((waited + 1))
    case "$OS" in
      macos) pgrep -xq "Outline" 2>/dev/null || { green "Outline quit."; return 0; } ;;
      linux)  pgrep -xiq "outline" 2>/dev/null || { green "Outline quit."; return 0; } ;;
    esac
  done

  die "Outline did not quit within 5 seconds. Close it manually, then re-run."
}

# ── URL Handling ────────────────────────────────────────────────────────────

normalize_url() {
  local url="$1"

  # Strip whitespace
  url="$(echo "$url" | xargs)"

  # Extract or default scheme
  local scheme host_and_rest
  if [[ "$url" =~ ^([a-zA-Z]+)://(.*) ]]; then
    scheme="$(echo "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')"
    host_and_rest="${BASH_REMATCH[2]}"
  else
    scheme="https"
    host_and_rest="$url"
  fi

  # Split host from path at the first /
  local host
  if [[ "$host_and_rest" == */* ]]; then
    host="${host_and_rest%%/*}"
  else
    host="$host_and_rest"
  fi

  # Lowercase the host (preserves port)
  host="$(echo "$host" | tr '[:upper:]' '[:lower:]')"

  echo "${scheme}://${host}"
}

validate_url() {
  local url="$1"

  # Must be https
  if [[ ! "$url" =~ ^https:// ]]; then
    die "URL must use HTTPS (Outline requires it for authentication). Got: ${url}"
  fi

  # Extract host (without scheme, without port)
  local hostport="${url#https://}"
  local host="${hostport%%:*}"

  # Must be a FQDN (contains a dot)
  if [[ "$host" != *.* ]]; then
    die "URL host must be a fully qualified domain (e.g., docs.example.com). Got: ${host}"
  fi

  # No invalid characters
  if [[ "$host" =~ [[:space:]] || "$host" =~ [^a-zA-Z0-9._-] ]]; then
    die "URL host contains invalid characters. Got: ${host}"
  fi

  # Validate port if present
  if [[ "$hostport" == *:* ]]; then
    local port="${hostport##*:}"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
      die "Invalid port number: ${port}"
    fi
  fi

  # Must not be the stock cloud URL
  if [[ "$url" == "$ORIGINAL_HOST" ]]; then
    die "That's the default Outline cloud URL. Provide your self-hosted instance URL."
  fi

  # Reachability check
  yellow "Checking reachability of ${url} ..."
  local http_code
  http_code="$(curl -s -o /dev/null -w '%{http_code}' -L --connect-timeout 5 --max-time 10 "$url" 2>/dev/null || true)"

  if [[ -z "$http_code" || "$http_code" == "000" ]]; then
    yellow "Could not reach ${url}. The server may be down or behind a VPN."
    if [[ -t 0 ]]; then
      printf "  Continue anyway? [y/N] "
      read -r confirm
      [[ "$confirm" =~ ^[Yy]$ ]] || die "Aborted."
    else
      die "Unreachable in non-interactive mode. Verify the URL and retry."
    fi
  else
    green "Reachable (HTTP ${http_code})."
  fi
}

prompt_url() {
  if [[ ! -t 0 ]]; then
    die "No URL provided. In non-interactive mode, pass the URL as an argument:
  outline-mod.sh https://your-instance.example.com"
  fi

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

# ── Integrity ───────────────────────────────────────────────────────────────

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

read_current_url() {
  local env_js="$1"
  # Match the production URL inside JS template-literal backticks in the host getter
  local url
  # shellcheck disable=SC2016 # backticks are literal (JS template syntax, not shell)
  url="$(grep -oE '`https://[^`]+`' "$env_js" 2>/dev/null | tr -d '`' | head -1)"
  echo "$url"
}

# ── Dry Run ─────────────────────────────────────────────────────────────────

show_dry_run() {
  local target_url="$1"
  local current_url="$2"

  echo ""
  bold "[DRY RUN] No changes will be made."
  echo ""
  echo "  Platform:      ${OS}"
  echo "  ASAR:          ${ASAR}"
  echo "  Backup:        ${BACKUP}"
  echo "  Current URL:   ${current_url}"
  echo "  Target URL:    ${target_url}"
  echo ""
  bold "  Actions that would be performed:"
  echo ""

  local n=1

  if [[ ! -f "$BACKUP" ]]; then
    echo "    ${n}. Back up app.asar"
    echo "       cp ${ASAR} ${BACKUP}"
    n=$((n+1))
    echo "    ${n}. Record SHA256 of original ASAR"
    n=$((n+1))
  else
    echo "    -  Backup already exists (skip)"
  fi

  echo "    ${n}. Extract ASAR to temp directory"
  n=$((n+1))
  echo "    ${n}. Patch build/env.js"
  echo "       ${current_url} → ${target_url}"
  n=$((n+1))
  echo "    ${n}. Repack to temporary ASAR, verify integrity"
  n=$((n+1))
  echo "    ${n}. Atomic swap: replace app.asar"
  n=$((n+1))

  if [[ "$OS" == "macos" && -n "$APP_ROOT" ]]; then
    echo "    ${n}. Re-sign application (ad-hoc)"
    echo "       codesign --force --deep --sign - ${APP_ROOT}"
    n=$((n+1))
    echo "    ${n}. Clear quarantine flag"
    echo "       xattr -cr ${APP_ROOT}"
    n=$((n+1))
  fi

  echo "    ${n}. Disable auto-updates"
  case "$OS" in
    macos) echo "       defaults write ${PLIST_DOMAIN} AutoUpdateDisabled -bool YES" ;;
    linux) echo "       (note: verify manually — mechanism varies by install method)" ;;
  esac

  n=$((n+1))
  echo "    ${n}. Clean up (remove temp files and cached @electron/asar)"
  echo ""
  green "  No changes were made. Remove --dry-run to apply."
  echo ""
}

# ── Core: Patch ─────────────────────────────────────────────────────────────

do_patch() {
  local target_url="$1"
  local total_steps=6
  [[ "$OS" == "macos" ]] && total_steps=7

  # ── Step 1: Backup ──
  step 1 "$total_steps" "Backing up original ASAR"
  if [[ -f "$BACKUP" ]]; then
    yellow "  Backup already exists — skipping."
    debug "  Backup: ${BACKUP}"
  else
    cp "$ASAR" "$BACKUP"
    local backup_hash
    backup_hash="$(sha256 "$BACKUP")"
    echo "$backup_hash" > "${BACKUP}.sha256"
    green "  Saved: ${BACKUP}"
    dim "  SHA256: ${backup_hash}"
  fi

  # ── Step 2: Extract ──
  step 2 "$total_steps" "Extracting ASAR archive"
  local extract_dir
  extract_dir="$(mktemp -d)/outline-mod"
  register_cleanup "$extract_dir"
  npx --yes @electron/asar extract "$ASAR" "$extract_dir" 2>/dev/null
  local env_js="${extract_dir}/build/env.js"
  [[ -f "$env_js" ]] || die "Extracted archive missing build/env.js. The app structure may have changed."
  green "  Extracted."

  # ── Step 3: Patch ──
  step 3 "$total_steps" "Patching build/env.js"
  local current_url
  current_url="$(read_current_url "$env_js")"
  if [[ -z "$current_url" ]]; then
    die "Could not locate the host URL in build/env.js. The app structure may have changed."
  fi

  if [[ "$current_url" != "$ORIGINAL_HOST" ]]; then
    yellow "  App is already modded to: ${current_url}"
  fi

  if [[ "$current_url" == "$target_url" ]]; then
    green "  Already patched to ${target_url}. Nothing to change."
    return 0
  fi

  # Use pipe delimiter for sed to avoid escaping slashes in URLs
  case "$OS" in
    macos) sed -i '' "s|${current_url}|${target_url}|g" "$env_js" ;;
    linux) sed -i "s|${current_url}|${target_url}|g" "$env_js" ;;
  esac

  if ! grep -q "$target_url" "$env_js"; then
    die "Patch failed: ${target_url} not found in env.js after replacement."
  fi
  green "  ${current_url} → ${target_url}"

  # ── Step 4: Repack (to temp file) ──
  step 4 "$total_steps" "Repacking ASAR archive"
  local tmp_asar="${ASAR}.tmp"
  register_cleanup "$tmp_asar"
  npx --yes @electron/asar pack "$extract_dir" "$tmp_asar" 2>/dev/null
  green "  Repacked to temporary file."

  # ── Step 5: Verify + atomic swap ──
  step 5 "$total_steps" "Verifying integrity and swapping"

  # Verify the temp ASAR contains the patched URL
  local verify_dir
  verify_dir="$(mktemp -d)/outline-verify"
  register_cleanup "$verify_dir"
  npx --yes @electron/asar extract "$tmp_asar" "$verify_dir" 2>/dev/null

  if ! grep -q "$target_url" "${verify_dir}/build/env.js"; then
    die "Verification failed: repacked ASAR does not contain ${target_url}."
  fi

  # Compare file counts (original backup vs patched)
  if [[ -f "$BACKUP" ]]; then
    local orig_count patch_count
    orig_count="$(npx --yes @electron/asar list "$BACKUP" 2>/dev/null | wc -l | tr -d ' ')"
    patch_count="$(npx --yes @electron/asar list "$tmp_asar" 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "$orig_count" != "$patch_count" ]]; then
      die "File count mismatch: original has ${orig_count} files, patched has ${patch_count}."
    fi
    debug "  File count: ${orig_count} (matches original)"
  fi

  # Atomic swap
  mv "$tmp_asar" "$ASAR"
  local patched_hash
  patched_hash="$(sha256 "$ASAR")"
  green "  Verified and swapped."
  dim "  SHA256: ${patched_hash}"

  # ── Step 6 (macOS): Re-sign ──
  local sign_step=6
  if [[ "$OS" == "macos" && -n "$APP_ROOT" ]]; then
    step "$sign_step" "$total_steps" "Re-signing application"
    codesign --force --deep --sign - "$APP_ROOT" 2>/dev/null
    green "  Ad-hoc code signature applied."

    # Clear quarantine
    xattr -cr "$APP_ROOT" 2>/dev/null || true

    # Verify signature
    if codesign --verify --deep "$APP_ROOT" 2>/dev/null; then
      debug "  Signature verification: passed"
    else
      yellow "  Signature verification returned non-zero (may be normal for ad-hoc)."
    fi
  fi

  # ── Final step: Disable auto-updates ──
  step "$total_steps" "$total_steps" "Disabling auto-updates"
  case "$OS" in
    macos)
      defaults write "$PLIST_DOMAIN" AutoUpdateDisabled -bool YES
      green "  Auto-updates disabled (macOS user defaults)."
      ;;
    linux)
      yellow "  Auto-update disable varies by install method on Linux."
      echo "    If installed via .deb: sudo apt-mark hold outline"
      echo "    If installed via AppImage: delete or rename the AppImage updater."
      echo "    In all cases: re-run this script after any manual update."
      ;;
  esac

  # ── Summary ──
  echo ""
  green "Done. Outline now points to ${target_url}"
  echo ""
  echo "  Next steps:"
  echo "    1. Launch Outline"
  echo "    2. Log in through your instance's auth flow"
  echo "    3. If auth redirect fails, see the README for a cookie-based fallback"
  echo ""
  echo "  To undo:  ./outline-mod.sh --rollback"
  echo "  To check: ./outline-mod.sh --status"
  echo ""
  dim "  Cleanup: temp files and cached dependencies will be removed on exit."
}

# ── Core: Rollback ──────────────────────────────────────────────────────────

do_rollback() {
  bold "Rolling back to original Outline"
  echo ""

  [[ -f "$BACKUP" ]] || die "No backup found at ${BACKUP}. Nothing to roll back."

  if $DRY_RUN; then
    echo "  [DRY RUN] Would restore: ${BACKUP} → ${ASAR}"
    [[ "$OS" == "macos" && -n "$APP_ROOT" ]] && echo "  [DRY RUN] Would re-sign: ${APP_ROOT}"
    echo "  [DRY RUN] Would re-enable auto-updates."
    echo ""
    green "  No changes were made."
    return 0
  fi

  cp "$BACKUP" "$ASAR"
  green "  Original ASAR restored."

  local hash
  hash="$(sha256 "$ASAR")"
  dim "  SHA256: ${hash}"

  # Verify against stored hash if available
  if [[ -f "${BACKUP}.sha256" ]]; then
    local stored_hash
    stored_hash="$(cat "${BACKUP}.sha256")"
    if [[ "$hash" == "$stored_hash" ]]; then
      green "  SHA256 matches original backup."
    else
      yellow "  SHA256 does not match stored backup hash."
      yellow "    Stored:  ${stored_hash}"
      yellow "    Current: ${hash}"
    fi
  fi

  if [[ "$OS" == "macos" && -n "$APP_ROOT" ]]; then
    codesign --force --deep --sign - "$APP_ROOT" 2>/dev/null
    green "  Code signature reapplied."
    xattr -cr "$APP_ROOT" 2>/dev/null || true
  fi

  case "$OS" in
    macos)
      defaults delete "$PLIST_DOMAIN" AutoUpdateDisabled 2>/dev/null || true
      green "  Auto-updates re-enabled."
      ;;
    linux)
      echo "  If you pinned the package version, unpin it:"
      echo "    sudo apt-mark unhold outline"
      ;;
  esac

  echo ""
  green "Rollback complete. Outline is back to ${ORIGINAL_HOST}."
}

# ── Core: Status ────────────────────────────────────────────────────────────

do_status() {
  bold "Outline Mod Status"
  echo ""

  [[ -f "$ASAR" ]] || die "app.asar not found at ${ASAR}."

  # Current URL
  local extract_dir
  extract_dir="$(mktemp -d)/outline-status"
  register_cleanup "$extract_dir"
  npx --yes @electron/asar extract "$ASAR" "$extract_dir" 2>/dev/null

  local current_url
  current_url="$(read_current_url "${extract_dir}/build/env.js")"

  if [[ "$current_url" == "$ORIGINAL_HOST" ]]; then
    echo "  Target URL:     ${current_url} (stock, unmodified)"
  else
    echo "  Target URL:     ${current_url} (modded)"
  fi

  echo "  Platform:       ${OS}"
  echo "  ASAR:           ${ASAR}"

  # SHA256 of current ASAR
  local current_hash
  current_hash="$(sha256 "$ASAR")"
  echo "  ASAR SHA256:    ${current_hash}"

  # Backup
  if [[ -f "$BACKUP" ]]; then
    echo "  Backup:         ${BACKUP}"
    local backup_hash
    backup_hash="$(sha256 "$BACKUP")"
    echo "  Backup SHA256:  ${backup_hash}"

    # Compare to stored hash
    if [[ -f "${BACKUP}.sha256" ]]; then
      local stored
      stored="$(cat "${BACKUP}.sha256")"
      if [[ "$backup_hash" == "$stored" ]]; then
        echo "  Backup intact:  yes (matches stored checksum)"
      else
        red "  Backup intact:  NO — hash mismatch"
        echo "    Stored:  ${stored}"
        echo "    Actual:  ${backup_hash}"
      fi
    fi

    # File count comparison
    local orig_count current_count
    orig_count="$(npx --yes @electron/asar list "$BACKUP" 2>/dev/null | wc -l | tr -d ' ')"
    current_count="$(npx --yes @electron/asar list "$ASAR" 2>/dev/null | wc -l | tr -d ' ')"
    echo "  File count:     ${current_count} (backup: ${orig_count})"
  else
    echo "  Backup:         none"
  fi

  # Auto-update setting
  case "$OS" in
    macos)
      local autoupdate
      autoupdate="$(defaults read "$PLIST_DOMAIN" AutoUpdateDisabled 2>/dev/null || echo "not set")"
      echo "  Auto-updates:   AutoUpdateDisabled=${autoupdate}"
      ;;
    linux)
      echo "  Auto-updates:   (check package manager)"
      ;;
  esac

  # Code signature (macOS)
  if [[ "$OS" == "macos" && -n "$APP_ROOT" ]]; then
    if codesign --verify --deep "$APP_ROOT" 2>/dev/null; then
      echo "  Code signature: valid"
    else
      echo "  Code signature: invalid or missing"
    fi
  fi

  echo ""
}

# ── Main ────────────────────────────────────────────────────────────────────

main() {
  parse_args "$@"
  detect_os
  find_app
  check_npx

  case "$COMMAND" in
    rollback)
      if ! $DRY_RUN; then
        check_permissions "$@"
        check_process
      fi
      do_rollback
      ;;
    status)
      do_status
      ;;
    patch)
      if ! $DRY_RUN; then
        check_permissions "$@"
        check_process
      fi

      # Get the URL
      local raw_url
      if [[ -n "$TARGET_URL" ]]; then
        raw_url="$TARGET_URL"
      else
        raw_url="$(prompt_url)"
      fi

      local target_url
      target_url="$(normalize_url "$raw_url")"
      validate_url "$target_url"

      # Read current URL for dry-run display
      if $DRY_RUN; then
        local tmp_read
        tmp_read="$(mktemp -d)/outline-dryrun"
        register_cleanup "$tmp_read"
        npx --yes @electron/asar extract "$ASAR" "$tmp_read" 2>/dev/null
        local current_url
        current_url="$(read_current_url "${tmp_read}/build/env.js")"
        show_dry_run "$target_url" "${current_url:-unknown}"
        exit 0
      fi

      # Confirm
      echo ""
      bold "Will patch Outline to connect to: ${target_url}"
      if [[ -t 0 ]]; then
        printf "Proceed? [Y/n] "
        read -r confirm
        if [[ "$confirm" =~ ^[Nn]$ ]]; then
          die "Aborted."
        fi
      fi
      echo ""

      do_patch "$target_url"
      ;;
  esac
}

main "$@"
