# uninstall.ps1
# Cleanly removes grab-app from a machine. Preserves downloads.
#
# Removes (silently):
#   - Running tray process
#   - Desktop shortcuts (grab.lnk, grab Downloads.lnk)
#   - Autostart entry (shell:startup\grab.lnk)
#   - HKCU\Software\Microsoft\Windows\CurrentVersion\Run\GRAB
#   - Tray promotion registry key (HKCU NotifyIconSettings\{grab-guid})
#   - Runtime theme scratch file (.runtime-theme.xaml) + any config.json.corrupt-* backups
#   - Per-engine done-archive files (done-archive-yt-dlp.txt, done-archive-gallery-dl.txt)
#   - Stale OneDrive Desktop / Startup shortcuts left by prior installs
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
#   .\uninstall.ps1 -RevertPSGallery  Set-PSRepository -Name PSGallery -InstallationPolicy Untrusted (audit finding 58)

[CmdletBinding()]
param(
    [switch]$Yes,
    [switch]$KeepState,
    [switch]$RevertPSGallery
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
# Also catch wscript.exe grab-app.vbs launches (finding 24).
$vbsTray = Get-CimInstance Win32_Process -Filter "Name='wscript.exe'" -ErrorAction SilentlyContinue |
           Where-Object { $_.CommandLine -match 'grab-app\.vbs' }
if ($vbsTray) {
    foreach ($t in $vbsTray) {
        try { Stop-Process -Id $t.ProcessId -Force -ErrorAction SilentlyContinue; Ok "stopped wscript tray PID $($t.ProcessId)" } catch { Warn "couldn't stop PID $($t.ProcessId): $_" }
    }
}

# --- 2. Desktop shortcuts (LOCAL + OneDrive-redirected) -----------------
Section 'Desktop shortcuts'
$desktopCandidates = @(
    [Environment]::GetFolderPath('Desktop'),
    (Join-Path $env:USERPROFILE 'Desktop'),
    (Join-Path $env:USERPROFILE 'OneDrive\Desktop')
) | Where-Object { $_ } | Select-Object -Unique
foreach ($desk in $desktopCandidates) {
    if (-not (Test-Path -LiteralPath $desk)) { continue }
    foreach ($name in @('grab.lnk','grab Downloads.lnk','Grab (paste).lnk','Grab (drop).lnk','Grab Downloads.lnk')) {
        $p = Join-Path $desk $name
        if (Test-Path -LiteralPath $p) {
            try { Remove-Item -LiteralPath $p -Force -ErrorAction Stop; Ok "removed $desk\$name" } catch { Warn "couldn't remove ${desk}\${name}: $_" }
        }
    }
}

# --- 3. Autostart entries (shortcut + HKCU\Run + OneDrive-redirected) ---
Section 'Autostart'
$startupCandidates = @(
    [Environment]::GetFolderPath('Startup'),
    (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'),
    (Join-Path $env:USERPROFILE 'OneDrive\Microsoft\Windows\Start Menu\Programs\Startup')
) | Where-Object { $_ } | Select-Object -Unique
$removedAny = $false
foreach ($su in $startupCandidates) {
    if (-not (Test-Path -LiteralPath $su)) { continue }
    $startLnk = Join-Path $su 'grab.lnk'
    if (Test-Path -LiteralPath $startLnk) {
        try { Remove-Item -LiteralPath $startLnk -Force -ErrorAction Stop; Ok "removed $startLnk"; $removedAny = $true } catch { Warn "couldn't remove ${startLnk}: $_" }
    }
}
if (-not $removedAny) { Skip 'no autostart shortcut' }

# HKCU\Run\GRAB (v0.3.0 primary autostart) -- ALWAYS present when autostart on.
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
try {
    if (Get-ItemProperty -Path $runKey -Name 'GRAB' -ErrorAction SilentlyContinue) {
        Remove-ItemProperty -Path $runKey -Name 'GRAB' -Force -ErrorAction Stop
        Ok "removed HKCU\Run\GRAB"
    } else {
        Skip 'no HKCU\Run\GRAB entry'
    }
} catch { Warn "couldn't remove HKCU\Run\GRAB: $_" }

# Tray promotion key (v0.3.0). Best-effort; matched by stable GUID.
$grabGuid  = '{f3e2c9a1-4b8e-4d3a-9c1b-5e6a7b8c9d0e}'
$notifyKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\NotifyIconSettings\$grabGuid"
try {
    if (Test-Path $notifyKey) {
        Remove-Item -Path $notifyKey -Recurse -Force -ErrorAction Stop
        Ok "removed tray-promotion registry key ($grabGuid)"
    }
} catch { Warn "couldn't remove NotifyIconSettings key: $_" }

# --- 4. App-data folder + assorted scratch --------------------------------
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
        # Even when the user keeps state, prune the transient scratch files
        # + backups that add up over time (audit v0.3.0-pass2 finding 24).
        foreach ($scratch in @(
            (Join-Path $appData '.runtime-theme.xaml'),
            (Join-Path $appData 'done-archive-yt-dlp.txt'),
            (Join-Path $appData 'done-archive-gallery-dl.txt')
        )) {
            if (Test-Path -LiteralPath $scratch) {
                try { Remove-Item -LiteralPath $scratch -Force -ErrorAction Stop; Ok "removed $scratch" } catch { Warn "couldn't remove ${scratch}: $_" }
            }
        }
        # config.json.corrupt-* backups
        try {
            $bakups = @(Get-ChildItem -LiteralPath $appData -Filter 'config.json.corrupt-*' -File -ErrorAction SilentlyContinue)
            foreach ($b in $bakups) {
                try { Remove-Item -LiteralPath $b.FullName -Force -ErrorAction Stop; Ok "removed backup $($b.Name)" } catch {}
            }
        } catch {}
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

# --- 6. Optional PSGallery revert (audit finding 58) -------------------
if ($RevertPSGallery) {
    Section 'PSGallery policy revert'
    try {
        Set-PSRepository -Name PSGallery -InstallationPolicy Untrusted -ErrorAction Stop
        Ok 'PSGallery InstallationPolicy -> Untrusted (matches pre-install default)'
    } catch { Warn "couldn't revert PSGallery: $_" }
}

# --- 7. Reminder about the source tree ----------------------------------
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
