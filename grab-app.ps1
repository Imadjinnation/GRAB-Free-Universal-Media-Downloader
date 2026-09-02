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
# NOTE: PS 5.1 requires the variable to exist BEFORE [ref] captures it,
# otherwise the ref doesn't populate and every instance thinks it's second.
$script:GotLock = $false
$script:SingletonMutex = New-Object System.Threading.Mutex($true, 'Global\GrabAppTraySingleton', [ref]$script:GotLock)
if (-not $script:GotLock) {
    Write-Host 'grab-app is already running (tray singleton). Exiting this instance.' -ForegroundColor DarkGray
    try { $script:SingletonMutex.Dispose() } catch {}
    return
}

# STA is required for WPF windows to work from this thread.
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-Warning 'grab-app requires STA. Relaunching...'
    # Release the mutex before relaunching so the STA child can take it.
    try { $script:SingletonMutex.ReleaseMutex(); $script:SingletonMutex.Dispose() } catch {}
    # Quote $PSCommandPath so paths containing spaces (e.g. "My Projects\")
    # don't split into multiple tokens. Also DO NOT reassign $args (it's an
    # automatic variable that would shadow the current scope's arg array).
    $relaunchArgs = @('-STA','-NoProfile','-ExecutionPolicy','Bypass','-File', ('"' + $PSCommandPath + '"'))
    Start-Process powershell.exe -ArgumentList $relaunchArgs -WindowStyle Hidden
    return
}

$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot

# Dot-source the pieces (order matters -- utils first)
. (Join-Path $root 'src\utils.ps1')
. (Join-Path $root 'src\core.ps1')
. (Join-Path $root 'src\queue.ps1')
. (Join-Path $root 'src\popup.ps1')
. (Join-Path $root 'src\settings.ps1')
. (Join-Path $root 'src\tray.ps1')

# Ensure app data + config exist (installer usually did this already)
Ensure-AppData
$cfg = Get-Config
Log-Info "grab-app starting | v$($cfg.version)"

# Callbacks the tray will invoke
$onShowPopup = {
    param([string]$tab = 'paste')
    try { Show-Popup -Tab $tab } catch { Log-Err "Show-Popup failed: $($_.Exception.Message)" }
}
$onShowSettings = {
    try { Show-Settings } catch { Log-Err "Show-Settings failed: $($_.Exception.Message)" }
}
$onBeforeQuit = {
    Log-Info 'grab-app quitting'
}

# First-run: pop the settings window so the user can pick a download folder
# and toggle clipboard-watch / autostart before anything else happens.
# firstRunComplete is set by Save (settings.ps1) or by Start-Tray's balloon
# (tray.ps1) as a fallback.
if (-not $cfg.firstRunComplete) {
    # Defer to after the tray's message loop starts so the settings window
    # has a live Dispatcher; queue via CurrentDispatcher.BeginInvoke.
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
        [Action]{ try { Show-Settings } catch { Log-Err "first-run Settings failed: $($_.Exception.Message)" } },
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
