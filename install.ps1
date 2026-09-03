# install.ps1 -- portable one-command bootstrapper for grab-app
# Safe to re-run. Detects existing installs, upgrades where possible.
# No hardcoded user paths; works for anyone cloning this repo.

[CmdletBinding()]
param(
    [switch]$NoStartup,   # skip adding to Windows startup
    [switch]$Quiet        # minimal output
)

$ErrorActionPreference = 'Continue'
$script:Root = $PSScriptRoot
$script:AppData = Join-Path $env:APPDATA 'grab-app'
$script:Errors = @()
$script:Warnings = @()

function Say([string]$msg, [string]$color = 'Gray') {
    if (-not $Quiet) { Write-Host "  $msg" -ForegroundColor $color }
}
function Section([string]$title) {
    if (-not $Quiet) { Write-Host ""; Write-Host "  == $title ==" -ForegroundColor Cyan }
}
function Ok([string]$msg)   { Say "OK    $msg" 'Green' }
function Warn([string]$msg) { Say "WARN  $msg" 'Yellow'; $script:Warnings += $msg }
function Fail([string]$msg) { Say "FAIL  $msg" 'Red'; $script:Errors += $msg }

# --- Banner ---------------------------------------------------------------
if (-not $Quiet) {
    Write-Host ""
    Write-Host "  grab -- setup" -ForegroundColor White
    Write-Host "  ------------" -ForegroundColor DarkGray
    Write-Host "  Installing dependencies and wiring things up. Safe to re-run." -ForegroundColor DarkGray
}

# --- Python check ---------------------------------------------------------
Section 'Python'
$pyExe = $null
foreach ($cmd in @('python','py','python3')) {
    $probe = & $cmd --version 2>&1
    if ($LASTEXITCODE -eq 0 -and $probe -match 'Python (\d+)\.(\d+)') {
        $major = [int]$Matches[1]; $minor = [int]$Matches[2]
        if ($major -eq 3 -and $minor -ge 10) {
            $pyExe = $cmd
            Ok "$cmd -> $probe"
            break
        } else {
            Warn "$cmd is $probe but need >= 3.10"
        }
    }
}
if (-not $pyExe) {
    Fail 'Python 3.10+ not found. Install from https://www.python.org/downloads/ then re-run this.'
    exit 1
}

# Resolve the scripts folder for THIS Python. This is where pip puts the .exe wrappers.
# Audit P2-35: `python -c ... 2>&1` coerces stderr into the string result, and
# a garbled result silently trips Test-Path into $false (or worse, into a
# path with embedded stderr characters). Capture stderr separately with
# `2>$null` and null-check explicitly.
$scriptsDir = & $pyExe -c "import sysconfig; print(sysconfig.get_path('scripts'))" 2>$null
if (-not $scriptsDir -or -not (Test-Path -LiteralPath $scriptsDir)) {
    # Fall back to user scripts dir (pip --user)
    $scriptsDir = & $pyExe -c "import site,os,sys; print(os.path.join(site.USER_BASE, 'Scripts'))" 2>$null
}
if (-not $scriptsDir -or -not (Test-Path -LiteralPath $scriptsDir)) {
    Fail "Could not resolve Python scripts dir for $pyExe"
    exit 1
}
Ok "Scripts dir: $scriptsDir"

# --- Install pip packages -------------------------------------------------
Section 'Downloader engines'
# yt-dlp[default] pulls in yt-dlp-ejs (JS challenge solver) which is REQUIRED
# for HD YouTube in 2026+ (PO Token bypass). --pre picks up nightly builds
# where YouTube fixes land within hours of a breakage; the yt-dlp team is in
# a constant back-and-forth with YouTube.
$packages = @(
    @{ name = 'yt-dlp[default]'; args = @('--pre') },
    @{ name = 'gallery-dl';       args = @() }
)
foreach ($pkg in $packages) {
    Say "installing/upgrading $($pkg.name) ..."
    $extra = $pkg.args
    $out = & $pyExe -m pip install --upgrade --quiet --disable-pip-version-check @extra $pkg.name 2>&1
    if ($LASTEXITCODE -eq 0) { Ok "$($pkg.name) installed" } else { Fail "$($pkg.name) install failed: $out" }
}

# --- Ensure Scripts dir is on User PATH -----------------------------------
Section 'PATH'
$userPath = [Environment]::GetEnvironmentVariable('Path','User')
if ($userPath -notlike "*$scriptsDir*") {
    $newPath = if ($userPath) { $userPath.TrimEnd(';') + ';' + $scriptsDir } else { $scriptsDir }
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    Ok "Added $scriptsDir to User PATH (new terminals only)"
} else {
    Ok "PATH already contains Scripts dir"
}
$env:Path = $env:Path.TrimEnd(';') + ';' + $scriptsDir

# --- BurntToast (Windows toast notifications) -----------------------------
Section 'Toast notifications (BurntToast)'
$btInstalled = Get-Module -ListAvailable -Name BurntToast
if (-not $btInstalled) {
    Say 'installing BurntToast module (CurrentUser scope) ...'
    try {
        # Ensure NuGet provider + trusted PSGallery so it installs quietly
        $null = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
        # Audit P2-34: parser precedence bug. `-not X.Y -eq 'Trusted'` parses
        # as `((-not X.Y) -eq 'Trusted')` which is always $false (a bool is
        # never the string 'Trusted'). Right shape is an explicit `-ne`.
        if ((Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue).InstallationPolicy -ne 'Trusted') {
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
        }
        Install-Module -Name BurntToast -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        Ok 'BurntToast installed'
    } catch {
        Warn "BurntToast install failed: $($_.Exception.Message). Toasts will fall back to console messages."
    }
} else {
    Ok "BurntToast already installed (v$($btInstalled[0].Version))"
}

# --- ffmpeg check ---------------------------------------------------------
Section 'ffmpeg'
$ffmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue
if ($ffmpeg) {
    Ok "ffmpeg present ($($ffmpeg.Source))"
} else {
    Say 'ffmpeg not found; attempting winget install ...'
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        $out = winget install --exact --id Gyan.FFmpeg --accept-source-agreements --accept-package-agreements --silent 2>&1
        if ($LASTEXITCODE -eq 0) { Ok 'ffmpeg installed via winget' }
        else { Warn "winget ffmpeg install failed; download manually from https://ffmpeg.org/download.html" }
    } else {
        Warn 'winget not available; install ffmpeg manually from https://ffmpeg.org/download.html'
    }
}

# --- App data folder + default config -------------------------------------
Section 'App data'
$foldersToMake = @($script:AppData, (Join-Path $script:AppData 'logs'))
foreach ($f in $foldersToMake) {
    if (-not (Test-Path $f)) { New-Item -ItemType Directory -Path $f -Force | Out-Null }
}
Ok "App data at $script:AppData"

$configPath = Join-Path $script:AppData 'config.json'
# Dot-source utils.ps1 so we can use Get-GrabVersion, Get-DownloadFolderDefault,
# and Write-JsonAtomic here. Keeps install.ps1 in lock-step with the app's
# single source of truth for the version constant and the default paths.
. (Join-Path $script:Root 'src\utils.ps1')
if (-not (Test-Path $configPath)) {
    $defaultConfig = @{
        version           = Get-GrabVersion
        downloadFolder    = Get-DownloadFolderDefault
        askBeforeEach     = $false
        clipboardWatch    = $false            # user must opt in
        concurrency       = 3
        autostart         = -not $NoStartup   # default ON since no hotkey
        cookieBrowser     = 'chrome'          # 'chrome' | 'firefox' | 'edge' | 'none'
        toastsEnabled     = $true
        popupPositionX    = $null             # remembered after user drags
        popupPositionY    = $null
        firstRunComplete  = $false
    }
    Write-JsonAtomic -Path $configPath -Data $defaultConfig -Depth 4
    Ok "Wrote default config: $configPath"
} else {
    Ok "Existing config kept: $configPath"
}

# Ensure download folder exists
$dlFolder = (Get-Content $configPath -Raw | ConvertFrom-Json).downloadFolder
if (-not (Test-Path $dlFolder)) { New-Item -ItemType Directory -Path $dlFolder -Force | Out-Null }
Ok "Download folder: $dlFolder"

# --- Desktop shortcuts (rewire to new app) --------------------------------
Section 'Desktop shortcuts'
$WshShell = New-Object -ComObject WScript.Shell
# v0.3.0: always target the LOCAL Desktop, never OneDrive-redirected. Users
# reported the desktop icon vanishing after sync events; the fix is to not
# put the shortcut into OneDrive in the first place.
$Desktop = Get-LocalDesktopPath
$appEntry = Join-Path $script:Root 'grab-app.ps1'
$vbsEntry = Join-Path $script:Root 'grab-app.vbs'
# Audit P2-33: the drag-drop launcher (src\_drop_.bat) shipped with v0.1
# and was removed in v0.2 when the tray took over the paste flow -- the
# variable that referenced it was dead code and has been removed.

# Migration cleanup: if the user had prior installs, they may have grab.lnk /
# grab Downloads.lnk on the OneDrive Desktop. Remove them so we don't end up
# with duplicate shortcuts (one live at local Desktop, one stale at
# OneDrive\Desktop that no longer targets a live .ps1).
$oneDriveDesktop = Join-Path $env:USERPROFILE 'OneDrive\Desktop'
if ($Desktop -ne $oneDriveDesktop -and (Test-Path -LiteralPath $oneDriveDesktop)) {
    foreach ($stale in @('grab.lnk','grab Downloads.lnk')) {
        $p = Join-Path $oneDriveDesktop $stale
        if (Test-Path -LiteralPath $p) {
            Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
            Ok "removed stale OneDrive Desktop shortcut ($stale)"
        }
    }
}

function Make-Shortcut([string]$name, [string]$target, [string]$args, [string]$icon, [string]$desc, [string]$workDir) {
    $lnk = Join-Path $Desktop "$name.lnk"
    $sc = $WshShell.CreateShortcut($lnk)
    $sc.TargetPath = $target
    if ($args)    { $sc.Arguments = $args }
    if ($workDir) { $sc.WorkingDirectory = $workDir }
    if ($icon)    { $sc.IconLocation = $icon }
    $sc.Description = $desc
    $sc.Save()
    Ok "$name.lnk"
}

# Prefer the bundled multi-res icon; fall back to a shell32.dll glyph so the
# shortcut still gets a face even before the .ico ships.
$grabIco = Join-Path $script:Root 'assets\icon.ico'
$grabIconLoc = if (Test-Path -LiteralPath $grabIco) { $grabIco } else { "$env:SystemRoot\System32\shell32.dll,143" }

# v0.3.0: prefer the wscript.exe silent launcher when it ships alongside the
# .ps1. It sidesteps the Windows Terminal "black flash on startup" issue that
# `-WindowStyle Hidden` alone doesn't fully fix on Win11 defaults.
if (Test-Path -LiteralPath $vbsEntry) {
    Make-Shortcut `
        -name 'grab' `
        -target 'wscript.exe' `
        -args   ('"' + $vbsEntry + '"') `
        -icon   $grabIconLoc `
        -desc   'Launch the grab tray app' `
        -workDir $script:Root
} else {
    Make-Shortcut `
        -name 'grab' `
        -target 'powershell.exe' `
        -args   ('-STA -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $appEntry + '"') `
        -icon   $grabIconLoc `
        -desc   'Launch the grab tray app' `
        -workDir $script:Root
}

# v0.3.0: NO 'grab Downloads.lnk' desktop shortcut (audit P1-10). Two icons
# on the desktop for the same app was cluttery -- the tray menu now has an
# "Open downloads" item that supersedes it. The tray's self-heal sweep
# deletes stale copies from prior installs (see Invoke-SelfHealSweep).

# --- Autostart entry (opt-out via -NoStartup) -----------------------------
# v0.3.0: HKCU\Run is the primary (survives OneDrive folder-sync tricks). We
# also drop a shell:startup shortcut into the LOCAL Startup folder when it's
# NOT redirected into OneDrive/Dropbox/iCloud. Cleans up stale OneDrive
# Startup shortcuts from prior installs for the same reason as the Desktop
# migration above.
Section 'Autostart'
$oneDriveStartup = Join-Path $env:USERPROFILE 'OneDrive\Microsoft\Windows\Start Menu\Programs\Startup'
if (Test-Path -LiteralPath $oneDriveStartup) {
    $stale = Join-Path $oneDriveStartup 'grab.lnk'
    if (Test-Path -LiteralPath $stale) {
        Remove-Item -LiteralPath $stale -Force -ErrorAction SilentlyContinue
        Ok 'removed stale OneDrive Startup shortcut (grab.lnk)'
    }
}
$startup    = Get-LocalStartupPath
$startupLnk = Join-Path $startup 'grab.lnk'
if ($NoStartup) {
    if (Test-Path -LiteralPath $startupLnk) { Remove-Item -LiteralPath $startupLnk -Force }
    Set-AutostartRegistry $false
    Ok 'Autostart skipped (per -NoStartup flag)'
} else {
    # Registry entry first (the primary, always writeable).
    Set-AutostartRegistry $true
    Ok 'HKCU\Run\GRAB registry entry set'
    # Startup-folder shortcut only when it's a real local path.
    if (Test-IsOneDrivePath $startup) {
        Warn "Startup folder is in OneDrive ($startup); using HKCU\Run only. Autostart still works."
    } else {
        $sc = $WshShell.CreateShortcut($startupLnk)
        if (Test-Path -LiteralPath $vbsEntry) {
            $sc.TargetPath = 'wscript.exe'
            $sc.Arguments  = '"' + $vbsEntry + '"'
        } else {
            $sc.TargetPath = 'powershell.exe'
            $sc.Arguments  = '-STA -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $appEntry + '"'
        }
        $sc.WorkingDirectory = $script:Root
        $sc.IconLocation = $grabIconLoc
        $sc.Description = 'Start grab tray at login'
        $sc.Save()
        Ok "Startup shortcut: $startupLnk"
    }
}

# --- Windows 11 tray icon promotion (show in taskbar, not up-caret) ------
# Users report GRAB's tray icon defaulting to the hidden "up-caret" tray on
# Win11. Setting the NotifyIconSettings promotion flag for our stable GUID
# tells Windows to keep the icon in the taskbar. Best-effort: this key may
# be shell-managed and rejected on some builds; we ignore failures.
try {
    $grabGuid = '{f3e2c9a1-4b8e-4d3a-9c1b-5e6a7b8c9d0e}'
    $notifyKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\NotifyIconSettings\$grabGuid"
    if (-not (Test-Path $notifyKey)) { New-Item -Path $notifyKey -Force | Out-Null }
    New-ItemProperty -Path $notifyKey -Name 'IsPromoted' -Value 1 -PropertyType DWORD -Force | Out-Null
    Ok 'tray promotion registry key set (IsPromoted=1)'
} catch { Warn "tray promotion registry write failed: $($_.Exception.Message)" }

# --- Summary --------------------------------------------------------------
Write-Host ""
if ($script:Errors.Count -eq 0) {
    Write-Host "  grab setup complete." -ForegroundColor Green
    Write-Host ""
    Write-Host "  Next steps:" -ForegroundColor White
    Write-Host "    - Launch by double-clicking the 'grab' icon on your Desktop" -ForegroundColor Gray
    Write-Host "    - Or run: powershell -ExecutionPolicy Bypass -File `"$appEntry`"" -ForegroundColor Gray
    Write-Host "    - The tray icon (bottom-right of your screen) is where everything lives" -ForegroundColor Gray
    Write-Host ""
    if ($script:Warnings.Count -gt 0) {
        Write-Host "  Warnings you can safely ignore or fix later:" -ForegroundColor Yellow
        $script:Warnings | ForEach-Object { Write-Host "    - $_" -ForegroundColor DarkYellow }
        Write-Host ""
    }
} else {
    Write-Host "  Setup finished with errors:" -ForegroundColor Red
    $script:Errors | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    Write-Host "  Fix them and re-run install.ps1" -ForegroundColor Yellow
    exit 1
}
