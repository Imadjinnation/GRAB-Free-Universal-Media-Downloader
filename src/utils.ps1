# src/utils.ps1
# Shared helpers used by every other src/ file. No hardcoded paths.
# Dot-source: . "$PSScriptRoot\utils.ps1"

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

# ---------- Config load / save --------------------------------------------

function Get-Config {
    Ensure-AppData
    if (-not (Test-Path $script:ConfigPath)) {
        $default = @{
            version              = '0.1.0'
            downloadFolder       = Join-Path $env:USERPROFILE 'Downloads\imadjinn-grab'
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
        $default | ConvertTo-Json -Depth 4 | Set-Content -Path $script:ConfigPath -Encoding UTF8
        return $default
    }
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
        return Get-Config
    }
    if ($null -eq $cfg) {
        # Empty file / whitespace-only: same recovery path.
        Log-Warn 'config.json parsed as $null; rewriting defaults.'
        Remove-Item -LiteralPath $script:ConfigPath -Force -ErrorAction SilentlyContinue
        return Get-Config
    }
    # Back-fill new keys added post-first-config, so older configs still work
    if (-not $cfg.PSObject.Properties.Name.Contains('sensitiveSites')) {
        $cfg | Add-Member -MemberType NoteProperty -Name sensitiveSites -Value @() -Force
    }
    if (-not $cfg.PSObject.Properties.Name.Contains('sensitiveByDefault')) {
        $cfg | Add-Member -MemberType NoteProperty -Name sensitiveByDefault -Value $false -Force
    }
    if (-not $cfg.PSObject.Properties.Name.Contains('sensitiveFolderName')) {
        $cfg | Add-Member -MemberType NoteProperty -Name sensitiveFolderName -Value '.private' -Force
    }
    if (-not $cfg.PSObject.Properties.Name.Contains('videoQuality')) {
        $cfg | Add-Member -MemberType NoteProperty -Name videoQuality -Value 'best' -Force
    }
    if (-not $cfg.PSObject.Properties.Name.Contains('crtScanlines')) {
        # Back-fill: default TRUE so existing configs keep the arcade cabinet
        # look after upgrading. Users can uncheck it in Settings > Display.
        $cfg | Add-Member -MemberType NoteProperty -Name crtScanlines -Value $true -Force
    }
    return $cfg
}

function Set-Config([object]$config) {
    Ensure-AppData
    $config | ConvertTo-Json -Depth 4 | Set-Content -Path $script:ConfigPath -Encoding UTF8
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
        $raw = Get-Content -LiteralPath $SourceThemePath -Raw -Encoding UTF8
        $sub = $raw.Replace('__GRAB_FONTS__', $FontsUri)
        $out = Join-Path $script:AppData '.runtime-theme.xaml'
        # Write only when different -- avoids touching mtime every launch.
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

function Resolve-Tool([string]$name) {
    # Prefer the PIP-installed exe over anything else on PATH. WinGet packages
    # (like yt-dlp.yt-dlp) install their own copy and can win a PATH tie-break,
    # but they update on their own schedule -- we can't manage them. The pip
    # copy is the one our install.ps1 keeps on nightly.
    if ($script:ToolCache.ContainsKey($name)) { return $script:ToolCache[$name] }
    # 1. Python scripts folder (managed by install.ps1)
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
    # 2. Fallback to whatever is on PATH
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { $script:ToolCache[$name] = $cmd.Source; return $cmd.Source }
    return $null
}

# ---------- Logging -------------------------------------------------------

function Write-Log([string]$level, [string]$msg) {
    Ensure-AppData
    $file = Join-Path $script:LogFolder ("grab-{0}.log" -f (Get-Date -Format 'yyyy-MM-dd'))
    $stamp = Get-Date -Format 'HH:mm:ss'
    # Redact tokens / auth params from URLs before they hit the log (audit low-19).
    $sanitized = $msg -replace '([?&](?:token|auth|password|api_key|apikey|sig|signature)=)[^&\s]+','${1}REDACTED'
    $line = "$stamp [$level] $sanitized"
    Add-Content -Path $file -Value $line -Encoding UTF8
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

# ---------- URL utilities -------------------------------------------------

function Test-IsUrl([string]$s) {
    return $s -match '^https?://\S+$'
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
