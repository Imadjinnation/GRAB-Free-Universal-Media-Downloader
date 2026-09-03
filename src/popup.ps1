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

# WinForms is cheap and needed at row-build time (Screen.WorkingArea for
# multi-monitor checks). WPF assemblies are deferred to Ensure-WpfLoaded
# so the first tray icon appears without waiting on their JIT (see
# src/tray.ps1 Start-Tray phase 1). Load-PopupWindow calls Ensure-WpfLoaded
# up front so any WPF class reference in this file resolves.
Add-Type -AssemblyName System.Windows.Forms  | Out-Null

. "$PSScriptRoot\utils.ps1"
. "$PSScriptRoot\queue.ps1"

$script:Window = $null

# ==========================================================================
# Row builders for Queue and Recent tabs
# ==========================================================================

function _StatusColor([string]$status) {
    # Per-status color mapping (mockup-matched v0.2.2):
    #   pending          -> amber   #FFD447  (queued to run soon)
    #   queued           -> muted   #8974A6  (dark, waiting)
    #   running          -> amber   #FFD447  (live, in-flight)
    #   done             -> green   #8DFF6B  (lime success)
    #   failed           -> red     #FF4444  (REC red)
    #   cancelled        -> muted   #8974A6  (out of the flow)
    switch ($status) {
        'pending'   { '#FFD447' }
        'queued'    { '#8974A6' }
        'running'   { '#FFD447' }
        'done'      { '#8DFF6B' }
        'failed'    { '#FF4444' }
        'cancelled' { '#8974A6' }
        default     { '#8974A6' }
    }
}

function _CategoryBadge([string]$url) {
    # Returns @{ Label, Color } for the small VT323 UPPERCASE chip that
    # sits at the head of a Recent row. Colors follow the mockup palette:
    #   Videos = amber, Comics = magenta, Audio = cyan,
    #   Images = green, Social = pink, Misc = muted gray.
    $cat = try { Get-CategoryForUrl $url } catch { 'Misc' }
    $map = @{
        'Videos' = @{ Label='VID'; Color='#FFD447' }
        'Comics' = @{ Label='COM'; Color='#FF2E93' }
        'Audio'  = @{ Label='AUD'; Color='#00E5D2' }
        'Images' = @{ Label='IMG'; Color='#8DFF6B' }
        'Social' = @{ Label='SOC'; Color='#FF2D8C' }
        'Misc'   = @{ Label='MSC'; Color='#8974A6' }
    }
    if ($map.ContainsKey($cat)) { return $map[$cat] }
    return $map['Misc']
}

function Get-QueueStatusText {
    # Footer status line (PART H2). Returns "SYS: READY . queue idle" when the
    # queue is empty, otherwise "RUN: n . WAIT: m . CONCURRENCY c". Formatted
    # for the VT323 footer -- middle-dot separators (chr 183), ALL CAPS labels.
    try {
        $q = @(Read-Queue)
        if ($q.Count -eq 0) { return "SYS: READY $([char]0x00B7) queue idle" }
        $running = @($q | Where-Object { $_.Status -eq 'running' }).Count
        $waiting = @($q | Where-Object { $_.Status -in @('pending','queued') }).Count
        $conc = try { (Get-Config).concurrency } catch { 3 }
        return "RUN: $running $([char]0x00B7) WAIT: $waiting $([char]0x00B7) CONCURRENCY $conc"
    } catch {
        return "SYS: READY $([char]0x00B7) queue idle"
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
    $statusUp    = ($job.Status).ToUpper()
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
        "Foreground=`"$statusColor`" Background=`"Transparent`" BorderThickness=`"0`" " +
        "Cursor=`"Hand`" FontSize=`"13`" Width=`"26`" Height=`"26`" Margin=`"6,0,0,0`"/>"
    } else { '' }

    # Card layout (mockup v0.2.2): NO left border rail. Instead, a 10x10
    # glowing LED (Ellipse + DropShadowEffect same color as fill) at the row
    # head is the single strongest state signal. Card background pushed
    # slightly darker (#12081E) to match mockup queue rows; site names use
    # VT323 monospace 11px in teal-cyan #00E5D2 per PART C.
    $xaml = @"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        CornerRadius="6"
        Background="#12081E"
        BorderBrush="#241A3E"
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
             VerticalAlignment="Center" Margin="0,0,10,0">
      <Ellipse.Effect>
        <DropShadowEffect Color="$statusColor" BlurRadius="10" ShadowDepth="0" Opacity="0.9"/>
      </Ellipse.Effect>
    </Ellipse>
    <StackPanel Grid.Column="1">
      <TextBlock Foreground="#F5EBD0" FontSize="12" TextTrimming="CharacterEllipsis" TextWrapping="NoWrap">
        <Run FontFamily="__GRAB_FONTS__#VT323" FontSize="11" Foreground="#00E5D2" Text="$siteShortEs "/><Run Foreground="#8974A6" Text="$urlShort"/>
      </TextBlock>
      <TextBlock Text="$msgEs" Foreground="#8974A6" FontSize="10" Margin="0,2,0,0" TextTrimming="CharacterEllipsis"/>
    </StackPanel>
    <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
      <TextBlock Text="$statusUp" Foreground="$statusColor" FontSize="11"
                 FontFamily="__GRAB_FONTS__#VT323" VerticalAlignment="Center"/>
      $actionBlock
    </StackPanel>
  </Grid>
</Border>
"@
    $xaml = Invoke-GrabTokenReplace -XamlText $xaml -FontsUri (_GrabFontsUri)
    $row = [Windows.Markup.XamlReader]::Parse($xaml)
    $btn = $row.FindName('ActionBtn')
    if ($btn) {
        # Audit P2-44: capture only the id; re-read the job's current status
        # inside the click handler. Previously the closure captured `$status`
        # at row-build time, so a row that was 'pending' when built but had
        # transitioned to 'running' by click time still hit the Cancel branch
        # (fine) -- and, worse, a 'failed' row that had auto-retried before
        # the click hit Retry when it should have Cancelled. Reading fresh
        # closes the stale-status window.
        $jobId  = $job.Id
        $btn.Add_Click({
            $current = @(Read-Queue | Where-Object { $_.Id -eq $jobId } | Select-Object -First 1)
            $status = if ($current.Count -gt 0) { $current[0].Status } else { 'pending' }
            if ($status -in @('pending','running')) { Cancel-QueueJob $jobId | Out-Null }
            else { Retry-QueueJob $jobId }
        }.GetNewClosure())
    }
    return $row
}

function Build-RecentRow([object]$entry) {
    $siteShort   = Get-SiteName $entry.Url
    $urlShort    = _EscapeXaml (_TrimUrl $entry.Url 55)
    $siteShortEs = _EscapeXaml $siteShort
    $doneAt      = if ($entry.DoneAt) {
        try {
            # Audit v0.3.0-pass2 finding 38/56: parse the 'o' stamp with
            # InvariantCulture (fixed format) and display in the user's
            # own culture so they see localised month names / hour format.
            $dt = [datetime]::ParseExact([string]$entry.DoneAt, 'o', [Globalization.CultureInfo]::InvariantCulture)
            $dt.ToString('MMM d, HH:mm', [Globalization.CultureInfo]::CurrentCulture)
        } catch { [string]$entry.DoneAt }
    } else { '' }
    $summary     = "$($entry.FilesAdded) file(s) via $($entry.ToolUsed)"
    # Mockup success/fail: lime green (#8DFF6B) for done, red (#FF4444) for failed
    $statusColor = if ($entry.Status -eq 'done') { '#8DFF6B' } else { '#FF4444' }
    # Category badge (VT323 UPPERCASE 10px chip per PART A #3):
    $badge = _CategoryBadge $entry.Url
    $badgeLabel = $badge.Label
    $badgeColor = $badge.Color
    # -LiteralPath so folder names with [ ] don't get wildcard-parsed
    # into a phantom "Missing" state.
    $destExists  = ($entry.Dest -and (Test-Path -LiteralPath $entry.Dest))
    $openLabel   = if ($destExists) { 'Open' } else { 'Missing' }
    $openEnabled = if ($destExists) { 'True' } else { 'False' }

    $xaml = @"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        CornerRadius="6"
        Background="#12081E"
        BorderBrush="#241A3E"
        BorderThickness="1"
        Padding="10,8"
        Margin="0,0,0,6">
  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="Auto"/>
      <ColumnDefinition Width="*"/>
      <ColumnDefinition Width="Auto"/>
    </Grid.ColumnDefinitions>
    <!-- Category badge: 1px rounded VT323 UPPERCASE 10px chip -->
    <Border Grid.Column="0" CornerRadius="1"
            BorderBrush="$badgeColor" BorderThickness="1"
            Background="Transparent"
            Padding="5,1"
            Margin="0,0,8,0"
            VerticalAlignment="Center">
      <TextBlock Text="$badgeLabel" Foreground="$badgeColor"
                 FontFamily="__GRAB_FONTS__#VT323" FontSize="10"
                 VerticalAlignment="Center"/>
    </Border>
    <StackPanel Grid.Column="1">
      <TextBlock Foreground="#F5EBD0" FontSize="12" TextTrimming="CharacterEllipsis" TextWrapping="NoWrap">
        <Run FontFamily="__GRAB_FONTS__#VT323" FontSize="11" Foreground="#00E5D2" Text="$siteShortEs "/><Run Foreground="#8974A6" Text="$urlShort"/>
      </TextBlock>
      <TextBlock Foreground="#8974A6" FontSize="10" Margin="0,2,0,0">
        <Run Text="$doneAt"/><Run Text=" &#183; "/><Run Text="$summary"/>
      </TextBlock>
    </StackPanel>
    <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
      <Button x:Name="OpenBtn" Content="$openLabel" IsEnabled="$openEnabled"
              Foreground="#00E5D2" Background="Transparent" BorderBrush="#00E5D2" BorderThickness="1"
              Cursor="Hand" FontSize="10" FontFamily="__GRAB_FONTS__#VT323"
              Padding="10,4" Margin="0,0,4,0"/>
      <Button x:Name="RetryBtn" Content="Re-grab"
              Foreground="#00E5D2" Background="Transparent" BorderBrush="#00E5D2" BorderThickness="1"
              Cursor="Hand" FontSize="10" FontFamily="__GRAB_FONTS__#VT323"
              Padding="10,4"/>
    </StackPanel>
  </Grid>
</Border>
"@
    $xaml = Invoke-GrabTokenReplace -XamlText $xaml -FontsUri (_GrabFontsUri)
    $row = [Windows.Markup.XamlReader]::Parse($xaml)
    $openBtn  = $row.FindName('OpenBtn')
    $retryBtn = $row.FindName('RetryBtn')
    if ($openBtn) {
        $dest = $entry.Dest
        $openBtn.Add_Click({
            # Audit P2-45: Start-Process explorer.exe $dest tokenises on space,
            # so a folder like "C:\My Downloads\Videos" opens as two separate
            # explorer instances. Wrap in double quotes via -ArgumentList so
            # explorer sees one intact path.
            if ($dest -and (Test-Path -LiteralPath $dest)) {
                Start-Process explorer.exe -ArgumentList ('"' + $dest + '"')
            }
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

function _GrabFontsUri {
    # file:///D:/path/to/assets/fonts/  -- WPF FontFamily URI + '#Family'
    # returns the trailing-slash version because "URI/#Name" is the well-formed
    # shape WPF wants (fonts folder + hash + family name).
    $abs = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets\fonts'
    return 'file:///' + (($abs -replace '\\','/').TrimEnd('/')) + '/'
}

function _GrabThemeUri {
    # Returns the file:/// URI of a runtime copy of theme.xaml with the
    # __GRAB_FONTS__ tokens already substituted, so theme-styled controls
    # (ArcadePrimary/Tab/Ghost etc.) actually resolve to Silkscreen/VT323/
    # Inter instead of the WPF default. See Get-RuntimeThemeUri in utils.ps1
    # for the rationale.
    $srcTheme = Join-Path (Split-Path $PSScriptRoot -Parent) 'ui\theme.xaml'
    return Get-RuntimeThemeUri -SourceThemePath $srcTheme -FontsUri (_GrabFontsUri)
}

function _GrabAssetsUri {
    # file:///D:/path/to/assets -- base; callers append /<file>
    $abs = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets'
    return 'file:///' + (($abs -replace '\\','/').TrimEnd('/'))
}

function Load-PopupWindow {
    if ($script:Window) { return $script:Window }
    # First time through -- ensure the WPF assemblies are loaded (tray.ps1
    # defers them so the tray icon appears fast; the popup is the first
    # user surface that actually needs XamlReader / Window classes).
    Ensure-WpfLoaded

    $xamlPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'ui\popup.xaml'
    # Substitute the placeholders via the unified helper:
    #   __GRAB_FONTS__  -> file:///.../assets/fonts/  (Silkscreen/VT323/Inter)
    #   __GRAB_THEME__  -> file:///.../ui/theme.xaml  (shared arcade styles)
    #   __GRAB_ASSETS__ -> file:///.../assets         (scanlines.png)
    # Tests apply the same substitution before parsing.
    $rawXaml  = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
    $xamlText = Invoke-GrabTokenReplace -XamlText $rawXaml `
        -FontsUri  (_GrabFontsUri) `
        -ThemeUri  (_GrabThemeUri) `
        -AssetsUri (_GrabAssetsUri)
    # XamlReader.Parse can throw XamlParseException on malformed XAML; the
    # exception used to bubble out of Show-Popup and kill the tray's WPF
    # pump (audit P1-15). Now we catch, toast, and return $null so the tray
    # keeps running while a diagnostic sits in the log.
    try {
        $w = [Windows.Markup.XamlReader]::Parse($xamlText)
    } catch {
        Log-Err "popup XAML parse failed: $($_.Exception.Message)"
        try { Send-Toast 'grab UI failed to load' 'Check the log' } catch {}
        return $null
    }

    # Named element handles
    $ctl = @{}
    foreach ($n in @('TitleBar','MinBtn','CloseBtn','RecDot',
                     'TabPaste','TabQueue','TabRecent',
                     'PastePanel','QueuePanel','RecentPanel',
                     'UrlBox','MultiBox','SingleInputBorder','MultiInputBorder',
                     'Hint','HintKicker','StatusLine','ToggleMulti','GrabBtn','SensitiveToggle',
                     'AmberCaret','FooterStatus',
                     'QueueList','QueueEmpty','QueueClearDone',
                     'RecentList','RecentEmpty',
                     'ClearRecentBtn','ClearOldRecentBtn',
                     'ScanlinesOverlay')) {
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
    # Audit v0.3.0-pass2 P3-77: persist popup Width/Height too. ResizeMode
    # is CanResizeWithGrip; without saving the size, a user-resized popup
    # snaps back to the XAML default (480x420) on next open.
    $w.Add_SizeChanged({
        if ($WinLocal -and $WinLocal.WindowState -eq 'Normal') {
            Update-Config @{ popupWidth = [int]$WinLocal.Width; popupHeight = [int]$WinLocal.Height } | Out-Null
        }
    }.GetNewClosure())

    # ---------- Tab switching ----------------------------------------------
    # Three-color arcade rule (PART A #1):
    #   PASTE  -> amber underline  (Tag = "active-amber")
    #   QUEUE  -> cyan  underline  (Tag = "active-cyan")
    #   RECENT -> green underline  (Tag = "active-green")
    # The ArcadeTab template picks the color from the Tag value.
    $tabColorMap = @{
        'TabPaste'  = 'active-amber'
        'TabQueue'  = 'active-cyan'
        'TabRecent' = 'active-green'
    }
    $switchTab = {
        param($active)
        foreach ($t in @('TabPaste','TabQueue','TabRecent')) {
            $CtlLocal[$t].Tag = if ($t -eq $active) { $tabColorMap[$t] } else { $null }
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
            # Audit P2-40: askBeforeEach implementation. When on, pop the
            # Confirm-DownloadDialog for EACH url and honor its verdict
            # (Cancel skips the url; CHOOSE FOLDER supplies a one-time Dest
            # override without touching config). Off (default) keeps the
            # zero-friction paste-and-go flow.
            $cfg = try { Get-Config } catch { $null }
            $askBeforeEach = $false
            try { $askBeforeEach = [bool]$cfg.askBeforeEach } catch {}
            $added = 0
            if ($askBeforeEach -and (Get-Command Confirm-DownloadDialog -ErrorAction SilentlyContinue)) {
                foreach ($u in $urls) {
                    $defaultCat = try { Get-CategoryForUrl $u } catch { 'Misc' }
                    $defaultDom = try { Get-FullDomain     $u } catch { 'misc' }
                    $defaultDest = try {
                        if ($isSensitive) {
                            $priv = if ($cfg.sensitiveFolderName) { [string]$cfg.sensitiveFolderName } else { '.private' }
                            Join-Path $cfg.downloadFolder (Join-Path $defaultCat (Join-Path $priv $defaultDom))
                        } else {
                            Join-Path $cfg.downloadFolder (Join-Path $defaultCat $defaultDom)
                        }
                    } catch { '' }
                    $verdict = Confirm-DownloadDialog -Url $u -Dest $defaultDest -Sensitive:$isSensitive -Owner $WinLocal
                    if ($verdict.Cancelled) {
                        Log-Info "askBeforeEach: user cancelled $u"
                        continue
                    }
                    $addArgs = @{ Urls = @($u) }
                    if ($isSensitive) { $addArgs['Sensitive'] = $true }
                    if ($verdict.Override) { $addArgs['Dest'] = $verdict.Override }
                    $n = Add-QueueJob @addArgs
                    $added = $added + [int]$n
                }
            } else {
                $added = if ($isSensitive) { Add-QueueJob -Urls $urls -Sensitive } else { Add-QueueJob -Urls $urls }
            }
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

    # Amber blinking caret (PART H1): hide the decorative caret while the
    # real TextBox has keyboard focus (WPF's native caret takes over).
    if ($ctl.AmberCaret) {
        $ctl.UrlBox.Add_GotKeyboardFocus({ $CtlLocal.AmberCaret.Visibility = 'Collapsed' }.GetNewClosure())
        $ctl.UrlBox.Add_LostKeyboardFocus({ $CtlLocal.AmberCaret.Visibility = 'Visible'   }.GetNewClosure())
    }
    $ctl.MultiBox.Add_KeyDown({
        param($sender, $e)
        if ($e.Key -eq 'Return' -and ([System.Windows.Input.Keyboard]::Modifiers -band 'Control')) { & $doSubmit }
        elseif ($e.Key -eq 'Escape') { $WinLocal.Hide() }
    }.GetNewClosure())

    # ---------- Queue + Recent tabs: live-refresh timer ------------------
    # Rebuilds QueueList and RecentList children from disk state every 2s.
    # Uses WPF DispatcherTimer so it stops naturally when the popup hides.
    #
    # Diff-hash short-circuit (audit P1-21): pre-v0.3.0, every tick blindly
    # Clear()ed the StackPanel and rebuilt every row, which visibly flickered
    # AND reset the scroll position mid-read. Now we hash the JSON serialization
    # of what would be rendered and skip the rebuild when nothing has changed
    # since the last tick. First tick always renders (LastQueueHash starts null).
    $LastQueueHashRef  = [ref]$null
    $LastRecentHashRef = [ref]$null

    $renderQueue = {
        $q = @(Read-Queue) | Sort-Object -Property AddedAt -Descending
        # Refresh the footer status text (PART H2). Uses helper so any caller
        # can force-update the footer without knowing the queue schema. Cheap;
        # done every tick regardless of diff-hash result.
        if ($CtlLocal.FooterStatus) {
            try { $CtlLocal.FooterStatus.Text = Get-QueueStatusText } catch {}
        }
        # Hash a JSON snapshot of the fields we actually render (Id, Status,
        # StatusMsg, ToolUsed) so cosmetic churn on unrendered fields doesn't
        # invalidate the cache. MD5 is fine here (collision resistance
        # irrelevant; just a fingerprint).
        $projection = $q | Select-Object Id, Status, StatusMsg, Url, Sensitive
        $json = if ($projection) { ($projection | ConvertTo-Json -Depth 3 -Compress) } else { '[]' }
        $md5  = [System.Security.Cryptography.MD5]::Create()
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
            $hash  = [System.BitConverter]::ToString($md5.ComputeHash($bytes))
        } finally { $md5.Dispose() }
        if ($LastQueueHashRef.Value -eq $hash) { return }
        $LastQueueHashRef.Value = $hash
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
        # Hash the recent list so scroll position isn't reset every tick when
        # nothing new has completed.
        $projection = $r | Select-Object Url, Status, DoneAt, FilesAdded, ToolUsed
        $json = if ($projection) { ($projection | ConvertTo-Json -Depth 3 -Compress) } else { '[]' }
        $md5  = [System.Security.Cryptography.MD5]::Create()
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
            $hash  = [System.BitConverter]::ToString($md5.ComputeHash($bytes))
        } finally { $md5.Dispose() }
        if ($LastRecentHashRef.Value -eq $hash) { return }
        $LastRecentHashRef.Value = $hash
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

    # ---------- Amber caret + REC dot pulse animations ------------------
    # Both are now programmatic so we can Stop() them when the popup hides
    # (audit P1-27). Pre-v0.3.0 they were XAML EventTrigger + Storyboard
    # bound to Loaded, which kept the timeline ticking Opacity every
    # ~15ms even while the popup sat off-screen -- a battery drain that
    # was hard to reason about because it was hidden inside the compiled
    # storyboard tree.
    $caretAnim = New-Object System.Windows.Media.Animation.DoubleAnimation
    $caretAnim.From = 1.0
    $caretAnim.To = 0.0
    $caretAnim.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(450))
    $caretAnim.AutoReverse = $true
    $caretAnim.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    # Freeze() lets WPF share the animation across the shared UI thread
    # without hand-off overhead; safe because we never mutate it after.
    try { $caretAnim.Freeze() } catch {}

    $recAnim = New-Object System.Windows.Media.Animation.DoubleAnimation
    $recAnim.From = 1.0
    $recAnim.To = 0.4
    $recAnim.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(800))
    $recAnim.AutoReverse = $true
    $recAnim.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    try { $recAnim.Freeze() } catch {}

    # Audit v0.3.0-pass2 findings 5, 7, 34/35: honor reduced-motion, and
    # notify the tray tick timer when the popup is visible so QUEUE tab
    # progress stays responsive (never throttled while the user watches).
    $wantAnim = $true
    try { $wantAnim = [System.Windows.SystemParameters]::ClientAreaAnimation } catch {}
    $WinLocal.Add_IsVisibleChanged({
        if ($WinLocal.IsVisible) {
            try { if (Get-Command Notify-PopupVisible -ErrorAction SilentlyContinue) { Notify-PopupVisible $true } } catch {}
            $refreshTimer.Start()
            if ($wantAnim) {
                try { $CtlLocal.AmberCaret.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $caretAnim) } catch {}
                try { $CtlLocal.RecDot.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $recAnim)     } catch {}
            }
        } else {
            try { if (Get-Command Notify-PopupVisible -ErrorAction SilentlyContinue) { Notify-PopupVisible $false } } catch {}
            $refreshTimer.Stop()
            # Passing $null unbinds the animation so the timeline stops
            # firing; Opacity stays at whatever the last frame rendered.
            try { $CtlLocal.AmberCaret.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null) } catch {}
            try { $CtlLocal.RecDot.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)     } catch {}
        }
    }.GetNewClosure())

    # Queue tab "Clear finished" button
    $ctl.QueueClearDone.Add_Click({
        try { Clear-QueueDone; & $renderQueue } catch { Log-Err "clear-done: $($_.Exception.Message)" }
    }.GetNewClosure())

    # Recent tab: CLEAR ALL (danger) + CLEAR > 30 DAYS (ghost). Both only
    # touch recent.json (history) -- the downloaded files themselves stay on
    # disk. Sensitive downloads never appear in Recent to begin with (see
    # Invoke-QueueTick), but non-sensitive entries can still be personal and
    # users need a way to purge them.
    if ($ctl.ClearRecentBtn) {
        $ctl.ClearRecentBtn.Add_Click({
            try {
                # Confirm-ArcadeDialog lives in tray.ps1; both files are dot-
                # sourced into the same scope by grab-app.ps1, so it's visible
                # at click time. Guard for the standalone-test case where the
                # dialog isn't loaded, and fall through to the clear.
                $ok = $true
                if (Get-Command Confirm-ArcadeDialog -ErrorAction SilentlyContinue) {
                    $ok = Confirm-ArcadeDialog `
                        -Title   'CLEAR RECENT?' `
                        -Message ("This removes all entries from the Recent tab.`n`n" +
                                  "Downloaded files stay on disk -- only the history list is cleared.") `
                        -YesLabel 'CLEAR' `
                        -NoLabel  'CANCEL' `
                        -Owner    $WinLocal
                }
                if ($ok) {
                    $removed = Clear-Recent
                    Log-Info "recent CLEAR ALL: removed $removed entry(ies)"
                    & $renderRecent
                }
            } catch { Log-Err "clear-recent: $($_.Exception.Message)" }
        }.GetNewClosure())
    }
    if ($ctl.ClearOldRecentBtn) {
        $ctl.ClearOldRecentBtn.Add_Click({
            try {
                $cutoff = (Get-Date).AddDays(-30)
                $removed = Clear-Recent -OlderThan $cutoff
                Log-Info "recent CLEAR > 30 DAYS: removed $removed entry(ies)"
                & $renderRecent
            } catch { Log-Err "clear-recent-old: $($_.Exception.Message)" }
        }.GetNewClosure())
    }

    # Expose helpers on the window so Show-Popup can drive tab switching
    # and other external callers can reach controls / callbacks.
    $w | Add-Member -MemberType NoteProperty -Name '__SwitchTab' -Value $switchTab -Force
    $w | Add-Member -MemberType NoteProperty -Name '__Controls'  -Value $ctl -Force

    $script:Window = $w
    return $w
}

function _DipToDeviceMatrix([Windows.Window]$w) {
    # Returns the CompositionTarget's TransformToDevice matrix so we can
    # convert DIPs <-> device pixels correctly on scaled monitors. Falls
    # back to identity when there's no PresentationSource yet (window not
    # loaded); caller must handle that.
    try {
        $src = [System.Windows.PresentationSource]::FromVisual($w)
        if ($src -and $src.CompositionTarget) {
            return $src.CompositionTarget.TransformToDevice
        }
    } catch {}
    return $null
}

function Get-DockedPosition([Windows.Window]$w) {
    # DPI-aware dock to bottom-right of the working area of whichever
    # monitor currently contains the mouse cursor. Audit v0.3.0-pass2
    # finding 26: pre-4.5 this always used SystemParameters.WorkArea which
    # is the PRIMARY screen -- users with taskbar on a secondary monitor
    # always got docked to the primary, not the display they're actively
    # working on.
    $curPos = [System.Windows.Forms.Cursor]::Position    # device pixels
    $scr = [System.Windows.Forms.Screen]::FromPoint($curPos)
    $waDev = $scr.WorkingArea                            # device pixels (System.Drawing.Rectangle)
    # Convert device-pixel work area to DIPs. WPF Window.Left/Top are DIPs.
    $mtx = _DipToDeviceMatrix $w
    if ($mtx -and $mtx.M11 -gt 0 -and $mtx.M22 -gt 0) {
        $left   = $waDev.Left   / $mtx.M11
        $top    = $waDev.Top    / $mtx.M22
        $right  = $waDev.Right  / $mtx.M11
        $bottom = $waDev.Bottom / $mtx.M22
    } else {
        # Fallback when the window has no source yet: use SystemParameters
        # for the current monitor as approximated by the primary.
        $wa = [System.Windows.SystemParameters]::WorkArea
        $left = $wa.Left; $top = $wa.Top; $right = $wa.Right; $bottom = $wa.Bottom
    }
    $x = $right  - $w.Width  - 24
    $y = $bottom - $w.Height - 24
    if ($x -lt $left) { $x = $left + 24 }
    if ($y -lt $top)  { $y = $top  + 24 }
    return @{ X = $x; Y = $y }
}

function Test-PopupOnScreen([double]$x, [double]$y, [double]$width, [double]$height, [Windows.Window]$w = $null) {
    # Returns $true if the given rect (in DIPs) intersects any monitor's
    # working area. Audit v0.3.0-pass2 finding 25: on scaled monitors we
    # were comparing DIP left/top with device-pixel WorkingArea.Left/Top
    # so a 150% scaled display made the check pass for garbage positions.
    # Convert device-pixel WorkingArea to DIPs via PresentationSource before
    # the intersect check.
    $mtx = if ($w) { _DipToDeviceMatrix $w } else { $null }
    foreach ($scr in [System.Windows.Forms.Screen]::AllScreens) {
        $wa = $scr.WorkingArea
        if ($mtx -and $mtx.M11 -gt 0 -and $mtx.M22 -gt 0) {
            $l = $wa.Left   / $mtx.M11
            $t = $wa.Top    / $mtx.M22
            $r = $wa.Right  / $mtx.M11
            $b = $wa.Bottom / $mtx.M22
        } else {
            # No matrix yet -- fall back to raw (best-effort; pre-4.5 behavior).
            $l = $wa.Left; $t = $wa.Top; $r = $wa.Right; $b = $wa.Bottom
        }
        if (($x + $width) -gt $l -and $x -lt $r -and
            ($y + $height) -gt $t  -and $y -lt $b) {
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
        # Load-PopupWindow returns $null on a XAML parse failure so the tray
        # survives (audit P1-15). We already toasted; leave quietly.
        if (-not $w) { return }
        $ctl = $w.__Controls
        $cfg = Get-Config

        # Restore remembered size FIRST (audit v0.3.0-pass2 P3-77) so the
        # position math below uses the size the user picked. Guard the values
        # against XAML MinWidth/MinHeight caps -- silently clamp instead of
        # trying to grow the window smaller than WPF allows.
        $sizeProps = $cfg.PSObject.Properties.Name
        if ($sizeProps -contains 'popupWidth' -and $cfg.popupWidth) {
            try {
                $wantW = [double]$cfg.popupWidth
                if ($wantW -ge $w.MinWidth -and $wantW -le $w.MaxWidth) { $w.Width = $wantW }
            } catch {}
        }
        if ($sizeProps -contains 'popupHeight' -and $cfg.popupHeight) {
            try {
                $wantH = [double]$cfg.popupHeight
                if ($wantH -ge $w.MinHeight) { $w.Height = $wantH }
            } catch {}
        }
        # Position: use remembered position if it lands on a real screen,
        # otherwise fall back to docked bottom-right. This handles the case
        # of a monitor being disconnected between sessions.
        $usedRemembered = $false
        if ($null -ne $cfg.popupPositionX -and $null -ne $cfg.popupPositionY) {
            $rx = [double]$cfg.popupPositionX
            $ry = [double]$cfg.popupPositionY
            if (Test-PopupOnScreen $rx $ry $w.Width $w.Height $w) {
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

        # Honor the crtScanlines toggle every time the popup shows so a
        # config change (via Settings) picks up on next open. Overlay is
        # hidden when the config flag is $false.
        if ($ctl.ScanlinesOverlay) {
            $ctl.ScanlinesOverlay.Visibility = if ($cfg.crtScanlines) { 'Visible' } else { 'Collapsed' }
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
        } catch {
            # Audit P2-46: don't just swallow. Clipboard.GetText can fail if
            # another process is holding the clipboard open (browser extensions
            # are notorious). Log once per session so repeated open+focus
            # cycles don't spam the log if the culprit is persistent.
            if (-not $script:ClipReadWarnedThisSession) {
                Log-Warn "Clipboard.GetText failed on popup open: $($_.Exception.Message)"
                $script:ClipReadWarnedThisSession = $true
            }
        }

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
