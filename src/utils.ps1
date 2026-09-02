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
            toastsEnabled        = $true
            popupPositionX       = $null
            popupPositionY       = $null
            firstRunComplete     = $false
            # Safety / privacy
            sensitiveByDefault   = $false                 # every download routes to .private
            sensitiveSites       = @()                    # URL substrings that auto-route to .private
            sensitiveFolderName  = '.private'             # folder name inside category
        }
        $default | ConvertTo-Json -Depth 4 | Set-Content -Path $script:ConfigPath -Encoding UTF8
        return $default
    }
    $cfg = Get-Content $script:ConfigPath -Raw | ConvertFrom-Json
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
        New-BurntToastNotification @params
    } catch {
        Write-Host "[toast] $title -- $body" -ForegroundColor Cyan
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

function Set-FolderHidden([string]$path) {
    # Idempotently sets Hidden attribute on a folder. Wrapped in try/catch
    # because attribute writes can fail on protected paths -- and that
    # should never block a download.
    try {
        if (Test-Path -LiteralPath $path) {
            $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if (-not ($item.Attributes -band [System.IO.FileAttributes]::Hidden)) {
                $item.Attributes = $item.Attributes -bor [System.IO.FileAttributes]::Hidden
            }
        }
    } catch { Log-Warn "Set-FolderHidden failed on $path : $($_.Exception.Message)" }
}

function Get-CategoryForUrl([string]$u) {
    # Top-level bucket for filmmaker-friendly folder layout.
    # Precedence: explicit lists first, then fall back to Misc.
    $u = $u.ToLower()

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
    $videoHosts = @(
        'youtube.com','youtu.be','tiktok.com','vimeo.com','twitch.tv',
        'dailymotion.com','fb.watch','streamable.com','bitchute.com',
        'rumble.com','odysee.com','peertube','soundcloud.com','bandcamp.com'
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
