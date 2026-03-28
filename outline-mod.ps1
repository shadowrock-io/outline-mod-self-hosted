<#
.SYNOPSIS
    Patch the Outline desktop app to connect to a self-hosted instance (Windows).

.DESCRIPTION
    Modifies one URL string in the Outline desktop app's ASAR archive so it
    connects to your self-hosted Outline instance instead of app.getoutline.com.

    For macOS/Linux, use outline-mod.sh (Bash) instead.

.PARAMETER Url
    The root URL of your self-hosted Outline instance (e.g., https://docs.example.com).
    If omitted, you'll be prompted interactively.

.PARAMETER Rollback
    Restore the original unmodified app from backup.

.PARAMETER Status
    Show the current mod state, checksums, and configuration.

.PARAMETER DryRun
    Show what would happen without changing anything.

.PARAMETER AppPath
    Override the auto-detected Outline installation path.

.PARAMETER Help
    Show usage information.

.EXAMPLE
    .\outline-mod.ps1 https://docs.example.com
    .\outline-mod.ps1 -Rollback
    .\outline-mod.ps1 -Status
    .\outline-mod.ps1 -DryRun https://docs.example.com
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Url,

    [switch]$Rollback,
    [switch]$Status,
    [switch]$DryRun,
    [string]$AppPath,
    [switch]$Help
)

$ErrorActionPreference = "Stop"
$Script:Version = "2.0.0"
$Script:OriginalHost = "https://app.getoutline.com"
$Script:Asar = ""
$Script:Backup = ""
$Script:ResourcesDir = ""
$Script:NpxAsarPreexisted = $false

# ── Output Helpers ──────────────────────────────────────────────────────────

function Write-Red($msg)    { Write-Host $msg -ForegroundColor Red }
function Write-Green($msg)  { Write-Host $msg -ForegroundColor Green }
function Write-Yellow($msg) { Write-Host $msg -ForegroundColor Yellow }
function Write-Bold($msg)   { Write-Host $msg -ForegroundColor White }
function Write-Dim($msg)    { Write-Host $msg -ForegroundColor DarkGray }

function Write-Step($num, $total, $msg) {
    Write-Bold "[$num/$total] $msg"
}

function Stop-WithError($msg) {
    Write-Red "Error: $msg"
    exit 1
}

# ── Usage ───────────────────────────────────────────────────────────────────

function Show-Usage {
    Write-Host @"
Outline Desktop App - Self-Hosted Mod v$($Script:Version) (Windows)

USAGE
  .\outline-mod.ps1 [url]                Patch (interactive if no url)
  .\outline-mod.ps1 -Rollback            Restore original unmodified app
  .\outline-mod.ps1 -Status              Show current mod state
  .\outline-mod.ps1 -DryRun [url]        Preview actions without changes

OPTIONS
  -Url <url>          Self-hosted Outline URL
  -Rollback           Restore the original app
  -Status             Show current state and checksums
  -DryRun             Preview mode (no modifications)
  -AppPath <path>     Override auto-detected install location
  -Help               Show this message

EXAMPLES
  .\outline-mod.ps1 https://docs.example.com
  .\outline-mod.ps1 -DryRun https://docs.example.com
  .\outline-mod.ps1 -AppPath "D:\Programs\Outline" https://docs.example.com
  .\outline-mod.ps1 -Rollback
  .\outline-mod.ps1 -Status

PERMISSIONS
  Per-user installs (typical): no elevation needed.
  System-wide installs (Program Files): run as Administrator.

AUDITING
  This script is a single file. Read it before running.
  Use -DryRun to preview all actions without modifying anything.
"@
    exit 0
}

# ── Cleanup ─────────────────────────────────────────────────────────────────

function Snapshot-NpxCache {
    try {
        $npmCache = (npm config get cache 2>$null)
        $npxDir = Join-Path $npmCache "_npx"
        if (Test-Path $npxDir) {
            Get-ChildItem $npxDir -Directory | ForEach-Object {
                $asarPath = Join-Path $_.FullName "node_modules\@electron\asar"
                if (Test-Path $asarPath) {
                    $Script:NpxAsarPreexisted = $true
                }
            }
        }
    } catch { }
}

function Clean-NpxCache {
    if ($Script:NpxAsarPreexisted) { return }
    try {
        # Skip if globally installed
        $globalCheck = npm list -g "@electron/asar" 2>$null
        if ($globalCheck -match "@electron/asar") { return }

        $npmCache = (npm config get cache 2>$null)
        $npxDir = Join-Path $npmCache "_npx"
        if (Test-Path $npxDir) {
            Get-ChildItem $npxDir -Directory | ForEach-Object {
                $asarPath = Join-Path $_.FullName "node_modules\@electron\asar"
                if (Test-Path $asarPath) {
                    Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
    } catch { }
}

# ── App Discovery ───────────────────────────────────────────────────────────

function Find-OutlineApp {
    if ($AppPath) {
        # User-provided path
        $candidates = @(
            (Join-Path $AppPath "resources\app.asar"),
            (Join-Path $AppPath "app.asar")
        )
        foreach ($c in $candidates) {
            if (Test-Path $c) {
                $Script:Asar = $c
                break
            }
        }
        if (-not $Script:Asar) {
            # Maybe they pointed directly at the asar
            if ((Test-Path $AppPath) -and $AppPath.EndsWith(".asar")) {
                $Script:Asar = $AppPath
            } else {
                Stop-WithError "Could not find app.asar at: $AppPath"
            }
        }
    } else {
        # Auto-detect
        $searchPaths = @(
            (Join-Path $env:LOCALAPPDATA "Programs\Outline\resources\app.asar"),
            (Join-Path $env:LOCALAPPDATA "Programs\outline\resources\app.asar")
        )
        if ($env:PROGRAMFILES) {
            $searchPaths += (Join-Path $env:PROGRAMFILES "Outline\resources\app.asar")
        }
        if (${env:PROGRAMFILES(X86)}) {
            $searchPaths += (Join-Path ${env:PROGRAMFILES(X86)} "Outline\resources\app.asar")
        }

        foreach ($p in $searchPaths) {
            if (Test-Path $p) {
                $Script:Asar = $p
                break
            }
        }

        if (-not $Script:Asar) {
            Write-Red "Outline not found in standard locations."
            Write-Host "  Searched:"
            foreach ($p in $searchPaths) {
                Write-Host "    $p"
            }
            Write-Host ""
            Write-Host "  Use -AppPath to specify a custom location:"
            Write-Host '    .\outline-mod.ps1 -AppPath "C:\path\to\Outline" https://your-url.com'
            exit 1
        }
    }

    $Script:ResourcesDir = Split-Path $Script:Asar -Parent
    $Script:Backup = $Script:Asar -replace '\.asar$', '-original.asar'
}

# ── Preflight ───────────────────────────────────────────────────────────────

function Test-Npx {
    try {
        $null = Get-Command npx -ErrorAction Stop
    } catch {
        Stop-WithError "npx not found. Install Node.js from https://nodejs.org"
    }
    Snapshot-NpxCache
}

function Test-Permissions {
    try {
        $testFile = Join-Path $Script:ResourcesDir ".outline-mod-test"
        [System.IO.File]::Create($testFile).Dispose()
        Remove-Item $testFile -Force
    } catch {
        Write-Red "No write permission for: $($Script:ResourcesDir)"
        Write-Host ""
        Write-Host "  Run PowerShell as Administrator and try again."
        exit 1
    }
}

function Test-Process {
    $proc = Get-Process -Name "Outline" -ErrorAction SilentlyContinue
    if (-not $proc) { return }

    Write-Yellow "Outline is currently running."
    $confirm = Read-Host "  Quit Outline and continue? [Y/n]"
    if ($confirm -match '^[Nn]$') {
        Stop-WithError "Aborted. Quit Outline first, then re-run."
    }

    # Graceful close
    $proc | ForEach-Object { $_.CloseMainWindow() | Out-Null }

    # Wait up to 5 seconds
    $waited = 0
    while ($waited -lt 10) {
        Start-Sleep -Milliseconds 500
        $waited++
        $proc = Get-Process -Name "Outline" -ErrorAction SilentlyContinue
        if (-not $proc) {
            Write-Green "  Outline quit."
            return
        }
    }

    Stop-WithError "Outline did not quit within 5 seconds. Close it manually, then re-run."
}

# ── URL Handling ────────────────────────────────────────────────────────────

function Normalize-Url([string]$rawUrl) {
    $rawUrl = $rawUrl.Trim()

    # Extract or default scheme
    if ($rawUrl -match '^([a-zA-Z]+)://(.*)') {
        $scheme = $Matches[1].ToLower()
        $hostAndRest = $Matches[2]
    } else {
        $scheme = "https"
        $hostAndRest = $rawUrl
    }

    # Split host from path
    $slashIdx = $hostAndRest.IndexOf('/')
    if ($slashIdx -ge 0) {
        $hostPart = $hostAndRest.Substring(0, $slashIdx)
    } else {
        $hostPart = $hostAndRest
    }

    $hostPart = $hostPart.ToLower()
    return "${scheme}://${hostPart}"
}

function Validate-Url([string]$url) {
    if (-not $url.StartsWith("https://")) {
        Stop-WithError "URL must use HTTPS (Outline requires it for authentication). Got: $url"
    }

    $hostport = $url.Substring(8)  # strip https://
    $host = ($hostport -split ':')[0]

    if (-not $host.Contains('.')) {
        Stop-WithError "URL host must be a fully qualified domain (e.g., docs.example.com). Got: $host"
    }

    if ($host -match '[^a-zA-Z0-9.\-]') {
        Stop-WithError "URL host contains invalid characters. Got: $host"
    }

    if ($hostport -match ':(\d+)$') {
        $port = [int]$Matches[1]
        if ($port -lt 1 -or $port -gt 65535) {
            Stop-WithError "Invalid port number: $port"
        }
    }

    if ($url -eq $Script:OriginalHost) {
        Stop-WithError "That's the default Outline cloud URL. Provide your self-hosted instance URL."
    }

    # Reachability check
    Write-Yellow "Checking reachability of $url ..."
    try {
        $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10 -MaximumRedirection 5 -ErrorAction Stop
        Write-Green "Reachable (HTTP $($response.StatusCode))."
    } catch {
        Write-Yellow "Could not reach $url. The server may be down or behind a VPN."
        $confirm = Read-Host "  Continue anyway? [y/N]"
        if ($confirm -notmatch '^[Yy]$') {
            Stop-WithError "Aborted."
        }
    }
}

function Prompt-Url {
    Write-Host ""
    Write-Bold "Outline Desktop App - Self-Hosted Mod"
    Write-Host ""
    Write-Host "Enter the root URL of your self-hosted Outline instance."
    Write-Host "Examples: https://docs.example.com, https://outline.company.io:8443"
    Write-Host ""
    $input = Read-Host "Outline URL"
    if (-not $input) { Stop-WithError "No URL provided." }
    return $input
}

# ── Integrity ───────────────────────────────────────────────────────────────

function Get-Sha256($path) {
    return (Get-FileHash -Algorithm SHA256 $path).Hash.ToLower()
}

function Get-CurrentUrl($envJsPath) {
    $content = Get-Content $envJsPath -Raw
    if ($content -match '`(https://[^`]+)`') {
        return $Matches[1]
    }
    return $null
}

# ── Dry Run ─────────────────────────────────────────────────────────────────

function Show-DryRun($targetUrl, $currentUrl) {
    Write-Host ""
    Write-Bold "[DRY RUN] No changes will be made."
    Write-Host ""
    Write-Host "  Platform:      Windows"
    Write-Host "  ASAR:          $($Script:Asar)"
    Write-Host "  Backup:        $($Script:Backup)"
    Write-Host "  Current URL:   $currentUrl"
    Write-Host "  Target URL:    $targetUrl"
    Write-Host ""
    Write-Bold "  Actions that would be performed:"
    Write-Host ""

    $n = 1
    if (-not (Test-Path $Script:Backup)) {
        Write-Host "    $n. Back up app.asar"
        $n++
        Write-Host "    $n. Record SHA256 of original ASAR"
        $n++
    } else {
        Write-Host "    -  Backup already exists (skip)"
    }

    Write-Host "    $n. Extract ASAR to temp directory"
    $n++
    Write-Host "    $n. Patch build/env.js"
    Write-Host "       $currentUrl -> $targetUrl"
    $n++
    Write-Host "    $n. Repack to temporary ASAR, verify integrity"
    $n++
    Write-Host "    $n. Atomic swap: replace app.asar"
    $n++
    Write-Host "    $n. Clear cached session URL from Electron config.json"
    $n++
    Write-Host "    $n. Clean up (remove temp files and cached @electron/asar)"
    Write-Host ""
    Write-Green "  No changes were made. Remove -DryRun to apply."
    Write-Host ""
}

# ── Core: Patch ─────────────────────────────────────────────────────────────

function Invoke-Patch([string]$targetUrl) {
    $totalSteps = 7

    # Step 1: Backup
    Write-Step 1 $totalSteps "Backing up original ASAR"
    if (Test-Path $Script:Backup) {
        Write-Yellow "  Backup already exists - skipping."
    } else {
        Copy-Item $Script:Asar $Script:Backup
        $hash = Get-Sha256 $Script:Backup
        Set-Content -Path "$($Script:Backup).sha256" -Value $hash -NoNewline
        Write-Green "  Saved: $($Script:Backup)"
        Write-Dim "  SHA256: $hash"
    }

    # Step 2: Extract
    Write-Step 2 $totalSteps "Extracting ASAR archive"
    $extractDir = Join-Path ([System.IO.Path]::GetTempPath()) "outline-mod-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    npx --yes "@electron/asar" extract $Script:Asar $extractDir 2>$null
    $envJs = Join-Path $extractDir "build\env.js"
    if (-not (Test-Path $envJs)) {
        Stop-WithError "Extracted archive missing build\env.js. The app structure may have changed."
    }
    Write-Green "  Extracted."

    # Step 3: Patch
    Write-Step 3 $totalSteps "Patching build\env.js"
    $currentUrl = Get-CurrentUrl $envJs
    if (-not $currentUrl) {
        Stop-WithError "Could not locate the host URL in build\env.js."
    }

    if ($currentUrl -ne $Script:OriginalHost) {
        Write-Yellow "  App is already modded to: $currentUrl"
    }

    if ($currentUrl -eq $targetUrl) {
        Write-Green "  Already patched to $targetUrl. Nothing to change."
        Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
        return
    }

    $content = Get-Content $envJs -Raw
    $content = $content.Replace($currentUrl, $targetUrl)
    Set-Content -Path $envJs -Value $content -NoNewline

    if (-not (Get-Content $envJs -Raw).Contains($targetUrl)) {
        Stop-WithError "Patch failed: $targetUrl not found in env.js after replacement."
    }
    Write-Green "  $currentUrl -> $targetUrl"

    # Step 4: Patch auth flow (in-app OAuth popup)
    Write-Step 4 $totalSteps "Patching auth flow for in-app OAuth"

    # Use the same Node.js patcher as the bash script (node is already a dependency)
    $patcherPath = Join-Path $extractDir "_patcher.js"
    $patcherContent = @'
const fs = require("fs");
const path = require("path");
const dir = process.argv[2];
const uhPath = path.join(dir, "build/utils/URLHelper.js");
let uh = fs.readFileSync(uhPath, "utf8");
const uhOld = '            parsedUrl.pathname.startsWith("/share/") ||\n            parsedUrl.pathname.startsWith("/auth/"));';
const uhNew = '            parsedUrl.pathname.startsWith("/share/"));';
if (!uh.includes(uhOld)) { console.error("URLHelper.js: /auth/ pattern not found"); process.exit(1); }
uh = uh.replace(uhOld, uhNew);
fs.writeFileSync(uhPath, uh);
const awPath = path.join(dir, "build/AppWindow.js");
let aw = fs.readFileSync(awPath, "utf8");
const navOld = `        this.handleNavigation = (event, targetUrl) => {\n            if (URLHelper_1.default.isExternal(targetUrl)) {\n                event.preventDefault();\n                void electron_1.shell.openExternal(targetUrl);\n                return false;\n            }\n            return true;\n        };`;
const navNew = `        this.handleNavigation = (event, targetUrl) => {\n            try {\n                var targetParsed = new URL(targetUrl);\n                var appHost = new URL(env_1.default.host).host;\n                if (targetParsed.host === appHost && targetParsed.pathname.startsWith("/auth")) {\n                    event.preventDefault();\n                    this._openAuthPopup(targetUrl, appHost);\n                    return false;\n                }\n            } catch (e) {}\n            if (URLHelper_1.default.isExternal(targetUrl)) {\n                event.preventDefault();\n                void electron_1.shell.openExternal(targetUrl);\n                return false;\n            }\n            return true;\n        };`;
if (!aw.includes(navOld)) { console.error("AppWindow.js: handleNavigation pattern not found"); process.exit(1); }
aw = aw.replace(navOld, navNew);
const exportLine = "exports.default = AppWindow;";
const popup = `\nAppWindow.prototype._openAuthPopup = function(authUrl, appHost) {\n    var mainWindow = this;\n    var authWin = new electron_1.BrowserWindow({\n        width: 520, height: 720, title: "Sign in", show: true,\n        titleBarStyle: "default",\n        webPreferences: { contextIsolation: true, nodeIntegration: false }\n    });\n    var ua = authWin.webContents.getUserAgent();\n    authWin.webContents.setUserAgent(ua.replace(/ Electron\\/[\\d.]+/, "").replace(/ Outline\\/[\\d.]+/, ""));\n    authWin.webContents.on("did-finish-load", function() {\n        authWin.webContents.insertCSS("html, body, body * { -webkit-app-region: no-drag !important; }");\n    });\n    authWin.webContents.on("did-navigate", function(navEvt, navUrl) {\n        authWin.webContents.insertCSS("html, body, body * { -webkit-app-region: no-drag !important; }");\n        checkAuthComplete(navUrl);\n    });\n    authWin.loadURL(authUrl);\n    authWin.webContents.setWindowOpenHandler(function(details) {\n        setTimeout(function() { authWin.webContents.loadURL(details.url); }, 50);\n        return { action: "deny" };\n    });\n    function checkAuthComplete(url) {\n        try {\n            var parsed = new URL(url);\n            if (parsed.host === appHost && !parsed.pathname.startsWith("/auth/")) {\n                authWin.close();\n                mainWindow.loadURL(url);\n                return true;\n            }\n        } catch(e) {}\n        return false;\n    }\n    authWin.webContents.on("will-navigate", function(evt, url) {\n        if (checkAuthComplete(url)) { evt.preventDefault(); }\n    });\n    authWin.webContents.on("will-redirect", function(evt, url) {\n        if (checkAuthComplete(url)) { evt.preventDefault(); }\n    });\n};\n` + exportLine;
if (!aw.includes(exportLine)) { console.error("AppWindow.js: export pattern not found"); process.exit(1); }
aw = aw.replace(exportLine, popup);
fs.writeFileSync(awPath, aw);
'@
    Set-Content -Path $patcherPath -Value $patcherContent
    $patchResult = & node $patcherPath $extractDir 2>&1
    if ($LASTEXITCODE -ne 0) {
        Stop-WithError "Auth flow patch failed: $patchResult"
    }
    Remove-Item $patcherPath -Force -ErrorAction SilentlyContinue
    Write-Green "  Auth flow patched for in-app OAuth."

    # Step 5: Repack + verify
    Write-Step 5 $totalSteps "Repacking and verifying"
    $tmpAsar = "$($Script:Asar).tmp"
    npx --yes "@electron/asar" pack $extractDir $tmpAsar 2>$null

    # Verify
    $verifyDir = Join-Path ([System.IO.Path]::GetTempPath()) "outline-verify-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    npx --yes "@electron/asar" extract $tmpAsar $verifyDir 2>$null
    $verifyEnvJs = Join-Path $verifyDir "build\env.js"
    if (-not (Get-Content $verifyEnvJs -Raw).Contains($targetUrl)) {
        Stop-WithError "Verification failed: repacked ASAR does not contain $targetUrl."
    }

    # File count check
    if (Test-Path $Script:Backup) {
        $origCount = (npx --yes "@electron/asar" list $Script:Backup 2>$null | Measure-Object -Line).Lines
        $patchCount = (npx --yes "@electron/asar" list $tmpAsar 2>$null | Measure-Object -Line).Lines
        if ($origCount -ne $patchCount) {
            Stop-WithError "File count mismatch: original=$origCount, patched=$patchCount."
        }
    }

    # Atomic swap
    Move-Item $tmpAsar $Script:Asar -Force
    $patchedHash = Get-Sha256 $Script:Asar
    Write-Green "  Verified and swapped."
    Write-Dim "  SHA256: $patchedHash"

    # Cleanup temp dirs
    Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $verifyDir -Recurse -Force -ErrorAction SilentlyContinue

    # Step 6: Clear cached session URL
    Write-Step 6 $totalSteps "Clearing cached session URL"
    $configDir = Join-Path $env:APPDATA "Outline"
    if (-not (Test-Path $configDir)) {
        $configDir = Join-Path $env:APPDATA "outline"
    }
    $configFile = Join-Path $configDir "config.json"
    if (Test-Path $configFile) {
        $oldContent = Get-Content $configFile -Raw -ErrorAction SilentlyContinue
        Set-Content -Path $configFile -Value '{}' -NoNewline
        if ($oldContent -match '"url"') {
            Write-Green "  Cleared cached URL from config.json"
        } else {
            Write-Green "  config.json reset."
        }
    } else {
        Write-Dim "  No config.json found — nothing to clear."
    }

    # Step 7: Auto-update note
    Write-Step 7 $totalSteps "Auto-update guidance"
    Write-Yellow "  Auto-update disable on Windows varies by install method."
    Write-Host "    The app may update itself and overwrite this patch."
    Write-Host "    Re-run this script after any Outline update."

    # Summary
    Write-Host ""
    Write-Green "Done. Outline now points to $targetUrl"
    Write-Host ""
    Write-Host "  Next steps:"
    Write-Host "    1. Launch Outline"
    Write-Host "    2. Log in through your instance's auth flow"
    Write-Host ""
    Write-Host "  To undo:  .\outline-mod.ps1 -Rollback"
    Write-Host "  To check: .\outline-mod.ps1 -Status"
    Write-Host ""
    Write-Dim "  Cleanup: temp files and cached dependencies removed."

    # Clean npx cache
    Clean-NpxCache
}

# ── Core: Rollback ──────────────────────────────────────────────────────────

function Invoke-Rollback {
    Write-Bold "Rolling back to original Outline"
    Write-Host ""

    if (-not (Test-Path $Script:Backup)) {
        Stop-WithError "No backup found at $($Script:Backup). Nothing to roll back."
    }

    if ($DryRun) {
        Write-Host "  [DRY RUN] Would restore: $($Script:Backup) -> $($Script:Asar)"
        Write-Host ""
        Write-Green "  No changes were made."
        return
    }

    Copy-Item $Script:Backup $Script:Asar -Force
    Write-Green "  Original ASAR restored."

    $hash = Get-Sha256 $Script:Asar
    Write-Dim "  SHA256: $hash"

    # Verify against stored hash
    $sha256File = "$($Script:Backup).sha256"
    if (Test-Path $sha256File) {
        $stored = (Get-Content $sha256File -Raw).Trim()
        if ($hash -eq $stored) {
            Write-Green "  SHA256 matches original backup."
        } else {
            Write-Yellow "  SHA256 does not match stored backup hash."
            Write-Yellow "    Stored:  $stored"
            Write-Yellow "    Current: $hash"
        }
    }

    Write-Host ""
    Write-Green "Rollback complete. Outline is back to $($Script:OriginalHost)."
}

# ── Core: Status ────────────────────────────────────────────────────────────

function Show-Status {
    Write-Bold "Outline Mod Status"
    Write-Host ""

    if (-not (Test-Path $Script:Asar)) {
        Stop-WithError "app.asar not found at $($Script:Asar)."
    }

    # Extract to read current URL
    $extractDir = Join-Path ([System.IO.Path]::GetTempPath()) "outline-status-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    npx --yes "@electron/asar" extract $Script:Asar $extractDir 2>$null
    $envJs = Join-Path $extractDir "build\env.js"
    $currentUrl = Get-CurrentUrl $envJs
    Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue

    if ($currentUrl -eq $Script:OriginalHost) {
        Write-Host "  Target URL:     $currentUrl (stock, unmodified)"
    } else {
        Write-Host "  Target URL:     $currentUrl (modded)"
    }

    Write-Host "  Platform:       Windows"
    Write-Host "  ASAR:           $($Script:Asar)"

    $currentHash = Get-Sha256 $Script:Asar
    Write-Host "  ASAR SHA256:    $currentHash"

    if (Test-Path $Script:Backup) {
        Write-Host "  Backup:         $($Script:Backup)"
        $backupHash = Get-Sha256 $Script:Backup
        Write-Host "  Backup SHA256:  $backupHash"

        $sha256File = "$($Script:Backup).sha256"
        if (Test-Path $sha256File) {
            $stored = (Get-Content $sha256File -Raw).Trim()
            if ($backupHash -eq $stored) {
                Write-Host "  Backup intact:  yes (matches stored checksum)"
            } else {
                Write-Red "  Backup intact:  NO - hash mismatch"
            }
        }
    } else {
        Write-Host "  Backup:         none"
    }

    Write-Host ""

    # Clean npx cache
    Clean-NpxCache
}

# ── Main ────────────────────────────────────────────────────────────────────

if ($Help) { Show-Usage }

Find-OutlineApp
Test-Npx

if ($Rollback) {
    if (-not $DryRun) {
        Test-Permissions
        Test-Process
    }
    Invoke-Rollback
    Clean-NpxCache
    exit 0
}

if ($Status) {
    Show-Status
    exit 0
}

# Patch mode
if (-not $DryRun) {
    Test-Permissions
    Test-Process
}

# Get URL
if (-not $Url) {
    $Url = Prompt-Url
}

$targetUrl = Normalize-Url $Url
Validate-Url $targetUrl

if ($DryRun) {
    $extractDir = Join-Path ([System.IO.Path]::GetTempPath()) "outline-dryrun-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    npx --yes "@electron/asar" extract $Script:Asar $extractDir 2>$null
    $currentUrl = Get-CurrentUrl (Join-Path $extractDir "build\env.js")
    Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    Show-DryRun $targetUrl ($currentUrl ?? "unknown")
    Clean-NpxCache
    exit 0
}

# Confirm
Write-Host ""
Write-Bold "Will patch Outline to connect to: $targetUrl"
$confirm = Read-Host "Proceed? [Y/n]"
if ($confirm -match '^[Nn]$') {
    Stop-WithError "Aborted."
}
Write-Host ""

Invoke-Patch $targetUrl
