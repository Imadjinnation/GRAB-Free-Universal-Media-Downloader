# src/utils.ps1
# Shared helpers used by every other src/ file. No hardcoded paths.
# Dot-source: . "$PSScriptRoot\utils.ps1"

# ---------- Version constant (single source of truth) ---------------------
# Every version-carrying surface (config.version, About footer stamp, Settings
# VersionLabel, installer default, README) should read from Get-GrabVersion
# so we can't drift the way v0.1.0 vs v0.2.2 vs About vs settings did in
# v0.2.2. Bump this in ONE place per release.
$script:GrabVersion = '0.3.0'

function Get-GrabVersion { return $script:GrabVersion }

# App-data root. Override with $env:GRAB_APP_DATA_OVERRIDE for tests / power-users.
$script:AppData = if ($env:GRAB_APP_DATA_OVERRIDE) {
    $env:GRAB_APP_DATA_OVERRIDE
} else {
    Join-Path $env:APPDATA 'grab-app'
}
$script:ConfigPath   = Join-Path $script:AppData 'config.json'
$script:QueuePath    = Join-Path $script:AppData 'queue.json'
$script:RecentPath   = Join-Path $script:AppData 'recent.json'
$script:ArchivePath  = Join-Path $script:AppData 'done-archive.txt'
$script:LogFolder    = Join-Path $script:AppData 'logs'

# ---------- Config in-memory cache ----------------------------------------
# Get-Config used to re-parse config.json on every call (queue tick, popup
# refresh, clipboard tick, every row build). Cache the parsed PSCustomObject
# and invalidate on the file's LastWriteTimeUtc. Set-Config bumps this too.
$script:ConfigCache      = $null
$script:ConfigCacheMtime = $null

# ---------- Paths ---------------------------------------------------------

function Get-AppDataPath { return $script:AppData }
function Get-ConfigPath  { return $script:ConfigPath }
function Get-QueuePath   { return $script:QueuePath }
function Get-RecentPath  { return $script:RecentPath }
function Get-LogFolder   { return $script:LogFolder }

function Get-ArchivePath([string]$engine = '') {
    # yt-dlp and gallery-dl use incompatible line formats in
    # --download-archive; keep separate files. Legacy no-arg returns the
    # combined path (for backward compat with tests + tools that still
    # reference done-archive.txt).
    if ([string]::IsNullOrEmpty($engine)) { return $script:ArchivePath }
    return Join-Path $script:AppData ("done-archive-{0}.txt" -f $engine)
}

function Ensure-AppData {
    foreach ($p in @($script:AppData, $script:LogFolder)) {
        if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    }
}

# ---------- Atomic UTF-8-no-BOM JSON writer -------------------------------
# Replaces `$x | ConvertTo-Json | Set-Content -Encoding UTF8`. Two goals:
#   1) UTF-8 WITHOUT BOM. Set-Content -Encoding UTF8 writes a BOM in PS 5.1,
#      which tripped external tools that expect plain UTF-8 (audit P1-8).
#   2) Atomic replace. Kill mid-write no longer corrupts state (audit P1-9).
#
# We register a small MoveFileEx P/Invoke helper because [System.IO.File]::
# Replace() throws "The path is not of a legal form" under Windows PowerShell
# 5.1's overload resolution when the destinationBackupFileName is $null
# (verified empirically on Windows 11). MoveFileEx with MOVEFILE_REPLACE_
# EXISTING | MOVEFILE_WRITE_THROUGH is the same NTFS metadata-only rename
# that File.Replace wraps, minus the .NET quirk.
if (-not ('GrabApp.AtomicIO' -as [type])) {
    Add-Type -Namespace GrabApp -Name AtomicIO -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
static extern bool MoveFileEx(string src, string dst, int flags);

// MOVEFILE_REPLACE_EXISTING (0x1) + MOVEFILE_WRITE_THROUGH (0x8)
public static void ReplaceMove(string src, string dst) {
    if (!MoveFileEx(src, dst, 0x9)) {
        throw new System.ComponentModel.Win32Exception(System.Runtime.InteropServices.Marshal.GetLastWin32Error(), "MoveFileEx failed: " + src + " -> " + dst);
    }
}
'@ | Out-Null
}

function Write-JsonAtomic {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Data,
        [int]$Depth = 6
    )
    $tmp = "$Path.tmp"
    $json = $Data | ConvertTo-Json -Depth $Depth
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tmp, $json, $utf8NoBom)
    # NTFS-atomic rename over an existing file via MoveFileEx.
    if (Test-Path -LiteralPath $Path) {
        [GrabApp.AtomicIO]::ReplaceMove($tmp, $Path)
    } else {
        [System.IO.File]::Move($tmp, $Path)
    }
}

# ---------- Default download folder ---------------------------------------
# Central helper for the default downloadFolder value. Prefers D:\ if it
# exists (matches the user's actual setup), else falls back to a folder
# under %USERPROFILE% -- but NOT inside ~\Downloads because OneDrive /
# iCloud can sync-lock those and, more importantly, tests calling
# Invoke-Grab without a Dest override used to spill into that path and
# create ghost folders in the user's real Downloads (audit P0-6).
function Get-DownloadFolderDefault {
    if (Test-Path -LiteralPath 'D:\') { return 'D:\imadjinn-grab' }
    return (Join-Path $env:USERPROFILE 'imadjinn-grab')
}

# ---------- Unified XAML token substitution -------------------------------
# popup.ps1, settings.ps1, and tray.ps1 each had their own copy of a helper
# that swapped __GRAB_FONTS__ / __GRAB_THEME__ / __GRAB_ASSETS__ tokens in
# XAML text for real file:/// URIs. That's how the theme.xaml font-token
# fallback bug slipped in (each helper had subtle drift). One helper, one
# source of truth. Callers still compute their own URIs (a caller may not
# want all three) and pass in what they want substituted.
function Invoke-GrabTokenReplace {
    param(
        [Parameter(Mandatory)][string]$XamlText,
        [string]$FontsUri  = '',
        [string]$ThemeUri  = '',
        [string]$AssetsUri = ''
    )
    # PS 5.1 quirk: [string]$x = $null actually stores '' (empty string), so a
    # `$null -ne $x` check always fires. Use IsNullOrEmpty so a caller that
    # omits a token URI genuinely skips that substitution (leaves the token
    # in place) rather than replacing it with empty and breaking XAML parsing.
    $out = $XamlText
    if (-not [string]::IsNullOrEmpty($FontsUri))  { $out = $out.Replace('__GRAB_FONTS__',  $FontsUri) }
    if (-not [string]::IsNullOrEmpty($ThemeUri))  { $out = $out.Replace('__GRAB_THEME__',  $ThemeUri) }
    if (-not [string]::IsNullOrEmpty($AssetsUri)) { $out = $out.Replace('__GRAB_ASSETS__', $AssetsUri) }
    return $out
}

# ---------- WPF assembly lazy-loader --------------------------------------
# The tray icon should appear within ~1.5s of process start; before v0.3.0
# the JIT + load cost of PresentationFramework/PresentationCore/WindowsBase
# on cold-start added 3-5s to time-to-tray. NotifyIcon lives in
# System.Windows.Forms + System.Drawing which are lightweight, but the WPF
# assemblies are only needed when the user opens the popup, settings, or
# About window. This helper defers their Add-Type until first use, then
# caches the fact so subsequent calls are no-ops. Idempotent.
$script:WpfLoaded = $false
function Ensure-WpfLoaded {
    if ($script:WpfLoaded) { return }
    Add-Type -AssemblyName PresentationFramework | Out-Null
    Add-Type -AssemblyName PresentationCore      | Out-Null
    Add-Type -AssemblyName WindowsBase           | Out-Null
    $script:WpfLoaded = $true
}

# ---------- OneDrive-safe local user folders ------------------------------
# Windows can redirect Desktop / Documents / Startup into OneDrive. When that
# happens, shell:startup shortcuts get sync-shuffled and sometimes silently
# vanish (the shipping v0.2.2 desktop icon disappeared for exactly this
# reason). These helpers return the REAL local folder path even when the
# Shell has redirected the well-known folder to OneDrive.
function Test-IsOneDrivePath([string]$path) {
    if (-not $path) { return $false }
    return ($path -match '\\OneDrive(\\|$)|\\Dropbox(\\|$)|\\iCloudDrive(\\|$)')
}
function Get-LocalDesktopPath {
    # Prefer the shell folder if it isn't redirected. Otherwise fall back to
    # $env:USERPROFILE\Desktop -- the true local path Windows guarantees.
    $shell = [Environment]::GetFolderPath('Desktop')
    if ($shell -and -not (Test-IsOneDrivePath $shell)) { return $shell }
    $local = Join-Path $env:USERPROFILE 'Desktop'
    if (Test-Path -LiteralPath $local) { return $local }
    # Last resort: use whatever the shell says even if it's OneDrive.
    return $shell
}
function Get-LocalStartupPath {
    # Same story as Desktop -- Startup can be redirected into OneDrive
    # (rare but happens with folder-move policies), which makes autostart
    # shortcuts fragile. Prefer the real local Startup path.
    #
    # Audit P2-57: tests used to touch the user's real Startup folder. If
    # GRAB_STARTUP_OVERRIDE is set (only in test contexts), return it verbatim
    # so Set-Autostart writes into an ephemeral temp folder instead.
    if ($env:GRAB_STARTUP_OVERRIDE) { return $env:GRAB_STARTUP_OVERRIDE }
    $shell = [Environment]::GetFolderPath('Startup')
    if ($shell -and -not (Test-IsOneDrivePath $shell)) { return $shell }
    $local = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
    if (Test-Path -LiteralPath $local) { return $local }
    return $shell
}

# ---------- Autostart via HKCU Run registry -------------------------------
# The primary autostart mechanism is now the HKCU\Software\Microsoft\Windows\
# CurrentVersion\Run registry entry, not the shell:startup shortcut. When the
# user's Startup folder lives inside OneDrive/Dropbox/iCloud (which is the
# case for many modern Windows installs), the shortcut can silently vanish
# during sync -- especially if the user pauses/unlinks the drive. HKCU\Run
# is local to the machine and survives cloud shenanigans.
#
# Audit v0.3.0-pass2 P0-1: pre-4.5 this hard-coded `powershell.exe -File
# grab-app.ps1`, so every login flashed a black console window before the
# tray icon appeared. Now we mirror _RestartTray's pattern -- if the
# wscript.exe launcher (grab-app.vbs) exists in the repo root, use IT so
# the launch is fully silent; fall back to powershell.exe only when the
# .vbs is missing (older checkouts).
# Audit v0.3.0-pass2 finding 32: WScript.Shell RCWs were never released
# so every autostart write / self-heal sweep leaked a COM handle. This
# helper wraps the create-and-release dance so every callsite gets it
# right without duplicating the pattern.
function New-GrabShortcut {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Target,
        [string]$Arguments = '',
        [string]$WorkingDirectory = '',
        [string]$IconLocation = '',
        [string]$Description = ''
    )
    $wsh = $null
    try {
        $wsh = New-Object -ComObject WScript.Shell
        $sc = $wsh.CreateShortcut($Path)
        $sc.TargetPath = $Target
        if ($Arguments)        { $sc.Arguments = $Arguments }
        if ($WorkingDirectory) { $sc.WorkingDirectory = $WorkingDirectory }
        if ($IconLocation)     { $sc.IconLocation = $IconLocation }
        if ($Description)      { $sc.Description = $Description }
        $sc.Save()
    } finally {
        if ($wsh) {
            try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($wsh) | Out-Null } catch {}
        }
    }
}

function Get-AutostartRegistryCommand {
    # Returns the exact command string we want written to HKCU\Run\GRAB, so
    # both Set-AutostartRegistry and drift-detection in Invoke-SelfHealSweep
    # can compare against a single source of truth.
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $vbs      = Join-Path $repoRoot 'grab-app.vbs'
    $entry    = Join-Path $repoRoot 'grab-app.ps1'
    if (Test-Path -LiteralPath $vbs) {
        return 'wscript.exe "' + $vbs + '"'
    }
    return 'powershell.exe -STA -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $entry + '"'
}

function Set-AutostartRegistry([bool]$enable) {
    # Test hook (audit P2 #61): tests set GRAB_RUN_KEY_OVERRIDE to a fake
    # subkey path so a Set-Autostart round-trip never touches the real
    # HKCU\Run entry.
    $key   = if ($env:GRAB_RUN_KEY_OVERRIDE) { $env:GRAB_RUN_KEY_OVERRIDE } else { 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' }
    $name  = 'GRAB'
    $value = Get-AutostartRegistryCommand
    try {
        if ($enable) {
            if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
            Set-ItemProperty -Path $key -Name $name -Value $value -Force
        } else {
            Remove-ItemProperty -Path $key -Name $name -ErrorAction SilentlyContinue
        }
    } catch { Log-Warn "Set-AutostartRegistry ($enable) failed: $($_.Exception.Message)" }
}

# ---------- Config load / save --------------------------------------------

function Get-Config {
    Ensure-AppData
    if (-not (Test-Path $script:ConfigPath)) {
        $default = @{
            version              = $script:GrabVersion   # single source of truth
            downloadFolder       = Get-DownloadFolderDefault
            askBeforeEach        = $false
            clipboardWatch       = $false
            concurrency          = 3
            autostart            = $true
            cookieBrowser        = 'chrome'
            videoQuality         = 'best'                 # yt-dlp preferred ceiling
            toastsEnabled        = $true
            popupPositionX       = $null
            popupPositionY       = $null
            firstRunComplete     = $false
            # Safety / privacy
            sensitiveByDefault   = $false                 # every download routes to .private
            sensitiveSites       = @()                    # URL substrings that auto-route to .private
            sensitiveFolderName  = '.private'             # folder name inside category
            # Display (arcade cabinet effects)
            crtScanlines         = $true                  # static CRT overlay in popup/settings/about
        }
        Write-JsonAtomic -Path $script:ConfigPath -Data $default -Depth 4
        # Seed cache so the immediate next Get-Config doesn't re-read from disk.
        $script:ConfigCache      = $default
        try { $script:ConfigCacheMtime = (Get-Item -LiteralPath $script:ConfigPath).LastWriteTimeUtc } catch {}
        return $default
    }
    # Fast path: mtime-checked in-memory cache. Get-Config runs on every
    # queue tick, clipboard tick, popup refresh, and row build -- the file
    # rarely changes between reads, so ConvertFrom-Json each time was pure
    # waste. Cache invalidation keys on LastWriteTimeUtc so external edits
    # (or another process's Set-Config) still get picked up. See audit P0-4.
    try {
        $curMtime = (Get-Item -LiteralPath $script:ConfigPath).LastWriteTimeUtc
        if ($null -ne $script:ConfigCache -and $script:ConfigCacheMtime -eq $curMtime) {
            return $script:ConfigCache
        }
    } catch {}
    # Malformed config.json used to crash the app on startup (ConvertFrom-Json
    # throws, then every PSObject.Properties.Name.Contains(...) call below
    # blows up on the null $cfg). If the parse fails, back up the corrupt file
    # (so users can inspect it) and continue with defaults so grab keeps working.
    $cfg = $null
    try {
        $cfg = Get-Content $script:ConfigPath -Raw | ConvertFrom-Json
    } catch {
        Log-Warn "config.json is corrupt ($($_.Exception.Message)); backing up and using defaults."
        try {
            $backup = "$($script:ConfigPath).corrupt-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
            Copy-Item -LiteralPath $script:ConfigPath -Destination $backup -Force -ErrorAction SilentlyContinue
        } catch {}
        # Rewrite fresh defaults + return them directly (short-circuit back-fill).
        Remove-Item -LiteralPath $script:ConfigPath -Force -ErrorAction SilentlyContinue
        # Invalidate cache -- the recursive call will re-seed it.
        $script:ConfigCache = $null
        $script:ConfigCacheMtime = $null
        return Get-Config
    }
    if ($null -eq $cfg) {
        # Empty file / whitespace-only: same recovery path.
        Log-Warn 'config.json parsed as $null; rewriting defaults.'
        Remove-Item -LiteralPath $script:ConfigPath -Force -ErrorAction SilentlyContinue
        $script:ConfigCache = $null
        $script:ConfigCacheMtime = $null
        return Get-Config
    }
    # Back-fill new keys added post-first-config, so older configs still work
    # Audit v0.3.0-pass2 finding 62: PSObject.Properties.Name.Contains is
    # case-sensitive (System.Collections.ObjectModel.Collection.Contains).
    # A config with 'SensitiveSites' (mis-cased on hand-edit) would
    # silently double-add the key, then the mis-cased read below fails.
    # Use a case-insensitive helper.
    $hasProp = { param($o,$n) foreach ($p in $o.PSObject.Properties.Name) { if ($p -ieq $n) { return $true } } return $false }
    if (-not (& $hasProp $cfg 'sensitiveSites')) {
        $cfg | Add-Member -MemberType NoteProperty -Name sensitiveSites -Value @() -Force
    }
    if (-not (& $hasProp $cfg 'sensitiveByDefault')) {
        $cfg | Add-Member -MemberType NoteProperty -Name sensitiveByDefault -Value $false -Force
    }
    if (-not (& $hasProp $cfg 'sensitiveFolderName')) {
        $cfg | Add-Member -MemberType NoteProperty -Name sensitiveFolderName -Value '.private' -Force
    }
    if (-not (& $hasProp $cfg 'videoQuality')) {
        $cfg | Add-Member -MemberType NoteProperty -Name videoQuality -Value 'best' -Force
    }
    if (-not (& $hasProp $cfg 'crtScanlines')) {
        # Back-fill: default TRUE so existing configs keep the arcade cabinet
        # look after upgrading. Users can uncheck it in Settings > Display.
        $cfg | Add-Member -MemberType NoteProperty -Name crtScanlines -Value $true -Force
    }
    # Phase 5: auto-update daily check + tracking keys.
    if (-not (& $hasProp $cfg 'autoUpdateCheck')) {
        $cfg | Add-Member -MemberType NoteProperty -Name autoUpdateCheck -Value $true -Force
    }
    if (-not (& $hasProp $cfg 'lastGrabUpdateCheck')) {
        # ISO-8601 UTC timestamp of the last GitHub Releases poll, or ''.
        $cfg | Add-Member -MemberType NoteProperty -Name lastGrabUpdateCheck -Value '' -Force
    }
    if (-not (& $hasProp $cfg 'lastToolUpdateCheck')) {
        $cfg | Add-Member -MemberType NoteProperty -Name lastToolUpdateCheck -Value '' -Force
    }
    # Phase 5: existing-user migration hint. If the on-disk downloadFolder
    # matches the pre-v0.1.1 OneDrive-fragile default, surface a one-time
    # balloon nudging the user to move to the new default. Non-destructive
    # -- we never rewrite their folder without their consent.
    if (-not (& $hasProp $cfg 'migrationV030PromptShown')) {
        $cfg | Add-Member -MemberType NoteProperty -Name migrationV030PromptShown -Value $false -Force
    }
    # Version migration: if the on-disk config predates the current grab
    # release, bump its version stamp and persist. Prevents drift like the
    # v0.1.0 -> v0.2.2 gap that made every audit start with a stale config.
    # Guarded to avoid infinite loops (Set-Config -> Get-Config).
    if ($cfg.version -ne $script:GrabVersion) {
        $fromVer = $cfg.version
        $cfg.version = $script:GrabVersion
        Set-Config $cfg
        Log-Info "config version migrated from $fromVer to $script:GrabVersion"
        # Set-Config already updated the cache; return the migrated object.
        return $cfg
    }
    # Cache the parsed object for the next call.
    $script:ConfigCache = $cfg
    try { $script:ConfigCacheMtime = (Get-Item -LiteralPath $script:ConfigPath).LastWriteTimeUtc } catch {}
    return $cfg
}

function Set-Config([object]$config) {
    Ensure-AppData
    Write-JsonAtomic -Path $script:ConfigPath -Data $config -Depth 4
    # Refresh cache in lock-step with the write so the very next Get-Config
    # returns the value we just persisted (not a stale copy).
    $script:ConfigCache = $config
    try { $script:ConfigCacheMtime = (Get-Item -LiteralPath $script:ConfigPath).LastWriteTimeUtc } catch {}
}

function Update-Config([hashtable]$updates) {
    $cfg = Get-Config
    foreach ($key in $updates.Keys) { $cfg.$key = $updates[$key] }
    Set-Config $cfg
    return $cfg
}

# ---------- Runtime theme URI (font-token substitution) -------------------
# theme.xaml on disk has __GRAB_FONTS__ placeholder tokens (e.g. inside
# ArcadePrimary, ArcadeTab, Kicker, etc.). Our XAML loaders substitute those
# tokens in the WINDOW xaml text before parsing -- but the theme is included
# via `<ResourceDictionary Source="file:///.../theme.xaml"/>` and WPF loads
# that file DIRECTLY from disk without our substitution. Result: every
# theme-styled control (buttons, tabs, tooltips, section headers, kickers)
# silently falls back to the WPF default font instead of Silkscreen / VT323
# / Inter -- a big visual regression that no earlier test caught.
#
# Fix: at load time, materialize a substituted copy of theme.xaml to a
# stable temp file and return its file:/// URI. Window loaders point their
# __GRAB_THEME__ replacement at this URI so WPF sees the resolved fonts.
# Written to <AppData>\grab-app\.runtime-theme.xaml so it survives reboots
# without stacking multiple temp files.
function Get-RuntimeThemeUri {
    param(
        [Parameter(Mandatory)][string]$SourceThemePath,
        [Parameter(Mandatory)][string]$FontsUri
    )
    Ensure-AppData
    try {
        $out = Join-Path $script:AppData '.runtime-theme.xaml'
        # Fast path (audit P1-28): if the runtime file already exists AND is
        # newer than the source theme.xaml, skip the read+substitute+write
        # entirely. Source rarely changes between launches; content diff
        # (below) is expensive per launch on cold FS. Only run the content
        # check when mtime says the source WAS touched more recently.
        if (Test-Path -LiteralPath $out) {
            try {
                $srcMtime = (Get-Item -LiteralPath $SourceThemePath).LastWriteTimeUtc
                $outMtime = (Get-Item -LiteralPath $out).LastWriteTimeUtc
                if ($outMtime -ge $srcMtime) {
                    return 'file:///' + (($out -replace '\\','/'))
                }
            } catch {}
        }
        $raw = Get-Content -LiteralPath $SourceThemePath -Raw -Encoding UTF8
        $sub = $raw.Replace('__GRAB_FONTS__', $FontsUri)
        # Write only when different -- avoids touching mtime every launch even
        # when the source WAS newer but with a compatible substitution result.
        $needWrite = $true
        if (Test-Path -LiteralPath $out) {
            try {
                $cur = Get-Content -LiteralPath $out -Raw -Encoding UTF8
                if ($cur -eq $sub) { $needWrite = $false }
            } catch {}
        }
        if ($needWrite) {
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($out, $sub, $utf8NoBom)
        }
        return 'file:///' + (($out -replace '\\','/'))
    } catch {
        Log-Warn "Get-RuntimeThemeUri fell back to source theme: $($_.Exception.Message)"
        # Fallback: return the on-disk theme URI so the load doesn't fail.
        # Fonts will still fall back, but the UI stays functional.
        return 'file:///' + (($SourceThemePath -replace '\\','/'))
    }
}

# ---------- Tool discovery (portable) -------------------------------------
# Resolve yt-dlp / gallery-dl from PATH first, then from the Python scripts
# folder we can query directly. Never hardcodes a user path.

function Get-PythonScriptsDir {
    foreach ($cmd in @('python','py','python3')) {
        $probe = & $cmd --version 2>&1
        if ($LASTEXITCODE -eq 0) {
            $dir = & $cmd -c "import sysconfig; print(sysconfig.get_path('scripts'))" 2>&1
            if (Test-Path $dir) { return $dir }
            $dir = & $cmd -c "import site,os; print(os.path.join(site.USER_BASE,'Scripts'))" 2>&1
            if (Test-Path $dir) { return $dir }
        }
    }
    return $null
}

$script:ToolCache = @{}

# Repo-root-relative assets/bin/ directory. Populated by the Phase 5.5
# installer / portable-zip build (build/build-installer.ps1) and NOT
# by a plain `git clone` -- see .gitignore. Kept as a script-scoped value
# so tests can override it via GRAB_BUNDLED_BIN_OVERRIDE without touching
# the on-disk path.
function Get-BundledBinDir {
    if ($env:GRAB_BUNDLED_BIN_OVERRIDE) { return $env:GRAB_BUNDLED_BIN_OVERRIDE }
    # $PSScriptRoot here is src/, so bin dir is ../assets/bin.
    return (Join-Path (Split-Path $PSScriptRoot -Parent) 'assets\bin')
}

function Resolve-Tool([string]$name) {
    # Precedence:
    #   1. Bundled binary at <repo>/assets/bin/<name>.exe -- shipped with
    #      the Phase 5.5 installer / portable zip. Wins over PATH so users
    #      never accidentally run a stale pip-installed yt-dlp against the
    #      wrong yt-dlp-ejs. Managed by our own updater.
    #   2. Python scripts folder (managed by install.ps1's legacy pip flow).
    #   3. Whatever is on PATH (winget yt-dlp.yt-dlp etc.).
    # Cached per process; invalidate by clearing $script:ToolCache in tests.
    if ($script:ToolCache.ContainsKey($name)) { return $script:ToolCache[$name] }

    # 1. Bundled binary (Phase 5.5). Prepend to PATH so children see it first.
    $bundledDir = Get-BundledBinDir
    if ($bundledDir -and (Test-Path -LiteralPath $bundledDir)) {
        $bundled = Join-Path $bundledDir "$name.exe"
        if (Test-Path -LiteralPath $bundled) {
            if ($env:Path -notlike "$bundledDir;*") { $env:Path = $bundledDir + ';' + $env:Path }
            $script:ToolCache[$name] = $bundled
            return $bundled
        }
    }
    # 2. Python scripts folder (managed by install.ps1's pip flow)
    $scripts = Get-PythonScriptsDir
    if ($scripts) {
        $exe = Join-Path $scripts "$name.exe"
        if (Test-Path $exe) {
            # Prepend to PATH so children (Start-Job workers) see it first
            if ($env:Path -notlike "$scripts;*") { $env:Path = $scripts + ';' + $env:Path }
            $script:ToolCache[$name] = $exe
            return $exe
        }
    }
    # 3. Fallback to whatever is on PATH
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { $script:ToolCache[$name] = $cmd.Source; return $cmd.Source }
    return $null
}

# ---------- Logging -------------------------------------------------------
# Rotation policy (audit P1-23):
#   - Per-day file grab-YYYY-MM-DD.log; if today's file exceeds 5MB, rotate
#     to .1 (deleting any prior .1 first). Two files per day is the cap.
#   - Log folder is pruned to the newest 30 daily files. Older ones are
#     deleted. Rotated .1 files count as one file each.
# Rotation is best-effort: any failure logs to stderr but never blocks the
# actual Add-Content write below. That guarantees log capture never gets
# lost to a rotation edge case.

$script:LogMaxBytes    = 5MB
$script:LogKeepDays    = 30
$script:LogRotateCheck = 0     # last tick counter; rotates every 20 writes

# Audit PERF-3: batched log flush. Write-Log used to Add-Content on every
# call (one open + fsync per line -- expensive during a burst of queue
# ticks). Now Write-Log enqueues into a concurrent queue, and a dispatcher
# timer (started from Start-Timers in tray.ps1) drains it every 1s. Callers
# that need the log flushed immediately (Stop-Tray on shutdown) call
# Flush-LogQueue.
$script:LogQueue    = $null
$script:LogBatching = $false
function _EnsureLogQueue {
    if ($null -eq $script:LogQueue) {
        $script:LogQueue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
    }
}
function Enable-LogBatching { _EnsureLogQueue; $script:LogBatching = $true }
function Disable-LogBatching { $script:LogBatching = $false; Flush-LogQueue }
function Flush-LogQueue {
    _EnsureLogQueue
    if ($script:LogQueue.Count -eq 0) { return }
    # Group by target file so we open each per-day log at most once per flush.
    $buckets = @{}
    $item = $null
    while ($script:LogQueue.TryDequeue([ref]$item)) {
        $key = $item.File
        if (-not $buckets.ContainsKey($key)) { $buckets[$key] = New-Object System.Collections.Generic.List[string] }
        [void]$buckets[$key].Add($item.Line)
    }
    foreach ($k in $buckets.Keys) {
        try {
            Add-Content -Path $k -Value ($buckets[$k]) -Encoding UTF8
        } catch {
            # Never let a log write bring down a caller; drop the batch quietly.
        }
    }
}

function _RotateLogIfNeeded([string]$file) {
    try {
        if (Test-Path -LiteralPath $file) {
            $len = (Get-Item -LiteralPath $file -ErrorAction Stop).Length
            if ($len -ge $script:LogMaxBytes) {
                $rot = "$file.1"
                if (Test-Path -LiteralPath $rot) {
                    Remove-Item -LiteralPath $rot -Force -ErrorAction SilentlyContinue
                }
                Move-Item -LiteralPath $file -Destination $rot -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {}
}

function _PruneOldLogs {
    try {
        $files = Get-ChildItem -LiteralPath $script:LogFolder -Filter 'grab-*.log*' -File -ErrorAction SilentlyContinue |
                 Sort-Object -Property LastWriteTimeUtc -Descending
        if ($files.Count -gt $script:LogKeepDays) {
            $files | Select-Object -Skip $script:LogKeepDays | ForEach-Object {
                try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue } catch {}
            }
        }
    } catch {}
}

function Write-Log([string]$level, [string]$msg) {
    Ensure-AppData
    $file = Join-Path $script:LogFolder ("grab-{0}.log" -f (Get-Date -Format 'yyyy-MM-dd'))
    # Both rotation checks are bucketed off a single mod-N counter so the
    # hot path (log-a-line) stays close to just Add-Content. Rotate every
    # 50 writes; prune every 200. Both are best-effort and never block the
    # actual log append below. At worst, a rotation is delayed by <50 lines
    # which is trivial compared to the 5MB threshold.
    # Audit v0.3.0-pass2 P2 finding 51: rotate check batched to every 500
    # writes (was 50). Prune stays at every 200 writes because a full log
    # folder listing is cheap; rotate does a stat() so batching it further
    # is a small hot-path win under bursty logging.
    $script:LogRotateCheck = ($script:LogRotateCheck + 1) % 500
    if (($script:LogRotateCheck % 500) -eq 0) { _RotateLogIfNeeded $file }
    if ($script:LogRotateCheck -eq 0)         { _PruneOldLogs }
    # Audit v0.3.0-pass2 finding 55: UTC 'Z' suffix so log timestamps are
    # unambiguous across timezones and DST rollover (portable-apps case).
    $stamp = (Get-Date).ToUniversalTime().ToString('HH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
    # Audit P2-55: redact wider list of secret-shaped query params from URLs
    # before they hit the log. Extended vocabulary catches bearer tokens,
    # JWTs, OAuth/access/id tokens, session cookies, AWS signed-URL params,
    # etc. Kept in one alternation so the whole match+replace stays one pass.
    $sanitized = $msg -replace `
        '([?&](?:token|auth|password|api[_-]?key|apikey|sig|signature|bearer|access[_-]?token|id[_-]?token|oauth[_-]?token|sess(?:ion)?|jwt|code|X-Amz-[A-Za-z-]+)=)[^&\s]+','${1}REDACTED'
    $line = "$stamp [$level] $sanitized"
    # Audit PERF-3: when batching is on (started from Start-Timers), enqueue
    # instead of writing synchronously. A 1s dispatcher timer drains the queue.
    if ($script:LogBatching) {
        _EnsureLogQueue
        [void]$script:LogQueue.Enqueue([pscustomobject]@{ File = $file; Line = $line })
    } else {
        Add-Content -Path $file -Value $line -Encoding UTF8
    }
}

function Log-Info ([string]$msg) { Write-Log 'INFO'  $msg }
function Log-Warn ([string]$msg) { Write-Log 'WARN'  $msg }
function Log-Err  ([string]$msg) { Write-Log 'ERROR' $msg }

# ---------- Toast notifications -------------------------------------------
# BurntToast preferred; falls back to console write.

function Send-Toast([string]$title, [string]$body, [string]$action = $null) {
    $cfg = Get-Config
    if (-not $cfg.toastsEnabled) { return }
    try {
        Import-Module BurntToast -ErrorAction Stop
        $params = @{ Text = @($title, $body) }
        if ($action) { $params['AppLogo'] = $null }  # placeholder for future icon
        # BurntToast wraps the Windows toast API which the OS themes itself;
        # a custom XML template with our arcade palette is possible but
        # brittle across Windows versions. Kept as-is per Part D scope note.
        New-BurntToastNotification @params
    } catch {
        # Console fallback: magenta matches the arcade palette (warnings /
        # generic notify) so debugging output is visually consistent.
        Write-Host "[toast] $title -- $body" -ForegroundColor Magenta
    }
}

# ---------- Auto-update daily check (Phase 5) ------------------------------
# Polls GitHub Releases at most once per 24 hours for:
#   1. grab itself (imadjinnation/GRAB-Free-Universal-Media-Downloader)
#   2. yt-dlp (yt-dlp/yt-dlp) -- compared against the local yt-dlp --version
#   3. gallery-dl (mikf/gallery-dl) -- compared against the local --version
# ffmpeg is intentionally skipped (rarely updated, large, and winget already
# handles it in install.ps1). All network I/O is best-effort with a 5s timeout:
# 404 (no releases yet) and 403 (rate limit) are swallowed silently so a
# GitHub outage never surfaces user-visible noise. New GRAB versions fire a
# balloon toast; new dependency versions log-only in Phase 5 (auto-download
# and swap deferred to Phase 5.5+ once the installer plumbing lands).
#
# Repos (URLs kept explicit so grep can find them; the /latest endpoint
# returns the highest non-prerelease semver-shaped tag).
$script:GrabReleasesLatest      = 'https://api.github.com/repos/imadjinnation/GRAB-Free-Universal-Media-Downloader/releases/latest'
$script:GrabReleasesHtml        = 'https://github.com/imadjinnation/GRAB-Free-Universal-Media-Downloader/releases'
$script:YtDlpReleasesLatest     = 'https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest'
$script:GalleryDlReleasesLatest = 'https://api.github.com/repos/mikf/gallery-dl/releases/latest'

function _NormalizeGrabTag([string]$tag) {
    # Strip any leading 'grab-v' or 'v' prefix. Handles 'grab-v0.3.0',
    # 'v0.3.0', '0.3.0' identically -> '0.3.0'.
    if ([string]::IsNullOrEmpty($tag)) { return '' }
    return ($tag -replace '^grab-','' -replace '^v','').Trim()
}

function _CompareSemver([string]$a, [string]$b) {
    # Returns -1 / 0 / 1 the same way [System.Version] would, but tolerant of
    # non-numeric segments (yt-dlp nightly uses 2024.10.22.213947, gallery-dl
    # uses 1.27.5). Falls back to string compare on parse failure.
    if ([string]::IsNullOrEmpty($a) -and [string]::IsNullOrEmpty($b)) { return 0 }
    if ([string]::IsNullOrEmpty($a)) { return -1 }
    if ([string]::IsNullOrEmpty($b)) { return  1 }
    try {
        $va = [System.Version]::Parse($a)
        $vb = [System.Version]::Parse($b)
        return $va.CompareTo($vb)
    } catch {}
    return [string]::Compare($a, $b, [System.StringComparison]::OrdinalIgnoreCase)
}

function Invoke-GitHubLatest {
    # Wrapper around Invoke-RestMethod for the /releases/latest endpoint.
    # Returns the parsed PSCustomObject on success; $null on any failure
    # (404 no releases, 403 rate limit, network, TLS, timeout, DNS). Tests
    # inject Invoke-RestMethod via the pipeline (see smoke.ps1); this helper
    # is a thin seam we can mock.
    param(
        [Parameter(Mandatory)][string]$Url,
        [int]$TimeoutSec = 5
    )
    try {
        # UA is required by GitHub's REST API or it 403s every call.
        $ua = 'grab/' + (Get-GrabVersion) + ' (+https://github.com/imadjinnation/GRAB-Free-Universal-Media-Downloader)'
        return Invoke-RestMethod -Uri $Url -Method Get -Headers @{ 'User-Agent' = $ua } -TimeoutSec $TimeoutSec -ErrorAction Stop
    } catch {
        return $null
    }
}

function _ToolInstalledVersion([string]$name) {
    # Runs `<tool> --version` and returns the trimmed first line, or ''.
    # No exception ever escapes -- a missing tool just returns ''.
    try {
        $exe = Resolve-Tool $name
        if (-not $exe) { return '' }
        $out = & $exe --version 2>&1
        if ($LASTEXITCODE -ne 0) { return '' }
        if ($out -is [array]) { $out = $out[0] }
        return ($out.ToString()).Trim()
    } catch { return '' }
}

function Check-ForUpdates {
    # Public entrypoint. Called from the tray timer at most once per 24h.
    # Returns a summary hashtable so tests can assert what happened without
    # tapping the balloon-toast UI. The tray wires the returned hashtable's
    # GrabNewer flag to a ShowBalloonTip + configures the click handler.
    #
    # Side effects:
    #   - Reads config for lastGrabUpdateCheck / lastToolUpdateCheck.
    #   - Writes them via Update-Config on a real (non-skipped) check.
    #   - Logs each outcome.
    # Never throws; every network failure surfaces as Ok=$false and null tag.
    param(
        [switch]$Force,        # bypass the 24h skip (for manual "check now")
        [scriptblock]$Fetcher  # test hook: takes $url, returns PSCustomObject
    )
    $result = [ordered]@{
        Skipped         = $false
        Reason          = ''
        GrabLatest      = $null    # e.g. '0.4.0'
        GrabCurrent     = Get-GrabVersion
        GrabNewer       = $false
        GrabUrl         = $script:GrabReleasesHtml
        YtDlpLatest     = $null
        YtDlpCurrent    = $null
        YtDlpNewer      = $false
        GalleryDlLatest = $null
        GalleryDlCurrent = $null
        GalleryDlNewer  = $false
    }
    $cfg = $null
    try { $cfg = Get-Config } catch { $result.Skipped = $true; $result.Reason = 'config-unavailable'; return $result }
    if (-not $Force -and -not $cfg.autoUpdateCheck) {
        $result.Skipped = $true; $result.Reason = 'disabled-in-config'
        return $result
    }
    # 24-hour throttle. lastGrabUpdateCheck is an ISO-8601 UTC string; parse
    # with InvariantCulture to avoid the local-date DST bug (audit finding 55).
    if (-not $Force) {
        try {
            if ($cfg.lastGrabUpdateCheck) {
                $last = [datetime]::ParseExact(
                    [string]$cfg.lastGrabUpdateCheck,
                    'o', [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::RoundtripKind)
                $ageHours = ([datetime]::UtcNow - $last).TotalHours
                if ($ageHours -lt 24) {
                    $result.Skipped = $true
                    $result.Reason  = ('throttled:{0:N1}h since last check' -f $ageHours)
                    return $result
                }
            }
        } catch { Log-Warn "Check-ForUpdates: bad lastGrabUpdateCheck ('$($cfg.lastGrabUpdateCheck)'); treating as never-checked." }
    }
    # Fetch each release. When a $Fetcher scriptblock is provided (tests), use
    # it in place of Invoke-GitHubLatest so a fake response can drive assertions.
    $fetch = if ($Fetcher) { $Fetcher } else { { param($u) Invoke-GitHubLatest -Url $u } }

    # ---- grab ------------------------------------------------------------
    try {
        $r = & $fetch $script:GrabReleasesLatest
        if ($r -and $r.tag_name) {
            $latest = _NormalizeGrabTag ([string]$r.tag_name)
            $result.GrabLatest = $latest
            if ((_CompareSemver $latest (Get-GrabVersion)) -gt 0) {
                $result.GrabNewer = $true
                Log-Info "auto-update: GRAB v$latest available (current $($result.GrabCurrent))"
            } else {
                Log-Info "auto-update: GRAB is current (v$($result.GrabCurrent))"
            }
            if ($r.html_url) { $result.GrabUrl = [string]$r.html_url }
        } else {
            Log-Info 'auto-update: no GRAB release found (404 / rate-limited / offline) -- skipping silently'
        }
    } catch { Log-Warn "auto-update GRAB check failed: $($_.Exception.Message)" }

    # ---- yt-dlp ----------------------------------------------------------
    try {
        $result.YtDlpCurrent = _ToolInstalledVersion 'yt-dlp'
        if ($result.YtDlpCurrent) {
            $r = & $fetch $script:YtDlpReleasesLatest
            if ($r -and $r.tag_name) {
                $latest = _NormalizeGrabTag ([string]$r.tag_name)
                $result.YtDlpLatest = $latest
                if ((_CompareSemver $latest $result.YtDlpCurrent) -gt 0) {
                    $result.YtDlpNewer = $true
                    Log-Info "auto-update: yt-dlp $latest available (installed $($result.YtDlpCurrent))"
                }
            }
        }
    } catch { Log-Warn "auto-update yt-dlp check failed: $($_.Exception.Message)" }

    # ---- gallery-dl ------------------------------------------------------
    try {
        $result.GalleryDlCurrent = _ToolInstalledVersion 'gallery-dl'
        if ($result.GalleryDlCurrent) {
            $r = & $fetch $script:GalleryDlReleasesLatest
            if ($r -and $r.tag_name) {
                $latest = _NormalizeGrabTag ([string]$r.tag_name)
                $result.GalleryDlLatest = $latest
                if ((_CompareSemver $latest $result.GalleryDlCurrent) -gt 0) {
                    $result.GalleryDlNewer = $true
                    Log-Info "auto-update: gallery-dl $latest available (installed $($result.GalleryDlCurrent))"
                }
            }
        }
    } catch { Log-Warn "auto-update gallery-dl check failed: $($_.Exception.Message)" }

    # Stamp the last-check timestamp regardless of individual repo outcome
    # so a persistent GitHub outage doesn't turn Check-ForUpdates into a hot
    # loop. Test hook: skip the persist when Fetcher is supplied so tests
    # don't pollute config state.
    if (-not $Fetcher) {
        try {
            $now = [datetime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            Update-Config @{ lastGrabUpdateCheck = $now; lastToolUpdateCheck = $now } | Out-Null
        } catch { Log-Warn "auto-update: failed to persist lastGrabUpdateCheck: $($_.Exception.Message)" }
    }
    return $result
}

# ---------- URL utilities -------------------------------------------------

function Test-IsUrl([string]$s) {
    return $s -match '^https?://\S+$'
}

function Get-RedactedUrl([string]$u) {
    # Audit P2-56: recent.json used to store URLs verbatim, including any
    # ?token=... / signed-URL params. This helper applies the same redaction
    # rule as Write-Log (kept in lock-step deliberately) so Recent entries
    # never leak short-lived credentials to whoever opens the JSON.
    if ($null -eq $u) { return '' }
    return ($u -replace `
        '([?&](?:token|auth|password|api[_-]?key|apikey|sig|signature|bearer|access[_-]?token|id[_-]?token|oauth[_-]?token|sess(?:ion)?|jwt|code|X-Amz-[A-Za-z-]+)=)[^&\s]+','${1}REDACTED')
}

function Get-SiteName([string]$u) {
    # Short name (first label). e.g. 'youtube', 'allporncomic'
    try {
        $h = ([Uri]$u).Host -replace '^www\.', ''
        ($h -split '\.')[0]
    } catch { 'misc' }
}

function Get-FullDomain([string]$u) {
    # Full host including TLD, minus www. e.g. 'allporncomic.com', 'youtube.com'
    # Keeps subdomains (en.wikipedia.org) since they carry meaning per-site.
    try {
        $h = ([Uri]$u).Host -replace '^www\.', ''
        if ([string]::IsNullOrWhiteSpace($h)) { return 'misc' }
        return $h.ToLower()
    } catch { 'misc' }
}

function Test-IsSensitiveUrl([string]$url) {
    # Routes a URL to the .private hidden subfolder if:
    #   - sensitiveByDefault is on, OR
    #   - the URL matches any pattern in sensitiveSites (case-insensitive
    #     substring; simple regex-escape so users don't need to know regex).
    # Case-insensitive so "AllPornComic.com" matches "allporncomic.com".
    $cfg = Get-Config
    if ($cfg.sensitiveByDefault) { return $true }
    if (-not $cfg.sensitiveSites) { return $false }
    $lower = $url.ToLower()
    foreach ($pat in $cfg.sensitiveSites) {
        if ([string]::IsNullOrWhiteSpace($pat)) { continue }
        if ($lower -like ("*" + $pat.ToLower().Trim() + "*")) { return $true }
    }
    return $false
}

function Set-FolderHidden([string]$path, [switch]$Recurse) {
    # Idempotently sets Hidden attribute on a folder. Wrapped in try/catch
    # because attribute writes can fail on protected paths -- and that
    # should never block a download. When -Recurse is set, also hides
    # every subfolder + file inside so nothing peeks through even if the
    # user has "show hidden items" off but drills into the root by path.
    $failCount = 0
    try {
        if (Test-Path -LiteralPath $path) {
            $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if (-not ($item.Attributes -band [System.IO.FileAttributes]::Hidden)) {
                $item.Attributes = $item.Attributes -bor [System.IO.FileAttributes]::Hidden
            }
            if ($Recurse) {
                # Get-ChildItem -Force sees hidden entries; skip reparse points
                # (junctions/symlinks) to avoid following into the OS tree.
                Get-ChildItem -LiteralPath $path -Force -Recurse -ErrorAction SilentlyContinue |
                    Where-Object { -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) } |
                    ForEach-Object {
                        try {
                            if (-not ($_.Attributes -band [System.IO.FileAttributes]::Hidden)) {
                                $_.Attributes = $_.Attributes -bor [System.IO.FileAttributes]::Hidden
                            }
                        } catch { $failCount++ }
                    }
                if ($failCount -gt 0) { Log-Warn "Set-FolderHidden -Recurse: $failCount item(s) refused Hidden under $path" }
            }
        }
    } catch { Log-Warn "Set-FolderHidden failed on $path : $($_.Exception.Message)" }
}

function Get-CategoryForUrl([string]$u) {
    # Top-level bucket for filmmaker-friendly folder layout.
    # Precedence: explicit lists first, then fall back to Misc.
    $u = $u.ToLower()

    # --- Audio (music, podcasts, RSS feeds) --------------------------------
    # Checked BEFORE Comics so soundcloud/bandcamp go to Audio, not Videos.
    # Extension check catches direct .mp3/.flac/etc links regardless of host.
    # RSS/feed detection: URLs ending in feed markers -- podcast-shaped.
    $audioHosts = @(
        'soundcloud.com','bandcamp.com','mixcloud.com','audiomack.com',
        'hearthis.at','ccmixter.org','freemusicarchive.org','jamendo.com',
        'khinsider.com','radio.garden','tunein.com','somafm.com',
        'live365.com','iheart.com/podcast','spotifypodcast','applepodcasts.com',
        'podcasts.apple.com','overcast.fm','pca.st','castbox.fm','podbean.com',
        'anchor.fm','buzzsprout.com','simplecast.com','transistor.fm',
        'libsyn.com','spreaker.com','redcircle.com','omny.fm','megaphone.link',
        'art19.com'
    )
    foreach ($h in $audioHosts) { if ($u -match [regex]::Escape($h)) { return 'Audio' } }
    # archive.org: only route to Audio when the URL hints at audio content
    # (details/audio or explicit audio download). General archive.org URLs
    # (books, video, images) still fall through to Misc/Videos as before.
    if ($u -match 'archive\.org' -and $u -match '(/details/[^/]*audio|/details/opensource_audio|\.mp3(\?|$)|\.flac(\?|$)|\.wav(\?|$))') {
        return 'Audio'
    }
    # Direct-file extension: strip query, then match .mp3/.m4a/.flac/.opus/.ogg/.wav/.aac
    $noQuery = ($u -split '[?#]')[0]
    if ($noQuery -match '\.(mp3|m4a|flac|opus|ogg|wav|aac)$') { return 'Audio' }
    # Podcast-shaped feeds: RSS/XML endpoints where the path looks feed-y.
    # We require BOTH a feed marker AND a podcast/audio hint to avoid catching
    # generic blog RSS as audio.
    $isFeedShape = ($noQuery -match '/(rss|feed|feeds|podcast)(/|$)') -or
                   ($noQuery -match '\.(rss|xml)$')
    $hasPodcastHint = ($u -match 'podcast|episode|audio|show|/rss/|/feed/|feeds\.')
    if ($isFeedShape -and $hasPodcastHint) { return 'Audio' }

    # --- Comics / manga / webtoons -----------------------------------------
    $comicHosts = @(
        'mangadex.org','mangapark','mangahere','mangakakalot','manganato',
        'webtoons.com','tapas.io','toomics','lezhin.com','tappytoon',
        'allporncomic.com','8muses.com','multporn','hentai2read','nhentai.net',
        'e-hentai.org','exhentai.org','hitomi.la','tsumino.com',
        'readcomiconline','readallcomics','getcomics.info','comixextra',
        'mangadex','pixiv.net/artworks','pixiv.net/manga'
    )
    foreach ($h in $comicHosts) { if ($u -match [regex]::Escape($h)) { return 'Comics' } }

    # --- Videos ------------------------------------------------------------
    # Note: soundcloud/bandcamp used to live here, they now route to Audio
    # (matched above). Kept them out of this list too so the intent is clear.
    $videoHosts = @(
        'youtube.com','youtu.be','tiktok.com','vimeo.com','twitch.tv',
        'dailymotion.com','fb.watch','streamable.com','bitchute.com',
        'rumble.com','odysee.com','peertube'
    )
    foreach ($h in $videoHosts) { if ($u -match [regex]::Escape($h)) { return 'Videos' } }

    # --- Image galleries ---------------------------------------------------
    $imageHosts = @(
        'pinterest.','artstation.com','deviantart.com','imgur.com','flickr.com',
        'behance.net','unsplash.com','pexels.com','pixabay.com',
        'danbooru.','gelbooru.','e621.net','safebooru','rule34','pixiv.net'
    )
    foreach ($h in $imageHosts) { if ($u -match [regex]::Escape($h)) { return 'Images' } }

    # --- Social (mixed video + image + text) -------------------------------
    $socialHosts = @(
        'instagram.com','twitter.com','x.com','reddit.com',
        'facebook.com','tumblr.com','threads.net','bsky.app','mastodon',
        'weibo.com','vk.com'
    )
    foreach ($h in $socialHosts) { if ($u -match [regex]::Escape($h)) { return 'Social' } }

    return 'Misc'
}

# ---------- Site routing (which engine handles this URL) ------------------
# Kept identical in spirit to the old tools/imadjinn-grab.ps1 Pick-Tool.

function Pick-Tool([string]$u) {
    $u = $u.ToLower()

    # Instagram: reels/tv are single videos -> yt-dlp; profiles/posts -> gallery-dl
    if ($u -match 'instagram\.com') {
        if ($u -match '/reel/|/tv/') { return 'yt-dlp' } else { return 'gallery-dl' }
    }

    $videoHosts = @(
        'youtube.com','youtu.be','tiktok.com','vimeo.com','twitch.tv',
        'dailymotion.com','facebook.com','fb.watch','streamable.com',
        'soundcloud.com','bandcamp.com'
    )
    foreach ($h in $videoHosts) { if ($u -match [regex]::Escape($h)) { return 'yt-dlp' } }

    $galleryHosts = @(
        'pinterest.','artstation.com','deviantart.com','imgur.com','flickr.com',
        'reddit.com','danbooru.','gelbooru.','e621.net','tumblr.com',
        'behance.net','unsplash.com','pixiv.net','mangadex.org','mangapark',
        'webtoons.com','tapas.io'
    )
    foreach ($h in $galleryHosts) { if ($u -match [regex]::Escape($h)) { return 'gallery-dl' } }

    if ($u -match 'twitter\.com|x\.com') { return 'gallery-dl' }

    return 'yt-dlp'  # unknown -> try video first, fallback handled by caller
}
