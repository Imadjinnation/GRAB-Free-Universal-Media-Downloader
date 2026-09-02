# uninstall.ps1
# Cleanly removes grab-app from a machine. Preserves downloads.
#
# Removes (silently):
#   - Running tray process
#   - Desktop shortcuts (grab.lnk, grab Downloads.lnk)
#   - Autostart entry (shell:startup\grab.lnk)
#
# Asks before removing:
#   - App-data folder (%APPDATA%\grab-app\  -- configs, queue, recent history, logs)
#   - pip packages (yt-dlp, gallery-dl, BurntToast) -- other tools may use them
#
# NEVER touches:
#   - Files you have downloaded (~\Downloads\imadjinn-grab\ or whatever you set)
#   - The grab source code (this repo)
#   - ffmpeg
#
# Usage:
#   .\uninstall.ps1            interactive (prompts before removing data / packages)
#   .\uninstall.ps1 -Yes       remove everything without asking (state + packages)
#   .\uninstall.ps1 -KeepState never remove app-data folder (only remove shortcuts / tray)

[CmdletBinding()]
param(
    [switch]$Yes,
    [switch]$KeepState
)

$ErrorActionPreference = 'Continue'
$script:Removed = @()
$script:Kept    = @()

function Say([string]$msg, [string]$color = 'Gray') { Write-Host "  $msg" -ForegroundColor $color }
function Section([string]$t) { Write-Host ""; Write-Host "  == $t ==" -ForegroundColor Cyan }
function Ok  ([string]$msg) { Say "OK    $msg" 'Green';   $script:Removed += $msg }
function Skip([string]$msg) { Say "SKIP  $msg" 'DarkGray'; $script:Kept    += $msg }
function Warn([string]$msg) { Say "WARN  $msg" 'Yellow' }

Write-Host ""
Write-Host "  grab -- uninstall" -ForegroundColor White
Write-Host "  ----------------" -ForegroundColor DarkGray
Write-Host "  Your downloaded files will NOT be touched." -ForegroundColor DarkGray

# --- 1. Stop any running tray -------------------------------------------
Section 'Tray process'
$tray = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandLine -match '-File\s+[''"]?[A-Za-z]:\\[^"]*grab-app\.ps1[''"]?' -and
            $_.CommandLine -notlike '*Start-Process*'
        }
if ($tray) {
    foreach ($t in $tray) {
        try { Stop-Process -Id $t.ProcessId -Force -ErrorAction SilentlyContinue; Ok "stopped tray PID $($t.ProcessId)" } catch { Warn "couldn't stop PID $($t.ProcessId): $_" }
    }
} else {
    Skip 'no running tray'
}

# --- 2. Desktop shortcuts -----------------------------------------------
Section 'Desktop shortcuts'
$Desktop = [Environment]::GetFolderPath('Desktop')
foreach ($name in @('grab.lnk','grab Downloads.lnk','Grab (paste).lnk','Grab (drop).lnk','Grab Downloads.lnk')) {
    $p = Join-Path $Desktop $name
    if (Test-Path -LiteralPath $p) {
        try { Remove-Item -LiteralPath $p -Force -ErrorAction Stop; Ok "removed $name" } catch { Warn "couldn't remove $name : $_" }
    }
}

# --- 3. Autostart entry -------------------------------------------------
Section 'Autostart'
$startup = [Environment]::GetFolderPath('Startup')
$startLnk = Join-Path $startup 'grab.lnk'
if (Test-Path -LiteralPath $startLnk) {
    try { Remove-Item -LiteralPath $startLnk -Force -ErrorAction Stop; Ok 'removed shell:startup\grab.lnk' } catch { Warn "couldn't remove startup: $_" }
} else {
    Skip 'no autostart entry'
}

# --- 4. App-data folder -------------------------------------------------
Section 'App data'
$appData = Join-Path $env:APPDATA 'grab-app'
if (Test-Path -LiteralPath $appData) {
    $doIt = $Yes
    if (-not $KeepState -and -not $Yes) {
        Write-Host ""
        Write-Host "  Remove %APPDATA%\grab-app\ ?" -ForegroundColor Yellow
        Write-Host "  This deletes your settings, active queue, recent history, and logs." -ForegroundColor DarkGray
        Write-Host "  Your downloaded files are separate and stay put." -ForegroundColor DarkGray
        $ans = Read-Host "  [y/N]"
        $doIt = ($ans -match '^(y|yes)$')
    }
    if ($KeepState) { $doIt = $false }
    if ($doIt) {
        try { Remove-Item -LiteralPath $appData -Recurse -Force -ErrorAction Stop; Ok "removed $appData" }
        catch { Warn "couldn't remove app-data: $_" }
    } else {
        Skip "$appData kept (settings + queue + history + logs still there)"
    }
} else {
    Skip 'no app-data folder'
}

# --- 5. pip packages ----------------------------------------------------
Section 'pip packages (yt-dlp, gallery-dl, BurntToast)'
$doPkg = $Yes
if (-not $Yes) {
    Write-Host ""
    Write-Host "  Uninstall pip packages: yt-dlp, gallery-dl?" -ForegroundColor Yellow
    Write-Host "  Other tools on this machine may use them -- BurntToast is a common PS module." -ForegroundColor DarkGray
    Write-Host "  Safe default: keep them." -ForegroundColor DarkGray
    $ans = Read-Host "  [y/N]"
    $doPkg = ($ans -match '^(y|yes)$')
}
if ($doPkg) {
    foreach ($pkg in @('yt-dlp','gallery-dl','yt-dlp-ejs')) {
        $null = & python -m pip uninstall -y $pkg 2>&1
        Ok "pip uninstalled $pkg"
    }
    # BurntToast is a PS module -- separate uninstall
    try {
        if (Get-Module -ListAvailable BurntToast) {
            Uninstall-Module -Name BurntToast -AllVersions -Force -ErrorAction Stop
            Ok 'PS module BurntToast uninstalled'
        }
    } catch { Warn "couldn't uninstall BurntToast: $_" }
} else {
    Skip 'pip packages kept'
}

# --- 6. Reminder about the source tree ----------------------------------
Section 'Source repo'
Skip "$PSScriptRoot -- you cloned this. Delete manually when done."

# --- Summary ------------------------------------------------------------
Write-Host ""
Write-Host "  Uninstall complete." -ForegroundColor Green
Write-Host ""
if ($script:Removed.Count -gt 0) {
    Write-Host "  Removed:" -ForegroundColor White
    $script:Removed | ForEach-Object { Write-Host "    - $_" -ForegroundColor DarkGreen }
}
if ($script:Kept.Count -gt 0) {
    Write-Host "  Kept:" -ForegroundColor White
    $script:Kept | ForEach-Object { Write-Host "    - $_" -ForegroundColor DarkGray }
}
Write-Host ""
Write-Host "  Your downloaded files are untouched." -ForegroundColor Green
