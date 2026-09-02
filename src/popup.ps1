# src/popup.ps1
# Loads ui/popup.xaml and wires up:
#   - custom titlebar drag / minimize / close
#   - bottom-right dock on first show, remembered position on subsequent shows
#   - tab switching between Paste / Queue / Recent
#   - Paste tab: single URL + "Add many" multi-line mode, dedupe, adds to queue
#
# Close (X) HIDES the window; the tray stays running. Quit is tray-only.
# The window is created once per app run and reused across shows.
#
# Public functions:
#   Show-Popup [-Tab paste|queue|recent]
#   Hide-Popup
#
# Dot-source: . "$PSScriptRoot\popup.ps1"

Add-Type -AssemblyName PresentationFramework | Out-Null
Add-Type -AssemblyName PresentationCore      | Out-Null
Add-Type -AssemblyName WindowsBase           | Out-Null
Add-Type -AssemblyName System.Windows.Forms  | Out-Null   # for Screen.WorkingArea

. "$PSScriptRoot\utils.ps1"
. "$PSScriptRoot\queue.ps1"

$script:Window = $null

# ==========================================================================
# Row builders for Queue and Recent tabs
# ==========================================================================

function _StatusColor([string]$status) {
    switch ($status) {
        'pending'   { '#5E5E63' }
        'running'   { '#F5A87A' }
        'done'      { '#4CAF50' }
        'failed'    { '#F44336' }
        'cancelled' { '#5E5E63' }
        default     { '#8E8E93' }
    }
}

function _EscapeXaml([string]$s) {
    if ($null -eq $s) { return '' }
    return [System.Security.SecurityElement]::Escape($s)
}

function _TrimUrl([string]$u, [int]$max = 55) {
    if ($null -eq $u) { return '' }
    if ($u.Length -le $max) { return $u }
    return $u.Substring(0, $max) + '...'
}

function Build-QueueRow([object]$job) {
    $siteShort   = Get-SiteName $job.Url
    $urlShort    = _EscapeXaml (_TrimUrl $job.Url 55)
    $siteShortEs = _EscapeXaml $siteShort
    $msgEs       = _EscapeXaml $job.StatusMsg
    $statusColor = _StatusColor $job.Status
    $actionLabel = switch ($job.Status) {
        'pending'   { [char]0x00D7 }   # ×  (cancel)
        'running'   { [char]0x00D7 }
        'failed'    { [char]0x21BB }   # ↻ (retry)
        'cancelled' { [char]0x21BB }
        default     { $null }
    }
    $actionTip = if ($job.Status -in @('pending','running')) { 'Cancel' } else { 'Retry' }
    $actionBlock = if ($actionLabel) {
        "<Button x:Name=`"ActionBtn`" Content=`"$actionLabel`" ToolTip=`"$actionTip`" " +
        "Foreground=`"#8E8E93`" Background=`"Transparent`" BorderThickness=`"0`" " +
        "Cursor=`"Hand`" FontSize=`"13`" Width=`"26`" Height=`"26`" Margin=`"6,0,0,0`"/>"
    } else { '' }

    $xaml = @"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        CornerRadius="8"
        Background="#1A1A1D"
        BorderBrush="#2A2A2E"
        BorderThickness="1"
        Padding="10,8"
        Margin="0,0,0,6">
  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="Auto"/>
      <ColumnDefinition Width="*"/>
      <ColumnDefinition Width="Auto"/>
    </Grid.ColumnDefinitions>
    <Ellipse Grid.Column="0" Width="10" Height="10" Fill="$statusColor"
             VerticalAlignment="Center" Margin="0,0,10,0"/>
    <StackPanel Grid.Column="1">
      <TextBlock Foreground="#F5F5F7" FontSize="12" TextTrimming="CharacterEllipsis" TextWrapping="NoWrap">
        <Run FontWeight="SemiBold" Text="$siteShortEs "/><Run Foreground="#8E8E93" Text="$urlShort"/>
      </TextBlock>
      <TextBlock Text="$msgEs" Foreground="#8E8E93" FontSize="10" Margin="0,2,0,0" TextTrimming="CharacterEllipsis"/>
    </StackPanel>
    <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
      <TextBlock Text="$($job.Status)" Foreground="$statusColor" FontSize="10" VerticalAlignment="Center"/>
      $actionBlock
    </StackPanel>
  </Grid>
</Border>
"@
    $row = [Windows.Markup.XamlReader]::Parse($xaml)
    $btn = $row.FindName('ActionBtn')
    if ($btn) {
        $jobId  = $job.Id
        $status = $job.Status
        $btn.Add_Click({
            if ($status -in @('pending','running')) { Cancel-QueueJob $jobId }
            else { Retry-QueueJob $jobId }
        }.GetNewClosure())
    }
    return $row
}

function Build-RecentRow([object]$entry) {
    $siteShort   = Get-SiteName $entry.Url
    $urlShort    = _EscapeXaml (_TrimUrl $entry.Url 55)
    $siteShortEs = _EscapeXaml $siteShort
    $doneAt      = if ($entry.DoneAt) { ([datetime]$entry.DoneAt).ToString('MMM d, HH:mm') } else { '' }
    $summary     = "$($entry.FilesAdded) file(s) via $($entry.ToolUsed)"
    $statusColor = if ($entry.Status -eq 'done') { '#4CAF50' } else { '#F44336' }
    # -LiteralPath so folder names with [ ] don't get wildcard-parsed
    # into a phantom "Missing" state.
    $destExists  = ($entry.Dest -and (Test-Path -LiteralPath $entry.Dest))
    $openLabel   = if ($destExists) { 'Open' } else { 'Missing' }
    $openEnabled = if ($destExists) { 'True' } else { 'False' }

    $xaml = @"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        CornerRadius="8"
        Background="#1A1A1D"
        BorderBrush="#2A2A2E"
        BorderThickness="1"
        Padding="10,8"
        Margin="0,0,0,6">
  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="*"/>
      <ColumnDefinition Width="Auto"/>
    </Grid.ColumnDefinitions>
    <StackPanel Grid.Column="0">
      <TextBlock Foreground="#F5F5F7" FontSize="12" TextTrimming="CharacterEllipsis" TextWrapping="NoWrap">
        <Run FontWeight="SemiBold" Text="$siteShortEs "/><Run Foreground="#8E8E93" Text="$urlShort"/>
      </TextBlock>
      <TextBlock Foreground="#8E8E93" FontSize="10" Margin="0,2,0,0">
        <Run Text="$doneAt"/><Run Text=" &#183; "/><Run Text="$summary"/>
      </TextBlock>
    </StackPanel>
    <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
      <Button x:Name="OpenBtn" Content="$openLabel" IsEnabled="$openEnabled"
              Foreground="#F5F5F7" Background="#26262A" BorderThickness="0"
              Cursor="Hand" FontSize="10" Padding="10,4" Margin="0,0,4,0"/>
      <Button x:Name="RetryBtn" Content="Re-grab"
              Foreground="#F5F5F7" Background="#26262A" BorderThickness="0"
              Cursor="Hand" FontSize="10" Padding="10,4"/>
    </StackPanel>
  </Grid>
</Border>
"@
    $row = [Windows.Markup.XamlReader]::Parse($xaml)
    $openBtn  = $row.FindName('OpenBtn')
    $retryBtn = $row.FindName('RetryBtn')
    if ($openBtn) {
        $dest = $entry.Dest
        $openBtn.Add_Click({
            if ($dest -and (Test-Path -LiteralPath $dest)) { Start-Process explorer.exe $dest }
        }.GetNewClosure())
    }
    if ($retryBtn) {
        $url = $entry.Url
        $retryBtn.Add_Click({
            Add-QueueJob -Urls @($url) | Out-Null
        }.GetNewClosure())
    }
    return $row
}

function Load-PopupWindow {
    if ($script:Window) { return $script:Window }

    $xamlPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'ui\popup.xaml'
    [xml]$xaml = Get-Content $xamlPath -Raw -Encoding UTF8
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $w = [Windows.Markup.XamlReader]::Load($reader)

    # Named element handles
    $ctl = @{}
    foreach ($n in @('TitleBar','MinBtn','CloseBtn',
                     'TabPaste','TabQueue','TabRecent',
                     'PastePanel','QueuePanel','RecentPanel',
                     'UrlBox','MultiBox','SingleInputBorder','MultiInputBorder',
                     'Hint','StatusLine','ToggleMulti','GrabBtn','SensitiveToggle',
                     'QueueList','QueueEmpty','QueueClearDone',
                     'RecentList','RecentEmpty')) {
        $ctl[$n] = $w.FindName($n)
    }

    # KEY LESSON:
    # .GetNewClosure() captures LOCAL variables ($foo), not $script:* refs.
    # When a WPF event fires the handler, the scriptblock runs in a scope
    # where popup.ps1's $script: is NOT available. We must capture the state
    # we need via plain locals, and mutable state goes through [ref] cells.
    $CtlLocal    = $ctl                       # captured by every closure below
    $WinLocal    = $w                         # captured
    $MultiRef    = [ref]$false                # mutable: multi-URL input mode
    $SwitchRef   = [ref]$null                 # will hold the tab-switch scriptblock

    # ---------- Titlebar behavior ------------------------------------------
    $ctl.TitleBar.Add_MouseLeftButtonDown({
        # WPF event handlers don't populate the pipeline var (was the audit
        # crit-2 bug). MouseLeftButtonDown fires for the left button by
        # definition -- no guard needed. Drag directly.
        $WinLocal.DragMove()
    }.GetNewClosure())
    $ctl.MinBtn.Add_Click({ $WinLocal.WindowState = 'Minimized' }.GetNewClosure())
    $ctl.CloseBtn.Add_Click({ $WinLocal.Hide() }.GetNewClosure())

    # OS close-button = hide, not close (tray remains alive)
    $w.Add_Closing({
        param($sender, $e)
        $e.Cancel = $true
        $sender.Hide()
    })

    # Save position when user drags
    $w.Add_LocationChanged({
        if ($WinLocal -and $WinLocal.WindowState -eq 'Normal') {
            Update-Config @{ popupPositionX = [int]$WinLocal.Left; popupPositionY = [int]$WinLocal.Top } | Out-Null
        }
    }.GetNewClosure())

    # ---------- Tab switching ----------------------------------------------
    $switchTab = {
        param($active)
        foreach ($t in @('TabPaste','TabQueue','TabRecent')) {
            $CtlLocal[$t].Tag = if ($t -eq $active) { 'active' } else { $null }
        }
        $CtlLocal.PastePanel.Visibility  = if ($active -eq 'TabPaste')  { 'Visible' } else { 'Collapsed' }
        $CtlLocal.QueuePanel.Visibility  = if ($active -eq 'TabQueue')  { 'Visible' } else { 'Collapsed' }
        $CtlLocal.RecentPanel.Visibility = if ($active -eq 'TabRecent') { 'Visible' } else { 'Collapsed' }
    }.GetNewClosure()
    $SwitchRef.Value = $switchTab

    $ctl.TabPaste.Add_Click({  Log-Info 'tab: paste';  & $SwitchRef.Value 'TabPaste'  }.GetNewClosure())
    $ctl.TabQueue.Add_Click({  Log-Info 'tab: queue';  & $SwitchRef.Value 'TabQueue'  }.GetNewClosure())
    $ctl.TabRecent.Add_Click({ Log-Info 'tab: recent'; & $SwitchRef.Value 'TabRecent' }.GetNewClosure())

    # ---------- Paste tab behavior -----------------------------------------
    $ctl.ToggleMulti.Add_Click({
        $MultiRef.Value = -not $MultiRef.Value
        if ($MultiRef.Value) {
            $CtlLocal.SingleInputBorder.Visibility = 'Collapsed'
            $CtlLocal.MultiInputBorder.Visibility  = 'Visible'
            $CtlLocal.ToggleMulti.Content = 'Single URL'
            $CtlLocal.Hint.Text = 'One URL per line. Duplicates and non-URLs are skipped.'
            $CtlLocal.MultiBox.Focus()
        } else {
            $CtlLocal.SingleInputBorder.Visibility = 'Visible'
            $CtlLocal.MultiInputBorder.Visibility  = 'Collapsed'
            $CtlLocal.ToggleMulti.Content = 'Add many...'
            $CtlLocal.Hint.Text = 'Tip: copy a link first and it will auto-fill here.'
            $CtlLocal.UrlBox.Focus()
        }
    }.GetNewClosure())

    $doSubmit = {
        Log-Info 'submit: fired'
        try {
            $urls = @()
            if ($MultiRef.Value) {
                $lines = $CtlLocal.MultiBox.Text -split "`r?`n"
                foreach ($ln in $lines) {
                    $u = $ln.Trim()
                    if ($u -and (Test-IsUrl $u)) { $urls += $u }
                }
            } else {
                $u = $CtlLocal.UrlBox.Text.Trim()
                if ($u -and (Test-IsUrl $u)) { $urls += $u }
            }
            Log-Info "submit: parsed $($urls.Count) URL(s)"
            if ($urls.Count -eq 0) {
                $CtlLocal.StatusLine.Text = "That doesn't look like a URL. Paste a link starting with http:// or https://."
                return
            }
            $isSensitive = [bool]$CtlLocal.SensitiveToggle.IsChecked
            $added = if ($isSensitive) { Add-QueueJob -Urls $urls -Sensitive } else { Add-QueueJob -Urls $urls }
            Log-Info ("submit: Add-QueueJob returned added=$added" + $(if ($isSensitive) { ' [SENSITIVE]' } else { '' }))
            $suffix = if ($isSensitive) { ' [sensitive -> .private]' } else { '' }
            $CtlLocal.StatusLine.Text = if ($added -eq 0) { "Already in the queue." }
                                        elseif ($added -eq 1) { "Added 1$suffix. Switch to Queue tab to watch." }
                                        else { "Added $added$suffix. Switch to Queue tab to watch." }
            if ($added -gt 0) {
                $CtlLocal.UrlBox.Text = ''
                $CtlLocal.MultiBox.Text = ''
                # Reset sensitive toggle after submit so the next grab isn't accidentally
                # inheriting the flag. Sticky would be dangerous.
                $CtlLocal.SensitiveToggle.IsChecked = $false
                & $SwitchRef.Value 'TabQueue'
            }
        } catch {
            Log-Err "submit exception: $($_.Exception.Message)"
            try { $CtlLocal.StatusLine.Text = "Error: $($_.Exception.Message)" } catch {}
        }
    }.GetNewClosure()

    $ctl.GrabBtn.Add_Click($doSubmit)

    $ctl.UrlBox.Add_KeyDown({
        param($sender, $e)
        if ($e.Key -eq 'Return') { & $doSubmit }
        elseif ($e.Key -eq 'Escape') { $WinLocal.Hide() }
    }.GetNewClosure())
    $ctl.MultiBox.Add_KeyDown({
        param($sender, $e)
        if ($e.Key -eq 'Return' -and ([System.Windows.Input.Keyboard]::Modifiers -band 'Control')) { & $doSubmit }
        elseif ($e.Key -eq 'Escape') { $WinLocal.Hide() }
    }.GetNewClosure())

    # ---------- Queue + Recent tabs: live-refresh timer ------------------
    # Rebuilds QueueList and RecentList children from disk state every 2s.
    # Uses WPF DispatcherTimer so it stops naturally when the popup hides.
    $renderQueue = {
        $q = @(Read-Queue) | Sort-Object -Property AddedAt -Descending
        $CtlLocal.QueueList.Children.Clear()
        if ($q.Count -eq 0) {
            $CtlLocal.QueueEmpty.Visibility = 'Visible'
            return
        }
        $CtlLocal.QueueEmpty.Visibility = 'Collapsed'
        foreach ($job in $q) {
            $CtlLocal.QueueList.Children.Add((Build-QueueRow $job)) | Out-Null
        }
    }.GetNewClosure()

    $renderRecent = {
        $r = @(Get-Recent)
        $CtlLocal.RecentList.Children.Clear()
        if ($r.Count -eq 0) {
            $CtlLocal.RecentEmpty.Visibility = 'Visible'
            return
        }
        $CtlLocal.RecentEmpty.Visibility = 'Collapsed'
        foreach ($entry in $r) {
            $CtlLocal.RecentList.Children.Add((Build-RecentRow $entry)) | Out-Null
        }
    }.GetNewClosure()

    # Store refresh callbacks on the window so Show-Popup can fire them
    $w | Add-Member -MemberType NoteProperty -Name '__RenderQueue'  -Value $renderQueue  -Force
    $w | Add-Member -MemberType NoteProperty -Name '__RenderRecent' -Value $renderRecent -Force

    # Timer only ticks while the popup is visible; Start()/Stop() on
    # show / hide instead of a runs-forever loop with early return
    # (small battery win).
    $refreshTimer = New-Object System.Windows.Threading.DispatcherTimer
    $refreshTimer.Interval = [TimeSpan]::FromSeconds(2)
    $refreshTimer.Add_Tick({
        try { & $renderQueue; & $renderRecent } catch { Log-Err "popup refresh: $($_.Exception.Message)" }
    }.GetNewClosure())
    $WinLocal.Add_IsVisibleChanged({
        if ($WinLocal.IsVisible) { $refreshTimer.Start() } else { $refreshTimer.Stop() }
    }.GetNewClosure())

    # Queue tab "Clear finished" button
    $ctl.QueueClearDone.Add_Click({
        try { Clear-QueueDone; & $renderQueue } catch { Log-Err "clear-done: $($_.Exception.Message)" }
    }.GetNewClosure())

    # Expose helpers on the window so Show-Popup can drive tab switching
    # and other external callers can reach controls / callbacks.
    $w | Add-Member -MemberType NoteProperty -Name '__SwitchTab' -Value $switchTab -Force
    $w | Add-Member -MemberType NoteProperty -Name '__Controls'  -Value $ctl -Force

    $script:Window = $w
    return $w
}

function Get-DockedPosition([Windows.Window]$w) {
    # DPI-aware dock to bottom-right of the primary screen's working area.
    # SystemParameters.WorkArea returns a Rect in DIPs -- the same unit WPF's
    # Window.Left / Top expect. Using Screen.WorkingArea (device pixels) with
    # WPF DIP Width produced off-screen positions on scaled displays.
    $wa = [System.Windows.SystemParameters]::WorkArea
    $x = $wa.Right  - $w.Width  - 24
    $y = $wa.Bottom - $w.Height - 24
    # Clamp inside the work area (defensive)
    if ($x -lt $wa.Left) { $x = $wa.Left + 24 }
    if ($y -lt $wa.Top)  { $y = $wa.Top  + 24 }
    return @{ X = $x; Y = $y }
}

function Test-PopupOnScreen([double]$x, [double]$y, [double]$w, [double]$h) {
    # Returns $true if the given rect intersects any monitor's working area.
    # Used to reject stale saved positions from a monitor that no longer exists.
    foreach ($scr in [System.Windows.Forms.Screen]::AllScreens) {
        $wa = $scr.WorkingArea
        # WorkingArea is device pixels; convert to DIPs using the primary DPI.
        # Good enough for a sanity check ('is this roughly on some screen?').
        if (($x + $w) -gt $wa.Left -and $x -lt $wa.Right -and
            ($y + $h) -gt $wa.Top  -and $y -lt $wa.Bottom) {
            return $true
        }
    }
    return $false
}

function Show-Popup {
    param(
        [ValidateSet('paste','queue','recent')][string]$Tab = 'paste'
    )
    Log-Info "Show-Popup called (tab=$Tab)"
    try {
        $w   = Load-PopupWindow
        if (-not $w) { Log-Err 'Load-PopupWindow returned $null'; return }
        $ctl = $w.__Controls
        $cfg = Get-Config

        # Position: use remembered position if it lands on a real screen,
        # otherwise fall back to docked bottom-right. This handles the case
        # of a monitor being disconnected between sessions.
        $usedRemembered = $false
        if ($null -ne $cfg.popupPositionX -and $null -ne $cfg.popupPositionY) {
            $rx = [double]$cfg.popupPositionX
            $ry = [double]$cfg.popupPositionY
            if (Test-PopupOnScreen $rx $ry $w.Width $w.Height) {
                $w.Left = $rx
                $w.Top  = $ry
                $usedRemembered = $true
            }
        }
        if (-not $usedRemembered) {
            $p = Get-DockedPosition $w
            $w.Left = $p.X
            $w.Top  = $p.Y
        }

        # Prefill URL from clipboard if it looks like one
        try {
            $clip = [System.Windows.Forms.Clipboard]::GetText()
            if ($clip -and (Test-IsUrl $clip.Trim())) {
                $ctl.UrlBox.Text = $clip.Trim()
                $ctl.Hint.Text = 'Detected URL on clipboard -- press Enter to grab it.'
            } else {
                $ctl.Hint.Text = 'Tip: copy a link first and it will auto-fill here.'
            }
        } catch {}

        # Switch to requested tab
        $tabMap = @{ paste='TabPaste'; queue='TabQueue'; recent='TabRecent' }
        & $w.__SwitchTab $tabMap[$Tab]

        if ($w.WindowState -eq 'Minimized') { $w.WindowState = 'Normal' }
        $w.Show()
        $w.Activate()
        # Force to foreground even when another window has focus.
        $w.Topmost = $true
        $w.Topmost = $false
        if ($Tab -eq 'paste') { $ctl.UrlBox.Focus(); $ctl.UrlBox.SelectAll() }
        # Do an immediate refresh of Queue and Recent so the popup shows
        # current state instantly (don't wait 2s for the next timer tick).
        try { & $w.__RenderQueue; & $w.__RenderRecent } catch { Log-Err "initial render: $($_.Exception.Message)" }
        Log-Info "Show-Popup rendered at Left=$($w.Left) Top=$($w.Top) W=$($w.Width) H=$($w.Height) visible=$($w.IsVisible)"
    } catch {
        Log-Err "Show-Popup exception: $($_.Exception.Message) at $($_.InvocationInfo.ScriptLineNumber)"
        throw
    }
}

function Hide-Popup {
    if ($script:Window) { $script:Window.Hide() }
}
