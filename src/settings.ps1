# src/settings.ps1
# Loads ui/settings.xaml, binds controls to config values, and persists
# edits via Update-Config. Autostart toggle also creates/removes the
# shell:startup shortcut so it takes effect immediately.
#
# Public functions:
#   Show-Settings                 -- open the settings window
#
# Dot-source: . "$PSScriptRoot\settings.ps1"

Add-Type -AssemblyName PresentationFramework | Out-Null
Add-Type -AssemblyName PresentationCore      | Out-Null
Add-Type -AssemblyName WindowsBase           | Out-Null
Add-Type -AssemblyName System.Windows.Forms  | Out-Null

. "$PSScriptRoot\utils.ps1"
# Confirm-ArcadeDialog lives in tray.ps1 -- do NOT dot-source it here
# (creates a load-order cycle; grab-app.ps1 sources both into the same
# scope, so the function is visible at click time).

$script:SettingsWindow = $null

function Get-AutostartShortcutPath {
    Join-Path ([Environment]::GetFolderPath('Startup')) 'grab.lnk'
}

function Set-Autostart([bool]$enable) {
    # Toggles shell:startup shortcut immediately (config also stored so
    # install.ps1 respects the choice on next run).
    $lnk = Get-AutostartShortcutPath
    if ($enable) {
        $wsh = New-Object -ComObject WScript.Shell
        $sc = $wsh.CreateShortcut($lnk)
        $sc.TargetPath = 'powershell.exe'
        $entry = Join-Path (Split-Path $PSScriptRoot -Parent) 'grab-app.ps1'
        $sc.Arguments  = '-STA -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $entry + '"'
        $sc.WorkingDirectory = (Split-Path $PSScriptRoot -Parent)
        # Prefer the bundled multi-res icon; fall back to a shell glyph.
        $repoRoot = Split-Path $PSScriptRoot -Parent
        $grabIco  = Join-Path $repoRoot 'assets\icon.ico'
        $sc.IconLocation = if (Test-Path -LiteralPath $grabIco) { $grabIco } else { "$env:SystemRoot\System32\imageres.dll,109" }
        $sc.Description  = 'Launch grab tray at login'
        $sc.Save()
    } else {
        if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force -ErrorAction SilentlyContinue }
    }
}

function _GrabFontsUri {
    # file:///D:/path/to/assets/fonts/  -- WPF FontFamily URI + '#Family'
    $abs = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets\fonts'
    return 'file:///' + (($abs -replace '\\','/').TrimEnd('/')) + '/'
}

function _GrabThemeUri {
    # Returns the file:/// URI of a runtime copy of theme.xaml with the
    # __GRAB_FONTS__ tokens already substituted (see utils.ps1 for why).
    $srcTheme = Join-Path (Split-Path $PSScriptRoot -Parent) 'ui\theme.xaml'
    return Get-RuntimeThemeUri -SourceThemePath $srcTheme -FontsUri (_GrabFontsUri)
}

function _GrabAssetsUri {
    # file:///D:/path/to/assets -- base; callers append /<file>
    $abs = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets'
    return 'file:///' + (($abs -replace '\\','/').TrimEnd('/'))
}

function Load-SettingsWindow {
    if ($script:SettingsWindow) { return $script:SettingsWindow }

    $xamlPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'ui\settings.xaml'
    # Substitute the three placeholder tokens via the unified helper so bundled
    # fonts, the shared theme.xaml dictionary, and the scanlines PNG all
    # resolve at runtime. See popup.ps1 for the same pattern.
    $rawXaml  = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
    $xamlText = Invoke-GrabTokenReplace -XamlText $rawXaml `
        -FontsUri  (_GrabFontsUri) `
        -ThemeUri  (_GrabThemeUri) `
        -AssetsUri (_GrabAssetsUri)
    $w = [Windows.Markup.XamlReader]::Parse($xamlText)

    $ctl = @{}
    foreach ($n in @('TitleBar','MinBtn','CloseBtn',
                     'DownloadFolder','BrowseBtn','AskBeforeEach',
                     'ConcurrencySlider','ConcurrencyLabel',
                     'CookieBrowser','VideoQuality','ToastsEnabled','ClipboardWatch','Autostart',
                     'SensitiveByDefault','SensitiveSites',
                     'CrtScanlines','ScanlinesOverlay',
                     'VersionLabel','OpenStateBtn','OpenLogsBtn',
                     'ResetBtn','SaveBtn','CancelBtn','StatusLine')) {
        $ctl[$n] = $w.FindName($n)
    }

    # Local captures for closures
    $CtlLocal = $ctl
    $WinLocal = $w

    # ---------- Titlebar behavior ------------------------------------------
    $ctl.TitleBar.Add_MouseLeftButtonDown({ $WinLocal.DragMove() }.GetNewClosure())
    $ctl.MinBtn.Add_Click({ $WinLocal.WindowState = 'Minimized' }.GetNewClosure())
    $ctl.CloseBtn.Add_Click({ $WinLocal.Hide() }.GetNewClosure())
    $w.Add_Closing({ param($sender, $e) $e.Cancel = $true; $sender.Hide() })

    # ---------- Concurrency slider live label ------------------------------
    $ctl.ConcurrencySlider.Add_ValueChanged({
        $CtlLocal.ConcurrencyLabel.Text = [int]$CtlLocal.ConcurrencySlider.Value
    }.GetNewClosure())

    # ---------- CRT scanlines live preview ---------------------------------
    # Flip the overlay Visibility as soon as the box changes; the config
    # value only writes on Save, so users can toggle back and forth freely.
    $ctl.CrtScanlines.Add_Checked({
        if ($CtlLocal.ScanlinesOverlay) { $CtlLocal.ScanlinesOverlay.Visibility = 'Visible' }
    }.GetNewClosure())
    $ctl.CrtScanlines.Add_Unchecked({
        if ($CtlLocal.ScanlinesOverlay) { $CtlLocal.ScanlinesOverlay.Visibility = 'Collapsed' }
    }.GetNewClosure())

    # ---------- Browse folder ---------------------------------------------
    $ctl.BrowseBtn.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Pick a default download folder for grab'
        $dlg.ShowNewFolderButton = $true
        $current = $CtlLocal.DownloadFolder.Text
        if ($current -and (Test-Path -LiteralPath $current)) { $dlg.SelectedPath = $current }
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $CtlLocal.DownloadFolder.Text = $dlg.SelectedPath
        }
    }.GetNewClosure())

    # ---------- About buttons ---------------------------------------------
    $ctl.OpenStateBtn.Add_Click({
        $p = Get-AppDataPath
        if (Test-Path -LiteralPath $p) { Start-Process explorer.exe $p }
    }.GetNewClosure())
    $ctl.OpenLogsBtn.Add_Click({
        $p = Get-LogFolder
        if (Test-Path -LiteralPath $p) { Start-Process explorer.exe $p }
    }.GetNewClosure())

    # ---------- Save / Cancel / Reset -------------------------------------
    $ctl.SaveBtn.Add_Click({
        try {
            $folder = $CtlLocal.DownloadFolder.Text.Trim()
            if (-not $folder) {
                $CtlLocal.StatusLine.Text = 'Download folder cannot be empty.'
                return
            }
            if (-not (Test-Path -LiteralPath $folder)) {
                try {
                    New-Item -ItemType Directory -Path $folder -Force -ErrorAction Stop | Out-Null
                } catch {
                    $CtlLocal.StatusLine.Text = "Can't create folder: $($_.Exception.Message)"
                    return
                }
            }

            # Parse sensitive-sites textarea: one pattern per line, trim, drop
            # blanks / comment-lines (starting with #), keep the rest.
            $rawLines = $CtlLocal.SensitiveSites.Text -split "`r?`n"
            $sitePatterns = @($rawLines | ForEach-Object { $_.Trim() } |
                              Where-Object { $_ -and -not $_.StartsWith('#') })

            $updates = @{
                downloadFolder     = $folder
                askBeforeEach      = [bool]$CtlLocal.AskBeforeEach.IsChecked
                concurrency        = [int]$CtlLocal.ConcurrencySlider.Value
                cookieBrowser      = ($CtlLocal.CookieBrowser.SelectedItem.Content).ToString()
                videoQuality       = ($CtlLocal.VideoQuality.SelectedItem.Content).ToString()
                toastsEnabled      = [bool]$CtlLocal.ToastsEnabled.IsChecked
                clipboardWatch     = [bool]$CtlLocal.ClipboardWatch.IsChecked
                autostart          = [bool]$CtlLocal.Autostart.IsChecked
                sensitiveByDefault = [bool]$CtlLocal.SensitiveByDefault.IsChecked
                sensitiveSites     = $sitePatterns
                crtScanlines       = [bool]$CtlLocal.CrtScanlines.IsChecked
                firstRunComplete   = $true
            }
            Update-Config $updates | Out-Null

            # Autostart shortcut mirrors the toggle immediately
            try { Set-Autostart $updates.autostart } catch {
                Log-Warn "autostart toggle failed: $($_.Exception.Message)"
            }

            $CtlLocal.StatusLine.Text = 'Saved.'
            Log-Info "settings saved: folder=$folder, concurrency=$($updates.concurrency), clipboard=$($updates.clipboardWatch), autostart=$($updates.autostart)"
            $WinLocal.Hide()
        } catch {
            $CtlLocal.StatusLine.Text = "Save failed: $($_.Exception.Message)"
            Log-Err "settings save exception: $($_.Exception.Message)"
        }
    }.GetNewClosure())

    $ctl.CancelBtn.Add_Click({ $WinLocal.Hide() }.GetNewClosure())

    $ctl.ResetBtn.Add_Click({
        # Arcade-styled Yes/No modal instead of the native Windows MessageBox,
        # so nothing in this window falls back to Windows-native chrome.
        # Falls back to $false (no-op) if the dialog can't render.
        $confirmed = $false
        if (Get-Command Confirm-ArcadeDialog -ErrorAction SilentlyContinue) {
            $confirmed = Confirm-ArcadeDialog `
                -Title   'RESET ALL SETTINGS?' `
                -Message ("Reset every setting to its default value?`n`n" +
                          "This does NOT delete downloads or history -- only the settings on this screen.") `
                -YesLabel 'RESET' `
                -NoLabel  'CANCEL' `
                -Owner    $WinLocal
        }
        if ($confirmed) {
            # Delegated so Settings, install.ps1, Get-Config, and tests share
            # one definition of "default download folder" (audit P0-6).
            $defaultFolder = Get-DownloadFolderDefault
            $CtlLocal.DownloadFolder.Text = $defaultFolder
            $CtlLocal.AskBeforeEach.IsChecked = $false
            $CtlLocal.ConcurrencySlider.Value = 3
            $CtlLocal.CookieBrowser.SelectedIndex = 0
            $CtlLocal.VideoQuality.SelectedIndex = 0
            $CtlLocal.ToastsEnabled.IsChecked  = $true
            $CtlLocal.ClipboardWatch.IsChecked = $false
            $CtlLocal.Autostart.IsChecked      = $true
            $CtlLocal.SensitiveByDefault.IsChecked = $false
            $CtlLocal.SensitiveSites.Text = ''
            $CtlLocal.CrtScanlines.IsChecked = $true
            $CtlLocal.StatusLine.Text = 'Defaults loaded. Click Save to apply.'
        }
    }.GetNewClosure())

    $w | Add-Member -MemberType NoteProperty -Name '__Controls' -Value $ctl -Force
    $script:SettingsWindow = $w
    return $w
}

function Show-Settings {
    Log-Info 'Show-Settings called'
    try {
        $w = Load-SettingsWindow
        $ctl = $w.__Controls
        $cfg = Get-Config

        # Bind current values into controls
        $ctl.DownloadFolder.Text = if ($cfg.downloadFolder) { [string]$cfg.downloadFolder } else { Get-DownloadFolderDefault }
        $ctl.AskBeforeEach.IsChecked = [bool]$cfg.askBeforeEach
        $ctl.ConcurrencySlider.Value = [int]$cfg.concurrency
        $ctl.ConcurrencyLabel.Text = [string][int]$cfg.concurrency

        # Cookie browser combo
        $browserVal = if ($cfg.cookieBrowser) { [string]$cfg.cookieBrowser } else { 'chrome' }
        $found = $false
        for ($i = 0; $i -lt $ctl.CookieBrowser.Items.Count; $i++) {
            if (($ctl.CookieBrowser.Items[$i].Content).ToString() -eq $browserVal) {
                $ctl.CookieBrowser.SelectedIndex = $i
                $found = $true
                break
            }
        }
        if (-not $found) { $ctl.CookieBrowser.SelectedIndex = 0 }

        # Video quality combo
        $qVal = if ($cfg.videoQuality) { [string]$cfg.videoQuality } else { 'best' }
        $qFound = $false
        for ($i = 0; $i -lt $ctl.VideoQuality.Items.Count; $i++) {
            if (($ctl.VideoQuality.Items[$i].Content).ToString() -eq $qVal) {
                $ctl.VideoQuality.SelectedIndex = $i
                $qFound = $true
                break
            }
        }
        if (-not $qFound) { $ctl.VideoQuality.SelectedIndex = 0 }

        $ctl.ToastsEnabled.IsChecked  = [bool]$cfg.toastsEnabled
        $ctl.ClipboardWatch.IsChecked = [bool]$cfg.clipboardWatch
        $ctl.Autostart.IsChecked      = [bool]$cfg.autostart
        $ctl.SensitiveByDefault.IsChecked = [bool]$cfg.sensitiveByDefault
        # CRT scanlines: default $true (see Get-Config back-fill).
        $ctl.CrtScanlines.IsChecked   = [bool]$cfg.crtScanlines
        # Live-preview: toggling the checkbox flips the overlay right away.
        if ($ctl.ScanlinesOverlay) {
            $ctl.ScanlinesOverlay.Visibility = if ($cfg.crtScanlines) { 'Visible' } else { 'Collapsed' }
        }
        # Show current sensitive-sites list, one per line
        $ctl.SensitiveSites.Text = if ($cfg.sensitiveSites) { ($cfg.sensitiveSites -join "`r`n") } else { '' }
        $ctl.VersionLabel.Text = "grab v$($cfg.version)  ·  state: $(Get-AppDataPath)"
        $ctl.StatusLine.Text = ''

        if ($w.WindowState -eq 'Minimized') { $w.WindowState = 'Normal' }
        $w.Show()
        $w.Activate()
        $w.Topmost = $true
        $w.Topmost = $false
    } catch {
        Log-Err "Show-Settings exception: $($_.Exception.Message)"
        throw
    }
}
