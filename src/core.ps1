# src/core.ps1
# The download engine. Takes a URL + options, runs the right tool, returns a
# structured result. No UI, no hardcoded paths, no assumptions about who's
# calling (CLI, queue worker, or interactive test all use it the same way).
# Dot-source: . "$PSScriptRoot\core.ps1"

. "$PSScriptRoot\utils.ps1"

# Result object returned by Invoke-Grab. Fields:
#   Success       [bool]     true if new files landed on disk
#   Tool          [string]   'yt-dlp' | 'gallery-dl' | 'none'
#   UsedCookies   [bool]     whether the successful run used browser cookies
#   FilesAdded    [int]      count of new files on disk
#   Destination   [string]   folder where files landed
#   Error         [string]   free-form message if Success is false
#   DurationMs    [int]      total wall time
#
# Design principle: exit codes lie. Success is proven by real files.

function _WithLongPathPrefix([string]$path) {
    # Audit v0.3.0-pass2 finding 39: Windows APIs cap at MAX_PATH (260 chars).
    # Deep comic-chapter downloads on nested category/series/chapter paths
    # trip this silently. Prefix with \\?\ (extended path syntax) to lift the
    # cap. Only applies to absolute Win32 paths; UNC paths need \\?\UNC\.
    # Skip when path is null/empty/relative/already prefixed.
    if ([string]::IsNullOrEmpty($path)) { return $path }
    if ($path.StartsWith('\\?\')) { return $path }
    if ($path.StartsWith('\\')) { return ('\\?\UNC\' + $path.Substring(2)) }
    if ($path -match '^[A-Za-z]:\\') { return ('\\?\' + $path) }
    return $path
}

function Get-FileCount([string]$path) {
    # -LiteralPath is REQUIRED. PowerShell treats [ ] as wildcards without it,
    # so folder names like "Series [Author]" quietly return 0. That silently
    # broke success detection AND the imadjinn.json file counts.
    if (-not (Test-Path -LiteralPath $path)) { return 0 }
    (Get-ChildItem -LiteralPath $path -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count
}

function Invoke-YtDlp([string]$url, [string]$dest, [bool]$useCookies, [string]$browser) {
    # yt-dlp: output template puts files directly under <dest>\<uploader>\
    # Uses its own archive file (Get-ArchivePath 'yt-dlp').
    #
    # No manual player_client override: nightly yt-dlp (>=2026.08.30) has
    # the `visionos` client + yt-dlp-ejs plugin, which returns 1080p/4K
    # streams without a PO Token. install.ps1 keeps the nightly channel.
    #
    # Test short-circuit (audit N2): when $env:GRAB_TESTS_SKIP_ENGINES is set,
    # skip the actual yt-dlp invocation and return failure. Cuts smoke-test
    # runtime dramatically -- the routing tests only check Destination path
    # calculation, not real network I/O. Real users never set this env var.
    if ($env:GRAB_TESTS_SKIP_ENGINES) { return 1 }
    $archive = Get-ArchivePath 'yt-dlp'
    $tool = Resolve-Tool 'yt-dlp'
    if (-not $tool) { throw 'yt-dlp not found. Run install.ps1.' }
    # Audit v0.3.0-pass2 finding 45: polite YouTube rate limiting. yt-dlp
    # otherwise retries a 429 immediately and can trip the throttle harder.
    # --sleep-requests inserts a small jitter between HTTP requests, and
    # --min-sleep-interval/max keep between-fragment pauses random so we
    # don't hammer with predictable cadence.
    $args = @(
        '-o', (Join-Path $dest '%(uploader,channel,extractor)s\%(title).150B [%(id)s].%(ext)s'),
        '--no-mtime',
        '--embed-metadata',
        '--embed-thumbnail',
        '--concurrent-fragments','4',
        '--retries','5',
        '--sleep-requests','1',
        '--min-sleep-interval','3',
        '--max-sleep-interval','8',
        '--download-archive', $archive
    )

    # --- Video-quality mapping (config.videoQuality) -----------------------
    # 'best'  -> no --format flag; yt-dlp picks the best mux itself.
    # NNNNp   -> cap height at NNNN, fall back to next-best if unavailable.
    # 'audio' -> best audio only, extracted to mp3 for portability.
    # Falls through to 'best' on any unknown value (older configs stay safe).
    $cfg = Get-Config
    $q = if ($cfg.videoQuality) { [string]$cfg.videoQuality } else { 'best' }
    switch ($q) {
        'best'  { }
        '2160p' { $args += @('--format', 'bv*[height<=2160]+ba/b[height<=2160]/best') }
        '1440p' { $args += @('--format', 'bv*[height<=1440]+ba/b[height<=1440]/best') }
        '1080p' { $args += @('--format', 'bv*[height<=1080]+ba/b[height<=1080]/best') }
        '720p'  { $args += @('--format', 'bv*[height<=720]+ba/b[height<=720]/best') }
        '480p'  { $args += @('--format', 'bv*[height<=480]+ba/b[height<=480]/best') }
        'audio' { $args += @('--format', 'bestaudio/best', '-x', '--audio-format', 'mp3') }
        default { }  # unknown -> yt-dlp default
    }

    if ($useCookies -and $browser -and $browser -ne 'none') { $args += @('--cookies-from-browser', $browser) }
    $args += $url
    # Audit v0.3.0-pass2 finding 44: capture yt-dlp output so we can sniff
    # "0 cookies" -- Chrome v127+ encrypts the cookie DB with an OS-bound
    # key that yt-dlp can't read on the fly. Surface a toast so the user
    # knows to switch to Firefox/Edge instead of staring at silent failure.
    $capture = New-Object System.Collections.Generic.List[string]
    & $tool @args 2>&1 | ForEach-Object {
        $line = $_.ToString()
        [void]$capture.Add($line)
        $_
    }
    $rc = $LASTEXITCODE
    if ($useCookies -and $browser -eq 'chrome') {
        $needle = $capture | Where-Object { $_ -match '(?i)(extracted\s+0\s+cookies|failed to decrypt|could not decrypt)' } | Select-Object -First 1
        if ($needle) {
            try { Send-Toast 'Chrome cookies unavailable' 'Chrome v127+ encrypts cookies -- try Firefox/Edge in Settings > Cookies.' } catch {}
            Log-Warn "chrome cookie extraction returned 0 rows: $needle"
        }
    }
    return $rc
}

function Invoke-GalleryDl([string]$url, [string]$dest, [bool]$useCookies, [string]$browser) {
    # gallery-dl: uses its own subfolder template + its own archive file.
    # Companion config at assets/gallery-dl-config.json overrides directory
    # templates for sites where the default causes chapter collisions.
    # See Invoke-YtDlp for the GRAB_TESTS_SKIP_ENGINES rationale.
    if ($env:GRAB_TESTS_SKIP_ENGINES) { return 1 }
    $archive = Get-ArchivePath 'gallery-dl'
    $tool = Resolve-Tool 'gallery-dl'
    if (-not $tool) { throw 'gallery-dl not found. Run install.ps1.' }
    $repoRoot   = Split-Path $PSScriptRoot -Parent
    $configPath = Join-Path $repoRoot 'assets\gallery-dl-config.json'
    $args = @(
        '-d', $dest,
        '--download-archive', $archive
    )
    if (Test-Path -LiteralPath $configPath) {
        $args += @('--config', $configPath)
    }
    if ($useCookies -and $browser -and $browser -ne 'none') { $args += @('--cookies-from-browser', $browser) }
    $args += $url
    & $tool @args 2>&1 | ForEach-Object { $_ }
    return $LASTEXITCODE
}

# Main entry point.
#   Invoke-Grab -Url <url> [-Dest <folder>] [-Tool auto|yt-dlp|gallery-dl] [-NoCookies]
# Returns the result object described above.
function Invoke-Grab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Url,
        [string]$Dest = $null,
        [ValidateSet('auto','yt-dlp','gallery-dl')][string]$Tool = 'auto',
        [switch]$NoCookies,
        # When true (or when URL auto-matches a sensitive pattern in config),
        # inject the "<sensitiveFolderName>" (default ".private") between
        # Category and Domain, and mark that folder Hidden. Callers who
        # already know the download is sensitive can force it with this flag.
        [switch]$Sensitive
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    # Wall-clock start captured NOW, before the download runs. Post-process
    # uses this to identify files created by THIS run (needs to happen up
    # front -- $result.DurationMs is only assigned after all attempts finish).
    $grabStartedAt = Get-Date
    $cfg = Get-Config

    # Decide sensitivity: explicit flag OR URL matches saved patterns OR
    # user opted "sensitive by default" in Settings.
    $isSensitive = [bool]$Sensitive -or (Test-IsSensitiveUrl $Url)

    if (-not $Dest) {
        # Layout:
        #   Normal:    <downloadFolder>\<Category>\<Domain>\...
        #   Sensitive: <downloadFolder>\<Category>\<.private>\<Domain>\...
        # The .private folder gets the Windows Hidden attribute so Explorer
        # doesn't show it unless "Show hidden items" is on.
        $category = Get-CategoryForUrl $Url
        $domain   = Get-FullDomain     $Url
        if ($isSensitive) {
            $privateName = if ($cfg.sensitiveFolderName) { [string]$cfg.sensitiveFolderName } else { '.private' }
            $Dest = Join-Path $cfg.downloadFolder (Join-Path $category (Join-Path $privateName $domain))
        } else {
            $Dest = Join-Path $cfg.downloadFolder (Join-Path $category $domain)
        }
    }
    # -LiteralPath in both Test-Path and New-Item so a downloadFolder with
    # `[` or `]` isn't interpreted as a wildcard pattern.
    if (-not (Test-Path -LiteralPath $Dest)) { New-Item -ItemType Directory -Path $Dest -Force | Out-Null }

    # If sensitive, ensure the .private folder itself is Hidden (may already
    # exist from an earlier grab -- Set-FolderHidden is idempotent).
    if ($isSensitive) {
        $privateName = if ($cfg.sensitiveFolderName) { [string]$cfg.sensitiveFolderName } else { '.private' }
        $privatePath = Join-Path $cfg.downloadFolder (Join-Path (Get-CategoryForUrl $Url) $privateName)
        Set-FolderHidden $privatePath
    }

    # Disk space check: warn if <1GB free on the destination drive. Doesn't
    # block the download (some downloads are <1MB); just makes the reason
    # obvious in the log if a later "disk full" surprise happens.
    try {
        $driveRoot = [System.IO.Path]::GetPathRoot($Dest)
        $drive = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
                 Where-Object { $_.Root -eq $driveRoot } | Select-Object -First 1
        if ($drive -and $drive.Free -lt 1GB) {
            $freeGb = [math]::Round($drive.Free / 1GB, 2)
            Log-Warn "disk-space low on $($drive.Name): ${freeGb} GB free at $Dest"
            if ($drive.Free -lt 100MB) {
                Log-Err  "disk-space CRITICAL on $($drive.Name): ${freeGb} GB -- large downloads will fail"
                Send-Toast 'Low disk space' "$driveRoot has only ${freeGb} GB free"
            }
        }
    } catch { }

    $chosen = if ($Tool -eq 'auto') { Pick-Tool $Url } else { $Tool }
    $result = [ordered]@{
        Success         = $false
        Tool            = 'none'
        UsedCookies     = $false
        FilesAdded      = 0
        Destination     = $Dest
        Error           = $null
        DurationMs      = 0
        AlreadyComplete = $false   # true when archive said everything was already downloaded
    }

    Log-Info "grab start | url=$Url | tool=$chosen | dest=$Dest"

    $useCookies = -not $NoCookies.IsPresent
    $browser    = $cfg.cookieBrowser

    # Attempt sequence:
    #   1. chosen tool + cookies
    #   2. chosen tool without cookies (in case cookies failed)
    #   3. other tool + cookies
    #   4. other tool without cookies
    # NOTE: keep $other assignment OUT of the hash literals below --
    # `(if ... else ...)` inline in a hash literal parses but fails at RUNTIME
    # in PS 5.1 ("The term 'if' is not recognized"). Extract it first.
    $other = if ($chosen -eq 'yt-dlp') { 'gallery-dl' } else { 'yt-dlp' }
    $attempts = @(
        @{ tool = $chosen; cookies = $useCookies }
        @{ tool = $chosen; cookies = $false }
        @{ tool = $other;  cookies = $useCookies }
        @{ tool = $other;  cookies = $false }
    )
    # Deduplicate consecutive identical attempts (e.g. NoCookies flag makes first two equal)
    $seen = @{}
    $attempts = $attempts | Where-Object {
        $k = "$($_.tool)|$($_.cookies)"
        if ($seen.ContainsKey($k)) { $false } else { $seen[$k] = $true; $true }
    }

    $before = Get-FileCount $Dest
    # Track whether the tool exited cleanly on ANY attempt -- gallery-dl and
    # yt-dlp both exit 0 when EVERYTHING listed at the URL is already in
    # the --download-archive (a re-run against an already-complete URL). In
    # that case $after == $before but the URL IS fully downloaded, just
    # nothing NEW landed. Reporting "failed" here (v0.3.0 shipping bug) hid
    # completed downloads: no Recent entry, no toast, no recursive Hidden,
    # user thinks nothing worked. See the Hero Tales test (retroactive fix
    # this session, permanent code fix here).
    $cleanExit = $false
    foreach ($a in $attempts) {
        $rc = 999
        try {
            if ($a.tool -eq 'yt-dlp') {
                $rc = Invoke-YtDlp $Url $Dest $a.cookies $browser
            } else {
                $rc = Invoke-GalleryDl $Url $Dest $a.cookies $browser
            }
        } catch {
            Log-Err "attempt failed with exception: $($_.Exception.Message)"
        }
        $after = Get-FileCount $Dest
        # Case A: new files landed -- unambiguous success.
        if ($after -gt $before) {
            $result.Success     = $true
            $result.Tool        = $a.tool
            $result.UsedCookies = $a.cookies
            $result.FilesAdded  = $after - $before
            break
        }
        # Case B: no new files BUT the tool exited 0 AND files exist at
        # $Dest -- the archive already has everything for this URL, so we
        # succeeded on a previous run. Still counts as success. FilesAdded
        # stays 0 (nothing NEW this attempt), Recent gets an entry, post-
        # process runs, recursive Hidden applies. StatusMsg reflects "no
        # new files" so the user sees the truth.
        if ($rc -eq 0 -and $after -gt 0) {
            $cleanExit = $true
            $result.Success     = $true
            $result.Tool        = $a.tool
            $result.UsedCookies = $a.cookies
            $result.FilesAdded  = 0
            $result.AlreadyComplete = $true   # popup can show a distinct badge
            break
        }
        if ($rc -eq 0) { $cleanExit = $true }
    }

    # --- Post-processing on success ---------------------------------------
    if ($result.Success) {
        try {
            # $grabStartedAt is captured at the top of Invoke-Grab -- accurate
            # regardless of how long attempts take.
            Invoke-PostProcess -Url $Url -Dest $Dest -Tool $result.Tool -FilesAdded $result.FilesAdded -StartedAt $grabStartedAt.AddSeconds(-5)
        } catch {
            Log-Warn "post-process failed (non-fatal): $($_.Exception.Message)"
        }
    }

    # --- Sensitive Hidden: applied to ANY files that landed under $privatePath,
    # regardless of $result.Success. Fixes the case where a partial download
    # (or a re-run where the archive already has files) leaves user's private
    # content visible because success detection failed. Idempotent + safe.
    # Runs OUTSIDE the Success gate.
    if ($isSensitive -and $privatePath -and (Test-Path -LiteralPath $privatePath)) {
        try {
            $filesUnder = @(Get-ChildItem -LiteralPath $privatePath -Recurse -Force -EA SilentlyContinue)
            if ($filesUnder.Count -gt 0) {
                Set-FolderHidden $privatePath -Recurse
                Log-Info "sensitive-hide applied recursively to $($filesUnder.Count) item(s) under $privatePath"
            }
        } catch {
            Log-Warn "sensitive-hide failed (non-fatal): $($_.Exception.Message)"
        }
    }

    $sw.Stop()
    $result.DurationMs = [int]$sw.ElapsedMilliseconds

    if ($result.Success) {
        if ($result.AlreadyComplete) {
            Log-Info "grab done  | already-complete (archive), no new files | tool=$($result.Tool) | ms=$($result.DurationMs)"
        } else {
            Log-Info "grab done  | added=$($result.FilesAdded) | tool=$($result.Tool) | ms=$($result.DurationMs)"
        }
    } else {
        # Distinguish "tool failed to run" from "URL truly has no downloadable
        # content" -- gallery-dl exit 0 with 0 files means URL was empty/404;
        # non-zero means real failure.
        if ($cleanExit) {
            $result.Error = 'Site returned no downloadable content (empty/404/private).'
        } else {
            $result.Error = 'All engines and cookie combinations failed to produce new files.'
        }
        Log-Err  "grab fail  | url=$Url | ms=$($result.DurationMs) | $($result.Error)"
    }
    return [PSCustomObject]$result
}

function Invoke-PostProcess {
    # SAFE post-process: does NOT move, rename, or delete any files or
    # folders. It only WRITES manifest JSON files where downloads actually
    # landed. Moving/merging turned out to be far too destructive (hidden
    # attributes propagating, half-lost merges, co-tenancy overlaps).
    #
    # Layout with this simpler design:
    #   <downloadFolder>\<Category>\<Domain>\<gallery-dl-tree>\<files>
    #
    # That means there's a slightly redundant extra folder for gallery-dl
    # (e.g. Comics\allporncomic.com\allporncomic\<series>\<chapter>\...).
    # We accept that for now -- removing it needs gallery-dl config overrides
    # per extractor, which is fragile. The trade-off is data safety.
    #
    # Post-process finds all "leaf" folders under $Dest that hold real files
    # AND that were touched by THIS download (contain files newer than the
    # download start). It writes one imadjinn.json per chapter and, when the
    # download spans multiple chapters that share a common parent, one
    # summary manifest at that parent.
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Dest,
        [Parameter(Mandatory)][string]$Tool,
        [int]$FilesAdded = 0,
        [datetime]$StartedAt = ([datetime]::MinValue)
    )

    if (-not (Test-Path -LiteralPath $Dest)) { return }

    # Find leaf folders whose files were created by this run. Use
    # CreationTime (Windows filesystem stamp when the file was created
    # locally) NOT LastWriteTime -- gallery-dl preserves the server's
    # Last-Modified time by default, so files come out with mtimes years
    # old, which would fail any "touched after StartedAt" check.
    $allLeaves = Get-LeafFoldersWithFiles $Dest
    $touchedLeaves = @()
    foreach ($leaf in $allLeaves) {
        $touched = @(Get-ChildItem -LiteralPath $leaf -File -ErrorAction SilentlyContinue |
                     Where-Object { $_.Extension -ne '.json' -and $_.CreationTime -ge $StartedAt })
        if ($touched.Count -gt 0) { $touchedLeaves += $leaf }
    }
    if ($touchedLeaves.Count -eq 0) {
        Log-Info "post-process: no leaf folders touched by this run under $Dest"
        return
    }

    # Group chapters by their PARENT (typically the series root). Write:
    #   - one manifest per chapter (in every touched leaf)
    #   - one series-summary manifest at each unique parent that has 2+ touched chapters
    $byParent = @{}
    foreach ($leaf in $touchedLeaves) {
        $parent = Split-Path $leaf -Parent
        if (-not $byParent.ContainsKey($parent)) { $byParent[$parent] = @() }
        $byParent[$parent] += $leaf
    }

    foreach ($parent in $byParent.Keys) {
        Write-SeriesManifestsForLeaves -Url $Url -Tool $Tool -SeriesRoot $parent -ChapterLeaves $byParent[$parent]
    }

    # Clean up per-image .info.json sidecars from yt-dlp.
    # Audit P2-54: filter by CreationTime >= StartedAt so we only delete
    # sidecars THIS run produced. Pre-v0.3.0 the sweep deleted every
    # .info.json under $Dest (including those from a prior tool or a
    # co-tenant series), which broke resume/inspect workflows for users
    # who kept .info.json intentionally.
    if ($Tool -eq 'yt-dlp') {
        Get-ChildItem -LiteralPath $Dest -Recurse -Filter '*.info.json' -ErrorAction SilentlyContinue |
            Where-Object { $_.CreationTime -ge $StartedAt } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

function Write-SeriesManifestsForLeaves {
    # Writes per-chapter imadjinn.json in each of $ChapterLeaves and, if
    # there are 2+ of them, one summary manifest in $SeriesRoot. Only
    # touches the folders passed in -- won't index co-tenant series.
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Tool,
        [Parameter(Mandatory)][string]$SeriesRoot,
        [Parameter(Mandatory)][array]$ChapterLeaves
    )

    $chapterSummaries = @()
    foreach ($leaf in $ChapterLeaves) {
        $files = @(Get-ChildItem -LiteralPath $leaf -File -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -ne 'imadjinn.json' -and $_.Extension -ne '.json' })
        $manifest = [ordered]@{
            source_url    = $Url
            category      = Get-CategoryForUrl $Url
            domain        = Get-FullDomain     $Url
            chapter       = Split-Path $leaf -Leaf
            downloaded_at = (Get-Date).ToString('o')
            tool_used     = $Tool
            file_count    = $files.Count
            total_bytes   = ($files | Measure-Object -Property Length -Sum).Sum
            files         = @($files | ForEach-Object {
                [ordered]@{ name = $_.Name; size = $_.Length }
            })
        }
        [System.IO.File]::WriteAllText(
            (Join-Path $leaf 'imadjinn.json'),
            ($manifest | ConvertTo-Json -Depth 6),
            [System.Text.Encoding]::UTF8)
        $chapterSummaries += [ordered]@{
            chapter    = $manifest.chapter
            file_count = $manifest.file_count
            total_bytes= $manifest.total_bytes
        }
    }
    Log-Info "post-process: $($ChapterLeaves.Count) chapter manifest(s) in $(Split-Path $SeriesRoot -Leaf)"

    if ($chapterSummaries.Count -gt 1) {
        $totalFiles = 0; $totalBytes = 0
        foreach ($c in $chapterSummaries) {
            $totalFiles += [int]$c.file_count
            $totalBytes += [long]$c.total_bytes
        }
        $seriesManifest = [ordered]@{
            source_url    = $Url
            category      = Get-CategoryForUrl $Url
            domain        = Get-FullDomain     $Url
            downloaded_at = (Get-Date).ToString('o')
            tool_used     = $Tool
            chapter_count = $chapterSummaries.Count
            file_count    = $totalFiles
            total_bytes   = $totalBytes
            chapters      = @($chapterSummaries)
        }
        [System.IO.File]::WriteAllText(
            (Join-Path $SeriesRoot 'imadjinn.json'),
            ($seriesManifest | ConvertTo-Json -Depth 6),
            [System.Text.Encoding]::UTF8)
        Log-Info "post-process: series summary at $(Split-Path $SeriesRoot -Leaf)"
    }
}

function Get-LeafFoldersWithFiles([string]$root) {
    # Returns an array of folder paths that contain at least one non-json
    # file. Uses -LiteralPath throughout so [ ] in folder names doesn't
    # silently break the traversal. Handles: (a) single-chapter downloads
    # (returns [$root] if $root has files directly), (b) multi-chapter
    # (returns each chapter subfolder), (c) deeper nesting.
    if (-not (Test-Path -LiteralPath $root)) { return @() }
    $results = @()
    # Recurse all directories; for each, check if it holds non-json files.
    $allDirs = @($root) + @(Get-ChildItem -LiteralPath $root -Recurse -Directory -ErrorAction SilentlyContinue |
                            ForEach-Object { $_.FullName })
    foreach ($d in $allDirs) {
        $hasFiles = @(Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue |
                      Where-Object { $_.Extension -ne '.json' -and $_.Name -ne 'imadjinn.json' }).Count -gt 0
        if ($hasFiles) { $results += $d }
    }
    return $results
}

# CLI shim so `grab-app\src\core.ps1 <URL>` also works standalone for testing.
if ($MyInvocation.InvocationName -notmatch 'utils\.ps1' -and $args.Count -gt 0) {
    $u = $args[0]
    if (Test-IsUrl $u) {
        $r = Invoke-Grab -Url $u
        $r | Format-List
    }
}
