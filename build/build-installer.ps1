# build/build-installer.ps1
# Phase 5.5 -- distribution build script for GRAB.
#
# Produces three artifacts under D:\IMADJINnation\grab\dist\:
#   1. GRAB-Setup.exe          -- Inno Setup wizard (per-user, no UAC)
#   2. GRAB-Portable-v<ver>.zip -- extract-and-run zip
#   3. SHA256SUMS.txt          -- checksums for both
#
# Bundling strategy (Option C+):
#   - yt-dlp.exe (nightly)  -- latest prerelease from yt-dlp/yt-dlp
#   - gallery-dl.exe        -- latest stable from mikf/gallery-dl
#   - ffmpeg-shared essentials -- ffmpeg.exe + required DLLs only
#                                  (drops ffplay/ffprobe/docs/includes)
#
# All downloads verified by SHA256 where the upstream ships checksums.
#
# NO SIGNING. Users see a one-time SmartScreen dialog; README + docs/smartscreen.md
# explain how to safely accept it.
#
# Usage:
#   .\build-installer.ps1              # full build
#   .\build-installer.ps1 -WhatIf      # dry-run: report artifacts, download nothing
#   .\build-installer.ps1 -SkipDownload # reuse dist/payload/bin/ (fast iteration)
#   .\build-installer.ps1 -NoZip       # only build the .exe installer
#   .\build-installer.ps1 -NoInstaller # only build the portable zip
#
# Exit codes: 0 = success, 1 = any step failed.
#
# NOTE: Phase 5.5 SHIPS this script; it does NOT run it. Phase 6 is when
# we actually cut the v0.3.0 release and invoke this build. Rationale:
#   - ~150MB of network bandwidth per run
#   - We don't want partial dist/ folders committed
#   - Bundled dep versions get locked in at Phase 6 (recorded in
#     dist\payload\dep-versions.json)

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$SkipDownload,
    [switch]$NoZip,
    [switch]$NoInstaller,
    [string]$OutDir     # override dist/ output location (tests use temp dir)
)

$ErrorActionPreference = 'Stop'

# --- Paths ----------------------------------------------------------------
$script:BuildRoot = $PSScriptRoot
$script:RepoRoot  = Split-Path $script:BuildRoot -Parent
$script:DistRoot  = if ($OutDir) { $OutDir } else { Join-Path $script:RepoRoot 'dist' }
$script:Payload   = Join-Path $script:DistRoot 'payload'
$script:Bin       = Join-Path $script:Payload 'bin'
$script:Tmp       = Join-Path $script:DistRoot '.tmp'

# --- Console helpers ------------------------------------------------------
function Say([string]$msg, [string]$color = 'Gray')    { Write-Host "  $msg" -ForegroundColor $color }
function Section([string]$title)                       { Write-Host ''; Write-Host "  == $title ==" -ForegroundColor Cyan }
function Ok([string]$msg)                              { Say "OK    $msg" 'Green' }
function Warn([string]$msg)                            { Say "WARN  $msg" 'Yellow' }
function Fail([string]$msg)                            { Say "FAIL  $msg" 'Red' }

# --- Version discovery ----------------------------------------------------
# Read the canonical version from src/utils.ps1 so we NEVER drift.
function Get-GrabRepoVersion {
    $u = Join-Path $script:RepoRoot 'src\utils.ps1'
    $t = Get-Content -LiteralPath $u -Raw -Encoding UTF8
    if ($t -match '(?m)^\s*\$script:GrabVersion\s*=\s*''([^'']+)''') {
        return $Matches[1]
    }
    throw "Could not parse GrabVersion from $u"
}

# --- SHA256 helper --------------------------------------------------------
function Get-FileSha256([string]$path) {
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLower()
}

# --- Download helper (dry-run aware) --------------------------------------
function Save-Url {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Dest,
        [string]$ExpectedSha256 = ''
    )
    if ($WhatIfPreference) {
        Say "WHATIF: would GET $Url -> $Dest"
        return
    }
    Say "GET $Url"
    Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -TimeoutSec 300
    if ($ExpectedSha256) {
        $got = Get-FileSha256 $Dest
        if ($got -ne $ExpectedSha256.ToLower()) {
            throw "SHA256 mismatch for $Dest`n  expected: $ExpectedSha256`n  actual:   $got"
        }
        Ok "sha256 verified for $(Split-Path $Dest -Leaf)"
    }
}

# --- Prepare dist/ --------------------------------------------------------
function Reset-DistDir {
    Section 'Prepare dist/'
    foreach ($p in @($script:DistRoot, $script:Payload, $script:Bin, $script:Tmp)) {
        if ($WhatIfPreference) { Say "WHATIF: would ensure dir $p"; continue }
        if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    }
    Ok "dist root: $script:DistRoot"
}

# --- 1. yt-dlp nightly ----------------------------------------------------
function Get-YtDlpNightly {
    Section 'yt-dlp (nightly)'
    if ($SkipDownload -and (Test-Path (Join-Path $script:Bin 'yt-dlp.exe'))) {
        Ok 'yt-dlp.exe already present (SkipDownload)'
        return (& (Join-Path $script:Bin 'yt-dlp.exe') --version 2>$null | Select-Object -First 1)
    }
    if ($WhatIfPreference) { Say 'WHATIF: would download yt-dlp nightly'; return 'WHATIF' }

    $api  = 'https://api.github.com/repos/yt-dlp/yt-dlp-nightly-builds/releases/latest'
    $ua   = @{ 'User-Agent' = 'grab-build/0.3.0' }
    $rel  = Invoke-RestMethod -Uri $api -Headers $ua -TimeoutSec 30
    $tag  = [string]$rel.tag_name
    $exe  = $rel.assets | Where-Object { $_.name -ieq 'yt-dlp.exe' } | Select-Object -First 1
    $sums = $rel.assets | Where-Object { $_.name -imatch 'SHA2-?256SUMS' } | Select-Object -First 1
    if (-not $exe) { throw 'no yt-dlp.exe asset in latest nightly release' }
    $dest = Join-Path $script:Bin 'yt-dlp.exe'
    Save-Url -Url $exe.browser_download_url -Dest $dest
    if ($sums) {
        $sumTxt = Invoke-WebRequest -Uri $sums.browser_download_url -UseBasicParsing -TimeoutSec 60
        $expected = ($sumTxt.Content -split "`n" |
                     Where-Object { $_ -match '\syt-dlp\.exe' } |
                     Select-Object -First 1) -split '\s+' | Select-Object -First 1
        if ($expected) {
            $got = Get-FileSha256 $dest
            if ($got -ne $expected.ToLower()) {
                throw "yt-dlp.exe sha256 mismatch: expected $expected, got $got"
            }
            Ok "yt-dlp.exe sha256 verified"
        }
    }
    Ok "yt-dlp nightly $tag installed at $dest"
    return $tag
}

# --- 2. gallery-dl --------------------------------------------------------
function Get-GalleryDl {
    Section 'gallery-dl'
    if ($SkipDownload -and (Test-Path (Join-Path $script:Bin 'gallery-dl.exe'))) {
        Ok 'gallery-dl.exe already present (SkipDownload)'
        return (& (Join-Path $script:Bin 'gallery-dl.exe') --version 2>$null | Select-Object -First 1)
    }
    if ($WhatIfPreference) { Say 'WHATIF: would download gallery-dl latest'; return 'WHATIF' }

    # NOTE: gallery-dl stopped attaching pre-built Windows binaries to
    # releases starting v1.32.0 (source-only distribution via PyPI/PEP517).
    # We walk back through recent releases until we find one that still
    # bundles gallery-dl.exe (v1.31.10 is the last one as of 2026-09).
    # When upstream resumes shipping binaries, this picks the newest
    # automatically. If none of the recent releases have it, we fail.
    $ua      = @{ 'User-Agent' = 'grab-build/0.3.0' }
    $rels    = Invoke-RestMethod -Uri 'https://api.github.com/repos/mikf/gallery-dl/releases?per_page=50' -Headers $ua -TimeoutSec 30
    $picked  = $null
    foreach ($r in $rels) {
        if ($r.draft) { continue }
        $a = $r.assets | Where-Object { $_.name -ieq 'gallery-dl.exe' } | Select-Object -First 1
        if ($a) { $picked = [pscustomobject]@{ Tag = [string]$r.tag_name; Asset = $a }; break }
    }
    if (-not $picked) { throw 'no gallery-dl.exe asset in any of the last 50 releases (upstream may have permanently stopped shipping binaries)' }
    $tag  = $picked.Tag
    $dest = Join-Path $script:Bin 'gallery-dl.exe'
    Save-Url -Url $picked.Asset.browser_download_url -Dest $dest
    Ok "gallery-dl $tag installed at $dest"
    return $tag
}

# --- 3. ffmpeg-shared essentials ------------------------------------------
# We take the gyan.dev "release-shared" build (smaller than -full, matches
# what winget install Gyan.FFmpeg pulls). Extract only:
#   ffmpeg.exe
#   bin/avcodec-*.dll   avformat-*.dll   avutil-*.dll
#   bin/swscale-*.dll   swresample-*.dll
# Discard ffplay.exe, ffprobe.exe, docs/, include/, lib/, ffmpeg-*-shared/*.
function Get-Ffmpeg {
    Section 'ffmpeg (shared essentials)'
    if ($SkipDownload -and (Test-Path (Join-Path $script:Bin 'ffmpeg.exe'))) {
        Ok 'ffmpeg.exe already present (SkipDownload)'
        return (& (Join-Path $script:Bin 'ffmpeg.exe') -version 2>$null | Select-Object -First 1)
    }
    if ($WhatIfPreference) { Say 'WHATIF: would download ffmpeg-release-shared 7z'; return 'WHATIF' }

    # Ensure 7-Zip present (winget install if missing).
    $sevenZip = Get-Command 7z -ErrorAction SilentlyContinue
    if (-not $sevenZip) {
        Say '7-Zip not on PATH; attempting winget install 7zip.7zip ...'
        $winget = Get-Command winget -ErrorAction SilentlyContinue
        if ($winget) {
            winget install --exact --id 7zip.7zip --accept-source-agreements --accept-package-agreements --silent | Out-Null
            $sevenZip = Get-Command 7z -ErrorAction SilentlyContinue
            if (-not $sevenZip) {
                # Try the well-known install path.
                $probe = "$env:ProgramFiles\7-Zip\7z.exe"
                if (Test-Path -LiteralPath $probe) { $sevenZip = [pscustomobject]@{ Source = $probe } }
            }
        }
        if (-not $sevenZip) { throw '7-Zip not found and could not be installed via winget' }
    }
    $sevenZipExe = $sevenZip.Source

    # NOTE: gyan.dev renamed the release-shared build to release-full-shared
    # (they consolidated the "release-shared" and "release-full-shared"
    # variants under one file). We still discard everything except
    # ffmpeg.exe + the shared DLLs listed in $keep below, so the extra bloat
    # doesn't reach the payload.
    $url = 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-full-shared.7z'
    $arc = Join-Path $script:Tmp 'ffmpeg-release-shared.7z'
    Save-Url -Url $url -Dest $arc
    $extractDir = Join-Path $script:Tmp 'ffmpeg-extract'
    if (Test-Path -LiteralPath $extractDir) { Remove-Item -LiteralPath $extractDir -Recurse -Force }
    New-Item -ItemType Directory -Path $extractDir -Force | Out-Null

    # 7z x -o<dir> <archive>  (space between -o and dir is intentional NOT allowed)
    & $sevenZipExe x "-o$extractDir" $arc -y | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "7z extraction failed (exit $LASTEXITCODE)" }

    # Locate ffmpeg.exe under extractDir\ffmpeg-*-shared\bin\ffmpeg.exe
    $ffbin = Get-ChildItem -LiteralPath $extractDir -Directory | Select-Object -First 1
    if (-not $ffbin) { throw 'ffmpeg 7z extracted no top-level folder' }
    $binSrc = Join-Path $ffbin.FullName 'bin'
    if (-not (Test-Path -LiteralPath $binSrc)) { throw "ffmpeg bin dir missing under $binSrc" }

    # Copy ffmpeg.exe + required DLLs; discard ffplay/ffprobe and everything else.
    $keep = @(
        'ffmpeg.exe',
        'avcodec-*.dll',
        'avformat-*.dll',
        'avutil-*.dll',
        'swscale-*.dll',
        'swresample-*.dll',
        'avdevice-*.dll',    # ffmpeg.exe links against it -> required at runtime
        'avfilter-*.dll',    # same
        'postproc-*.dll'     # same
    )
    foreach ($pat in $keep) {
        Get-ChildItem -LiteralPath $binSrc -Filter $pat -File -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $script:Bin $_.Name) -Force
        }
    }
    # Extract version from folder name, e.g. ffmpeg-7.1-full_build-shared
    $ver = $ffbin.Name -replace '^ffmpeg-','' -replace '-.*',''
    Ok "ffmpeg $ver installed at $script:Bin (kept ffmpeg.exe + $(($keep.Count - 1)) DLL patterns)"

    # Cleanup the 7z scratch (leave the .7z itself for Phase 6 debugging).
    try { Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    return $ver
}

# --- 4. Copy GRAB payload -------------------------------------------------
function Copy-GrabPayload {
    Section 'Copy GRAB payload'
    if ($WhatIfPreference) { Say 'WHATIF: would copy grab-app.*, src/, ui/, assets/, docs/, README, CHANGELOG, LICENSE'; return }

    # Top-level entry points
    foreach ($f in @('grab-app.ps1','grab-app.vbs','README.md','CHANGELOG.md','LICENSE','uninstall.ps1')) {
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot $f) -Destination (Join-Path $script:Payload $f) -Force
    }
    # Recursive dirs. Robocopy would be faster but Copy-Item -Recurse is
    # dependency-free and correct on read-only source trees.
    foreach ($d in @('src','ui','assets','docs')) {
        $src = Join-Path $script:RepoRoot $d
        $dst = Join-Path $script:Payload $d
        if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
        Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
    }
    Ok 'grab payload copied to dist/payload/'
}

# --- 5. Ship version manifest ---------------------------------------------
function Write-DepVersions {
    param(
        [string]$GrabVer,
        [string]$YtDlpVer,
        [string]$GalleryDlVer,
        [string]$FfmpegVer
    )
    Section 'Write dep-versions.json'
    $data = [ordered]@{
        grab         = $GrabVer
        'yt-dlp'     = $YtDlpVer
        'gallery-dl' = $GalleryDlVer
        ffmpeg       = $FfmpegVer
        builtUtc     = ([datetime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture))
    }
    $dest = Join-Path $script:Payload 'dep-versions.json'
    if ($WhatIfPreference) { Say "WHATIF: would write $dest"; return }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($dest, ($data | ConvertTo-Json -Depth 4), $utf8NoBom)
    Ok "wrote $dest"
}

# --- 6. Generate Inno Setup script ----------------------------------------
function Write-InnoSetupScript {
    param([string]$GrabVer)
    Section 'Generate Inno Setup script'
    $iss = Join-Path $script:DistRoot 'GRAB-Setup.iss'
    $template = Join-Path $script:BuildRoot 'GRAB-Setup.iss.template'
    if (-not (Test-Path -LiteralPath $template)) { throw "template missing: $template" }
    if ($WhatIfPreference) { Say "WHATIF: would emit $iss"; return $iss }

    $raw = Get-Content -LiteralPath $template -Raw -Encoding UTF8
    $out = $raw.
        Replace('__GRAB_VERSION__',   $GrabVer).
        Replace('__PAYLOAD_DIR__',    $script:Payload).
        Replace('__OUTPUT_DIR__',     $script:DistRoot).
        Replace('__ICON_PATH__',      (Join-Path $script:Payload 'assets\icon.ico'))
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($iss, $out, $utf8NoBom)
    Ok "wrote $iss"
    return $iss
}

# --- 7. Compile installer via iscc.exe ------------------------------------
function Invoke-InnoSetup {
    param([string]$IssPath)
    Section 'Compile installer (iscc.exe)'
    $iscc = Get-Command iscc -ErrorAction SilentlyContinue
    # Well-known install paths: machine-wide 32-bit, 64-bit, and per-user
    # (winget with --scope user, or the direct Inno Setup installer's default).
    $probes = @(
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
        "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
    )
    if (-not $iscc) {
        foreach ($p in $probes) {
            if (Test-Path -LiteralPath $p) { $iscc = [pscustomobject]@{ Source = $p }; break }
        }
    }
    if (-not $iscc) {
        Say 'iscc.exe not on PATH; attempting winget install JRSoftware.InnoSetup ...'
        if ($WhatIfPreference) { Say 'WHATIF: would winget install Inno Setup'; return }
        $winget = Get-Command winget -ErrorAction SilentlyContinue
        if (-not $winget) { throw 'winget not available; install Inno Setup manually from https://jrsoftware.org/isdl.php' }
        # --scope user avoids a UAC prompt (which would hang a background build).
        winget install --exact --id JRSoftware.InnoSetup --scope user --accept-source-agreements --accept-package-agreements --silent | Out-Null
        foreach ($p in $probes) {
            if (Test-Path -LiteralPath $p) { $iscc = [pscustomobject]@{ Source = $p }; break }
        }
        if (-not $iscc) { throw 'Inno Setup install failed; run again after installing manually' }
    }
    if ($WhatIfPreference) { Say "WHATIF: would run $($iscc.Source) $IssPath"; return }
    & $iscc.Source $IssPath | ForEach-Object { Say $_ }
    if ($LASTEXITCODE -ne 0) { throw "iscc exit $LASTEXITCODE" }
    $out = Join-Path $script:DistRoot 'GRAB-Setup.exe'
    if (-not (Test-Path -LiteralPath $out)) { throw "installer not produced at $out" }
    $size = (Get-Item -LiteralPath $out).Length
    if ($size -lt 30MB) { Warn "installer suspiciously small ($([math]::Round($size/1MB,1))MB); expected >30MB" }
    if ($size -gt 100MB) { Warn "installer suspiciously large ($([math]::Round($size/1MB,1))MB); expected <100MB" }
    Ok "installer built: $out ($([math]::Round($size/1MB,1))MB)"
}

# --- 8. Portable zip ------------------------------------------------------
function Build-PortableZip {
    param([string]$GrabVer)
    Section 'Build portable zip'
    $zip = Join-Path $script:DistRoot ("GRAB-Portable-v{0}.zip" -f $GrabVer)
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    if ($WhatIfPreference) { Say "WHATIF: would zip $script:Payload -> $zip"; return }

    # Drop PORTABLE.txt so double-clickers know what's what.
    $portableTxt = @"
GRAB -- Portable Edition v$GrabVer

No installation needed. No admin. Just double-click grab-app.vbs to launch.

Bundled binaries (bin\):
  - yt-dlp.exe      video downloader
  - gallery-dl.exe  image/gallery downloader
  - ffmpeg.exe      audio/video processor (shared essentials build)

Config lives in %APPDATA%\grab-app\ by default. To keep everything in
THIS folder (USB-stick style), create an empty file next to grab-app.vbs
called  portable-mode.flag  -- GRAB will store config, queue, and logs
alongside the binaries instead of roaming.

Uninstall: delete this folder + %APPDATA%\grab-app\ (or run uninstall.ps1 -Yes -NoPackages).

Docs: docs\  README.md  CHANGELOG.md
License: LICENSE (MIT)
Source: https://github.com/imadjinnation/GRAB-Free-Universal-Media-Downloader
"@
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Join-Path $script:Payload 'PORTABLE.txt'), $portableTxt, $utf8NoBom)

    # Compress-Archive is Windows-native, dependency-free.
    Compress-Archive -Path (Join-Path $script:Payload '*') -DestinationPath $zip -CompressionLevel Optimal
    $size = (Get-Item -LiteralPath $zip).Length
    Ok "portable zip: $zip ($([math]::Round($size/1MB,1))MB)"
}

# --- 9. SHA256SUMS.txt ----------------------------------------------------
function Write-ShaSums {
    param([string]$GrabVer)
    Section 'Write SHA256SUMS.txt'
    if ($WhatIfPreference) { Say 'WHATIF: would emit dist/SHA256SUMS.txt'; return }
    $sums = @()
    foreach ($f in @('GRAB-Setup.exe', ("GRAB-Portable-v{0}.zip" -f $GrabVer))) {
        $p = Join-Path $script:DistRoot $f
        if (Test-Path -LiteralPath $p) {
            $h = Get-FileSha256 $p
            $sums += ("{0}  {1}" -f $h, $f)
        }
    }
    $dest = Join-Path $script:DistRoot 'SHA256SUMS.txt'
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($dest, (($sums -join "`n") + "`n"), $utf8NoBom)
    Ok "wrote $dest"
}

# --- Main -----------------------------------------------------------------
function Invoke-Build {
    $grabVer = Get-GrabRepoVersion
    Say ""
    Say "  GRAB build v$grabVer" 'White'
    Say ("  " + ('-' * 30)) 'DarkGray'
    if ($WhatIfPreference) { Say 'DRY-RUN mode: no downloads, no writes.' 'Yellow' }

    Reset-DistDir
    $ytVer = Get-YtDlpNightly
    $gdVer = Get-GalleryDl
    $ffVer = Get-Ffmpeg
    Copy-GrabPayload
    Write-DepVersions -GrabVer $grabVer -YtDlpVer $ytVer -GalleryDlVer $gdVer -FfmpegVer $ffVer

    if (-not $NoInstaller) {
        $iss = Write-InnoSetupScript -GrabVer $grabVer
        Invoke-InnoSetup -IssPath $iss
    } else {
        Say 'installer step skipped (-NoInstaller)'
    }
    if (-not $NoZip) {
        Build-PortableZip -GrabVer $grabVer
    } else {
        Say 'portable zip step skipped (-NoZip)'
    }
    Write-ShaSums -GrabVer $grabVer

    Section 'Done'
    if ($WhatIfPreference) {
        Say 'dry-run: expected artifacts on a real build:'
        Say "  $script:DistRoot\GRAB-Setup.exe"
        Say ("  $script:DistRoot\GRAB-Portable-v{0}.zip" -f $grabVer)
        Say "  $script:DistRoot\SHA256SUMS.txt"
        Say "  $script:DistRoot\GRAB-Setup.iss"
        Say "  $script:DistRoot\payload\dep-versions.json"
        Ok 'dry-run complete (no artifacts written)'
        return
    }
    Say "artifacts in $script:DistRoot :"
    Get-ChildItem -LiteralPath $script:DistRoot -File | ForEach-Object {
        Say ("  {0}  ({1}MB)" -f $_.Name, [math]::Round($_.Length/1MB, 1))
    }
    Ok 'build complete'
}

try {
    Invoke-Build
    exit 0
} catch {
    Fail $_.Exception.Message
    exit 1
}
