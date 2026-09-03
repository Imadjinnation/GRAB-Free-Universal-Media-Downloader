# grab-app.ps1
# Main entry point. Loads config, starts the tray. The tray runs the
# message loop; the queue worker runs on the tray's timer. Popup and
# settings windows are opened on demand from the tray menu.

[CmdletBinding()]
param(
    [switch]$ShowPopupOnStart   # optional: pop the popup once at launch
)

# --- Singleton lock ---------------------------------------------------------
# Prevents multiple simultaneous tray instances (each of which would put its
# own icon in the system tray -- the "N green arrows" bug). If another
# grab-app is already running, exit silently. If we're first, hold the mutex
# for the lifetime of this process.
#
# v0.3.0: switched to the non-owning constructor + WaitOne(0) so we can
# handle AbandonedMutexException. Pre-v0.3.0 if the prior tray process was
# force-killed (Task Manager, logoff crash, etc), the OS marked the named
# mutex "abandoned"; the constructor form we used before threw
# AbandonedMutexException synchronously and grab-app crashed on next launch
# without ever creating the tray icon (audit P0-3). Catching it and
# treating it as "I now own this mutex" is the correct recovery path per
# .NET docs.
$script:SingletonMutex     = New-Object System.Threading.Mutex($false, 'Global\GrabAppTraySingleton')
$script:MutexWasAbandoned  = $false
try {
    $acquired = $script:SingletonMutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
    # A prior owner exited without releasing. WaitOne still transfers
    # ownership to us; we log a warning after utils.ps1 loads.
    $acquired = $true
    $script:MutexWasAbandoned = $true
}
if (-not $acquired) {
    Write-Host 'grab-app is already running (tray singleton). Exiting this instance.' -ForegroundColor DarkGray
    try { $script:SingletonMutex.Dispose() } catch {}
    return
}

# STA is required for WPF windows to work from this thread.
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-Warning 'grab-app requires STA. Relaunching...'
    # Release the mutex before relaunching so the STA child can take it.
    # ReleaseMutex only works when we actually own it (WaitOne(0) succeeded);
    # AbandonedMutexException recovery counts as owned per .NET docs.
    try { $script:SingletonMutex.ReleaseMutex() } catch {}
    try { $script:SingletonMutex.Dispose() } catch {}
    # Quote $PSCommandPath so paths containing spaces (e.g. "My Projects\")
    # don't split into multiple tokens. Also DO NOT reassign $args (it's an
    # automatic variable that would shadow the current scope's arg array).
    $relaunchArgs = @('-STA','-NoProfile','-ExecutionPolicy','Bypass','-File', ('"' + $PSCommandPath + '"'))
    Start-Process powershell.exe -ArgumentList $relaunchArgs -WindowStyle Hidden
    return
}

$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot

# Dot-source the pieces (order matters -- utils first). popup.ps1 and
# settings.ps1 are DEFERRED to first-use so cold-start hits the tray
# icon path (tray.ps1) as quickly as possible; each callback below
# dot-sources them on demand and guards with a $script:*Sourced flag so
# repeated shows are cheap. See src/tray.ps1 Start-Tray phase 1 for the
# tray-icon-first strategy.
. (Join-Path $root 'src\utils.ps1')
. (Join-Path $root 'src\core.ps1')
. (Join-Path $root 'src\queue.ps1')
. (Join-Path $root 'src\tray.ps1')

$script:PopupSourced    = $false
$script:SettingsSourced = $false

# Now that utils.ps1 is loaded, log any abandoned-mutex recovery so users
# can grep for it in %APPDATA%\grab-app\logs.
if ($script:MutexWasAbandoned) {
    Log-Warn 'grab-app: singleton mutex was abandoned by a prior process; reclaimed cleanly'
}

# Ensure app data + config exist (installer usually did this already)
Ensure-AppData
$cfg = Get-Config
Log-Info "grab-app starting | v$($cfg.version)"

# Callbacks the tray will invoke. Both popup.ps1 and settings.ps1 are
# lazily dot-sourced here (first show only) to keep initial tray-icon
# time as small as possible.
$onShowPopup = {
    param([string]$tab = 'paste')
    if (-not $script:PopupSourced) {
        . (Join-Path $root 'src\popup.ps1')
        $script:PopupSourced = $true
    }
    try { Show-Popup -Tab $tab } catch { Log-Err "Show-Popup failed: $($_.Exception.Message)" }
}
$onShowSettings = {
    if (-not $script:SettingsSourced) {
        . (Join-Path $root 'src\settings.ps1')
        $script:SettingsSourced = $true
    }
    try { Show-Settings } catch { Log-Err "Show-Settings failed: $($_.Exception.Message)" }
}
$onBeforeQuit = {
    Log-Info 'grab-app quitting'
}

# First-run: pop the settings window so the user can pick a download folder
# and toggle clipboard-watch / autostart before anything else happens.
# firstRunComplete is set by Save (settings.ps1) or by Start-Tray's balloon
# (tray.ps1) as a fallback. Uses the lazy dot-source path so settings.ps1
# still isn't loaded until we actually need to show it.
if (-not $cfg.firstRunComplete) {
    # Defer to after the tray's message loop starts so the settings window
    # has a live Dispatcher; queue via CurrentDispatcher.BeginInvoke.
    # WPF classes need Ensure-WpfLoaded, but by the time this fires,
    # Start-Tray phase 2 has already loaded them.
    Ensure-WpfLoaded
    # Capture $root into script scope so the [Action] delegate closure can
    # reach it. Same for the "already sourced" flag.
    $script:FirstRunRoot = $root
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
        [Action]{
            try {
                if (-not $script:SettingsSourced) {
                    . (Join-Path $script:FirstRunRoot 'src\settings.ps1')
                    $script:SettingsSourced = $true
                }
                Show-Settings
            } catch { Log-Err "first-run Settings failed: $($_.Exception.Message)" }
        },
        [System.Windows.Threading.DispatcherPriority]::ApplicationIdle) | Out-Null
}

if ($ShowPopupOnStart) { & $onShowPopup 'paste' }

# Blocks until user picks Quit from the tray menu.
try {
    Start-Tray -OnShowPopup $onShowPopup -OnShowSettings $onShowSettings -OnBeforeQuit $onBeforeQuit
} finally {
    # Release the singleton lock so the NEXT launch can succeed.
    try { $script:SingletonMutex.ReleaseMutex() } catch {}
    try { $script:SingletonMutex.Dispose() } catch {}
}
