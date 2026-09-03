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

# ---------- About window (arcade dark, mockup v0.2.2) --------------------
# Inline XAML instead of ui/about.xaml -- one small dialog, keeps ui/ tight.
# Uses the v0.2.2 palette:  Ground #0A0616, Card #141024, Accent #FF2D8C,
# Cyan #00E5D2, Amber #FFD447 (kicker: INSERT COIN, mockup halo). Silkscreen
# wordmark with a 52px 4-layer stack (amber halo + VHS chromatic aberration
# + cream ink), VT323 kicker + tagline, Inter body with amber opening and
# cyan tool-name Runs. __GRAB_FONTS__ / __GRAB_THEME__ / __GRAB_ASSETS__ are
# substituted at render time (fonts + shared theme + scanlines image).

$script:AboutXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="grab about"
        Width="520" Height="580"
        WindowStyle="None"
        AllowsTransparency="True"
        Background="Transparent"
        ShowInTaskbar="False"
        WindowStartupLocation="CenterScreen"
        ResizeMode="NoResize"
        UseLayoutRounding="True"
        SnapsToDevicePixels="True">
  <Window.Resources>
    <ResourceDictionary>
      <ResourceDictionary.MergedDictionaries>
        <ResourceDictionary Source="__GRAB_THEME__"/>
      </ResourceDictionary.MergedDictionaries>
    </ResourceDictionary>
  </Window.Resources>
  <Grid Margin="14" x:Name="AboutRoot">
    <Border CornerRadius="14"
            Background="{StaticResource Ground}"
            BorderBrush="{StaticResource BorderSoft}"
            BorderThickness="1">
      <Border.Effect>
        <DropShadowEffect Color="Black" BlurRadius="60" ShadowDepth="30" Opacity="0.5"/>
      </Border.Effect>
      <Border x:Name="InsetGlow"
              CornerRadius="14"
              BorderThickness="1"
              BorderBrush="#0DFF2E93"
              ClipToBounds="True">
      <Grid x:Name="Header" Margin="28,24,28,24" Background="#01000000">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Wordmark (mockup PART D): 52px 4-layer stack. Amber halo behind
             the VHS chromatic aberration and the cream ink on top. -->
        <Grid Grid.Row="0" Width="280" Height="70" HorizontalAlignment="Center">
          <TextBlock Text="GRAB" FontFamily="__GRAB_FONTS__#Silkscreen" FontWeight="Bold" FontSize="52"
                     Foreground="Transparent" TextOptions.TextRenderingMode="Aliased"
                     HorizontalAlignment="Center" VerticalAlignment="Center">
            <TextBlock.Effect>
              <DropShadowEffect Color="#FFD447" BlurRadius="40" ShadowDepth="0" Opacity="0.55"/>
            </TextBlock.Effect>
          </TextBlock>
          <TextBlock Text="GRAB" FontFamily="__GRAB_FONTS__#Silkscreen" FontWeight="Bold" FontSize="52"
                     Foreground="{StaticResource Cyan}"
                     HorizontalAlignment="Center" VerticalAlignment="Center"
                     Margin="-4,0,0,0" Opacity="0.85"/>
          <TextBlock Text="GRAB" FontFamily="__GRAB_FONTS__#Silkscreen" FontWeight="Bold" FontSize="52"
                     Foreground="{StaticResource Accent}"
                     HorizontalAlignment="Center" VerticalAlignment="Center"
                     Margin="4,0,0,0" Opacity="0.85"/>
          <TextBlock Text="GRAB" FontFamily="__GRAB_FONTS__#Silkscreen" FontWeight="Bold" FontSize="52"
                     Foreground="{StaticResource Text}"
                     HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Grid>

        <!-- Tagline (mockup PART D): VT323 16px cyan, uppercased -->
        <TextBlock Grid.Row="1"
                   FontFamily="__GRAB_FONTS__#VT323" FontSize="16"
                   Foreground="#00E5D2"
                   HorizontalAlignment="Center"
                   Margin="0,10,0,0"
                   Text="PASTE ANYTHING &#183; GET THE FILE"/>

        <!-- Kicker (moved into body area per PART D): amber INSERT COIN -->
        <TextBlock Grid.Row="2"
                   FontFamily="__GRAB_FONTS__#VT323" FontSize="12"
                   Foreground="#FFD447"
                   HorizontalAlignment="Center"
                   Margin="0,14,0,0"
                   Text="&#9656; INSERT COIN &#183; PLAYER 1 READY"/>

        <!-- Body: ScrollViewer so the full approved copy stays readable inside
             the fixed window, even at 14px Inter. Scroll bar renders on-demand
             and disappears when everything fits. BodyText is populated with a
             Run/InlineCollection in code so we can emphasize the opening
             sentence in amber, tool names + Imadjinn in cyan. -->
        <ScrollViewer Grid.Row="3" VerticalScrollBarVisibility="Auto"
                      HorizontalScrollBarVisibility="Disabled"
                      Margin="0,18,0,0" PanningMode="VerticalOnly">
          <TextBlock x:Name="BodyText"
                     Foreground="{StaticResource Text}"
                     FontFamily="__GRAB_FONTS__#Inter"
                     FontSize="13"
                     TextWrapping="Wrap"
                     LineHeight="19"/>
        </ScrollViewer>

        <!-- Stamp row (mockup PART D): split into left ("FREE FOREVER . MIT",
             VT323 muted) and right ("v0.2.2 . SEP 2026", Silkscreen 10px
             amber). The border-top is a dashed Line (WPF Border does not
             support dashed strokes) drawn full-width above the row. -->
        <Grid Grid.Row="4" Margin="0,18,0,0">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <Line Grid.Row="0" X1="0" Y1="0" X2="1000" Y2="0" Stretch="Fill"
                Stroke="#241A3E" StrokeThickness="1" StrokeDashArray="2 2"/>
          <Grid Grid.Row="1" Margin="0,10,0,0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock x:Name="StampLeft" Grid.Column="0"
                       FontFamily="__GRAB_FONTS__#VT323" FontSize="13"
                       Foreground="{StaticResource TextMuted}"
                       VerticalAlignment="Center"
                       Text="FREE FOREVER &#183; MIT"/>
            <TextBlock x:Name="StampRight" Grid.Column="1"
                       FontFamily="__GRAB_FONTS__#Silkscreen" FontWeight="Bold" FontSize="10"
                       Foreground="#FFD447"
                       VerticalAlignment="Center"
                       Text="v0.2.2 &#183; SEP 2026"/>
          </Grid>
        </Grid>

        <!-- Close button: ArcadePrimary from theme (hot-pink + black text,
             gains 2px cyan border on hover / focus). -->
        <StackPanel Grid.Row="5" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0">
          <Button x:Name="OkBtn" Style="{StaticResource ArcadePrimary}" Content="CLOSE" Width="120"/>
        </StackPanel>

        <!-- Hidden legacy Footer element, kept so Show-AboutWindow's
             FindName("Footer") lookup still resolves and old callers don't
             crash. Zero-height, collapsed. -->
        <TextBlock x:Name="Footer" Visibility="Collapsed"
                   FontFamily="__GRAB_FONTS__#VT323" FontSize="1"
                   Foreground="{StaticResource TextDim}"/>
      </Grid>
      </Border>
    </Border>

    <!-- Radial vignette (PART F). Darkens the corners subtly. -->
    <Rectangle IsHitTestVisible="False" Panel.ZIndex="998">
      <Rectangle.Fill>
        <RadialGradientBrush GradientOrigin="0.5,0.5" Center="0.5,0.5" RadiusX="0.85" RadiusY="0.85">
          <GradientStop Offset="0.55" Color="Transparent"/>
          <GradientStop Offset="1.0" Color="#88000000"/>
        </RadialGradientBrush>
      </Rectangle.Fill>
    </Rectangle>

    <!-- Static CRT scanlines overlay (see popup.xaml). -->
    <Rectangle x:Name="ScanlinesOverlay"
               IsHitTestVisible="False"
               Panel.ZIndex="999"
               Opacity="0.14">
      <Rectangle.Fill>
        <LinearGradientBrush StartPoint="0,0" EndPoint="0,3"
                             MappingMode="Absolute" SpreadMethod="Repeat">
          <GradientStop Offset="0"    Color="#40FFFFFF"/>
          <GradientStop Offset="0.5"  Color="#40FFFFFF"/>
          <GradientStop Offset="0.5"  Color="#00000000"/>
          <GradientStop Offset="1"    Color="#00000000"/>
        </LinearGradientBrush>
      </Rectangle.Fill>
    </Rectangle>
  </Grid>
</Window>
'@

function _GrabFontsUriTray {
    # file:///D:/path/to/assets/fonts/  -- WPF FontFamily URI shape.
    $abs = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets\fonts'
    return 'file:///' + (($abs -replace '\\','/').TrimEnd('/')) + '/'
}

function _GrabThemeUriTray {
    # Returns the file:/// URI of a runtime copy of theme.xaml with the
    # __GRAB_FONTS__ tokens already substituted (see utils.ps1 for why).
    $srcTheme = Join-Path (Split-Path $PSScriptRoot -Parent) 'ui\theme.xaml'
    return Get-RuntimeThemeUri -SourceThemePath $srcTheme -FontsUri (_GrabFontsUriTray)
}

function _GrabAssetsUriTray {
    # file:///D:/path/to/assets  -- base URI; callers append /scanlines.png
    $abs = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets'
    return 'file:///' + (($abs -replace '\\','/').TrimEnd('/'))
}

function _ApplyGrabTokens([string]$xamlText) {
    # Substitutes the three token markers with real file:/// URIs via the
    # unified Invoke-GrabTokenReplace helper (see utils.ps1). Keeps the raw
    # XAML files portable (no absolute paths committed) while letting
    # XamlReader.Parse resolve fonts, the shared theme dictionary, and the
    # scanlines PNG at runtime.
    return Invoke-GrabTokenReplace -XamlText $xamlText `
        -FontsUri  (_GrabFontsUriTray) `
        -ThemeUri  (_GrabThemeUriTray) `
        -AssetsUri (_GrabAssetsUriTray)
}

# ---------- Arcade-styled Yes/No confirmation dialog ----------------------
# Replaces the native Windows MessageBox for anything user-facing. Uses
# the same theme.xaml resource dictionary so no Windows-native chrome leaks.
# Returns [bool]: $true when Yes, $false when No / closed. Modal to $Parent.

$script:ConfirmDialogXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="grab confirm"
        Width="460" Height="240"
        WindowStyle="None"
        AllowsTransparency="True"
        Background="Transparent"
        ShowInTaskbar="False"
        WindowStartupLocation="CenterOwner"
        ResizeMode="NoResize"
        UseLayoutRounding="True"
        SnapsToDevicePixels="True">
  <Window.Resources>
    <ResourceDictionary>
      <ResourceDictionary.MergedDictionaries>
        <ResourceDictionary Source="__GRAB_THEME__"/>
      </ResourceDictionary.MergedDictionaries>
    </ResourceDictionary>
  </Window.Resources>
  <Grid Margin="14" x:Name="ConfirmRoot">
    <Border CornerRadius="14"
            Background="{StaticResource Ground}"
            BorderBrush="{StaticResource Cyan}"
            BorderThickness="1">
      <Border.Effect>
        <DropShadowEffect Color="Black" BlurRadius="60" ShadowDepth="30" Opacity="0.5"/>
      </Border.Effect>
      <Border x:Name="InsetGlow"
              CornerRadius="14"
              BorderThickness="1"
              BorderBrush="#0DFF2E93"
              ClipToBounds="True">
      <Grid x:Name="DlgHeader" Margin="24,20,24,20" Background="#01000000">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" x:Name="TitleText"
                   FontFamily="__GRAB_FONTS__#Silkscreen" FontWeight="Bold" FontSize="14"
                   Foreground="{StaticResource Accent}"
                   Text="CONFIRM"/>
        <TextBlock Grid.Row="1" x:Name="BodyText"
                   Foreground="{StaticResource Text}"
                   FontFamily="__GRAB_FONTS__#Inter"
                   FontSize="13"
                   TextWrapping="Wrap"
                   LineHeight="19"
                   Margin="0,14,0,0"/>
        <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
          <Button x:Name="NoBtn"  Style="{StaticResource ArcadeGhost}"   Content="CANCEL" Width="100" Margin="0,0,8,0"/>
          <Button x:Name="YesBtn" Style="{StaticResource ArcadePrimary}" Content="YES"    Width="120"/>
        </StackPanel>
      </Grid>
      </Border>
    </Border>
    <Rectangle x:Name="ScanlinesOverlay"
               IsHitTestVisible="False"
               Panel.ZIndex="999"
               Opacity="0.14">
      <Rectangle.Fill>
        <LinearGradientBrush StartPoint="0,0" EndPoint="0,3"
                             MappingMode="Absolute" SpreadMethod="Repeat">
          <GradientStop Offset="0"    Color="#40FFFFFF"/>
          <GradientStop Offset="0.5"  Color="#40FFFFFF"/>
          <GradientStop Offset="0.5"  Color="#00000000"/>
          <GradientStop Offset="1"    Color="#00000000"/>
        </LinearGradientBrush>
      </Rectangle.Fill>
    </Rectangle>
  </Grid>
</Window>
'@

function Confirm-ArcadeDialog {
    # Arcade-styled Yes/No modal. Replaces MessageBox.Show for any user
    # decision inside GRAB. Returns [bool]: $true on YES, $false on CANCEL
    # (or window close). Respects the crtScanlines config toggle.
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Message,
        [string]$YesLabel = 'YES',
        [string]$NoLabel  = 'CANCEL',
        [System.Windows.Window]$Owner = $null
    )
    try {
        $xamlText = _ApplyGrabTokens $script:ConfirmDialogXaml
        $w = [Windows.Markup.XamlReader]::Parse($xamlText)
        $w.FindName('TitleText').Text = $Title
        $w.FindName('BodyText').Text  = $Message
        $yes = $w.FindName('YesBtn'); $yes.Content = $YesLabel
        $no  = $w.FindName('NoBtn');  $no.Content  = $NoLabel
        $header = $w.FindName('DlgHeader')
        $scan = $w.FindName('ScanlinesOverlay')
        try {
            $cfg = Get-Config
            if ($scan -and -not $cfg.crtScanlines) { $scan.Visibility = 'Collapsed' }
        } catch {}
        # Drag on header
        $winLocal = $w
        $header.Add_MouseLeftButtonDown({ $winLocal.DragMove() }.GetNewClosure())
        # Result state
        $resultRef = [ref]$false
        $yes.Add_Click({ $resultRef.Value = $true;  $winLocal.Close() }.GetNewClosure())
        $no.Add_Click({  $resultRef.Value = $false; $winLocal.Close() }.GetNewClosure())
        if ($Owner) { $w.Owner = $Owner }
        $w.ShowDialog() | Out-Null
        return [bool]$resultRef.Value
    } catch {
        Log-Err "Confirm-ArcadeDialog failed: $($_.Exception.Message)"
        # Defensive: if the dialog can't render, treat as NO so nothing
        # destructive proceeds silently.
        return $false
    }
}

# Approved About body copy -- do NOT paraphrase. Blank lines separate
# paragraphs; WPF TextBlock keeps them as-is with TextWrapping="Wrap".
#
# We compose the text with char codes for the em-dash (U+2014) and middle
# dot (U+00B7) so this .ps1 stays pure ASCII on disk. That matters because
# Windows PowerShell 5.1 reads .ps1 files as ANSI when they lack a UTF-8
# BOM, which turns any literal em-dash / middle-dot into mojibake (Ã¢â‚¬â€
# or Â·) in the About window. ASCII source + runtime composition = safe.
$script:AboutBody = @"
Paste any link. GRAB downloads it. That's it.

Videos, image galleries, entire comic series, Pinterest boards, Reddit posts, tweets, TikToks $([char]0x2014) one input, one folder, no fighting with logins or captchas or "please disable your adblocker."

Under the hood, GRAB uses yt-dlp and gallery-dl $([char]0x2014) industry-standard open-source engines that already handle 1,000+ sites. We built the calm interface on top: auto-picker, queue, receipts, folders you can actually navigate.

Your links never leave your machine, except to the site you're downloading from. No account. No tracking. No cloud sync. Sensitive downloads route into a hidden folder Windows won't show unless you ask.

Free. Open. MIT-licensed. Made by Imadjinn.
"@

$script:AboutFooter = "grab  $([char]0x00B7)  v0.2.2  $([char]0x00B7)  sep 2026"

function _AddAboutBodyRuns([System.Windows.Controls.TextBlock]$tb) {
    # Populates the About body TextBlock with a chain of Runs so we can color:
    #   - opening sentence "Paste any link. GRAB downloads it." in amber
    #   - engine names (yt-dlp, gallery-dl) in cyan
    #   - "Imadjinn" byline in cyan
    # Everything else is the default Text (cream). Line breaks between
    # paragraphs use LineBreak inlines instead of `\n` so text wraps cleanly.
    $emdash = [char]0x2014
    $middot = [char]0x00B7
    $amber  = [System.Windows.Media.SolidColorBrush]::new(
              [System.Windows.Media.ColorConverter]::ConvertFromString('#FFD447'))
    $cyan   = [System.Windows.Media.SolidColorBrush]::new(
              [System.Windows.Media.ColorConverter]::ConvertFromString('#00E5D2'))

    $inlines = $tb.Inlines
    $inlines.Clear()

    # Para 1: amber opener + rest of first paragraph
    $r = New-Object System.Windows.Documents.Run 'Paste any link. GRAB downloads it. '
    $r.Foreground = $amber
    $r.FontWeight = 'Medium'
    $inlines.Add($r)
    $inlines.Add((New-Object System.Windows.Documents.Run "That's it."))
    $inlines.Add((New-Object System.Windows.Documents.LineBreak))
    $inlines.Add((New-Object System.Windows.Documents.LineBreak))

    # Para 2: catalog of what GRAB handles
    $inlines.Add((New-Object System.Windows.Documents.Run (
        "Videos, image galleries, entire comic series, Pinterest boards, Reddit posts, tweets, TikToks $emdash one input, one folder, no fighting with logins or captchas or `"please disable your adblocker.`"")))
    $inlines.Add((New-Object System.Windows.Documents.LineBreak))
    $inlines.Add((New-Object System.Windows.Documents.LineBreak))

    # Para 3: engines paragraph, with yt-dlp and gallery-dl in cyan
    $inlines.Add((New-Object System.Windows.Documents.Run 'Under the hood, GRAB uses '))
    $r = New-Object System.Windows.Documents.Run 'yt-dlp'; $r.Foreground = $cyan; $inlines.Add($r)
    $inlines.Add((New-Object System.Windows.Documents.Run ' and '))
    $r = New-Object System.Windows.Documents.Run 'gallery-dl'; $r.Foreground = $cyan; $inlines.Add($r)
    $inlines.Add((New-Object System.Windows.Documents.Run (
        " $emdash industry-standard open-source engines that already handle 1,000+ sites. We built the calm interface on top: auto-picker, queue, receipts, folders you can actually navigate.")))
    $inlines.Add((New-Object System.Windows.Documents.LineBreak))
    $inlines.Add((New-Object System.Windows.Documents.LineBreak))

    # Para 4: privacy paragraph (unstyled)
    $inlines.Add((New-Object System.Windows.Documents.Run (
        "Your links never leave your machine, except to the site you're downloading from. No account. No tracking. No cloud sync. Sensitive downloads route into a hidden folder Windows won't show unless you ask.")))
    $inlines.Add((New-Object System.Windows.Documents.LineBreak))
    $inlines.Add((New-Object System.Windows.Documents.LineBreak))

    # Para 5: license + attribution with "Imadjinn" in cyan
    $inlines.Add((New-Object System.Windows.Documents.Run 'Free. Open. MIT-licensed. Made by '))
    $r = New-Object System.Windows.Documents.Run 'Imadjinn'; $r.Foreground = $cyan; $inlines.Add($r)
    $inlines.Add((New-Object System.Windows.Documents.Run '.'))
}

function Show-AboutWindow {
    try {
        $xamlText = _ApplyGrabTokens $script:AboutXaml
        $w = [Windows.Markup.XamlReader]::Parse($xamlText)
        $body   = $w.FindName('BodyText')
        $footer = $w.FindName('Footer')
        $ok     = $w.FindName('OkBtn')
        $hdr    = $w.FindName('Header')
        $scan   = $w.FindName('ScanlinesOverlay')
        _AddAboutBodyRuns $body
        if ($footer) { $footer.Text = $script:AboutFooter }
        # Honor the config.crtScanlines toggle.
        try {
            $cfg = Get-Config
            if ($scan -and -not $cfg.crtScanlines) { $scan.Visibility = 'Collapsed' }
        } catch {}
        # Drag anywhere on the card (WindowStyle=None gives no titlebar).
        $winLocal = $w
        $hdr.Add_MouseLeftButtonDown({ $winLocal.DragMove() }.GetNewClosure())
        $ok.Add_Click({ $winLocal.Close() }.GetNewClosure())
        $w.ShowDialog() | Out-Null
    } catch {
        Log-Err "Show-AboutWindow failed: $($_.Exception.Message)"
    }
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
    $mAbout    = $menu.Items.Add('About',          $null, { Show-AboutWindow })
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
