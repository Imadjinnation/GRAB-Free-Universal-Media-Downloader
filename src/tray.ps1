# src/tray.ps1
# Persistent WinForms NotifyIcon. This is the app's home -- it stays in
# your taskbar tray, houses the right-click menu, watches the clipboard,
# and drives the queue tick timer.
#
# Design note: WinForms message loop drives the whole app. WPF windows
# (popup, settings) attach on-demand to the same STA thread via WPF's
# Dispatcher which happily coexists with the WinForms loop.
#
# Dot-source: . "$PSScriptRoot\tray.ps1"; Start-Tray

Add-Type -AssemblyName System.Windows.Forms | Out-Null
Add-Type -AssemblyName System.Drawing        | Out-Null
Add-Type -AssemblyName PresentationFramework | Out-Null
Add-Type -AssemblyName PresentationCore      | Out-Null
Add-Type -AssemblyName WindowsBase           | Out-Null

. "$PSScriptRoot\utils.ps1"
. "$PSScriptRoot\queue.ps1"

$script:Tray            = $null
$script:TickTimer       = $null
$script:ClipTimer       = $null
$script:LastClipboardUrl = ''
$script:PopupShow       = $null   # callback set by grab-app.ps1: opens popup on a given tab
$script:SettingsShow    = $null   # callback: opens settings window
$script:OnQuit          = $null   # callback: extra cleanup
$script:Dispatcher      = $null   # WPF Dispatcher for the main STA thread

# ---------- Icon loading --------------------------------------------------

function Get-TrayIcon {
    # Prefer bundled assets\icon.ico if it exists; otherwise fall back to a
    # built-in Windows shell icon (download arrow) so we always have SOMETHING.
    $iconPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets\icon.ico'
    if (Test-Path $iconPath) {
        try { return New-Object System.Drawing.Icon $iconPath } catch {}
    }
    # Fallback: extract from shell32.dll
    $sig = @'
[DllImport("shell32.dll", CharSet = CharSet.Auto)]
public static extern int ExtractIconEx(string szFileName, int nIconIndex, IntPtr[] phiconLarge, IntPtr[] phiconSmall, int nIcons);
[DllImport("user32.dll")]
public static extern int DestroyIcon(IntPtr hIcon);
'@
    if (-not ('GrabApp.IconEx' -as [type])) {
        Add-Type -Name IconEx -Namespace GrabApp -MemberDefinition $sig | Out-Null
    }
    $small = New-Object IntPtr[] 1
    $large = New-Object IntPtr[] 1
    $shell = Join-Path $env:SystemRoot 'System32\shell32.dll'
    [GrabApp.IconEx]::ExtractIconEx($shell, 176, $large, $small, 1) | Out-Null   # 176 = download arrow
    if ($small[0] -ne [IntPtr]::Zero) {
        $icon = [System.Drawing.Icon]::FromHandle($small[0])
        return $icon.Clone()
    }
    return [System.Drawing.SystemIcons]::Application
}

# ---------- Menu ----------------------------------------------------------

function Build-TrayMenu {
    $menu = New-Object System.Windows.Forms.ContextMenuStrip

    $mShow     = $menu.Items.Add('Show grab',      $null, { if ($script:PopupShow)    { & $script:PopupShow 'paste' } })
    $mQueue    = $menu.Items.Add('Queue',          $null, { if ($script:PopupShow)    { & $script:PopupShow 'queue' } })
    $mRecent   = $menu.Items.Add('Recent',         $null, { if ($script:PopupShow)    { & $script:PopupShow 'recent' } })
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $mSettings = $menu.Items.Add('Settings...',    $null, { if ($script:SettingsShow) { & $script:SettingsShow } })
    $mOpen     = $menu.Items.Add('Open downloads', $null, {
        $cfg = Get-Config
        if (Test-Path -LiteralPath $cfg.downloadFolder) { Start-Process explorer.exe $cfg.downloadFolder }
    })
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $mAbout    = $menu.Items.Add('About',          $null, {
        [System.Windows.Forms.MessageBox]::Show(
            "grab -- universal media downloader`n`nA calm tray app that auto-picks yt-dlp or gallery-dl per link.`n`nSee README.md for docs.",
            'grab',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    })
    $mQuit     = $menu.Items.Add('Quit',           $null, { Stop-Tray })

    # Bold "Show grab" as default
    $mShow.Font = New-Object System.Drawing.Font($mShow.Font, [System.Drawing.FontStyle]::Bold)
    return $menu
}

# ---------- Timers --------------------------------------------------------

function Start-Timers {
    # We use WPF DispatcherTimer instead of WinForms.Timer because the main
    # loop is Dispatcher.Run (see Start-Tray). DispatcherTimer fires on the
    # dispatcher thread; WinForms.Timer would never fire under Dispatcher.Run.

    # Queue tick every 2s
    $script:TickTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:TickTimer.Interval = [TimeSpan]::FromSeconds(2)
    $script:TickTimer.Add_Tick({
        try { Invoke-QueueTick } catch { Log-Err "tick error: $($_.Exception.Message)" }
    })
    $script:TickTimer.Start()

    # Clipboard watch every 1.5s (opt-in via config)
    $script:ClipTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:ClipTimer.Interval = [TimeSpan]::FromMilliseconds(1500)
    $script:ClipTimer.Add_Tick({
        try {
            $cfg = Get-Config
            if (-not $cfg.clipboardWatch) { return }
            $txt = try { [System.Windows.Forms.Clipboard]::GetText() } catch { '' }
            if ($txt -and $txt -ne $script:LastClipboardUrl -and (Test-IsUrl $txt)) {
                $script:LastClipboardUrl = $txt
                Send-Toast 'URL detected' "Click the tray icon to grab: $(Get-SiteName $txt)"
                if ($script:Tray) {
                    $script:Tray.ShowBalloonTip(4000, 'grab', "Detected: $(Get-SiteName $txt)`nClick the tray icon to add it.", [System.Windows.Forms.ToolTipIcon]::Info)
                }
            }
        } catch { Log-Err "clip tick error: $($_.Exception.Message)" }
    })
    $script:ClipTimer.Start()
}

function Stop-Timers {
    if ($script:TickTimer) { $script:TickTimer.Stop() }
    if ($script:ClipTimer) { $script:ClipTimer.Stop() }
}

# ---------- Lifecycle -----------------------------------------------------

function Start-Tray {
    param(
        [scriptblock]$OnShowPopup    = $null,
        [scriptblock]$OnShowSettings = $null,
        [scriptblock]$OnBeforeQuit   = $null
    )
    $script:PopupShow    = $OnShowPopup
    $script:SettingsShow = $OnShowSettings
    $script:OnQuit       = $OnBeforeQuit

    # Eagerly create the WPF Dispatcher for THIS STA thread. All timers,
    # popup windows, and Dispatcher.Run() below share this one dispatcher.
    $script:Dispatcher = [System.Windows.Threading.Dispatcher]::CurrentDispatcher

    $script:Tray = New-Object System.Windows.Forms.NotifyIcon
    $script:Tray.Icon = Get-TrayIcon
    $script:Tray.Text = 'grab -- right-click for menu'
    $script:Tray.ContextMenuStrip = (Build-TrayMenu)
    $script:Tray.Visible = $true

    # Left-click summons popup (paste tab)
    $script:Tray.add_MouseClick({
        param($sender, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            if ($script:PopupShow) { & $script:PopupShow 'paste' }
        }
    })
    # Balloon click also summons popup
    $script:Tray.add_BalloonTipClicked({ if ($script:PopupShow) { & $script:PopupShow 'paste' } })

    Start-Timers

    # First-time greeting -- mark firstRunComplete RIGHT AFTER showing it,
    # not on quit (users don't quit, they reboot -- and the flag would
    # otherwise be re-triggered every login forever).
    $cfg = Get-Config
    if (-not $cfg.firstRunComplete) {
        $script:Tray.ShowBalloonTip(6000, 'grab is ready',
            'I live in your tray. Left-click me to paste a link; right-click for menu.',
            [System.Windows.Forms.ToolTipIcon]::Info)
        Update-Config @{ firstRunComplete = $true } | Out-Null
    }

    # Crash-recovery sweep: any queue entry left in 'running' state from a
    # prior process (crashed / killed / rebooted) has no live PS Job. Reset
    # them to pending so the tick timer picks them up cleanly.
    try { Recover-OrphanedJobs } catch { Log-Warn "recover sweep failed: $($_.Exception.Message)" }

    Log-Info 'tray started (WPF Dispatcher primary loop)'

    # WPF Dispatcher.Run() as the primary message loop. This pumps BOTH
    # Win32 messages (so NotifyIcon works) AND WPF messages (so popup
    # windows render, respond to input, drag, etc). This replaces the
    # WinForms Application.Run pattern that broke WPF hit-testing.
    [System.Windows.Threading.Dispatcher]::Run()
}

function Stop-Tray {
    Log-Info 'tray stopping'
    Stop-Timers
    if ($script:OnQuit) { try { & $script:OnQuit } catch {} }
    try { Stop-AllJobs } catch {}
    if ($script:Tray) {
        $script:Tray.Visible = $false
        $script:Tray.Dispose()
        $script:Tray = $null
    }
    if ($script:Dispatcher) {
        # Cleanly stop Dispatcher.Run() so grab-app.ps1 returns.
        $script:Dispatcher.InvokeShutdown()
    }
}
