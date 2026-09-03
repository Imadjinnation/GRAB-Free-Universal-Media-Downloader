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

# Only the lightweight WinForms + GDI+ assemblies load eagerly here. WPF
# assemblies (PresentationFramework/PresentationCore/WindowsBase) are the
# expensive ones on cold start and are now loaded lazily via Ensure-WpfLoaded
# (utils.ps1) when Show-AboutWindow / Confirm-ArcadeDialog first render.
# Cuts time-to-tray-visible by ~3-5s on RTX 3050 6GB / cold PowerShell.
Add-Type -AssemblyName System.Windows.Forms | Out-Null
Add-Type -AssemblyName System.Drawing        | Out-Null

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
        try {
            return New-Object System.Drawing.Icon $iconPath
        } catch {
            # v0.3.0: log the exact failure so future icon regressions are
            # traceable. Pre-v0.3.0 the empty catch swallowed loader errors
            # (bad ICO magic, permission denied, locked by AV) and left users
            # staring at the shell fallback with no clue why (audit P1-14).
            $ico = $null
            try { $ico = Get-Item -LiteralPath $iconPath -ErrorAction Stop } catch {}
            $bytesHead = '?'
            try {
                $bytes = [System.IO.File]::ReadAllBytes($iconPath)
                if ($bytes.Length -ge 4) {
                    $bytesHead = ('{0:X2} {1:X2} {2:X2} {3:X2}' -f $bytes[0],$bytes[1],$bytes[2],$bytes[3])
                }
            } catch {}
            $size = if ($ico) { $ico.Length } else { -1 }
            $mtime = if ($ico) { $ico.LastWriteTimeUtc } else { 'unknown' }
            Log-Warn ("icon.ico load failed: {0}; size={1} mtime={2} head={3}; falling back to shell32.dll" -f `
                $_.Exception.Message, $size, $mtime, $bytesHead)
        }
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
        try {
            $icon = [System.Drawing.Icon]::FromHandle($small[0])
            # Clone() produces an owned .NET copy; the native handles must be
            # released explicitly or we leak an ICON GDI handle per call
            # (audit P1-20: Get-TrayIcon leaked, DestroyIcon was declared but
            # never invoked).
            $cloned = $icon.Clone()
            [GrabApp.IconEx]::DestroyIcon($small[0]) | Out-Null
            if ($large[0] -ne [IntPtr]::Zero) { [GrabApp.IconEx]::DestroyIcon($large[0]) | Out-Null }
            return $cloned
        } catch {
            Log-Warn "shell32 icon extract clone failed: $($_.Exception.Message)"
            try { [GrabApp.IconEx]::DestroyIcon($small[0]) | Out-Null } catch {}
            try { if ($large[0] -ne [IntPtr]::Zero) { [GrabApp.IconEx]::DestroyIcon($large[0]) | Out-Null } } catch {}
        }
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

$script:ConfirmDownloadXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="grab confirm download"
        Width="520" Height="320"
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
  <Grid Margin="14" x:Name="ConfirmDlRoot">
    <Border CornerRadius="14"
            Background="{StaticResource Ground}"
            BorderBrush="{StaticResource Amber}"
            BorderThickness="1">
      <Border.Effect>
        <DropShadowEffect Color="Black" BlurRadius="60" ShadowDepth="30" Opacity="0.5"/>
      </Border.Effect>
      <Border CornerRadius="14"
              BorderThickness="1"
              BorderBrush="#0DFF2E93"
              ClipToBounds="True">
      <Grid x:Name="ConfirmDlHeader" Margin="24,20,24,20" Background="#01000000">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0"
                   FontFamily="__GRAB_FONTS__#Silkscreen" FontWeight="Bold" FontSize="14"
                   Foreground="{StaticResource Amber}"
                   Text="CONFIRM GRAB"/>
        <TextBlock Grid.Row="1" x:Name="DlUrl"
                   Foreground="{StaticResource Text}"
                   FontFamily="__GRAB_FONTS__#VT323"
                   FontSize="14"
                   TextWrapping="Wrap"
                   Margin="0,10,0,0"/>
        <TextBlock Grid.Row="2" x:Name="DlDest"
                   Foreground="{StaticResource TextMuted}"
                   FontFamily="__GRAB_FONTS__#VT323"
                   FontSize="12"
                   TextWrapping="Wrap"
                   Margin="0,6,0,0"/>
        <TextBlock Grid.Row="3" x:Name="DlSensitive"
                   Foreground="#FF2D8C"
                   FontFamily="__GRAB_FONTS__#VT323"
                   FontSize="12"
                   Margin="0,6,0,0"/>
        <StackPanel Grid.Row="5" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
          <Button x:Name="DlCancel" Style="{StaticResource ArcadeGhost}"  Content="CANCEL"        Width="90"  Margin="0,0,8,0"/>
          <Button x:Name="DlChoose" Style="{StaticResource ArcadeGhost}"  Content="CHOOSE FOLDER" Width="140" Margin="0,0,8,0"/>
          <Button x:Name="DlGrab"   Style="{StaticResource ArcadePrimary}" Content="GRAB IT"       Width="120"/>
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

function Confirm-DownloadDialog {
    # Audit P2-40 (option B: implement AskBeforeEach). Modal per-download
    # confirmation: shows URL + destination + sensitive-toggle state, then
    # returns a hashtable:
    #   @{ Cancelled = $true }                       -- user picked CANCEL
    #   @{ Cancelled = $false; Override = $null }    -- user picked GRAB IT (use default dest)
    #   @{ Cancelled = $false; Override = 'C:\...' } -- user picked CHOOSE FOLDER
    # The Override, when set, is a one-time destination for THIS submission;
    # config.downloadFolder is not touched.
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Dest,
        [bool]$Sensitive = $false,
        $Owner = $null
    )
    try {
        Ensure-WpfLoaded
        $xamlText = _ApplyGrabTokens $script:ConfirmDownloadXaml
        try {
            $w = [Windows.Markup.XamlReader]::Parse($xamlText)
        } catch {
            Log-Err "Confirm-download dialog XAML parse failed: $($_.Exception.Message)"
            # If we can't render the dialog, err on the side of NOT downloading
            # so a UI failure never quietly queues without consent.
            return @{ Cancelled = $true; Override = $null }
        }
        $w.FindName('DlUrl').Text  = "URL: $Url"
        $w.FindName('DlDest').Text = "Dest: $Dest"
        $sensText = if ($Sensitive) { "Sensitive: ON  (routes to .private)" } else { "Sensitive: off" }
        $w.FindName('DlSensitive').Text = $sensText
        $header = $w.FindName('ConfirmDlHeader')
        $scan   = $w.FindName('ScanlinesOverlay')
        try {
            $cfg = Get-Config
            if ($scan -and -not $cfg.crtScanlines) { $scan.Visibility = 'Collapsed' }
        } catch {}
        $winLocal = $w
        $header.Add_MouseLeftButtonDown({ $winLocal.DragMove() }.GetNewClosure())

        $result = @{ Cancelled = $true; Override = $null }
        $resultRef = [ref]$result

        $w.FindName('DlCancel').Add_Click({
            $resultRef.Value = @{ Cancelled = $true; Override = $null }
            $winLocal.Close()
        }.GetNewClosure())
        $w.FindName('DlGrab').Add_Click({
            $resultRef.Value = @{ Cancelled = $false; Override = $null }
            $winLocal.Close()
        }.GetNewClosure())
        $w.FindName('DlChoose').Add_Click({
            Add-Type -AssemblyName System.Windows.Forms | Out-Null
            $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
            $dlg.Description = 'One-time destination for THIS download'
            $dlg.ShowNewFolderButton = $true
            if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $resultRef.Value = @{ Cancelled = $false; Override = $dlg.SelectedPath }
                $winLocal.Close()
            }
        }.GetNewClosure())

        if ($Owner) { $w.Owner = $Owner }
        $w.ShowDialog() | Out-Null
        return $resultRef.Value
    } catch {
        Log-Err "Confirm-DownloadDialog failed: $($_.Exception.Message)"
        return @{ Cancelled = $true; Override = $null }
    }
}

function Confirm-ArcadeDialog {
    # Arcade-styled Yes/No modal. Replaces MessageBox.Show for any user
    # decision inside GRAB. Returns [bool]: $true on YES, $false on CANCEL
    # (or window close). Respects the crtScanlines config toggle.
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Message,
        [string]$YesLabel = 'YES',
        [string]$NoLabel  = 'CANCEL',
        $Owner = $null
    )
    try {
        Ensure-WpfLoaded
        $xamlText = _ApplyGrabTokens $script:ConfirmDialogXaml
        # XamlReader.Parse is wrapped so a malformed dialog XAML can't kill
        # the tray -- we surface it via toast and return "no" so nothing
        # destructive proceeds (audit P1-15).
        try {
            $w = [Windows.Markup.XamlReader]::Parse($xamlText)
        } catch {
            Log-Err "Confirm dialog XAML parse failed: $($_.Exception.Message)"
            try { Send-Toast 'grab UI failed to load' 'Check the log' } catch {}
            return $false
        }
        $w.FindName('TitleText').Text = $Title
        $w.FindName('BodyText').Text  = $Message
        $yes = $w.FindName('YesBtn'); $yes.Content = $YesLabel
        $no  = $w.FindName('NoBtn');  $no.Content  = $NoLabel
        $header = $w.FindName('DlgHeader')
        $scan = $w.FindName('ScanlinesOverlay')
        # Audit P2-43: don't swallow the config-read error. If Get-Config
        # throws, we default to leaving the scanlines visible (the arcade
        # cabinet default) AND log the error so the underlying issue is
        # traceable instead of the visible symptom being "scanlines showing
        # even though I turned them off".
        try {
            $cfg = Get-Config
            if ($scan -and -not $cfg.crtScanlines) { $scan.Visibility = 'Collapsed' }
        } catch {
            Log-Warn "Confirm-ArcadeDialog: Get-Config failed, keeping scanlines default: $($_.Exception.Message)"
        }
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
        Ensure-WpfLoaded
        $xamlText = _ApplyGrabTokens $script:AboutXaml
        try {
            $w = [Windows.Markup.XamlReader]::Parse($xamlText)
        } catch {
            Log-Err "About XAML parse failed: $($_.Exception.Message)"
            try { Send-Toast 'grab UI failed to load' 'Check the log' } catch {}
            return
        }
        $body   = $w.FindName('BodyText')
        $footer = $w.FindName('Footer')
        $ok     = $w.FindName('OkBtn')
        $hdr    = $w.FindName('Header')
        $scan   = $w.FindName('ScanlinesOverlay')
        _AddAboutBodyRuns $body
        if ($footer) { $footer.Text = $script:AboutFooter }
        # Honor the config.crtScanlines toggle. Audit P2-43: log the
        # swallowed error so the wrong-default symptom is diagnosable.
        try {
            $cfg = Get-Config
            if ($scan -and -not $cfg.crtScanlines) { $scan.Visibility = 'Collapsed' }
        } catch {
            Log-Warn "Show-AboutWindow: Get-Config failed, keeping scanlines default: $($_.Exception.Message)"
        }
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
# Menu renderer (audit P1-30). WinForms ContextMenuStrip defaults to Windows
# system colors -- the tray menu was the last piece of the app that looked
# like generic Windows chrome. Get-ArcadeMenuRenderer swaps in a
# ProfessionalColorTable with the arcade palette so the menu matches the
# rest of GRAB (hot-pink hover, dark card ground, warm-cream ink). Font
# stays a system font because WinForms cannot load file-URI TTFs (Inter would
# require the user to have it installed system-wide, which they usually do
# not); Segoe UI at 9.5pt reads close enough at the tray menu size.

function Get-ArcadeMenuRenderer {
    Add-Type -AssemblyName System.Drawing        | Out-Null
    Add-Type -AssemblyName System.Windows.Forms  | Out-Null
    if (-not ('ArcadeColors' -as [type])) {
        $sig = @'
public class ArcadeColors : System.Windows.Forms.ProfessionalColorTable {
    public override System.Drawing.Color MenuItemSelected { get { return System.Drawing.ColorTranslator.FromHtml("#FF2D8C"); } }
    public override System.Drawing.Color MenuItemSelectedGradientBegin { get { return System.Drawing.ColorTranslator.FromHtml("#FF2D8C"); } }
    public override System.Drawing.Color MenuItemSelectedGradientEnd { get { return System.Drawing.ColorTranslator.FromHtml("#C81874"); } }
    public override System.Drawing.Color MenuItemBorder { get { return System.Drawing.ColorTranslator.FromHtml("#FF2D8C"); } }
    public override System.Drawing.Color ToolStripDropDownBackground { get { return System.Drawing.ColorTranslator.FromHtml("#141024"); } }
    public override System.Drawing.Color ImageMarginGradientBegin { get { return System.Drawing.ColorTranslator.FromHtml("#141024"); } }
    public override System.Drawing.Color ImageMarginGradientMiddle { get { return System.Drawing.ColorTranslator.FromHtml("#141024"); } }
    public override System.Drawing.Color ImageMarginGradientEnd { get { return System.Drawing.ColorTranslator.FromHtml("#141024"); } }
    public override System.Drawing.Color SeparatorDark { get { return System.Drawing.ColorTranslator.FromHtml("#241A3E"); } }
    public override System.Drawing.Color SeparatorLight { get { return System.Drawing.ColorTranslator.FromHtml("#241A3E"); } }
    public override System.Drawing.Color MenuBorder { get { return System.Drawing.ColorTranslator.FromHtml("#241A3E"); } }
}
'@
        try {
            Add-Type -TypeDefinition $sig -ReferencedAssemblies System.Drawing, System.Windows.Forms
        } catch {
            Log-Warn "ArcadeColors compile failed: $($_.Exception.Message); menu falls back to system chrome"
            return $null
        }
    }
    try {
        return New-Object System.Windows.Forms.ToolStripProfessionalRenderer ([ArcadeColors]::new())
    } catch {
        Log-Warn "ArcadeColors instantiation failed: $($_.Exception.Message)"
        return $null
    }
}

function _CopyDiagnostics {
    # Copies a short diagnostic bundle to the clipboard: last N log lines +
    # config.json + version + PID + repo path. Handy for support / bug reports.
    # Best-effort; never throws. Called from the tray "Copy diagnostics" item.
    try {
        Add-Type -AssemblyName System.Windows.Forms | Out-Null
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine("grab v$(Get-GrabVersion)")
        [void]$sb.AppendLine("pid: $PID")
        [void]$sb.AppendLine("repo: $(Split-Path $PSScriptRoot -Parent)")
        [void]$sb.AppendLine("appdata: $(Get-AppDataPath)")
        [void]$sb.AppendLine("time: $(Get-Date -Format o)")
        [void]$sb.AppendLine('----- config.json -----')
        try {
            $cfgRaw = Get-Content -LiteralPath (Get-ConfigPath) -Raw -Encoding UTF8
            [void]$sb.AppendLine($cfgRaw)
        } catch {
            [void]$sb.AppendLine("(config unreadable: $($_.Exception.Message))")
        }
        [void]$sb.AppendLine('----- last 100 log lines -----')
        try {
            $today = Join-Path (Get-LogFolder) ("grab-{0}.log" -f (Get-Date -Format 'yyyy-MM-dd'))
            if (Test-Path -LiteralPath $today) {
                $tail = Get-Content -LiteralPath $today -Tail 100 -ErrorAction SilentlyContinue
                [void]$sb.AppendLine(($tail -join "`r`n"))
            } else {
                [void]$sb.AppendLine('(no log today)')
            }
        } catch {
            [void]$sb.AppendLine("(log tail failed: $($_.Exception.Message))")
        }
        [System.Windows.Forms.Clipboard]::SetText($sb.ToString())
        Send-Toast 'grab diagnostics copied' 'Paste into a bug report / DM'
        Log-Info 'diagnostics copied to clipboard'
    } catch {
        Log-Err "Copy diagnostics failed: $($_.Exception.Message)"
    }
}

function _RestartTray {
    # Kills the current tray and relaunches via powershell.exe (or the .vbs
    # wrapper if available). The singleton mutex is released as this process
    # exits, so the child grabs it cleanly. Called from the tray "Restart"
    # menu item so users don't have to hunt for Task Manager after a stuck
    # state (audit P1-26).
    try {
        $repoRoot = Split-Path $PSScriptRoot -Parent
        $vbs      = Join-Path $repoRoot 'grab-app.vbs'
        $entry    = Join-Path $repoRoot 'grab-app.ps1'
        if (Test-Path -LiteralPath $vbs) {
            Start-Process 'wscript.exe' -ArgumentList ('"' + $vbs + '"')
        } else {
            Start-Process 'powershell.exe' -ArgumentList @(
                '-STA','-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass',
                '-File', ('"' + $entry + '"')
            )
        }
        Log-Info 'tray restart requested; stopping current process'
        Stop-Tray
    } catch {
        Log-Err "Restart tray failed: $($_.Exception.Message)"
    }
}

function Build-TrayMenu {
    $menu = New-Object System.Windows.Forms.ContextMenuStrip

    # Apply the arcade renderer + palette. When the compile fails (very rare),
    # fall through to system chrome so the menu still opens.
    $renderer = Get-ArcadeMenuRenderer
    if ($renderer) { $menu.Renderer = $renderer }
    try {
        $menu.BackColor  = [System.Drawing.ColorTranslator]::FromHtml('#141024')
        $menu.ForeColor  = [System.Drawing.ColorTranslator]::FromHtml('#F5EBD0')
        # Prefer Inter if the user has it installed system-wide, else Segoe UI.
        # We can't load a file-URI TTF into WinForms, so this is best-effort:
        # unknown families fall back to Segoe UI automatically.
        $menu.Font = New-Object System.Drawing.Font('Inter', 9.5)
    } catch {
        Log-Warn "tray menu palette apply failed: $($_.Exception.Message)"
    }

    $mShow     = $menu.Items.Add('Show grab',      $null, { if ($script:PopupShow)    { & $script:PopupShow 'paste' } })
    $mQueue    = $menu.Items.Add('Queue',          $null, { if ($script:PopupShow)    { & $script:PopupShow 'queue' } })
    $mRecent   = $menu.Items.Add('Recent',         $null, { if ($script:PopupShow)    { & $script:PopupShow 'recent' } })
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $mSettings = $menu.Items.Add('Settings...',    $null, { if ($script:SettingsShow) { & $script:SettingsShow } })
    $mOpen     = $menu.Items.Add('Open downloads', $null, {
        $cfg = Get-Config
        if (Test-Path -LiteralPath $cfg.downloadFolder) { Start-Process explorer.exe $cfg.downloadFolder }
    })
    $mLogs     = $menu.Items.Add('Show logs',      $null, {
        $p = Get-LogFolder
        if (Test-Path -LiteralPath $p) { Start-Process explorer.exe $p }
    })
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $mDiag     = $menu.Items.Add('Copy diagnostics', $null, { _CopyDiagnostics })
    $mRestart  = $menu.Items.Add('Restart tray',     $null, { _RestartTray })
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    # Audit P2-42: About handler used to swallow XAML parse / dispatcher
    # errors silently -- the user clicked About, nothing happened, no clue.
    # Now: try/catch, log with stack trace, and toast so the user has a
    # nudge to check the log.
    $mAbout    = $menu.Items.Add('About',          $null, {
        try { Show-AboutWindow }
        catch {
            Log-Err "Show-AboutWindow click failed: $($_.Exception.Message)"
            try { Send-Toast 'grab' 'Could not open About; check the log' } catch {}
        }
    })
    $mQuit     = $menu.Items.Add('Quit',           $null, { Stop-Tray })

    # Bold "Show grab" as default
    $mShow.Font = New-Object System.Drawing.Font($mShow.Font, [System.Drawing.FontStyle]::Bold)
    return $menu
}

# ---------- Timers --------------------------------------------------------

# Audit PERF-1/PERF-2 tick intervals. TickTimer defaults to 2s (fast enough
# for a responsive queue). When the queue is idle for >5min we back off to
# 30s so an unused GRAB draws almost no CPU. On battery we tighten a bit
# more (15s) so the laptop doesn't wake the disk unnecessarily.
$script:TickIntervalFast   = [TimeSpan]::FromSeconds(2)
$script:TickIntervalBattery = [TimeSpan]::FromSeconds(15)
$script:TickIntervalIdle    = [TimeSpan]::FromSeconds(30)
$script:LastQueueActivityAt = Get-Date
$script:OnBattery           = $false
$script:BatterySaverOn      = $false

function Get-DesiredTickInterval {
    # Priority: activity within 5min -> fast; else battery/saver -> battery;
    # else idle (30s). Callers use this to pick an interval before Start().
    $now = Get-Date
    $idleFor = $now - $script:LastQueueActivityAt
    $qCount = 0
    try { $qCount = @(Read-Queue).Count } catch {}
    if ($idleFor.TotalMinutes -lt 5 -or $qCount -gt 0) { return $script:TickIntervalFast }
    if ($script:BatterySaverOn -or $script:OnBattery) { return $script:TickIntervalBattery }
    return $script:TickIntervalIdle
}

function Notify-QueueActivity {
    # Called from anywhere that changes queue state (Add-QueueJob, job
    # completion) so the TickTimer resets to fast. Also called on startup.
    $script:LastQueueActivityAt = Get-Date
    if ($script:TickTimer -and $script:TickTimer.Interval -ne $script:TickIntervalFast) {
        $script:TickTimer.Interval = $script:TickIntervalFast
    }
}

function Update-TickInterval {
    # Called by the tick handler after Invoke-QueueTick; adjusts the timer
    # interval based on current conditions (idle, battery, saver mode).
    if (-not $script:TickTimer) { return }
    $desired = Get-DesiredTickInterval
    if ($script:TickTimer.Interval -ne $desired) {
        $script:TickTimer.Interval = $desired
    }
}

function _DetectBatteryLine {
    try {
        Add-Type -AssemblyName System.Windows.Forms | Out-Null
        $ps = [System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus
        # 'Offline' means "no AC" -> running on battery.
        return ($ps -eq [System.Windows.Forms.PowerLineStatus]::Offline)
    } catch { return $false }
}

function Sync-ClipTimer {
    # Audit P2-50 / PERF-4: start ClipTimer if config says clipboardWatch=on
    # AND it isn't already running; stop it if it's running but the toggle
    # went off. Called at Start-Timers and again from Settings Save.
    try {
        $cfg = Get-Config
        $wantOn = [bool]$cfg.clipboardWatch
    } catch { $wantOn = $false }
    if ($wantOn) {
        if (-not $script:ClipTimer) {
            $script:ClipTimer = New-Object System.Windows.Threading.DispatcherTimer
            $script:ClipTimer.Interval = [TimeSpan]::FromMilliseconds(1500)
            $script:ClipTimer.Add_Tick({
                try {
                    $c = Get-Config
                    if (-not $c.clipboardWatch) {
                        # Toggled off between ticks; stop right now.
                        try { $script:ClipTimer.Stop() } catch {}
                        return
                    }
                    $txt = try { [System.Windows.Forms.Clipboard]::GetText() } catch { '' }
                    if ($txt -and $txt -ne $script:LastClipboardUrl -and (Test-IsUrl $txt)) {
                        $script:LastClipboardUrl = $txt
                        Send-Toast 'URL detected' "Click the tray icon to grab: $(Get-SiteName $txt)"
                        if ($script:Tray) {
                            $script:Tray.ShowBalloonTip(4000, 'grab', "Detected: $(Get-SiteName $txt)`nClick the tray icon to add it.", [System.Windows.Forms.ToolTipIcon]::Info)
                        }
                    }
                    $script:ClipFailCount = 0
                } catch {
                    $script:ClipFailCount++
                    Log-Err "clip tick error #$($script:ClipFailCount): $($_.Exception.Message)"
                    if ($script:ClipFailCount -ge 10) {
                        try { $script:ClipTimer.Stop() } catch {}
                        try { Send-Toast 'grab clipboard watch halted' 'Too many errors -- check the log' } catch {}
                        Log-Err 'clipboard watch timer stopped after 10 consecutive failures'
                    }
                }
            })
        }
        if (-not $script:ClipTimer.IsEnabled) { $script:ClipTimer.Start() }
    } else {
        if ($script:ClipTimer -and $script:ClipTimer.IsEnabled) {
            try { $script:ClipTimer.Stop() } catch {}
        }
    }
}

function Start-Timers {
    # We use WPF DispatcherTimer instead of WinForms.Timer because the main
    # loop is Dispatcher.Run (see Start-Tray). DispatcherTimer fires on the
    # dispatcher thread; WinForms.Timer would never fire under Dispatcher.Run.
    #
    # Circuit breaker (audit P1-25): pre-v0.3.0 a broken tick handler could
    # log-flood indefinitely (many MB/day when the queue was in a bad state).
    # Now we count consecutive failures and stop the timer after 10 in a row,
    # surfacing a toast so the user knows something's wrong. A successful
    # tick resets the counter. Same policy for both timers.
    $script:TickFailCount = 0
    $script:ClipFailCount = 0

    # Turn on batched log writes (audit PERF-3). Write-Log now enqueues; the
    # LogFlushTimer below drains every 1s.
    Enable-LogBatching

    # Detect battery once at startup; PowerModeChanged (below) keeps it fresh.
    $script:OnBattery = _DetectBatteryLine

    # Queue tick with adaptive interval (audit PERF-1 / PERF-2).
    $script:TickTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:TickTimer.Interval = Get-DesiredTickInterval
    $script:TickTimer.Add_Tick({
        try {
            $before = try { @(Read-Queue).Count } catch { -1 }
            Invoke-QueueTick
            $after  = try { @(Read-Queue).Count } catch { -1 }
            # Any state churn resets activity so we stay on the fast interval
            # while the queue is doing work.
            if ($before -ne $after -or $after -gt 0) {
                $script:LastQueueActivityAt = Get-Date
            }
            $script:TickFailCount = 0
            Update-TickInterval
        } catch {
            $script:TickFailCount++
            Log-Err "tick error #$($script:TickFailCount): $($_.Exception.Message)"
            if ($script:TickFailCount -ge 10) {
                try { $script:TickTimer.Stop() } catch {}
                try { Send-Toast 'grab worker halted' 'Too many errors -- check the log' } catch {}
                Log-Err 'queue tick timer stopped after 10 consecutive failures'
            }
        }
    })
    $script:TickTimer.Start()

    # Clipboard watch: only start when clipboardWatch=true (PERF-4 / P2-50).
    Sync-ClipTimer

    # Log flush timer (PERF-3). Drains the batched log queue every 1s.
    $script:LogFlushTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:LogFlushTimer.Interval = [TimeSpan]::FromSeconds(1)
    $script:LogFlushTimer.Add_Tick({ try { Flush-LogQueue } catch {} })
    $script:LogFlushTimer.Start()

    # Battery / power-mode awareness (PERF-2). PowerModeChanged fires for
    # StatusChange (battery <-> AC transitions, battery-saver toggle) and
    # Suspend/Resume. We pause the queue tick on Suspend and refresh the
    # battery/saver flags on StatusChange so Update-TickInterval picks up
    # the change on the next tick.
    try {
        $handler = {
            param($senderObj, $e)
            try {
                switch ($e.Mode) {
                    ([Microsoft.Win32.PowerModes]::Suspend) {
                        try { $script:TickTimer.Stop() } catch {}
                        try { if ($script:ClipTimer) { $script:ClipTimer.Stop() } } catch {}
                        Log-Info 'power: suspend -- timers paused'
                    }
                    ([Microsoft.Win32.PowerModes]::Resume) {
                        $script:OnBattery = _DetectBatteryLine
                        try { $script:TickTimer.Start() } catch {}
                        try { Sync-ClipTimer } catch {}
                        Log-Info 'power: resume -- timers restarted'
                    }
                    ([Microsoft.Win32.PowerModes]::StatusChange) {
                        $script:OnBattery = _DetectBatteryLine
                        # Windows battery-saver mode isn't cleanly readable
                        # from managed APIs, but StatusChange fires when it
                        # toggles -- treat "on battery AND idle >5min" as
                        # the same tightening.
                        Update-TickInterval
                        Log-Info "power: status change (battery=$script:OnBattery)"
                    }
                }
            } catch { Log-Warn "PowerModeChanged handler: $($_.Exception.Message)" }
        }
        [Microsoft.Win32.SystemEvents]::add_PowerModeChanged($handler)
        $script:PowerModeHandler = $handler
    } catch { Log-Warn "PowerModeChanged wire-up failed: $($_.Exception.Message)" }
}

function Stop-Timers {
    if ($script:TickTimer)     { try { $script:TickTimer.Stop() }     catch {} }
    if ($script:ClipTimer)     { try { $script:ClipTimer.Stop() }     catch {} }
    if ($script:LogFlushTimer) { try { $script:LogFlushTimer.Stop() } catch {} }
    # Unhook the PowerModeChanged handler so we don't leak it across restarts.
    if ($script:PowerModeHandler) {
        try { [Microsoft.Win32.SystemEvents]::remove_PowerModeChanged($script:PowerModeHandler) } catch {}
        $script:PowerModeHandler = $null
    }
    # Flush any pending log entries before we lose the ability to drain.
    try { Flush-LogQueue } catch {}
    try { Disable-LogBatching } catch {}
}

# ---------- Lifecycle -----------------------------------------------------

function Start-Tray {
    param(
        [scriptblock]$OnShowPopup    = $null,
        [scriptblock]$OnShowSettings = $null,
        [scriptblock]$OnBeforeQuit   = $null
    )
    # === PHASE 1: make the tray icon appear as fast as possible =============
    # Users report GRAB taking 5-8s to show up in the tray after login (vs.
    # 1-2s for other tray apps). Root cause: the cost of Add-Type'ing
    # PresentationFramework/PresentationCore/WindowsBase and dot-sourcing
    # popup.ps1 + settings.ps1 all happened BEFORE we ever created the
    # NotifyIcon. Fix: create the icon FIRST, then do everything else. The
    # WinForms + GDI+ assemblies loaded at the top of this file are cheap
    # (~200ms combined); NotifyIcon creation is instant. WPF and its
    # dependents load lazily in phase 2 below.
    $script:Tray = New-Object System.Windows.Forms.NotifyIcon
    $script:Tray.Icon = Get-TrayIcon
    $script:Tray.Text = 'grab -- loading'
    $script:Tray.Visible = $true
    Log-Info 'tray icon visible'

    # === PHASE 2: heavy WPF init (Dispatcher, timers, etc) =================
    # Now that the user can see we're alive, load WPF and finish wiring.
    Ensure-WpfLoaded
    $script:Dispatcher = [System.Windows.Threading.Dispatcher]::CurrentDispatcher

    $script:PopupShow    = $OnShowPopup
    $script:SettingsShow = $OnShowSettings
    $script:OnQuit       = $OnBeforeQuit

    $script:Tray.ContextMenuStrip = (Build-TrayMenu)

    # Left-click summons popup (paste tab)
    $script:Tray.add_MouseClick({
        param($sender, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            if ($script:PopupShow) { & $script:PopupShow 'paste' }
        }
    })
    # Balloon click also summons popup
    $script:Tray.add_BalloonTipClicked({ if ($script:PopupShow) { & $script:PopupShow 'paste' } })

    # Windows 11 tray promotion: mark this app's tray icon as promoted so it
    # sits directly in the taskbar tray, not hidden under the up-caret. Every
    # tray icon needs a stable GUID (matches the AssemblyInfo/manifest GUID
    # convention). If the reg key doesn't exist yet, the OS honors the value
    # on first appearance; if it does, we set it to promoted for anyone who
    # started GRAB before v0.3.0 and got hidden by default.
    try {
        $grabGuid = '{f3e2c9a1-4b8e-4d3a-9c1b-5e6a7b8c9d0e}'
        $notifyKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\NotifyIconSettings\$grabGuid"
        if (-not (Test-Path $notifyKey)) { New-Item -Path $notifyKey -Force | Out-Null }
        New-ItemProperty -Path $notifyKey -Name 'IsPromoted' -Value 1 -PropertyType DWORD -Force | Out-Null
    } catch { Log-Warn "tray promotion registry write failed: $($_.Exception.Message)" }

    # Self-heal sweep BEFORE Start-Timers so any missing shortcuts /
    # autostart entries / ghost folders get fixed silently at login.
    try { Invoke-SelfHealSweep } catch { Log-Warn "self-heal sweep failed: $($_.Exception.Message)" }

    # Crash-recovery sweep: any queue entry left in 'running' state from a
    # prior process (crashed / killed / rebooted) has no live PS Job. Reset
    # them to pending so the tick timer picks them up cleanly.
    try { Recover-OrphanedJobs } catch { Log-Warn "recover sweep failed: $($_.Exception.Message)" }

    Start-Timers

    # First-time greeting -- mark firstRunComplete RIGHT AFTER showing it,
    # not on quit (users don't quit, they reboot -- and the flag would
    # otherwise be re-triggered every login forever). v0.3.0: expanded body
    # nudges the user to pin the tray icon (Windows 11 hides new tray icons
    # under the up-caret by default; the registry promotion above helps for
    # anyone who already saw the pin dialog once).
    $cfg = Get-Config
    if (-not $cfg.firstRunComplete) {
        # Audit P2-48: don't assume taskbar orientation. Users with a
        # top/side/auto-hide taskbar wouldn't recognise "bottom-right" as
        # a location. "At the corner of your screen (may be under the ^
        # arrow)" is orientation-neutral.
        $script:Tray.ShowBalloonTip(8000, 'grab is ready',
            "I live in the system tray at the corner of your screen (may be under the ^ arrow). Left-click me to paste a link; right-click for menu.`n`nTip: drag me out of the up-caret onto the taskbar so I'm always visible.",
            [System.Windows.Forms.ToolTipIcon]::Info)
        Update-Config @{ firstRunComplete = $true } | Out-Null
    }

    # Everything ready -- update tooltip so the user sees the transition
    # from "loading" -> "ready" if they were hovering during startup.
    $script:Tray.Text = 'grab -- right-click for menu'
    Log-Info 'tray started (WPF Dispatcher primary loop)'

    # WPF Dispatcher.Run() as the primary message loop. This pumps BOTH
    # Win32 messages (so NotifyIcon works) AND WPF messages (so popup
    # windows render, respond to input, drag, etc). Wrapped in try/catch
    # because pre-v0.3.0 an unhandled WPF exception during the pump killed
    # the tray silently (audit P0-1). Now: log full stack + surface via
    # MessageBox so users know the tray died.
    try {
        [System.Windows.Threading.Dispatcher]::Run()
    } catch {
        Log-Err "Dispatcher.Run crashed: $($_.Exception.Message)`n$($_.ScriptStackTrace)"
        try {
            Ensure-WpfLoaded
            [System.Windows.MessageBox]::Show(
                "grab tray crashed unexpectedly.`n`n$($_.Exception.Message)`n`nLog: %APPDATA%\grab-app\logs",
                'grab -- Tray crash', 'OK', 'Error') | Out-Null
        } catch {}
        throw
    }
}

function Invoke-SelfHealSweep {
    # Runs at every Start-Tray. Silently repairs anything the user's env
    # may have wiped since last launch: autostart entries, desktop shortcut,
    # download folder, and cleans the ghost ~\Downloads\imadjinn-grab
    # folder (audit P0-6) if it's empty. Never throws -- everything gets
    # logged and best-effort'd so a tray restart isn't blocked.
    try {
        $cfg = Get-Config
    } catch { return }

    # --- autostart: needs BOTH HKCU\Run AND (optionally) shortcut ------
    # HKCU\Run is now the primary mechanism (survives OneDrive quirks). If
    # the user has autostart on, ensure the reg entry exists.
    try {
        if ($cfg.autostart) {
            $regKey  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
            $hasReg  = $false
            try {
                $prop = Get-ItemProperty -Path $regKey -Name 'GRAB' -ErrorAction SilentlyContinue
                $hasReg = $null -ne $prop
            } catch {}
            if (-not $hasReg) {
                Set-AutostartRegistry $true
                Log-Info 'self-heal: recreated HKCU\Run autostart entry'
            }
        }
    } catch { Log-Warn "self-heal autostart-reg: $($_.Exception.Message)" }

    # Delete any old OneDrive Startup shortcut that predates v0.3.0. That
    # shortcut path is the source of the "autostart silently vanished"
    # complaints, so we clean it up defensively even when autostart is on.
    try {
        $oneDriveStartup = Join-Path $env:USERPROFILE 'OneDrive\Microsoft\Windows\Start Menu\Programs\Startup\grab.lnk'
        if (Test-Path -LiteralPath $oneDriveStartup) {
            Remove-Item -LiteralPath $oneDriveStartup -Force -ErrorAction SilentlyContinue
            Log-Info "self-heal: removed stale OneDrive Startup shortcut ($oneDriveStartup)"
        }
    } catch {}

    # Delete OneDrive Desktop grab.lnk (same story). We recreate on LOCAL
    # Desktop only from now on.
    try {
        $oneDriveDesktop = Join-Path $env:USERPROFILE 'OneDrive\Desktop\grab.lnk'
        if (Test-Path -LiteralPath $oneDriveDesktop) {
            Remove-Item -LiteralPath $oneDriveDesktop -Force -ErrorAction SilentlyContinue
            Log-Info "self-heal: removed stale OneDrive Desktop shortcut ($oneDriveDesktop)"
        }
    } catch {}

    # Delete the "grab Downloads.lnk" desktop shortcut that pre-v0.3.0
    # installers scattered next to grab.lnk (audit P1-10). The tray menu now
    # carries an "Open downloads" item that supersedes the shortcut. This
    # runs at every tray start so users who installed a prior version get
    # their desktop cleaned up next time GRAB launches, no reinstall needed.
    try {
        foreach ($base in @((Get-LocalDesktopPath), (Join-Path $env:USERPROFILE 'Desktop'), (Join-Path $env:USERPROFILE 'OneDrive\Desktop'))) {
            if ($base -and (Test-Path -LiteralPath $base)) {
                $lnk = Join-Path $base 'grab Downloads.lnk'
                if (Test-Path -LiteralPath $lnk) {
                    Remove-Item -LiteralPath $lnk -Force -ErrorAction SilentlyContinue
                    Log-Info "self-heal: removed stale 'grab Downloads.lnk' ($lnk)"
                }
            }
        }
    } catch {}

    # Recreate local Desktop shortcut if missing. Uses WSH so the shortcut
    # matches what install.ps1 writes (icon, args, workingdir). Best-effort;
    # a missing shortcut isn't fatal, users can launch from Start Menu.
    try {
        $desktop = Get-LocalDesktopPath
        if ($desktop -and (Test-Path -LiteralPath $desktop)) {
            $lnk = Join-Path $desktop 'grab.lnk'
            if (-not (Test-Path -LiteralPath $lnk)) {
                $repoRoot = Split-Path $PSScriptRoot -Parent
                # Prefer the wscript.exe silent launcher when it ships alongside
                # grab-app.ps1; falls back to plain powershell.exe otherwise.
                $vbs      = Join-Path $repoRoot 'grab-app.vbs'
                $appEntry = Join-Path $repoRoot 'grab-app.ps1'
                $grabIco  = Join-Path $repoRoot 'assets\icon.ico'
                $wsh = New-Object -ComObject WScript.Shell
                $sc = $wsh.CreateShortcut($lnk)
                if (Test-Path -LiteralPath $vbs) {
                    $sc.TargetPath = 'wscript.exe'
                    $sc.Arguments  = '"' + $vbs + '"'
                } else {
                    $sc.TargetPath = 'powershell.exe'
                    $sc.Arguments  = '-STA -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $appEntry + '"'
                }
                $sc.WorkingDirectory = $repoRoot
                if (Test-Path -LiteralPath $grabIco) { $sc.IconLocation = $grabIco }
                $sc.Description = 'Launch the grab tray app'
                $sc.Save()
                Log-Info "self-heal: recreated Desktop shortcut ($lnk)"
            }
        }
    } catch { Log-Warn "self-heal desktop shortcut: $($_.Exception.Message)" }

    # Download folder: recreate if missing so the next grab doesn't crash
    # trying to New-Item into a deleted parent.
    try {
        if ($cfg.downloadFolder -and -not (Test-Path -LiteralPath $cfg.downloadFolder)) {
            New-Item -ItemType Directory -Path $cfg.downloadFolder -Force -ErrorAction Stop | Out-Null
            Log-Info "self-heal: recreated download folder ($($cfg.downloadFolder))"
        }
    } catch { Log-Warn "self-heal download folder: $($_.Exception.Message)" }

    # Ghost folder (audit P0-6): pre-v0.3.0 tests spilled into
    # $env:USERPROFILE\Downloads\imadjinn-grab. If it exists AND is empty,
    # remove it. If it contains real files, leave it alone and log a warn.
    try {
        $ghost = Join-Path $env:USERPROFILE 'Downloads\imadjinn-grab'
        if (Test-Path -LiteralPath $ghost) {
            $files = @(Get-ChildItem -LiteralPath $ghost -Recurse -File -Force -ErrorAction SilentlyContinue)
            if ($files.Count -eq 0) {
                Remove-Item -LiteralPath $ghost -Recurse -Force -ErrorAction SilentlyContinue
                Log-Info 'self-heal: removed empty ghost folder ~\Downloads\imadjinn-grab'
            } else {
                Log-Warn "self-heal: ghost folder $ghost has $($files.Count) file(s); leaving alone"
            }
        }
    } catch {}
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
