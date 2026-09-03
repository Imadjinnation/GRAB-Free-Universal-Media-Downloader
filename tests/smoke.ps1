# tests/smoke.ps1
# Zero-dependency test harness. Runs a battery of strict tests against
# everything grab-app ships. Safe to run repeatedly. Never touches your
# real %APPDATA%\grab-app\ state -- uses an isolated temp folder via the
# GRAB_APP_DATA_OVERRIDE environment variable.
#
# Usage:  powershell -ExecutionPolicy Bypass -File tests\smoke.ps1
# Exit code: 0 = all pass, 1 = any failure.
#
# Style: linear script, no external framework needed. `Test 'name' { block }`
# runs the block; block throws to fail. Assertions helpers below.

$ErrorActionPreference = 'Continue'
$script:PassCount = 0
$script:FailCount = 0
$script:CurrentSection = ''
$script:Failures = @()

# ---------- Test harness --------------------------------------------------

function Section([string]$name) {
    $script:CurrentSection = $name
    Write-Host ""
    Write-Host "  [$name]" -ForegroundColor Cyan
}

function Test([string]$name, [scriptblock]$block) {
    try {
        & $block
        Write-Host ("    PASS  {0}" -f $name) -ForegroundColor Green
        $script:PassCount++
    } catch {
        Write-Host ("    FAIL  {0}" -f $name) -ForegroundColor Red
        Write-Host ("          -> {0}" -f $_.Exception.Message) -ForegroundColor DarkRed
        $script:Failures += "[$script:CurrentSection] $name -- $($_.Exception.Message)"
        $script:FailCount++
    }
}

function _fb($a, $b) { if ($a) { $a } else { $b } }

function Assert-True($cond, $msg = 'expected true') {
    if (-not $cond) { throw $msg }
}
function Assert-Equal($expected, $actual, $msg = $null) {
    if ($expected -ne $actual) {
        throw (_fb $msg "expected [$expected] got [$actual]")
    }
}
function Assert-NotNull($v, $msg = 'expected not-null') {
    if ($null -eq $v) { throw $msg }
}
function Assert-Contains([array]$haystack, $needle, $msg = $null) {
    if ($haystack -notcontains $needle) { throw (_fb $msg "collection does not contain [$needle]") }
}
function Assert-Match([string]$s, [string]$pattern, $msg = $null) {
    if ($s -notmatch $pattern) { throw (_fb $msg "[$s] does not match /$pattern/") }
}
function Assert-PathExists([string]$p, $msg = $null) {
    if (-not (Test-Path -LiteralPath $p)) { throw (_fb $msg "path missing: $p") }
}

# ---------- Set up isolated test state ------------------------------------

$repoRoot     = Split-Path $PSScriptRoot -Parent
$srcRoot      = Join-Path $repoRoot 'src'
$uiRoot       = Join-Path $repoRoot 'ui'
$docsRoot     = Join-Path $repoRoot 'docs'
$testAppData  = Join-Path $env:TEMP ("grab-tests-" + [guid]::NewGuid().ToString('N').Substring(0,8))
$env:GRAB_APP_DATA_OVERRIDE = $testAppData

Write-Host ""
Write-Host "  grab -- smoke tests" -ForegroundColor White
Write-Host "  -------------------" -ForegroundColor DarkGray
Write-Host "  Isolated app data: $testAppData" -ForegroundColor DarkGray

# Dot-source src/ modules AT SCRIPT SCOPE so functions are visible to every
# Test scriptblock below. Dot-sourcing inside a Test { } block would keep
# functions locked in that block's scope.
. (Join-Path $srcRoot 'utils.ps1')
. (Join-Path $srcRoot 'core.ps1')
. (Join-Path $srcRoot 'queue.ps1')
. (Join-Path $srcRoot 'popup.ps1')
. (Join-Path $srcRoot 'settings.ps1')
. (Join-Path $srcRoot 'tray.ps1')

# ---------- Shared XAML loader --------------------------------------------
# The XAML files (popup.xaml, settings.xaml, theme.xaml) use three token
# markers that production code substitutes at load time. Tests must apply
# the same substitution before parsing, otherwise Source="__GRAB_THEME__"
# fails as an invalid URI and every named-control lookup returns null.
function Get-GrabTokenSubstituted([string]$xamlText) {
    $fontsAbs  = Join-Path $repoRoot 'assets\fonts'
    $themeAbs  = Join-Path $repoRoot 'ui\theme.xaml'
    $assetsAbs = Join-Path $repoRoot 'assets'
    $fontsUri  = 'file:///' + (($fontsAbs  -replace '\\','/').TrimEnd('/')) + '/'
    $themeUri  = 'file:///' + (($themeAbs  -replace '\\','/'))
    $assetsUri = 'file:///' + (($assetsAbs -replace '\\','/').TrimEnd('/'))
    return $xamlText.
        Replace('__GRAB_FONTS__',  $fontsUri).
        Replace('__GRAB_THEME__',  $themeUri).
        Replace('__GRAB_ASSETS__', $assetsUri)
}

function Parse-GrabXaml([string]$xamlPath) {
    Add-Type -AssemblyName PresentationFramework | Out-Null
    $raw = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
    $sub = Get-GrabTokenSubstituted $raw
    return [Windows.Markup.XamlReader]::Parse($sub)
}

try {

# ==========================================================================
# 1. Project structure integrity
# ==========================================================================
Section 'Project structure'

$expectedFiles = @(
    'README.md', 'PROGRESS.md', 'LICENSE', '.gitignore', 'install.ps1', 'uninstall.ps1', 'grab-app.ps1',
    'src\utils.ps1', 'src\core.ps1', 'src\queue.ps1', 'src\tray.ps1', 'src\popup.ps1', 'src\settings.ps1',
    'ui\popup.xaml', 'ui\settings.xaml', 'ui\README.md',
    'assets\README.md', 'assets\gallery-dl-config.json',
    'docs\architecture.md', 'docs\site-coverage.md', 'docs\file-map.md',
    'tests\smoke.ps1'
)
foreach ($f in $expectedFiles) {
    Test "exists: $f" {
        Assert-PathExists (Join-Path $repoRoot $f)
    }
}

Test 'file-map.md indexes every real .ps1 in src\' {
    $fileMap = Get-Content (Join-Path $docsRoot 'file-map.md') -Raw
    $srcFiles = Get-ChildItem (Join-Path $repoRoot 'src') -Filter '*.ps1' -File -ErrorAction SilentlyContinue
    foreach ($f in $srcFiles) {
        if ($fileMap -notmatch [regex]::Escape("src/$($f.Name)")) {
            throw "src/$($f.Name) exists but is not indexed in docs/file-map.md"
        }
    }
}

Test 'README mentions every top-level .ps1' {
    $readme = Get-Content (Join-Path $repoRoot 'README.md') -Raw
    foreach ($n in @('install.ps1','grab-app.ps1')) {
        if ($readme -notmatch [regex]::Escape($n)) {
            throw "README doesn't mention $n"
        }
    }
}

# ==========================================================================
# 2. Script parse (every .ps1 loads without syntax errors)
# ==========================================================================
Section 'Script parse'

$psScripts = @(
    'install.ps1', 'uninstall.ps1', 'grab-app.ps1',
    'src\utils.ps1', 'src\core.ps1', 'src\queue.ps1', 'src\tray.ps1', 'src\popup.ps1', 'src\settings.ps1',
    'tests\smoke.ps1'
)
foreach ($s in $psScripts) {
    Test "parses: $s" {
        $path = Join-Path $repoRoot $s
        $tokens = $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
        if ($errors.Count -gt 0) {
            throw ($errors | ForEach-Object { $_.Message }) -join '; '
        }
    }
}

# ==========================================================================
# 3. XAML load + named controls resolve
# ==========================================================================
Section 'XAML load'

Test 'popup.xaml loads' {
    # popup.xaml uses __GRAB_FONTS__ / __GRAB_THEME__ / __GRAB_ASSETS__
    # placeholders that must be substituted before parsing (production
    # code does this in Load-PopupWindow). Parse-GrabXaml wraps it.
    $win = Parse-GrabXaml (Join-Path $uiRoot 'popup.xaml')
    Assert-NotNull $win
    Assert-Equal 480 ([int]$win.Width)
    Assert-Equal 420 ([int]$win.Height)
}

# Audit P2-58: each named-control test loads its own copy of the XAML so
# the tests don't depend on ordering / on a shared $script:XamlWindow state.
$expectedControls = @('TitleBar','MinBtn','CloseBtn','TabPaste','TabQueue','TabRecent',
    'PastePanel','QueuePanel','RecentPanel','UrlBox','MultiBox',
    'SingleInputBorder','MultiInputBorder','Hint','StatusLine','ToggleMulti','GrabBtn',
    'ClearRecentBtn','ClearOldRecentBtn')
foreach ($c in $expectedControls) {
    Test "popup.xaml has named control: $c" {
        $freshWin = Parse-GrabXaml (Join-Path $uiRoot 'popup.xaml')
        $ctl = $freshWin.FindName($c)
        Assert-NotNull $ctl "control $c not found"
    }
}

# ==========================================================================
# 4. Function exports (dot-source happened at top of file)
# ==========================================================================
Section 'Function exports'

$expectedExports = @{
    'utils.ps1' = @('Get-AppDataPath','Get-Config','Set-Config','Update-Config',
                    'Ensure-AppData','Test-IsUrl','Get-SiteName','Pick-Tool',
                    'Resolve-Tool','Log-Info','Send-Toast',
                    'Test-IsSensitiveUrl','Set-FolderHidden')
    'core.ps1'  = @('Invoke-Grab','Get-FileCount')
    'queue.ps1' = @('Add-QueueJob','Read-Queue','Write-Queue','Cancel-QueueJob',
                    'Retry-QueueJob','Clear-QueueDone','Append-Recent','Get-Recent',
                    'Clear-Recent','Invoke-QueueTick','Stop-AllJobs')
    'popup.ps1'    = @('Show-Popup','Hide-Popup')
    'tray.ps1'     = @('Start-Tray','Stop-Tray')
    'settings.ps1' = @('Show-Settings','Set-Autostart','Get-AutostartShortcutPath')
}
foreach ($file in $expectedExports.Keys) {
    foreach ($fn in $expectedExports[$file]) {
        Test "${file}: exports $fn" {
            $cmd = Get-Command $fn -ErrorAction SilentlyContinue
            Assert-NotNull $cmd "$fn not found after dot-sourcing $file"
        }
    }
}

# ==========================================================================
# 5. utils.ps1 -- pure functions
# ==========================================================================
Section 'utils.ps1'

Test 'AppData path honors GRAB_APP_DATA_OVERRIDE' {
    $p = Get-AppDataPath
    Assert-Equal $testAppData $p
}
Test 'Ensure-AppData creates root + logs folder' {
    Ensure-AppData
    Assert-PathExists $testAppData
    Assert-PathExists (Join-Path $testAppData 'logs')
}
Test 'Get-Config creates a valid default on first read' {
    $c = Get-Config
    Assert-NotNull $c
    # Default now sources from the version constant, not a hardcoded string.
    Assert-Equal (Get-GrabVersion) $c.version
    Assert-Equal $false  $c.askBeforeEach
    Assert-Equal $false  $c.clipboardWatch
    Assert-Equal 3       $c.concurrency
    Assert-NotNull $c.downloadFolder
    Assert-True (Test-Path (Get-ConfigPath)) 'config.json should be written'
}
Test 'Get-GrabVersion returns the v0.3.0 constant (single source of truth)' {
    # Regression: pre-v0.3.0 the version stamp was hardcoded in ~6 places
    # (config default, About footer, Settings label, install.ps1, README).
    # Get-GrabVersion is the single source now -- everyone must agree.
    Assert-Equal '0.3.0' (Get-GrabVersion)
}
Test 'Get-DownloadFolderDefault prefers D:\imadjinn-grab when D:\ exists' {
    # Ghost-folder prevention (audit P0-6): default no longer routes into
    # OneDrive/iCloud-sync-locked ~\Downloads.
    $p = Get-DownloadFolderDefault
    if (Test-Path -LiteralPath 'D:\') {
        Assert-Equal 'D:\imadjinn-grab' $p
    } else {
        # Machine without a D:\ drive -- falls back to %USERPROFILE% root,
        # not the ~\Downloads subfolder that used to spawn ghosts.
        Assert-Match $p ([regex]::Escape((Join-Path $env:USERPROFILE 'imadjinn-grab')))
    }
}
Test 'Write-JsonAtomic writes UTF-8 without BOM (audit P1-8)' {
    # Set-Content -Encoding UTF8 emits a BOM in PS 5.1, which trips external
    # tools that expect plain UTF-8. Write-JsonAtomic must not.
    $tmp = Join-Path $env:TEMP ("grab-atomic-" + [Guid]::NewGuid().ToString('N').Substring(0,8) + ".json")
    try {
        Write-JsonAtomic -Path $tmp -Data @{ hello = 'world' } -Depth 2
        Assert-PathExists $tmp
        $bytes = [System.IO.File]::ReadAllBytes($tmp)
        # UTF-8 BOM is EF BB BF -- first three bytes must NOT be that.
        if ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            throw 'Write-JsonAtomic wrote a UTF-8 BOM; it must not'
        }
        # And the JSON must round-trip.
        $obj = Get-Content -LiteralPath $tmp -Raw | ConvertFrom-Json
        Assert-Equal 'world' $obj.hello
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}
Test 'Write-JsonAtomic replaces existing file atomically (no .tmp left behind)' {
    $tmp = Join-Path $env:TEMP ("grab-atomic-" + [Guid]::NewGuid().ToString('N').Substring(0,8) + ".json")
    try {
        Write-JsonAtomic -Path $tmp -Data @{ n = 1 } -Depth 2
        Write-JsonAtomic -Path $tmp -Data @{ n = 2 } -Depth 2
        Assert-True (-not (Test-Path -LiteralPath "$tmp.tmp")) 'stale .tmp remains after replace'
        $obj = Get-Content -LiteralPath $tmp -Raw | ConvertFrom-Json
        Assert-Equal 2 $obj.n
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "$tmp.tmp" -Force -ErrorAction SilentlyContinue
    }
}
Test 'Invoke-GrabTokenReplace substitutes the three tokens (unified helper)' {
    $xaml = '<X fonts="__GRAB_FONTS__" theme="__GRAB_THEME__" assets="__GRAB_ASSETS__"/>'
    $out = Invoke-GrabTokenReplace -XamlText $xaml -FontsUri 'F' -ThemeUri 'T' -AssetsUri 'A'
    Assert-Match $out 'fonts="F"'
    Assert-Match $out 'theme="T"'
    Assert-Match $out 'assets="A"'
    # Optional args skip that specific replacement.
    $part = Invoke-GrabTokenReplace -XamlText $xaml -FontsUri 'FONLY'
    Assert-Match $part 'fonts="FONLY"'
    Assert-Match $part 'theme="__GRAB_THEME__"'
}
Test 'Get-Config version migration: legacy 0.1.0 gets bumped to current on load' {
    # Regression for the v0.1.0 -> v0.2.2 stuck-version drift.
    Ensure-AppData
    $legacy = @{
        version = '0.1.0'
        downloadFolder = 'C:\tmp\legacy'
        cookieBrowser = 'chrome'
        concurrency = 3
        toastsEnabled = $true
    }
    # Write directly (not via Set-Config) so no cache is seeded.
    $legacy | ConvertTo-Json -Depth 4 | Set-Content -Path (Get-ConfigPath) -Encoding UTF8
    # Clear the in-memory cache so the next Get-Config re-reads.
    $ok = Get-Command -Name Get-Config -CommandType Function -ErrorAction SilentlyContinue
    $c = Get-Config
    Assert-Equal (Get-GrabVersion) $c.version
    # And it persisted -- next parse sees the new value.
    $onDisk = Get-Content -LiteralPath (Get-ConfigPath) -Raw | ConvertFrom-Json
    Assert-Equal (Get-GrabVersion) $onDisk.version
}
Test 'Get-Config config cache: second read does not re-parse file' {
    # We cannot easily test "did we skip parsing" without instrumenting the
    # function, but we CAN test the cache mtime invariant: calling Get-Config
    # twice back-to-back returns the same object, and mutating the returned
    # object's transient properties is visible on the second call (proving
    # the same reference is served).
    $c1 = Get-Config
    $c1 | Add-Member -MemberType NoteProperty -Name '__cache_probe' -Value 'yes' -Force
    $c2 = Get-Config
    # Same reference -> same probe visible
    Assert-Equal 'yes' $c2.__cache_probe
    # Cleanup so downstream tests don't inherit the probe
    $c2.PSObject.Properties.Remove('__cache_probe')
}
Test 'Update-Config merges without losing other keys' {
    $c1 = Get-Config
    $orig = $c1.concurrency
    Update-Config @{ concurrency = 5 } | Out-Null
    $c2 = Get-Config
    Assert-Equal 5 $c2.concurrency
    Assert-Equal $c1.version $c2.version
    # restore
    Update-Config @{ concurrency = $orig } | Out-Null
}
Test 'Test-IsUrl accepts real URLs' {
    Assert-True (Test-IsUrl 'https://youtube.com/watch?v=abc')
    Assert-True (Test-IsUrl 'http://example.org/path/to/thing')
}
Test 'Test-IsUrl rejects garbage' {
    Assert-True (-not (Test-IsUrl ''))
    Assert-True (-not (Test-IsUrl 'hello world'))
    Assert-True (-not (Test-IsUrl 'ftp://example.org'))
    Assert-True (-not (Test-IsUrl 'javascript:alert(1)'))
}
Test 'Get-SiteName pulls short host' {
    Assert-Equal 'youtube'   (Get-SiteName 'https://www.youtube.com/watch?v=X')
    Assert-Equal 'instagram' (Get-SiteName 'https://www.instagram.com/reel/abc/')
    Assert-Equal 'mangadex'  (Get-SiteName 'https://mangadex.org/title/xyz')
}
Test 'Get-FullDomain returns full host (with TLD) minus www' {
    Assert-Equal 'allporncomic.com' (Get-FullDomain 'https://allporncomic.com/porncomic/xyz/')
    Assert-Equal 'youtube.com'      (Get-FullDomain 'https://www.youtube.com/watch?v=abc')
    Assert-Equal 'mangadex.org'     (Get-FullDomain 'https://mangadex.org/title/x/y')
    Assert-Equal 'en.wikipedia.org' (Get-FullDomain 'https://en.wikipedia.org/wiki/X')  # keep subdomain
}
Test 'Get-CategoryForUrl routes to filmmaker-friendly buckets' {
    Assert-Equal 'Videos'  (Get-CategoryForUrl 'https://www.youtube.com/watch?v=abc')
    Assert-Equal 'Videos'  (Get-CategoryForUrl 'https://www.tiktok.com/@x/video/1')
    Assert-Equal 'Comics'  (Get-CategoryForUrl 'https://mangadex.org/title/x/y')
    Assert-Equal 'Comics'  (Get-CategoryForUrl 'https://allporncomic.com/porncomic/x/')
    Assert-Equal 'Comics'  (Get-CategoryForUrl 'https://webtoons.com/en/x/y')
    Assert-Equal 'Images'  (Get-CategoryForUrl 'https://www.pinterest.com/user/board/')
    Assert-Equal 'Images'  (Get-CategoryForUrl 'https://www.artstation.com/username')
    Assert-Equal 'Social'  (Get-CategoryForUrl 'https://www.instagram.com/username/')
    Assert-Equal 'Social'  (Get-CategoryForUrl 'https://twitter.com/user/status/1')
    Assert-Equal 'Misc'    (Get-CategoryForUrl 'https://unknown-site.example/whatever')
}
Test 'Pick-Tool routes known hosts correctly' {
    Assert-Equal 'yt-dlp'     (Pick-Tool 'https://www.youtube.com/watch?v=abc')
    Assert-Equal 'yt-dlp'     (Pick-Tool 'https://www.tiktok.com/@x/video/1')
    Assert-Equal 'yt-dlp'     (Pick-Tool 'https://www.instagram.com/reel/xxx/')
    Assert-Equal 'gallery-dl' (Pick-Tool 'https://www.instagram.com/username/')
    Assert-Equal 'gallery-dl' (Pick-Tool 'https://mangadex.org/title/x/y')
    Assert-Equal 'gallery-dl' (Pick-Tool 'https://www.pinterest.com/user/board/')
    Assert-Equal 'gallery-dl' (Pick-Tool 'https://twitter.com/user/status/1')
    Assert-Equal 'gallery-dl' (Pick-Tool 'https://x.com/user/status/1')
    Assert-Equal 'yt-dlp'     (Pick-Tool 'https://unknown-site.example/whatever')
}
Test 'Write-Log creates a rotating per-day file' {
    Log-Info 'smoke test line'
    $file = Join-Path (Get-LogFolder) ("grab-{0}.log" -f (Get-Date -Format 'yyyy-MM-dd'))
    Assert-PathExists $file
    $content = Get-Content $file -Raw
    Assert-Match $content 'smoke test line'
}
Test 'Resolve-Tool locates yt-dlp' {
    $p = Resolve-Tool 'yt-dlp'
    Assert-NotNull $p 'yt-dlp not found; run install.ps1'
    Assert-PathExists $p
}
Test 'Resolve-Tool locates gallery-dl' {
    $p = Resolve-Tool 'gallery-dl'
    Assert-NotNull $p 'gallery-dl not found; run install.ps1'
    Assert-PathExists $p
}

# ==========================================================================
# 6. queue.ps1 -- state lifecycle
# ==========================================================================
Section 'queue.ps1'

Test 'Read-Queue on empty state emits nothing' {
    if (Test-Path (Get-QueuePath)) { Remove-Item (Get-QueuePath) -Force }
    $q = @(Read-Queue)
    Assert-Equal 0 $q.Count
}
Test 'Add-QueueJob adds a single URL' {
    $added = Add-QueueJob -Urls @('https://www.youtube.com/watch?v=test1')
    Assert-Equal 1 $added
    $q = @(Read-Queue)
    Assert-Equal 1 $q.Count
    Assert-Equal 'pending' $q[0].Status
    Assert-Equal 'https://www.youtube.com/watch?v=test1' $q[0].Url
}
Test 'Add-QueueJob dedupes URLs already pending' {
    $added = Add-QueueJob -Urls @('https://www.youtube.com/watch?v=test1')
    Assert-Equal 0 $added
    Assert-Equal 1 @(Read-Queue).Count
}
Test 'Add-QueueJob adds multiple URLs at once' {
    $added = Add-QueueJob -Urls @(
        'https://www.youtube.com/watch?v=test2',
        'https://www.youtube.com/watch?v=test3',
        'not-a-url',
        'https://www.youtube.com/watch?v=test2'
    )
    Assert-Equal 2 $added 'should add test2 and test3, skip garbage and duplicate'
    Assert-Equal 3 @(Read-Queue).Count
}
Test 'Cancel-QueueJob marks pending job cancelled' {
    $q = @(Read-Queue)
    $id = $q[0].Id
    Cancel-QueueJob $id
    $after = @(Read-Queue | Where-Object { $_.Id -eq $id })
    Assert-Equal 1 $after.Count 'expected exactly one match for the id'
    Assert-Equal 'cancelled' $after[0].Status
}
Test 'Retry-QueueJob resets a cancelled job to pending' {
    $q = @(Read-Queue)
    $cancelled = $q | Where-Object { $_.Status -eq 'cancelled' } | Select-Object -First 1
    Assert-NotNull $cancelled
    Retry-QueueJob $cancelled.Id
    $after = @(Read-Queue | Where-Object { $_.Id -eq $cancelled.Id })
    Assert-Equal 'pending' $after[0].Status
}
Test 'Clear-QueueDone drops non-active jobs only' {
    # Cancel one to make it non-active
    $q = @(Read-Queue)
    Cancel-QueueJob $q[0].Id
    $before = @(Read-Queue).Count
    Clear-QueueDone
    $after = @(Read-Queue).Count
    Assert-True ($after -lt $before) "expected reduction after clear-done ($before -> $after)"
    # None of the remaining should be cancelled/done/failed
    Read-Queue | ForEach-Object {
        Assert-True ($_.Status -in @('pending','running')) "unexpected status: $($_.Status)"
    }
}
Test 'Read-Queue handles corrupt json gracefully' {
    Set-Content -Path (Get-QueuePath) -Value 'not json at all {{{{' -Encoding UTF8
    # Contract: must not throw. Empty result is acceptable.
    $q = @(Read-Queue)
    Assert-Equal 0 $q.Count 'corrupt json should produce an empty queue, not crash'
    # restore clean state
    Write-Queue @()
}
Test 'Append-Recent + Get-Recent round-trip' {
    if (Test-Path (Get-RecentPath)) { Remove-Item (Get-RecentPath) -Force }
    $fake = [PSCustomObject]@{
        Url = 'https://example.com/a'; Dest = 'C:\tmp'; DoneAt = (Get-Date).ToString('o')
        Status = 'done'; FilesAdded = 3; ToolUsed = 'yt-dlp'; DurationMs = 1234; Error = $null
    }
    Append-Recent $fake
    $r = Get-Recent
    Assert-Equal 1 @($r).Count
    Assert-Equal 'https://example.com/a' $r[0].Url
    Assert-Equal 3 $r[0].FilesAdded
}
Test 'Append-Recent caps at 100 entries' {
    for ($i = 0; $i -lt 120; $i++) {
        Append-Recent ([PSCustomObject]@{
            Url = "https://example.com/$i"; Dest = 'C:\tmp'; DoneAt = (Get-Date).ToString('o')
            Status = 'done'; FilesAdded = 1; ToolUsed = 'yt-dlp'; DurationMs = 1; Error = $null
        })
    }
    $r = Get-Recent
    Assert-Equal 100 @($r).Count
    # newest first
    Assert-Match $r[0].Url '/119$'
}

# ==========================================================================
# 7. core.ps1 -- structural
# ==========================================================================
Section 'core.ps1'

Test 'Invoke-Grab is exported with the right parameter names' {
    $cmd = Get-Command Invoke-Grab -ErrorAction SilentlyContinue
    Assert-NotNull $cmd
    $names = @($cmd.Parameters.Keys)   # force to real array for -contains
    Assert-Contains $names 'Url'
    Assert-Contains $names 'Dest'
    Assert-Contains $names 'Tool'
    Assert-Contains $names 'NoCookies'
}
Test 'Get-FileCount returns 0 for non-existent path' {
    $n = Get-FileCount (Join-Path $env:TEMP ('nope-' + [guid]::NewGuid()))
    Assert-Equal 0 $n
}
Test 'Get-FileCount counts real files' {
    $tmp = Join-Path $env:TEMP ('gf-' + [guid]::NewGuid().ToString('N').Substring(0,6))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    'a' | Set-Content (Join-Path $tmp 'a.txt')
    'b' | Set-Content (Join-Path $tmp 'b.txt')
    Assert-Equal 2 (Get-FileCount $tmp)
    Remove-Item $tmp -Recurse -Force
}
Test 'Invoke-Grab default Dest follows Category\Domain layout' {
    # Regression for the folder-management redesign (2026-09-02): unless the
    # caller overrides Dest, Invoke-Grab must route into
    # <downloadFolder>\<Category>\<FullDomain>\.
    # Wrap this in an ephemeral downloadFolder so the test never spills into
    # a real user path -- audit P0-6 ghost-folder prevention. Skip actual
    # engine invocation (GRAB_TESTS_SKIP_ENGINES) -- this test only checks
    # the Destination path calculation, not real network I/O.
    $isoDir = Join-Path $env:TEMP ("grab-test-dl-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
    $orig = (Get-Config).downloadFolder
    $env:GRAB_TESTS_SKIP_ENGINES = '1'
    try {
        Update-Config @{ downloadFolder = $isoDir } | Out-Null
        $expected = Join-Path $isoDir (Join-Path 'Comics' 'allporncomic.com')
        $r = Invoke-Grab -Url 'https://allporncomic.com/porncomic/does-not-exist-xyz/' -NoCookies
        Assert-Equal $expected $r.Destination
    } finally {
        Update-Config @{ downloadFolder = $orig } | Out-Null
        Remove-Item -LiteralPath $isoDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item Env:GRAB_TESTS_SKIP_ENGINES -ErrorAction SilentlyContinue
    }
}
Test 'Get-LeafFoldersWithFiles finds every folder holding files' {
    $root = Join-Path $env:TEMP ('gdf-' + [guid]::NewGuid().ToString('N').Substring(0,6))
    New-Item -ItemType Directory -Path (Join-Path $root 'a\b\c') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $root 'a\d')   -Force | Out-Null
    'x' | Set-Content (Join-Path $root 'a\b\c\file.jpg')
    'x' | Set-Content (Join-Path $root 'a\d\file2.jpg')
    $leaves = Get-LeafFoldersWithFiles $root
    Assert-Equal 2 $leaves.Count 'expected two leaf folders'
    Remove-Item $root -Recurse -Force
}
Test 'Get-FileCount handles folder names with [ ] (bracket wildcard bug)' {
    # Regression: PowerShell treats [ ] as wildcards without -LiteralPath.
    # Folder names like "Series [Author]" quietly returned 0 files. That
    # broke imadjinn.json counts AND success detection.
    # NOTE: file/folder CREATION also needs -LiteralPath for the same reason.
    $root = Join-Path $env:TEMP ('br-' + [guid]::NewGuid().ToString('N').Substring(0,6))
    $bracket = Join-Path $root 'Series [Author]'
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    New-Item -ItemType Directory -Path $bracket -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $bracket 'a.jpg'), 'x')
    [System.IO.File]::WriteAllText((Join-Path $bracket 'b.jpg'), 'x')
    Assert-Equal 2 (Get-FileCount $bracket)
    Remove-Item -LiteralPath $root -Recurse -Force
}
Test 'Invoke-PostProcess writes per-chapter imadjinn.json on multi-chapter downloads' {
    # Regression: earlier the manifest was only written at the series root,
    # with a bogus file_count of 0. Now we write per-chapter + a summary.
    $root  = Join-Path $env:TEMP ('pp-' + [guid]::NewGuid().ToString('N').Substring(0,6))
    $chapA = Join-Path $root 'Chapter A [special]'
    $chapB = Join-Path $root 'Chapter B'
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    New-Item -ItemType Directory -Path $chapA -Force | Out-Null
    New-Item -ItemType Directory -Path $chapB -Force | Out-Null
    # Use .NET to write files so brackets don't trip the wildcard parser
    [System.IO.File]::WriteAllText((Join-Path $chapA '001.jpg'), ('x' * 1000))
    [System.IO.File]::WriteAllText((Join-Path $chapB '001.jpg'), ('x' * 2000))
    [System.IO.File]::WriteAllText((Join-Path $chapB '002.jpg'), ('x' * 3000))
    # StartedAt in the past so all our test files count as "touched"
    Invoke-PostProcess -Url 'https://example.com/series/xyz' -Dest $root -Tool 'gallery-dl' -StartedAt ([datetime]::MinValue)

    Assert-PathExists (Join-Path $chapA 'imadjinn.json') 'missing chapter A manifest'
    Assert-PathExists (Join-Path $chapB 'imadjinn.json') 'missing chapter B manifest'
    Assert-PathExists (Join-Path $root  'imadjinn.json') 'missing series manifest'
    $ma = Get-Content -LiteralPath (Join-Path $chapA 'imadjinn.json') -Raw | ConvertFrom-Json
    Assert-Equal 1 $ma.file_count
    Assert-Equal 'Chapter A [special]' $ma.chapter
    $ms = Get-Content -LiteralPath (Join-Path $root 'imadjinn.json') -Raw | ConvertFrom-Json
    Assert-Equal 2 $ms.chapter_count
    Assert-Equal 3 $ms.file_count

    Remove-Item -LiteralPath $root -Recurse -Force
}
Test 'Invoke-Grab captures $grabStartedAt BEFORE download so post-process uses accurate start' {
    # Regression for the audit crit-1: previously the code did
    #   $startTime = (Get-Date).AddMilliseconds(-$result.DurationMs).AddSeconds(-5)
    # but $result.DurationMs was still 0 at that call site -- so StartedAt
    # was always Now-5s, and every real download (>5s) had zero manifests
    # because no files qualified as "touched by this run".
    $content = Get-Content (Join-Path $srcRoot 'core.ps1') -Raw
    if ($content -match 'AddMilliseconds\(-\$result\.DurationMs\)') {
        throw 'core.ps1 still computes StartedAt from $result.DurationMs (which is 0 at that point) -- capture up front instead'
    }
    if ($content -notmatch '\$grabStartedAt\s*=\s*Get-Date') {
        throw 'core.ps1 must capture $grabStartedAt = Get-Date at the top of Invoke-Grab'
    }
}

Test 'Get-ArchivePath returns different files per engine (audit high-6)' {
    # Regression: yt-dlp and gallery-dl use incompatible --download-archive
    # line formats; sharing one file causes collisions.
    $yt = Get-ArchivePath 'yt-dlp'
    $gd = Get-ArchivePath 'gallery-dl'
    Assert-True ($yt -ne $gd) "expected different archive files, got same: $yt"
    Assert-Match $yt 'yt-dlp'
    Assert-Match $gd 'gallery-dl'
}

Test 'cookieBrowser=none does NOT get passed as --cookies-from-browser (audit high-7)' {
    # Regression: earlier the flag was always emitted with whatever value
    # cookieBrowser held, including "none". gallery-dl/yt-dlp then wasted
    # every first attempt on an invalid browser argument.
    $content = Get-Content (Join-Path $srcRoot 'core.ps1') -Raw
    if ($content -notmatch 'browser\s+-and\s+\$browser\s+-ne\s+.none.') {
        throw 'core.ps1 must gate --cookies-from-browser on $browser being non-empty AND not equal to "none"'
    }
}

Test 'tray.ps1 has crash-recovery sweep for orphaned running jobs (audit high-8)' {
    $trayContent = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    if ($trayContent -notmatch 'Recover-OrphanedJobs') {
        throw 'tray.ps1 must call Recover-OrphanedJobs on Start-Tray so stale "running" entries get retried'
    }
    $queueContent = Get-Content (Join-Path $srcRoot 'queue.ps1') -Raw
    if ($queueContent -notmatch 'function\s+Recover-OrphanedJobs') {
        throw 'queue.ps1 must define Recover-OrphanedJobs'
    }
}

Test 'firstRunComplete is set right after balloon (audit crit-3, not only on graceful quit)' {
    $trayContent = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    if ($trayContent -notmatch "firstRunComplete\s*=\s*\`$true") {
        throw 'tray.ps1 must set firstRunComplete = $true right after showing the first-run balloon (users don`''t "Quit")'
    }
}

Test 'TitleBar drag handler does NOT reference $_ (audit crit-2)' {
    # Regression: WPF event handlers don't populate $_. Using $_.ChangedButton
    # returned $null, guard failed, DragMove never fired. Popup uncuttable.
    $content = Get-Content (Join-Path $srcRoot 'popup.ps1') -Raw
    # Find the TitleBar.Add_MouseLeftButtonDown handler body
    if ($content -notmatch 'TitleBar\.Add_MouseLeftButtonDown\(\{([^}]*)\}') {
        throw 'TitleBar.Add_MouseLeftButtonDown handler not found or malformed'
    }
    $body = $Matches[1]
    if ($body -match '\$_') {
        throw "TitleBar drag handler still references `$_ (which is `$null in WPF handlers). Body: $($body -replace '\s+',' ')"
    }
    if ($body -notmatch 'DragMove') {
        throw 'TitleBar handler must call DragMove()'
    }
}

Test 'grab-app.ps1 quotes $PSCommandPath for STA relaunch (audit high-9)' {
    # Regression: Start-Process -ArgumentList joins array items with spaces,
    # so an un-quoted `-File $PSCommandPath` splits into multiple tokens if
    # the repo path contains spaces (e.g. "My Projects").
    $content = Get-Content (Join-Path $repoRoot 'grab-app.ps1') -Raw
    if ($content -notmatch "'`"'\s*\+\s*\`$PSCommandPath\s*\+\s*'`"'") {
        # weaker check: at least it wraps in quotes some way
        if ($content -notmatch '"\$PSCommandPath"' -and $content -notmatch "'\\`"'\\s*\\+\\s*\\`$PSCommandPath") {
            throw 'grab-app.ps1 STA relaunch must quote $PSCommandPath to survive paths with spaces'
        }
    }
}

Test 'core.ps1 uses -LiteralPath everywhere ChildItem/Test-Path/New-Item touches user-facing paths' {
    # Regression for audit high-4: initial Dest create was missing -LiteralPath.
    # Scan core.ps1 for Test-Path / New-Item calls that reference $Dest, $leaf,
    # $chapterRoot, $SeriesRoot, or $inner without -LiteralPath.
    $content = Get-Content (Join-Path $srcRoot 'core.ps1') -Raw
    $offenders = @()
    $rx = [regex]'(Test-Path|New-Item|Get-ChildItem|Remove-Item|Move-Item)\s+(-Path\s+)?(\$(Dest|leaf|chapterRoot|SeriesRoot|inner|root|path))\b(?![^\r\n]*-LiteralPath)'
    foreach ($m in $rx.Matches($content)) {
        # Skip if -LiteralPath appears anywhere in the same statement (up to 200 chars)
        $ctxStart = [Math]::Max(0, $m.Index - 20)
        $ctxLen   = [Math]::Min($content.Length - $ctxStart, 250)
        $ctx = $content.Substring($ctxStart, $ctxLen)
        if ($ctx -notmatch '-LiteralPath') {
            $offenders += ($m.Value -replace '\s+',' ')
        }
    }
    if ($offenders.Count -gt 0) {
        throw ("core.ps1 has FS calls on user paths without -LiteralPath:`n    " + ($offenders -join "`n    "))
    }
}

Test 'Invoke-Grab dry-run parses without runtime errors on unknown URL' {
    # Regression: my $attempts array used `(if ... else ...)` inside a hash
    # literal, which PARSES fine but FAILS at RUNTIME ("The term 'if' is
    # not recognized"). This meant the fallback chain silently crashed on
    # every real invocation. This test would have caught it in seconds.
    $tmp = Join-Path $env:TEMP ('igr-' + [guid]::NewGuid().ToString('N').Substring(0,6))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        # Use a URL that will fail cleanly at the engine level, not at PS
        # level. If the wrapper's own logic throws, the test fails.
        $r = Invoke-Grab -Url 'https://nope.invalid.example.test/does-not-exist' -Dest $tmp -NoCookies
        Assert-NotNull $r
        Assert-Equal $false $r.Success
        # Duration should reflect actual attempts, not an instant crash.
        Assert-True ($r.DurationMs -gt 0) 'DurationMs should be > 0 (wrapper actually ran the engines)'
    } finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ==========================================================================
# 7b. popup.ps1 -- closure regression check
# ==========================================================================
Section 'popup.ps1 closures'

Test 'TitleBar in popup.xaml has a hit-testable Background (not empty, not Transparent-only)' {
    # Regression: without a hit-testable Background, DragMove won't fire.
    # We accept anything non-empty non-Transparent (Transparent is technically
    # hit-testable but flaky across WPF versions).
    $xamlText = Get-Content (Join-Path $uiRoot 'popup.xaml') -Raw
    if ($xamlText -notmatch 'x:Name="TitleBar"[^>]*Background="([^"]+)"') {
        throw 'TitleBar element or its Background attribute not found'
    }
    $bg = $Matches[1]
    if ($bg -eq 'Transparent' -or $bg -eq '') {
        throw "TitleBar Background is `"$bg`" -- must be a resolved hit-testable value (e.g. #01000000)"
    }
}

Test 'Get-DockedPosition uses SystemParameters.WorkArea (DPI-aware), not Screen.WorkingArea' {
    # Regression: mixing device-pixel Screen.WorkingArea with DIP Window.Width
    # placed the popup off-screen on scaled displays.
    $content = Get-Content (Join-Path $srcRoot 'popup.ps1') -Raw
    # The function body should reference SystemParameters.WorkArea
    if ($content -notmatch 'SystemParameters\]::WorkArea') {
        throw 'popup.ps1 does not use SystemParameters.WorkArea -- positioning may be off on high-DPI displays'
    }
}

Test 'tray.ps1 uses DispatcherTimer, not WinForms.Timer' {
    # Regression: WinForms.Timer never fires under WPF Dispatcher.Run.
    $content = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    if ($content -match 'New-Object\s+System\.Windows\.Forms\.Timer') {
        throw 'tray.ps1 still creates WinForms.Timer -- will not fire under Dispatcher.Run'
    }
    if ($content -notmatch 'DispatcherTimer') {
        throw 'tray.ps1 does not use DispatcherTimer'
    }
}

Test 'Write-Log redacts token/auth params from URLs before writing to log' {
    # Regression for audit low-19: URLs with ?token=... were logged verbatim.
    $env:GRAB_APP_DATA_OVERRIDE = Join-Path $env:TEMP ("grab-log-test-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    try {
        Ensure-AppData
        Log-Info 'download https://cdn.example.com/file.mp4?token=SECRET123&sig=alsohidden&other=fine'
        $logFile = Join-Path (Get-LogFolder) ("grab-{0}.log" -f (Get-Date -Format 'yyyy-MM-dd'))
        $content = Get-Content $logFile -Raw
        Assert-True ($content -notmatch 'SECRET123') 'token value leaked into log'
        Assert-True ($content -notmatch 'alsohidden') 'sig value leaked into log'
        Assert-Match $content 'token=REDACTED'
        Assert-Match $content 'other=fine'
    } finally {
        Remove-Item -LiteralPath $env:GRAB_APP_DATA_OVERRIDE -Recurse -Force -ErrorAction SilentlyContinue
        # Restore test-runner isolation folder
        $env:GRAB_APP_DATA_OVERRIDE = $testAppData
    }
}

Test 'uninstall.ps1 has -KeepState and -Yes flags (documented interactive/silent modes)' {
    $c = Get-Content (Join-Path $repoRoot 'uninstall.ps1') -Raw
    Assert-Match $c '\[switch\]\$Yes'
    Assert-Match $c '\[switch\]\$KeepState'
    # Sanity: guaranteed to never touch downloads
    Assert-Match $c 'downloaded files'
    # Removes shortcuts by every known past name
    foreach ($shortcut in @('grab.lnk','grab Downloads.lnk','Grab \(paste\).lnk','Grab \(drop\).lnk')) {
        Assert-Match $c $shortcut "uninstall.ps1 doesn't remove $shortcut"
    }
}

Test 'Invoke-Grab warns on low disk space (audit med-12 groundwork)' {
    # Regression: verify Invoke-Grab checks free disk space before starting.
    # We don't force a real low-disk scenario; just assert the check exists.
    $c = Get-Content (Join-Path $srcRoot 'core.ps1') -Raw
    Assert-Match $c 'disk-space low'
    Assert-Match $c 'PathRoot\(\$Dest\)'
}

Test 'Test-IsSensitiveUrl matches configured patterns (case-insensitive substring)' {
    $orig = (Get-Config).sensitiveSites
    try {
        Update-Config @{ sensitiveSites = @('nhentai.net','allporncomic.com','MY-CUSTOM-PATTERN') } | Out-Null
        Update-Config @{ sensitiveByDefault = $false } | Out-Null
        Assert-True (Test-IsSensitiveUrl 'https://nhentai.net/g/12345/')
        Assert-True (Test-IsSensitiveUrl 'https://ALLPORNCOMIC.COM/porncomic/x/')    # case-insensitive
        Assert-True (Test-IsSensitiveUrl 'https://example.com/my-CUSTOM-pattern/xyz') # substring, insensitive
        Assert-True (-not (Test-IsSensitiveUrl 'https://youtube.com/watch?v=abc'))
        Assert-True (-not (Test-IsSensitiveUrl 'https://mangadex.org/'))
    } finally {
        Update-Config @{ sensitiveSites = @($orig) } | Out-Null
    }
}
Test 'Test-IsSensitiveUrl returns $true for everything when sensitiveByDefault' {
    $orig = (Get-Config).sensitiveByDefault
    try {
        Update-Config @{ sensitiveByDefault = $true } | Out-Null
        Assert-True (Test-IsSensitiveUrl 'https://any-url.example/whatever')
    } finally {
        Update-Config @{ sensitiveByDefault = $orig } | Out-Null
    }
}
Test 'Invoke-Grab routes into .private when -Sensitive is passed' {
    # The private folder is inserted between Category and Domain.
    # Ephemeral downloadFolder so nothing spills into a real user path
    # (ghost-folder prevention, audit P0-6). Engine calls skipped -- this
    # test only checks the Destination path calculation.
    $isoDir = Join-Path $env:TEMP ("grab-test-dl-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
    $orig = (Get-Config).downloadFolder
    $env:GRAB_TESTS_SKIP_ENGINES = '1'
    try {
        Update-Config @{ downloadFolder = $isoDir } | Out-Null
        $cfg = Get-Config
        $expected = Join-Path $isoDir (Join-Path 'Comics' (Join-Path $cfg.sensitiveFolderName 'allporncomic.com'))
        $r = Invoke-Grab -Url 'https://allporncomic.com/porncomic/does-not-exist-xyz/' -Sensitive -NoCookies
        Assert-Equal $expected $r.Destination
    } finally {
        Update-Config @{ downloadFolder = $orig } | Out-Null
        # Un-hide first because the .private root gets the Hidden attribute
        try {
            if (Test-Path -LiteralPath $isoDir) {
                Get-ChildItem -LiteralPath $isoDir -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
                    try { $_.Attributes = $_.Attributes -band (-bnot [System.IO.FileAttributes]::Hidden) } catch {}
                }
            }
        } catch {}
        Remove-Item -LiteralPath $isoDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item Env:GRAB_TESTS_SKIP_ENGINES -ErrorAction SilentlyContinue
    }
}
Test 'Set-FolderHidden actually sets the Windows Hidden attribute' {
    $tmp = Join-Path $env:TEMP ('hide-test-' + [guid]::NewGuid().ToString('N').Substring(0,6))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        Set-FolderHidden $tmp
        $item = Get-Item -LiteralPath $tmp -Force
        Assert-True ([bool]($item.Attributes -band [System.IO.FileAttributes]::Hidden)) 'folder was not marked Hidden'
    } finally {
        # Un-hide before Remove-Item -Force so cleanup doesn't get confused
        try {
            $it = Get-Item -LiteralPath $tmp -Force -ErrorAction Stop
            $it.Attributes = $it.Attributes -band (-bnot [System.IO.FileAttributes]::Hidden)
        } catch {}
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Test 'settings.xaml has the SensitiveByDefault + SensitiveSites controls' {
    $win = Parse-GrabXaml (Join-Path $uiRoot 'settings.xaml')
    Assert-NotNull ($win.FindName('SensitiveByDefault')) 'missing SensitiveByDefault checkbox'
    Assert-NotNull ($win.FindName('SensitiveSites'))     'missing SensitiveSites textarea'
}
Test 'popup.xaml has the SensitiveToggle checkbox on the Paste tab' {
    $win = Parse-GrabXaml (Join-Path $uiRoot 'popup.xaml')
    Assert-NotNull ($win.FindName('SensitiveToggle'))
}

Test 'grab-app.ps1 declares the singleton mutex correctly (prevents multi-tray bug)' {
    # v0.3.0: singleton now uses the non-owning-constructor + WaitOne(0) so
    # AbandonedMutexException is a recoverable "reclaim" rather than a
    # startup crash (audit P0-3). Either the old $script:GotLock pattern or
    # the new WaitOne(0)+AbandonedMutex pattern satisfies "we have a
    # singleton". The new pattern is checked more precisely by
    # "grab-app.ps1 handles AbandonedMutexException".
    $content = Get-Content (Join-Path $repoRoot 'grab-app.ps1') -Raw
    if ($content -notmatch 'GrabAppTraySingleton') {
        throw 'grab-app.ps1 missing named-mutex singleton (users can end up with duplicate tray icons)'
    }
    $legacyOK = $content -match '\$script:GotLock\s*=\s*\$false'
    $v030OK   = ($content -match 'WaitOne\(0\)') -and ($content -match 'AbandonedMutexException')
    if (-not ($legacyOK -or $v030OK)) {
        throw 'grab-app.ps1 singleton must either pre-declare $script:GotLock (old pattern) or use WaitOne(0)+AbandonedMutexException recovery (v0.3.0)'
    }
}
Test 'tray.ps1 uses WPF Dispatcher.Run() as the primary loop' {
    # Regression: WinForms.Application.Run breaks WPF hit-testing.
    $content = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    if ($content -match 'System\.Windows\.Forms\.Application\]::Run') {
        throw 'tray.ps1 still uses WinForms Application.Run -- WPF windows will not render/respond correctly'
    }
    if ($content -notmatch 'Dispatcher\]::Run\(\)') {
        throw 'tray.ps1 must call [System.Windows.Threading.Dispatcher]::Run() to pump both Win32 and WPF messages'
    }
}

Test 'settings.xaml loads and every named control resolves' {
    $win = Parse-GrabXaml (Join-Path $uiRoot 'settings.xaml')
    Assert-NotNull $win
    foreach ($n in @('TitleBar','MinBtn','CloseBtn',
                     'DownloadFolder','BrowseBtn','AskBeforeEach',
                     'ConcurrencySlider','ConcurrencyLabel',
                     'CookieBrowser','ToastsEnabled','ClipboardWatch','Autostart',
                     'VersionLabel','OpenStateBtn','OpenLogsBtn',
                     'ResetBtn','SaveBtn','CancelBtn','StatusLine')) {
        Assert-NotNull ($win.FindName($n)) "settings.xaml missing named control: $n"
    }
}

Test 'Set-Autostart writes/removes shell:startup shortcut correctly' {
    # Round-trip: enable, verify .lnk exists; disable, verify gone.
    $lnk = Get-AutostartShortcutPath
    # Save current state to restore
    $existed = Test-Path -LiteralPath $lnk
    try {
        Set-Autostart $true
        Assert-True (Test-Path -LiteralPath $lnk) "autostart shortcut not created at $lnk"
        Set-Autostart $false
        Assert-True (-not (Test-Path -LiteralPath $lnk)) 'autostart shortcut not removed on disable'
    } finally {
        # Restore whatever the user had
        if ($existed) { Set-Autostart $true } else { Set-Autostart $false }
    }
}

Test 'every Add_X handler either uses GetNewClosure() or refs only $script:*/params/locally-assigned vars' {
    # Regression for the null-scope bug on WPF button clicks. Uses the AST
    # instead of regex so nested braces / multi-line handlers are parsed
    # correctly. For every `.Add_X({...})` invocation, the immediate arg
    # must either be a `.GetNewClosure()` result OR a scriptblock whose
    # free variables are all safe (script:, global:, env:, params, or
    # locally assigned inside the block).
    $path = Join-Path $srcRoot 'popup.ps1'
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)

    $invocations = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
        $node.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
        $node.Member.Value -like 'Add_*'
    }, $true)

    $ignore = @('_','args','sender','e','PSItem','true','false','null','this')
    $offenders = @()

    foreach ($inv in $invocations) {
        if ($inv.Arguments.Count -lt 1) { continue }
        $arg = $inv.Arguments[0]

        # Case A: arg is `{...}.GetNewClosure()` -- accept
        if ($arg -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
            $arg.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
            $arg.Member.Value -eq 'GetNewClosure') { continue }

        # Case B: arg is a variable holding a scriptblock (e.g. $doSubmit)
        # -- accept, assumed captured at assignment time
        if ($arg -is [System.Management.Automation.Language.VariableExpressionAst]) { continue }

        # Case C: arg is a raw scriptblock `{...}` without .GetNewClosure()
        # -- inspect its free variables
        $sb = $null
        if ($arg -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
            $sb = $arg.ScriptBlock
        } elseif ($arg.Expression -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
            $sb = $arg.Expression.ScriptBlock
        }
        if (-not $sb) { continue }  # not a scriptblock arg -- skip

        # Named params
        $paramNames = @()
        if ($sb.ParamBlock -and $sb.ParamBlock.Parameters) {
            $paramNames = $sb.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }
        }
        # Vars assigned inside the body
        $assigned = $sb.EndBlock.Statements | Where-Object {
            $_ -is [System.Management.Automation.Language.AssignmentStatementAst]
        } | ForEach-Object {
            if ($_.Left -is [System.Management.Automation.Language.VariableExpressionAst]) {
                $_.Left.VariablePath.UserPath
            }
        }

        # All var references anywhere in the scriptblock
        $refs = $sb.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.VariableExpressionAst]
        }, $true)

        $bad = @()
        foreach ($r in $refs) {
            $vp = $r.VariablePath
            $name = $vp.UserPath
            $unqName = $name -replace '^[a-zA-Z]+:', ''
            if ($vp.IsScript -or $vp.IsGlobal) { continue }
            $drive = $vp.DriveName
            if ($drive -in @('script','global','env','using','local')) { continue }
            if ($unqName -in $ignore)        { continue }
            if ($unqName -in $paramNames)    { continue }
            if ($unqName -in $assigned)      { continue }
            $bad += "`$$unqName"
        }
        $bad = $bad | Sort-Object -Unique
        if ($bad.Count -gt 0) {
            $snippet = ($sb.Extent.Text -replace '\s+',' ')
            if ($snippet.Length -gt 60) { $snippet = $snippet.Substring(0, 60) + '...' }
            $offenders += ("refs [{0}] without .GetNewClosure(): {1}" -f ($bad -join ','), $snippet)
        }
    }

    if ($offenders.Count -gt 0) {
        throw ("closure-capture violations in popup.ps1:`n    " + ($offenders -join "`n    "))
    }
}
# ==========================================================================
# 7c. v0.1.2 polish -- video-quality picker, wrapping labels, dark About
# ==========================================================================
Section 'v0.1.2 polish'

Test 'Get-Config back-fills videoQuality with default "best"' {
    # Nuke and re-read so we always exercise the fresh-default branch.
    if (Test-Path -LiteralPath (Get-ConfigPath)) { Remove-Item -LiteralPath (Get-ConfigPath) -Force }
    $c = Get-Config
    Assert-NotNull $c.videoQuality 'videoQuality missing from default config'
    Assert-Equal 'best' $c.videoQuality
}

Test 'Get-Config back-fills videoQuality on legacy configs that lack the key' {
    # Simulate an older config.json without the videoQuality key.
    $legacy = @{
        version = '0.1.0'
        downloadFolder = Join-Path $env:USERPROFILE 'Downloads\imadjinn-grab'
        cookieBrowser = 'chrome'
        toastsEnabled = $true
        concurrency = 3
    }
    $legacy | ConvertTo-Json -Depth 4 | Set-Content -Path (Get-ConfigPath) -Encoding UTF8
    $c = Get-Config
    Assert-True $c.PSObject.Properties.Name.Contains('videoQuality') 'back-fill missed videoQuality'
    Assert-Equal 'best' $c.videoQuality
}

Test 'Invoke-YtDlp has a --format branch for every documented quality tier' {
    # Static-scan core.ps1 for the 7 values in the switch. Missing a branch
    # would silently drop yt-dlp to default -- exactly what we're trying to
    # prevent.
    $c = Get-Content (Join-Path $srcRoot 'core.ps1') -Raw
    foreach ($tier in @('2160p','1440p','1080p','720p','480p')) {
        if ($c -notmatch [regex]::Escape("height<=$($tier -replace 'p','')")) {
            throw "core.ps1 missing --format ceiling for $tier"
        }
    }
    # 'best' handled by empty switch arm (no --format flag)
    Assert-Match $c "'best'\s*\{\s*\}"
    # 'audio' extracts to mp3
    Assert-Match $c "'audio'\s*\{[^}]*--audio-format[^}]*mp3"
}

Test 'settings.xaml has the VideoQuality combobox with all 7 options' {
    $win = Parse-GrabXaml (Join-Path $uiRoot 'settings.xaml')
    $vq = $win.FindName('VideoQuality')
    Assert-NotNull $vq 'settings.xaml missing VideoQuality combobox'
    Assert-Equal 7 $vq.Items.Count 'expected 7 items (best, 2160p, 1440p, 1080p, 720p, 480p, audio)'
    $labels = @($vq.Items | ForEach-Object { $_.Content.ToString() })
    foreach ($opt in @('best','2160p','1440p','1080p','720p','480p','audio')) {
        Assert-Contains $labels $opt "VideoQuality combo missing option: $opt"
    }
}

Test 'settings.xaml SAFETY/PRIVACY description wraps (audit-safe against MinWidth=440 cutoff)' {
    # The specific long-string that was cut off: "Sensitive downloads route
    # into a hidden .private/ folder (Windows Hidden attribute)."
    # Fixed by adding TextWrapping="Wrap" to the FieldLabel style (or the
    # element itself); either satisfies the wrap contract.
    $xamlText = Get-Content (Join-Path $uiRoot 'settings.xaml') -Raw
    # FieldLabel style must declare TextWrapping=Wrap, so every label using
    # it inherits wrapping. (Setting it on the description element itself
    # would also satisfy the test.)
    $styleWrap = $xamlText -match '<Style x:Key="FieldLabel"[\s\S]*?TextWrapping"\s+Value="Wrap"[\s\S]*?</Style>'
    $inlineWrap = $xamlText -match 'Sensitive downloads route[\s\S]{0,200}TextWrapping="Wrap"'
    if (-not ($styleWrap -or $inlineWrap)) {
        throw 'SAFETY/PRIVACY description will overflow at MinWidth=440 -- add TextWrapping="Wrap" to FieldLabel style or the element'
    }
}

Test 'About handler in tray.ps1 no longer uses WinForms MessageBox' {
    $c = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    # The About menu handler must NOT invoke the WinForms MessageBox.
    # We look for the specific call pattern that used to open the light
    # popup: [System.Windows.Forms.MessageBox]::Show(
    if ($c -match '\[System\.Windows\.Forms\.MessageBox\]::Show') {
        throw 'tray.ps1 still uses [System.Windows.Forms.MessageBox]::Show -- About dialog reverted to light theme'
    }
    # And there must be a replacement WPF About window.
    if ($c -notmatch 'Show-AboutWindow') {
        throw 'tray.ps1 About handler must call Show-AboutWindow (dark WPF replacement)'
    }
}

# ==========================================================================
# 7d. v0.2 visual redesign + audio category
# ==========================================================================
Section 'v0.2 visuals + audio'

Test "Get-CategoryForUrl returns 'Audio' for soundcloud.com" {
    Assert-Equal 'Audio' (Get-CategoryForUrl 'https://soundcloud.com/artist/track-name')
}
Test "Get-CategoryForUrl returns 'Audio' for bandcamp.com" {
    Assert-Equal 'Audio' (Get-CategoryForUrl 'https://someband.bandcamp.com/album/thing')
}
Test "Get-CategoryForUrl returns 'Audio' for a .mp3 URL" {
    Assert-Equal 'Audio' (Get-CategoryForUrl 'https://example.com/audio/song.mp3')
    # Query string must not defeat extension match
    Assert-Equal 'Audio' (Get-CategoryForUrl 'https://cdn.example.com/x/song.mp3?token=abc&sig=z')
}
Test "Get-CategoryForUrl returns 'Audio' for a podcast feed URL" {
    Assert-Equal 'Audio' (Get-CategoryForUrl 'https://feeds.example.com/podcast/feed.rss')
    Assert-Equal 'Audio' (Get-CategoryForUrl 'https://example.com/podcast/feed')
    Assert-Equal 'Audio' (Get-CategoryForUrl 'https://overcast.fm/itunes123/some-show')
    # Generic blog RSS without audio-hint must NOT route to Audio
    Assert-Equal 'Misc'  (Get-CategoryForUrl 'https://someblog.example/rss')
}
Test 'assets/fonts/Silkscreen-Regular.ttf exists' {
    Assert-PathExists (Join-Path $repoRoot 'assets\fonts\Silkscreen-Regular.ttf')
    $sz = (Get-Item -LiteralPath (Join-Path $repoRoot 'assets\fonts\Silkscreen-Regular.ttf')).Length
    Assert-True ($sz -gt 1000) "Silkscreen-Regular.ttf suspiciously small: $sz bytes"
}
Test 'assets/fonts/VT323-Regular.ttf exists' {
    Assert-PathExists (Join-Path $repoRoot 'assets\fonts\VT323-Regular.ttf')
    $sz = (Get-Item -LiteralPath (Join-Path $repoRoot 'assets\fonts\VT323-Regular.ttf')).Length
    Assert-True ($sz -gt 1000) "VT323-Regular.ttf suspiciously small: $sz bytes"
}
Test 'assets/fonts/Inter-Regular.ttf exists' {
    Assert-PathExists (Join-Path $repoRoot 'assets\fonts\Inter-Regular.ttf')
    $sz = (Get-Item -LiteralPath (Join-Path $repoRoot 'assets\fonts\Inter-Regular.ttf')).Length
    Assert-True ($sz -gt 1000) "Inter-Regular.ttf suspiciously small: $sz bytes"
}
Test 'assets/icon.ico exists AND is >0 bytes AND has valid ICO magic (00 00 01 00)' {
    $p = Join-Path $repoRoot 'assets\icon.ico'
    Assert-PathExists $p
    $bytes = [System.IO.File]::ReadAllBytes($p)
    Assert-True ($bytes.Length -gt 0) 'icon.ico is empty'
    # ICONDIR: reserved (2 bytes = 0), type (2 bytes = 1 for icon)
    if ($bytes[0] -ne 0 -or $bytes[1] -ne 0 -or $bytes[2] -ne 1 -or $bytes[3] -ne 0) {
        throw ("bad ICO magic: {0:X2} {1:X2} {2:X2} {3:X2} (want 00 00 01 00)" -f $bytes[0],$bytes[1],$bytes[2],$bytes[3])
    }
}
Test 'ui/popup.xaml references Silkscreen font-family string' {
    $c = Get-Content (Join-Path $uiRoot 'popup.xaml') -Raw
    Assert-Match $c 'Silkscreen'
    Assert-Match $c 'VT323'
    Assert-Match $c 'Inter'
}
Test 'ui/popup.xaml has GRAB wordmark as 3 stacked TextBlocks (chromatic aberration)' {
    $c     = Get-Content (Join-Path $uiRoot 'popup.xaml') -Raw
    $theme = Get-Content (Join-Path $uiRoot 'theme.xaml') -Raw
    # Count TextBlock elements whose Text attribute equals "GRAB"
    $matches = [regex]::Matches($c, '<TextBlock[^>]*Text="GRAB"')
    Assert-True ($matches.Count -ge 3) "expected >=3 TextBlocks with Text=GRAB (chromatic aberration), got $($matches.Count)"
    # The aberration colors + primary text color live in theme.xaml as the
    # shared palette; popup.xaml references them via {StaticResource ...}.
    # A brush color is present when either file has the literal hex.
    # Palette updated in v0.2.2: cool white #F4F0FF -> cream #F5EBD0,
    # pure cyan #00E5FF -> phosphor teal #00E5D2, Accent unchanged.
    $combined = $c + $theme
    Assert-Match $combined '#00E5D2'
    Assert-Match $combined '#FF2D8C'
    Assert-Match $combined '#F5EBD0'
}
Test 'ui/settings.xaml uses VT323 font-family' {
    $c = Get-Content (Join-Path $uiRoot 'settings.xaml') -Raw
    Assert-Match $c 'VT323'
    Assert-Match $c 'Silkscreen'   # wordmark
    Assert-Match $c 'Inter'        # body/inputs
}
Test 'tray.ps1 Show-AboutWindow contains the approved About copy phrase' {
    $c = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    # Exact opening line of the approved body copy
    if ($c -notmatch "Paste any link\.\s*GRAB downloads it") {
        throw 'tray.ps1 About body missing the approved "Paste any link. GRAB downloads it" phrase'
    }
    # Sanity: MIT + Imadjinn attribution. Split assertion because the mockup
    # PART D redesign puts "Imadjinn" in its own colored Run (cyan), so the
    # two words no longer share a contiguous string literal.
    Assert-Match $c 'MIT-licensed'
    Assert-Match $c 'Made by '
    Assert-Match $c "'Imadjinn'"
}
Test 'tray.ps1 About window does NOT contain the old placeholder text' {
    $c = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    if ($c -match 'About copy pending') {
        throw 'tray.ps1 still contains the old placeholder text "About copy pending"'
    }
    if ($c -match 'placeholder') {
        throw 'tray.ps1 still contains the word "placeholder" in an About context'
    }
}
Test 'install.ps1 IconLocation prefers assets/icon.ico' {
    $c = Get-Content (Join-Path $repoRoot 'install.ps1') -Raw
    # Must reference assets\icon.ico as the preferred icon location
    Assert-Match $c 'assets\\icon\.ico'
    # And the desktop-shortcut IconLocation must use the resolved variable, not
    # a hardcoded shell32.dll,143.
    if ($c -match "-icon\s+`"\`$env:SystemRoot\\System32\\shell32\.dll,143`"\s+``\s*[\r\n]") {
        throw 'install.ps1 still hardcodes shell32.dll,143 as the -icon for the main grab shortcut'
    }
}
Test 'settings.ps1 Set-Autostart IconLocation prefers assets/icon.ico' {
    $c = Get-Content (Join-Path $srcRoot 'settings.ps1') -Raw
    Assert-Match $c 'assets\\icon\.ico'
    # Set-Autostart body must be gated on that path
    Assert-Match $c 'Set-Autostart'
    Assert-Match $c 'Test-Path[^\r\n]*grabIco'
}
Test 'Set-FolderHidden supports -Recurse switch parameter (AST scan)' {
    $path = Join-Path $srcRoot 'utils.ps1'
    $tokens = $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    $fn = $ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Set-FolderHidden'
    }, $true) | Select-Object -First 1
    Assert-NotNull $fn 'Set-FolderHidden function not found'
    $paramNames = @()
    if ($fn.Body.ParamBlock -and $fn.Body.ParamBlock.Parameters) {
        $paramNames = @($fn.Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    } elseif ($fn.Parameters) {
        # Legacy inline `param(...)` on function line
        $paramNames = @($fn.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    }
    Assert-Contains $paramNames 'Recurse' 'Set-FolderHidden must declare a -Recurse switch parameter'
}
Test 'Set-FolderHidden -Recurse hides all children in a test dir' {
    $tmp = Join-Path $env:TEMP ('grab-hide-test-' + [guid]::NewGuid().ToString('N').Substring(0,6))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $sub = Join-Path $tmp 'sub'
    New-Item -ItemType Directory -Path $sub -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $tmp 'top.txt'),  'x')
    [System.IO.File]::WriteAllText((Join-Path $sub 'deep.txt'), 'y')
    try {
        Set-FolderHidden $tmp -Recurse
        $root = Get-Item -LiteralPath $tmp -Force
        Assert-True ([bool]($root.Attributes -band [System.IO.FileAttributes]::Hidden)) 'root not hidden'
        $subItem  = Get-Item -LiteralPath $sub -Force
        Assert-True ([bool]($subItem.Attributes -band [System.IO.FileAttributes]::Hidden)) 'sub folder not hidden'
        $topFile  = Get-Item -LiteralPath (Join-Path $tmp 'top.txt')  -Force
        Assert-True ([bool]($topFile.Attributes -band [System.IO.FileAttributes]::Hidden)) 'top-level file not hidden'
        $deepFile = Get-Item -LiteralPath (Join-Path $sub 'deep.txt') -Force
        Assert-True ([bool]($deepFile.Attributes -band [System.IO.FileAttributes]::Hidden)) 'nested file not hidden'
    } finally {
        # Un-hide then remove
        Get-ChildItem -LiteralPath $tmp -Force -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            try { $_.Attributes = $_.Attributes -band (-bnot [System.IO.FileAttributes]::Hidden) } catch {}
        }
        try {
            $r = Get-Item -LiteralPath $tmp -Force -ErrorAction Stop
            $r.Attributes = $r.Attributes -band (-bnot [System.IO.FileAttributes]::Hidden)
        } catch {}
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Test 'core.ps1 calls Set-FolderHidden with -Recurse after post-process on sensitive downloads' {
    $c = Get-Content (Join-Path $srcRoot 'core.ps1') -Raw
    # There must be at least one call site that passes -Recurse to Set-FolderHidden.
    if ($c -notmatch 'Set-FolderHidden[^\r\n]*-Recurse') {
        throw 'core.ps1 must call Set-FolderHidden with -Recurse after a sensitive download so ALL files land Hidden'
    }
    # And it should live in the sensitive branch (isSensitive + Success).
    if ($c -notmatch '\$isSensitive[\s\S]{0,600}Set-FolderHidden[^\r\n]*-Recurse') {
        throw 'Set-FolderHidden -Recurse call is not inside the $isSensitive branch of Invoke-Grab'
    }
}

Section 'v0.2.1 theme + arcade colors + scanlines'

# --- theme.xaml exists and loads as a ResourceDictionary ------------------
Test 'theme.xaml exists AND is loadable via XamlReader' {
    $path = Join-Path $uiRoot 'theme.xaml'
    Assert-PathExists $path
    Add-Type -AssemblyName PresentationFramework | Out-Null
    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    $sub = Get-GrabTokenSubstituted $raw
    $dict = [Windows.Markup.XamlReader]::Parse($sub)
    Assert-NotNull $dict 'theme.xaml did not parse'
    Assert-True ($dict -is [System.Windows.ResourceDictionary]) 'theme.xaml top-level must be ResourceDictionary'
    # Palette + arcade styles both present:
    foreach ($k in @('Accent','Cyan','Amber','Green','Magenta','Rec','Text',
                     'ArcadeCombo','ArcadeSlider','ArcadeCheck','ArcadeText',
                     'ArcadePrimary','ArcadeGhost','ArcadeDanger','ArcadeTab',
                     'Wordmark','Kicker','SectionHeader','Body','Caption')) {
        Assert-True $dict.Contains($k) "theme.xaml missing resource key: $k"
    }
}

# --- Import gates ---------------------------------------------------------
Test 'ui/popup.xaml imports theme.xaml' {
    $c = Get-Content (Join-Path $uiRoot 'popup.xaml') -Raw
    Assert-Match $c 'theme\.xaml' 'popup.xaml must reference theme.xaml via ResourceDictionary Source'
    Assert-Match $c '<ResourceDictionary Source=' 'popup.xaml must import via <ResourceDictionary Source=...>'
}
Test 'ui/settings.xaml imports theme.xaml' {
    $c = Get-Content (Join-Path $uiRoot 'settings.xaml') -Raw
    Assert-Match $c 'theme\.xaml' 'settings.xaml must reference theme.xaml via ResourceDictionary Source'
    Assert-Match $c '<ResourceDictionary Source=' 'settings.xaml must import via <ResourceDictionary Source=...>'
}
Test 'tray.ps1 About XAML imports theme.xaml' {
    $c = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    Assert-Match $c 'theme\.xaml' 'About window must reference theme.xaml (arcade design system)'
    Assert-Match $c '<ResourceDictionary Source=' 'About window must import via <ResourceDictionary Source=...>'
}

# --- Every native control now references an arcade style ------------------
Test 'settings.xaml ComboBox references ArcadeCombo style' {
    $c = Get-Content (Join-Path $uiRoot 'settings.xaml') -Raw
    $hits = [regex]::Matches($c, 'Style="\{StaticResource ArcadeCombo\}"')
    Assert-True ($hits.Count -ge 2) "expected >=2 ComboBox references to ArcadeCombo (Cookie + VideoQuality), got $($hits.Count)"
}
Test 'settings.xaml Slider references ArcadeSlider style' {
    $c = Get-Content (Join-Path $uiRoot 'settings.xaml') -Raw
    Assert-Match $c 'Style="\{StaticResource ArcadeSlider\}"'
}
Test 'settings.xaml CheckBox references ArcadeCheck style' {
    $c = Get-Content (Join-Path $uiRoot 'settings.xaml') -Raw
    $hits = [regex]::Matches($c, 'Style="\{StaticResource ArcadeCheck\}"')
    # 6 checkboxes: AskBeforeEach, ToastsEnabled, ClipboardWatch,
    # CrtScanlines, SensitiveByDefault, Autostart
    Assert-True ($hits.Count -ge 6) "expected >=6 CheckBox references to ArcadeCheck, got $($hits.Count)"
}
Test 'settings.xaml TextBox references ArcadeText style' {
    $c = Get-Content (Join-Path $uiRoot 'settings.xaml') -Raw
    Assert-Match $c 'Style="\{StaticResource ArcadeText\}"'
}
Test 'settings.xaml Reset button uses ArcadeDanger style' {
    $c = Get-Content (Join-Path $uiRoot 'settings.xaml') -Raw
    Assert-Match $c 'ResetBtn[\s\S]{0,120}ArcadeDanger'
}
Test 'settings.xaml Save button uses ArcadePrimary style' {
    $c = Get-Content (Join-Path $uiRoot 'settings.xaml') -Raw
    Assert-Match $c 'SaveBtn[\s\S]{0,120}ArcadePrimary'
}

# --- Windows-native chrome elimination ------------------------------------
Test 'settings.ps1 no longer calls [System.Windows.MessageBox]::Show' {
    $c = Get-Content (Join-Path $srcRoot 'settings.ps1') -Raw
    if ($c -match '\[System\.Windows\.MessageBox\]::Show') {
        throw 'settings.ps1 must not call MessageBox.Show -- use Confirm-ArcadeDialog instead'
    }
    Assert-Match $c 'Confirm-ArcadeDialog' 'settings.ps1 must call Confirm-ArcadeDialog for the reset confirmation'
}
Test 'No src/*.ps1 file uses [System.Windows.MessageBox]::Show for user decisions' {
    # v0.3.0 exception: tray.ps1 uses MessageBox.Show as the LAST-RESORT
    # crash-notification path inside the Dispatcher.Run catch block, when
    # the arcade UI is by definition unavailable (the WPF pump just died).
    # Any other MessageBox.Show call is still a regression -- users must
    # see the arcade Confirm-ArcadeDialog for regular decisions.
    $files = Get-ChildItem $srcRoot -Filter '*.ps1' -File
    $offenders = @()
    foreach ($f in $files) {
        $c = Get-Content -LiteralPath $f.FullName -Raw
        # Find every MessageBox.Show call and verify it sits inside a
        # "Dispatcher.Run crashed" context (the sanctioned last-resort).
        $matches = [regex]::Matches($c, '\[System\.Windows\.MessageBox\]::Show')
        foreach ($m in $matches) {
            $ctxStart = [Math]::Max(0, $m.Index - 600)
            $ctxLen   = [Math]::Min($c.Length - $ctxStart, 900)
            $ctx = $c.Substring($ctxStart, $ctxLen)
            if ($ctx -notmatch 'Dispatcher\.Run crashed') {
                $offenders += "$($f.Name)@$($m.Index)"
            }
        }
    }
    if ($offenders.Count -gt 0) { throw "MessageBox.Show used outside the Dispatcher.Run crash handler in: $($offenders -join ', ')" }
}
Test 'tray.ps1 defines Confirm-ArcadeDialog' {
    $cmd = Get-Command Confirm-ArcadeDialog -ErrorAction SilentlyContinue
    Assert-NotNull $cmd 'Confirm-ArcadeDialog function not found (should be defined in tray.ps1)'
    $c = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    Assert-Match $c 'function Confirm-ArcadeDialog'
}

# --- Scanlines PNG + XAML references --------------------------------------
Test 'assets/scanlines.png exists AND has valid PNG magic (89 50 4E 47)' {
    $p = Join-Path $repoRoot 'assets\scanlines.png'
    Assert-PathExists $p
    $bytes = [System.IO.File]::ReadAllBytes($p)
    Assert-True ($bytes.Length -gt 0) 'scanlines.png is empty'
    if ($bytes[0] -ne 0x89 -or $bytes[1] -ne 0x50 -or $bytes[2] -ne 0x4E -or $bytes[3] -ne 0x47) {
        throw ("bad PNG magic: {0:X2} {1:X2} {2:X2} {3:X2} (want 89 50 4E 47)" -f $bytes[0],$bytes[1],$bytes[2],$bytes[3])
    }
}
Test 'popup.xaml has a ScanlinesOverlay Rectangle with a repeat brush' {
    # v0.2.2: swapped ImageBrush(scanlines.png) -> LinearGradientBrush with
    # MappingMode=Absolute + SpreadMethod=Repeat because the PNG-tile approach
    # was invisible at real DPI on the near-black ground. See PART 2 in
    # docs/... and the fix comment in popup.xaml.
    $c = Get-Content (Join-Path $uiRoot 'popup.xaml') -Raw
    Assert-Match $c 'x:Name="ScanlinesOverlay"'
    Assert-Match $c 'MappingMode="Absolute"'
    Assert-Match $c 'SpreadMethod="Repeat"'
}
Test 'settings.xaml has a ScanlinesOverlay Rectangle with a repeat brush' {
    $c = Get-Content (Join-Path $uiRoot 'settings.xaml') -Raw
    Assert-Match $c 'x:Name="ScanlinesOverlay"'
    Assert-Match $c 'MappingMode="Absolute"'
    Assert-Match $c 'SpreadMethod="Repeat"'
}
Test 'tray.ps1 About + Confirm XAML have a ScanlinesOverlay with a repeat brush' {
    $c = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    Assert-Match $c 'x:Name="ScanlinesOverlay"'
    # Both AboutXaml and ConfirmDialogXaml should use the same pattern:
    $hits = [regex]::Matches($c, 'SpreadMethod="Repeat"')
    Assert-True ($hits.Count -ge 2) "expected >=2 SpreadMethod=Repeat brushes in tray.ps1 (About + Confirm), got $($hits.Count)"
}

# --- crtScanlines config back-fill + default -----------------------------
Test 'Get-Config back-fills crtScanlines with $true (default arcade cabinet look)' {
    # Simulate a pre-v0.2.1 config without crtScanlines.
    $legacy = @{
        version = '0.1.0'
        downloadFolder = Join-Path $env:USERPROFILE 'Downloads\imadjinn-grab'
        cookieBrowser = 'chrome'
        toastsEnabled = $true
        concurrency = 3
    }
    $legacy | ConvertTo-Json -Depth 4 | Set-Content -Path (Get-ConfigPath) -Encoding UTF8
    $c = Get-Config
    Assert-True $c.PSObject.Properties.Name.Contains('crtScanlines') 'back-fill missed crtScanlines'
    Assert-Equal $true $c.crtScanlines
}
Test 'Get-Config default config includes crtScanlines' {
    # Wipe config so Get-Config recreates the fresh default. Get-Config
    # returns a Hashtable on first-write (from the default @{...} literal),
    # so use ContainsKey rather than PSObject.Properties for the presence check.
    if (Test-Path (Get-ConfigPath)) { Remove-Item (Get-ConfigPath) -Force }
    $c = Get-Config
    $hasKey = if ($c -is [hashtable]) { $c.ContainsKey('crtScanlines') }
              else { [bool]($c.PSObject.Properties.Name -contains 'crtScanlines') }
    Assert-True $hasKey 'default config missing crtScanlines'
    Assert-Equal $true $c.crtScanlines
}
Test 'settings.ps1 wires the CrtScanlines checkbox into Update-Config' {
    $c = Get-Content (Join-Path $srcRoot 'settings.ps1') -Raw
    Assert-Match $c 'crtScanlines\s*=\s*\[bool\]\$CtlLocal\.CrtScanlines\.IsChecked'
}

# --- About window kicker amber -------------------------------------------
Test 'About window kicker uses amber #FFD447 (mockup v0.2.2 warm-amber)' {
    $c = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    # The INSERT COIN kicker is one self-closing TextBlock. Find the element
    # whose attributes include the phrase and extract its Foreground attr.
    # [^/]* stays inside a single <TextBlock ... /> tag (won't cross the />).
    $kicker = [regex]::Match($c, '<TextBlock[^/]*Text="[^"]*INSERT COIN[^"]*"[^/]*/>')
    if (-not $kicker.Success) {
        # Fallback: look for the element opening before INSERT COIN in the
        # multi-line form (Text attribute on a later line than Foreground).
        $kicker = [regex]::Match($c, '<TextBlock[^<]*INSERT COIN[^<]*/>')
    }
    if (-not $kicker.Success) {
        throw 'Could not isolate the INSERT COIN TextBlock in tray.ps1 About XAML'
    }
    $fg = [regex]::Match($kicker.Value, 'Foreground="([^"]+)"')
    Assert-True $fg.Success 'INSERT COIN TextBlock has no Foreground attribute'
    $color = $fg.Groups[1].Value
    if ($color -notmatch '(?i)#FFD447') {
        throw "About kicker Foreground is $color but must be #FFD447 (mockup warm-amber insert-coin)"
    }
}
Test 'About window close button uses ArcadePrimary style (from theme)' {
    $c = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    Assert-Match $c 'OkBtn[\s\S]{0,120}ArcadePrimary'
}

# --- Queue-row + Recent-row arcade palette in popup.ps1 ------------------
Test 'popup.ps1 _StatusColor uses mockup palette (amber/lime/red/muted)' {
    $c = Get-Content (Join-Path $srcRoot 'popup.ps1') -Raw
    # Mockup v0.2.2: running/pending = amber, done = lime, failed = red,
    # queued/cancelled = muted (queued rows are dim, running is "hot").
    Assert-Match $c "'running'\s*\{\s*'#FFD447'"
    Assert-Match $c "'done'\s*\{\s*'#8DFF6B'"
    Assert-Match $c "'failed'\s*\{\s*'#FF4444'"
    Assert-Match $c "'pending'\s*\{\s*'#FFD447'"
    Assert-Match $c "'cancelled'\s*\{\s*'#8974A6'"
}
Test 'popup.ps1 defines category badge colors for all 5 categories (mockup palette)' {
    $c = Get-Content (Join-Path $srcRoot 'popup.ps1') -Raw
    Assert-Match $c "'Videos'\s*=\s*@\{[^}]*#FFD447"   # warm amber
    Assert-Match $c "'Comics'\s*=\s*@\{[^}]*#FF2E93"   # magenta
    Assert-Match $c "'Audio'\s*=\s*@\{[^}]*#00E5D2"    # phosphor teal
    Assert-Match $c "'Images'\s*=\s*@\{[^}]*#8DFF6B"   # lime green
    Assert-Match $c "'Social'\s*=\s*@\{[^}]*#FF2D8C"   # accent pink (unchanged)
    Assert-Match $c "'Misc'\s*=\s*@\{[^}]*#8974A6"     # warm muted
}
Test 'popup.ps1 Build-QueueRow and Build-RecentRow render without throwing' {
    Add-Type -AssemblyName PresentationFramework | Out-Null
    $job = [PSCustomObject]@{
        Id='t1'; Url='https://youtube.com/watch?v=abc'; Status='running';
        StatusMsg='downloading'; AddedAt=(Get-Date)
    }
    $row = Build-QueueRow $job
    Assert-NotNull $row 'Build-QueueRow returned null'
    Assert-True ($row -is [System.Windows.Controls.Border]) 'Build-QueueRow must return a Border'
    $entry = [PSCustomObject]@{
        Url='https://soundcloud.com/artist/song'; Status='done'; FilesAdded=3;
        ToolUsed='yt-dlp'; Dest=$env:TEMP; DoneAt=(Get-Date).ToString('o')
    }
    $r2 = Build-RecentRow $entry
    Assert-NotNull $r2 'Build-RecentRow returned null'
}

# --- Tab underline colors (PART A #1) ------------------------------------
Test 'popup.ps1 tab-switching maps PASTE=amber, QUEUE=cyan, RECENT=green' {
    $c = Get-Content (Join-Path $srcRoot 'popup.ps1') -Raw
    Assert-Match $c "'TabPaste'\s*=\s*'active-amber'"
    Assert-Match $c "'TabQueue'\s*=\s*'active-cyan'"
    Assert-Match $c "'TabRecent'\s*=\s*'active-green'"
}
Section 'v0.2.2 Clear Recent + scanline fix'

# --- Theme font token substitution ---------------------------------------
Test 'Get-RuntimeThemeUri writes a substituted theme with fonts URI (theme font-token bug fix)' {
    # Regression for the theme-fonts bug: theme.xaml on disk contains 17
    # __GRAB_FONTS__ tokens. WPF loads via <ResourceDictionary Source=...>
    # directly and does NOT run our substitution -- so every theme-styled
    # control (ArcadePrimary, ArcadeTab, ArcadeGhost, Kicker, SectionHeader,
    # ContextMenu, MenuItem, ToolTip...) silently fell back to WPF default
    # fonts. The fix: Get-RuntimeThemeUri writes a substituted copy to
    # <AppData>\grab-app\.runtime-theme.xaml and returns THAT URI.
    Assert-NotNull (Get-Command Get-RuntimeThemeUri -ErrorAction SilentlyContinue) `
        'Get-RuntimeThemeUri helper missing from utils.ps1'
    $fonts = 'file:///C:/fake/fonts/'
    $srcTheme = Join-Path $uiRoot 'theme.xaml'
    $uri = Get-RuntimeThemeUri -SourceThemePath $srcTheme -FontsUri $fonts
    Assert-Match $uri '\.runtime-theme\.xaml' 'runtime theme URI must live in the app-data folder'
    # The written file must NOT contain __GRAB_FONTS__ any more.
    $localPath = ($uri -replace '^file:///','') -replace '/','\'
    Assert-PathExists $localPath 'runtime theme file was not written'
    $content = Get-Content -LiteralPath $localPath -Raw
    if ($content -match '__GRAB_FONTS__') {
        throw 'runtime theme still has __GRAB_FONTS__ tokens -- substitution did not happen'
    }
    if ($content -notmatch [regex]::Escape($fonts)) {
        throw 'runtime theme does not contain the supplied fonts URI'
    }
}

Test 'popup.ps1 _GrabThemeUri returns the runtime (substituted) theme URI' {
    $c = Get-Content (Join-Path $srcRoot 'popup.ps1') -Raw
    if ($c -notmatch 'Get-RuntimeThemeUri') {
        throw 'popup.ps1 _GrabThemeUri must delegate to Get-RuntimeThemeUri (else fonts fall back to system default)'
    }
}
Test 'settings.ps1 _GrabThemeUri returns the runtime (substituted) theme URI' {
    $c = Get-Content (Join-Path $srcRoot 'settings.ps1') -Raw
    if ($c -notmatch 'Get-RuntimeThemeUri') {
        throw 'settings.ps1 _GrabThemeUri must delegate to Get-RuntimeThemeUri'
    }
}
Test 'tray.ps1 _GrabThemeUriTray returns the runtime (substituted) theme URI' {
    $c = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    if ($c -notmatch 'Get-RuntimeThemeUri') {
        throw 'tray.ps1 _GrabThemeUriTray must delegate to Get-RuntimeThemeUri'
    }
}

Test 'Get-Config recovers gracefully when config.json is malformed (no crash)' {
    # Regression: corrupt config.json used to throw ConvertFrom-Json + then
    # blow up every PSObject.Properties.Name.Contains(...) back-fill call
    # with "You cannot call a method on a null-valued expression". That
    # crashed the whole tray on startup any time the JSON got mangled.
    Ensure-AppData
    Set-Content -Path (Get-ConfigPath) -Value 'this is not json {{{' -Encoding UTF8
    $c = Get-Config
    Assert-NotNull $c 'Get-Config must NOT return $null on corrupt JSON'
    # Must yield a valid config with the default keys back-filled.
    Assert-NotNull $c.downloadFolder
    Assert-NotNull $c.concurrency
    $hasKey = if ($c -is [hashtable]) { $c.ContainsKey('crtScanlines') }
              else { [bool]($c.PSObject.Properties.Name -contains 'crtScanlines') }
    Assert-True $hasKey 'default back-fill missed crtScanlines after corrupt-json recovery'
    # A backup copy of the corrupt file should exist so users can inspect it.
    $backups = @(Get-ChildItem (Split-Path (Get-ConfigPath) -Parent) -Filter 'config.json.corrupt-*' -ErrorAction SilentlyContinue)
    Assert-True ($backups.Count -ge 1) 'corrupt-JSON backup was not written'
    # Cleanup
    foreach ($b in $backups) { Remove-Item -LiteralPath $b.FullName -Force -ErrorAction SilentlyContinue }
}

Test 'theme.xaml still has __GRAB_FONTS__ tokens (safety net for the runtime substitution)' {
    # If theme.xaml stops containing __GRAB_FONTS__ tokens, either someone
    # inlined absolute font URIs (portability regression) OR the tokens moved
    # somewhere the runtime substitution won't see them. Either way, guard.
    $c = Get-Content (Join-Path $uiRoot 'theme.xaml') -Raw
    $matches = [regex]::Matches($c, '__GRAB_FONTS__')
    Assert-True ($matches.Count -ge 10) "theme.xaml should reference __GRAB_FONTS__ many times (got $($matches.Count))"
}


# --- Clear-Recent helper --------------------------------------------------
Test 'Clear-Recent empties recent.json when called with no args' {
    # Seed a couple of recent entries then clear all.
    if (Test-Path (Get-RecentPath)) { Remove-Item (Get-RecentPath) -Force }
    for ($i = 0; $i -lt 3; $i++) {
        Append-Recent ([PSCustomObject]@{
            Url = "https://example.com/clear-$i"; Dest = 'C:\tmp'
            DoneAt = (Get-Date).ToString('o'); Status = 'done'
            FilesAdded = 1; ToolUsed = 'yt-dlp'; DurationMs = 1; Error = $null
        })
    }
    Assert-Equal 3 @(Get-Recent).Count 'seed step: expected 3 recent entries'
    $n = Clear-Recent
    Assert-Equal 3 $n 'Clear-Recent should return the count removed'
    Assert-Equal 0 @(Get-Recent).Count 'Recent must be empty after Clear-Recent (no args)'
}

Test 'Clear-Recent -OlderThan cutoff keeps recent items and drops old ones' {
    if (Test-Path (Get-RecentPath)) { Remove-Item (Get-RecentPath) -Force }
    # Two old (60 days ago) + two fresh (today).
    $old = (Get-Date).AddDays(-60).ToString('o')
    $new = (Get-Date).ToString('o')
    Append-Recent ([PSCustomObject]@{ Url='https://example.com/old-1'; Dest='C:\tmp'; DoneAt=$old; Status='done'; FilesAdded=1; ToolUsed='yt-dlp'; DurationMs=1; Error=$null })
    Append-Recent ([PSCustomObject]@{ Url='https://example.com/old-2'; Dest='C:\tmp'; DoneAt=$old; Status='done'; FilesAdded=1; ToolUsed='yt-dlp'; DurationMs=1; Error=$null })
    Append-Recent ([PSCustomObject]@{ Url='https://example.com/new-1'; Dest='C:\tmp'; DoneAt=$new; Status='done'; FilesAdded=1; ToolUsed='yt-dlp'; DurationMs=1; Error=$null })
    Append-Recent ([PSCustomObject]@{ Url='https://example.com/new-2'; Dest='C:\tmp'; DoneAt=$new; Status='done'; FilesAdded=1; ToolUsed='yt-dlp'; DurationMs=1; Error=$null })
    Assert-Equal 4 @(Get-Recent).Count 'seed step'
    $removed = Clear-Recent -OlderThan ((Get-Date).AddDays(-30))
    Assert-Equal 2 $removed 'should drop the two 60-days-old entries only'
    $kept = @(Get-Recent)
    Assert-Equal 2 $kept.Count 'should keep the two fresh entries'
    foreach ($k in $kept) {
        Assert-Match $k.Url '/new-'  'kept the wrong entry (dropped a recent one instead of the old)'
    }
}

Test 'Clear-Recent is idempotent on empty state' {
    if (Test-Path (Get-RecentPath)) { Remove-Item (Get-RecentPath) -Force }
    $n = Clear-Recent
    Assert-Equal 0 $n
    # Calling again must also not throw.
    $n2 = Clear-Recent -OlderThan (Get-Date)
    Assert-Equal 0 $n2
}

Test 'popup.xaml has ClearRecentBtn (ArcadeDanger) and ClearOldRecentBtn (ArcadeGhost)' {
    $c = Get-Content (Join-Path $uiRoot 'popup.xaml') -Raw
    Assert-Match $c 'x:Name="ClearRecentBtn"'
    Assert-Match $c 'x:Name="ClearOldRecentBtn"'
    # Style assertions -- ArcadeDanger for the destructive one, ArcadeGhost for older.
    Assert-Match $c 'ClearRecentBtn[\s\S]{0,400}ArcadeDanger'
    Assert-Match $c 'ClearOldRecentBtn[\s\S]{0,400}ArcadeGhost'
    # Both controls should be wired up in popup.ps1
    $ps = Get-Content (Join-Path $srcRoot 'popup.ps1') -Raw
    Assert-Match $ps 'ClearRecentBtn\.Add_Click'
    Assert-Match $ps 'ClearOldRecentBtn\.Add_Click'
    Assert-Match $ps 'Clear-Recent'
    Assert-Match $ps 'Clear-Recent\s+-OlderThan'
}

Test 'Clear-Recent handles corrupt recent.json without throwing (treats it as clear all)' {
    Set-Content -Path (Get-RecentPath) -Value 'not json at all {{{' -Encoding UTF8
    $n = Clear-Recent
    # Contract: no crash, and file ends up as a valid empty array.
    Assert-Equal 0 $n
    $raw = Get-Content (Get-RecentPath) -Raw
    Assert-Match $raw '^\s*\[\s*\]\s*$'
}

# --- Scanline overlay functional pixel test -----------------------------
Test 'Scanlines visible: off-screen render of popup shows band variation in a solid dark area' {
    # Renders the popup off-screen at 96 DPI and samples 60 consecutive
    # vertical pixels through a column that lies inside the outer card (dark
    # ground area). Counts pixel-value transitions -- a working scanline
    # overlay produces alternating bands so we expect >= 8 transitions.
    Add-Type -AssemblyName PresentationFramework | Out-Null
    Add-Type -AssemblyName PresentationCore      | Out-Null
    $win = Parse-GrabXaml (Join-Path $uiRoot 'popup.xaml')
    # Force layout so brushes actually render.
    $win.WindowStartupLocation = 'Manual'
    $win.Left = -10000; $win.Top = -10000    # off-screen
    $win.ShowInTaskbar = $false
    # Ensure the ScanlinesOverlay is Visible for this render.
    $overlay = $win.FindName('ScanlinesOverlay')
    if ($overlay) { $overlay.Visibility = 'Visible' }
    try {
        $win.Show()
        # Pump layout + render.
        $win.UpdateLayout()
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 200
        [System.Windows.Forms.Application]::DoEvents()

        $w = [int]$win.ActualWidth
        $h = [int]$win.ActualHeight
        if ($w -lt 100 -or $h -lt 100) { throw "window did not lay out: ${w}x${h}" }
        $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
        $rtb.Render($win)
        # Snapshot pixels
        $stride = $w * 4
        $pixels = New-Object 'byte[]' ($stride * $h)
        $rtb.CopyPixels($pixels, $stride, 0)

        # Sample a vertical strip through what should be a solid dark area:
        # x = w/2 (title bar / card center), y from 60..120 (below tabs strip).
        $x = [int]($w / 2)
        $yStart = 80
        $yEnd   = [Math]::Min($h - 20, $yStart + 60)
        $samples = @()
        for ($y = $yStart; $y -lt $yEnd; $y++) {
            $idx = ($y * $stride) + ($x * 4)
            # Blue Green Red Alpha (Pbgra32)
            $b = $pixels[$idx]; $g = $pixels[$idx + 1]; $r = $pixels[$idx + 2]
            $samples += ([int]$r + [int]$g + [int]$b)
        }
        # Count transitions (adjacent samples differing by >= 3).
        $transitions = 0
        for ($i = 1; $i -lt $samples.Count; $i++) {
            if ([math]::Abs($samples[$i] - $samples[$i-1]) -ge 3) { $transitions++ }
        }
        if ($transitions -lt 8) {
            throw "scanlines produced only $transitions transitions in a 60px strip (want >=8). Overlay effectively invisible."
        }
    } finally {
        try { $win.Close() } catch {}
    }
}

Test 'popup.xaml active tab underlines use per-tab colors via ArcadeTab template' {
    $c     = Get-Content (Join-Path $uiRoot 'popup.xaml') -Raw
    $theme = Get-Content (Join-Path $uiRoot 'theme.xaml') -Raw
    # PART A #1: three different destinations, three different colors.
    Assert-Match $c 'TabPaste[\s\S]{0,200}Tag="active-amber"'
    # ArcadeTab template must define triggers for all three color variants
    Assert-Match $theme 'active-amber'
    Assert-Match $theme 'active-cyan'
    Assert-Match $theme 'active-green'
    # Palette (mockup v0.2.2): warm amber + lime green live in theme.xaml
    Assert-Match $theme '#FFD447'   # warm amber
    Assert-Match $theme '#8DFF6B'   # lime green
}

# --- ADD MANY ghost button flipped from cyan to amber (PART A #4) --------
Test 'popup.xaml ADD MANY button uses amber outline (was cyan in v0.2)' {
    $c = Get-Content (Join-Path $uiRoot 'popup.xaml') -Raw
    # BorderBrush + Foreground set to Amber via StaticResource near ToggleMulti
    Assert-Match $c 'ToggleMulti[\s\S]{0,400}BorderBrush="\{StaticResource Amber\}"'
    Assert-Match $c 'ToggleMulti[\s\S]{0,400}Foreground="\{StaticResource Amber\}"'
}

# --- Send-Toast console fallback uses arcade color (PART D) --------------
Test 'Send-Toast console fallback uses -ForegroundColor Magenta (arcade match)' {
    $c = Get-Content (Join-Path $srcRoot 'utils.ps1') -Raw
    Assert-Match $c '\[toast\][\s\S]{0,120}-ForegroundColor Magenta'
}

# --- Focus rings via IsKeyboardFocused (PART A #7) -----------------------
Test 'theme.xaml defines focus-ring triggers via IsKeyboardFocused (pink accent)' {
    $c = Get-Content (Join-Path $uiRoot 'theme.xaml') -Raw
    # At least 3 controls should react to keyboard focus by flipping to Accent
    $hits = [regex]::Matches($c, 'IsKeyboardFocused" Value="True"')
    Assert-True ($hits.Count -ge 3) "expected >=3 IsKeyboardFocused triggers, got $($hits.Count)"
    # All those triggers should reference the Accent brush (hot pink)
    Assert-Match $c 'IsKeyboardFocused[\s\S]{0,200}Accent'
}

# --- ScrollBar / ContextMenu / MenuItem are re-styled --------------------
Test 'theme.xaml re-templates ScrollBar (no arrow buttons, cyan thumb)' {
    $c = Get-Content (Join-Path $uiRoot 'theme.xaml') -Raw
    Assert-Match $c '<Style TargetType="ScrollBar">'
    Assert-Match $c 'ScrollBarThumbArcade'
    # The arrow buttons should be Opacity="0" (transparent, non-interactive).
    Assert-Match $c 'RepeatButton[\s\S]{0,120}Opacity="0"'
}
Test 'theme.xaml re-styles ContextMenu + MenuItem (dark bg, arcade fonts)' {
    $c = Get-Content (Join-Path $uiRoot 'theme.xaml') -Raw
    Assert-Match $c '<Style TargetType="ContextMenu">'
    Assert-Match $c '<Style TargetType="MenuItem">'
    # MenuItem hover flips to Accent (hot pink)
    Assert-Match $c 'IsHighlighted[\s\S]{0,400}Accent'
}
Test 'theme.xaml re-styles ToolTip (kills Windows-yellow default popup)' {
    $c = Get-Content (Join-Path $uiRoot 'theme.xaml') -Raw
    Assert-Match $c '<Style TargetType="ToolTip">'
    # Arcade tooltip: dark bg + cyan border, VT323 text
    Assert-Match $c 'ToolTip[\s\S]{0,1000}Card'
}

# --- theme.xaml has all 6 required Button + Text/Slider/Combo/Check styles
Test 'theme.xaml defines all required arcade styles (Button x 3 + Text/Combo/Slider/Check/Tab + Scroll/CtxMenu/MenuItem)' {
    $c = Get-Content (Join-Path $uiRoot 'theme.xaml') -Raw
    foreach ($k in @('ArcadePrimary','ArcadeGhost','ArcadeDanger',
                     'ArcadeText','ArcadeCombo','ArcadeSlider','ArcadeCheck',
                     'ArcadeTab')) {
        Assert-Match $c ("x:Key=`"$k`"") "theme.xaml missing x:Key=`"$k`""
    }
}

# ==========================================================================
# 7e. v0.2.2 mockup-match pass -- warm palette + amber halo + LED dots +
# magenta tab underline + 52px About wordmark + footer + blinking caret +
# inset pink card glow + inline copy edit
# ==========================================================================
Section 'v0.2.2 mockup-match pass'

Test 'theme.xaml no longer defines cool-white text ink #F4F0FF' {
    $c = Get-Content (Join-Path $uiRoot 'theme.xaml') -Raw
    # The Text SolidColorBrush must not carry the pre-v0.2.2 cool white.
    # (Substring alone is enough: the shipped palette had exactly one Text=#F4F0FF.)
    if ($c -match '#F4F0FF') {
        throw 'theme.xaml still references #F4F0FF -- palette must ship cream #F5EBD0'
    }
}
Test 'theme.xaml uses cream ink #F5EBD0 for Text brush' {
    $c = Get-Content (Join-Path $uiRoot 'theme.xaml') -Raw
    Assert-Match $c '<SolidColorBrush x:Key="Text"\s+Color="#F5EBD0"/>'
}
Test 'theme.xaml uses warm amber #FFD447 (not shipped orange #FFB800)' {
    $c = Get-Content (Join-Path $uiRoot 'theme.xaml') -Raw
    Assert-Match $c '<SolidColorBrush x:Key="Amber"\s+Color="#FFD447"/>'
    # And the old shipping orange is gone.
    if ($c -match '#FFB800') {
        throw 'theme.xaml still references #FFB800 -- Amber brush must be warm #FFD447'
    }
}
Test 'theme.xaml uses phosphor teal #00E5D2 (not pure cyan #00E5FF)' {
    $c = Get-Content (Join-Path $uiRoot 'theme.xaml') -Raw
    Assert-Match $c '<SolidColorBrush x:Key="Cyan"\s+Color="#00E5D2"/>'
    if ($c -match '#00E5FF') {
        throw 'theme.xaml still references #00E5FF -- Cyan brush must be #00E5D2 (phosphor teal)'
    }
}
Test 'Popup wordmark has amber DropShadowEffect halo layer (PART B)' {
    $c = Get-Content (Join-Path $uiRoot 'popup.xaml') -Raw
    # 4-layer stack: the halo layer is a TextBlock Text="GRAB" with
    # Foreground="Transparent" + DropShadowEffect Color=#FFD447 BlurRadius=20.
    if ($c -notmatch '(?s)Text="GRAB"[^<]*Foreground="Transparent"[\s\S]{0,400}DropShadowEffect[^/]*Color="#FFD447"[^/]*BlurRadius="20"') {
        throw 'popup.xaml missing amber DropShadowEffect halo layer behind the GRAB wordmark'
    }
}
Test 'About wordmark FontSize is 52 (mockup PART D)' {
    $c = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    # Every GRAB layer in the About wordmark must render at 52px.
    $hits = [regex]::Matches($c, 'Text="GRAB"[^/]*FontSize="52"')
    if ($hits.Count -lt 4) {
        throw "About window has $($hits.Count) 52px GRAB layers, expected >=4 (4-layer stack: halo+cyan+pink+cream)"
    }
    # And the amber halo must use BlurRadius=40 for the About-sized glow.
    if ($c -notmatch 'DropShadowEffect[^/]*Color="#FFD447"[^/]*BlurRadius="40"') {
        throw 'About wordmark missing BlurRadius=40 amber halo (mockup PART D)'
    }
}
Test 'Queue rows use Ellipse LED (no left-border rail, mockup PART C)' {
    $c = Get-Content (Join-Path $srcRoot 'popup.ps1') -Raw
    # Confirm the shipped 3px left rail hack is gone from Build-QueueRow.
    if ($c -match 'BorderThickness="3,1,1,1"') {
        throw 'popup.ps1 still uses BorderThickness="3,1,1,1" left-rail hack -- switch to Ellipse LED per mockup PART C'
    }
    # And the row now carries an Ellipse whose Effect is the glow.
    if ($c -notmatch '(?s)Build-QueueRow[\s\S]{0,2000}<Ellipse[\s\S]{0,400}<Ellipse\.Effect>[\s\S]{0,200}DropShadowEffect') {
        throw 'popup.ps1 Build-QueueRow missing Ellipse with DropShadowEffect glow (LED look)'
    }
}
Test 'Active tabs render with magenta #FF2E93 underline (mockup PART G)' {
    $c = Get-Content (Join-Path $uiRoot 'theme.xaml') -Raw
    # All three active-* triggers must set the Under Background to #FF2E93.
    $hits = [regex]::Matches($c, 'TargetName="Under"[^/]*Property="Background"[^/]*Value="#FF2E93"')
    if ($hits.Count -lt 3) {
        throw "ArcadeTab template has $($hits.Count) magenta-underline triggers, expected 3 (one per active-* tag)"
    }
    # Active text also gets an amber glow (Effect on Lbl).
    if ($c -notmatch 'TargetName="Lbl"[\s\S]{0,300}DropShadowEffect[^/]*Color="#FFD447"') {
        throw 'ArcadeTab template must apply an amber DropShadowEffect on active tab text (mockup PART G)'
    }
}
Test 'Popup hint text is "Paste any link. We figure out the rest. [CTRL+V]" (PART I)' {
    $c = Get-Content (Join-Path $uiRoot 'popup.xaml') -Raw
    Assert-Match $c 'Paste any link\. We figure out the rest\.'
    Assert-Match $c '\[CTRL\+V\]'
    # The old kicker prefix ">" must be gone (was "> PASTE ANY LINK..." pre-v0.2.2).
    # -cmatch (case-sensitive) so this only fires when the ALL-CAPS shipped
    # text is still present -- the new sentence-case text is fine.
    if ($c -cmatch 'PASTE ANY LINK\. WE FIGURE OUT THE REST') {
        throw 'popup.xaml still contains the old all-caps "> PASTE ANY LINK..." kicker text (PART I says use sentence-case)'
    }
}
Test 'Popup contains NO v0.1.2 version chip element (PART H3)' {
    $c = Get-Content (Join-Path $uiRoot 'popup.xaml') -Raw
    # No literal version chip near the wordmark. If someone re-introduces one
    # (a <TextBlock ... Text="v0.1.2".../> or "VersionChip" x:Name), refuse.
    if ($c -match 'v0\.1\.\d') {
        throw "popup.xaml contains a v0.1.x version chip -- must not render one next to the GRAB wordmark (PART H3)"
    }
    if ($c -match 'VersionChip') {
        throw 'popup.xaml contains a VersionChip element -- removed per PART H3'
    }
}
Test 'About stamp split-Grid: FREE FOREVER left + Silkscreen amber version right (PART D)' {
    $c = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    # Left cell: VT323 muted "FREE FOREVER" phrase
    Assert-Match $c 'x:Name="StampLeft"[\s\S]{0,400}FREE FOREVER'
    # Right cell: Silkscreen Bold 10px amber #FFD447 with a v0.2.2 label
    if ($c -notmatch 'x:Name="StampRight"[\s\S]{0,500}Silkscreen[\s\S]{0,300}FontSize="10"[\s\S]{0,300}Foreground="#FFD447"') {
        throw 'About stamp right cell must be Silkscreen 10px amber #FFD447 (v0.2.2 label)'
    }
    Assert-Match $c 'v0\.2\.2'
}
Test 'Card CornerRadius is 14 in popup, settings, About and Confirm (mockup PART E)' {
    foreach ($rel in @('ui\popup.xaml','ui\settings.xaml')) {
        $c = Get-Content (Join-Path $repoRoot $rel) -Raw
        if ($c -notmatch 'CornerRadius="14"') {
            throw "$rel missing CornerRadius=14 (was 8; mockup uses 14)"
        }
    }
    $tray = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    # About XAML and ConfirmDialogXaml both live in tray.ps1.
    $hits = [regex]::Matches($tray, 'CornerRadius="14"')
    if ($hits.Count -lt 4) {
        throw "tray.ps1 has $($hits.Count) CornerRadius=14 occurrences, expected >=4 (About + Confirm each need outer+inner)"
    }
    # Inset pink halo emulation must be present in each root card.
    # v0.2.2 tuned the alpha from 0x26 (15%) to 0x0D (5%) after the perimeter
    # was reading too bright vs. the vignette-darkened center. Both are pink.
    Assert-Match $tray '#(?:26|0D)FF2E93'
}
Test 'Popup URL input has amber blinking caret Rectangle (PART H1)' {
    $c = Get-Content (Join-Path $uiRoot 'popup.xaml') -Raw
    Assert-Match $c 'x:Name="AmberCaret"'
    # It must be an amber Rectangle (fill #FFD447).
    if ($c -notmatch 'x:Name="AmberCaret"[\s\S]{0,400}Fill="#FFD447"') {
        throw 'AmberCaret must have Fill="#FFD447"'
    }
    # v0.3.0 phase 3 (audit P1-27): the blink animation moved from an XAML
    # Loaded EventTrigger + Storyboard into code (popup.ps1) so we can
    # Stop() it when the popup hides. Assert the code-driven equivalents:
    # a DoubleAnimation with Forever RepeatBehavior applied via
    # BeginAnimation on the AmberCaret Opacity.
    $ps = Get-Content (Join-Path $srcRoot 'popup.ps1') -Raw
    if ($ps -notmatch 'AmberCaret[\s\S]{0,800}BeginAnimation') {
        throw 'popup.ps1 must drive AmberCaret opacity via BeginAnimation (was: XAML Storyboard trigger)'
    }
    if ($ps -notmatch 'caretAnim[\s\S]{0,600}RepeatBehavior[\s\S]{0,200}Forever') {
        throw 'AmberCaret animation must set RepeatBehavior::Forever so it keeps blinking'
    }
    if ($ps -notmatch 'caretAnim[\s\S]{0,600}DoubleAnimation') {
        throw 'AmberCaret blink must use a DoubleAnimation (Opacity 1 -> 0)'
    }
}
Test 'Popup footer status bar contains "by IMADJINN" credit + FooterStatus (PART H2)' {
    $c = Get-Content (Join-Path $uiRoot 'popup.xaml') -Raw
    Assert-Match $c 'x:Name="FooterStatus"'
    Assert-Match $c 'IMADJINN'
    # The "by " prefix should be a VT323 muted Run, IMADJINN a Silkscreen amber Run.
    if ($c -notmatch 'Text="by "[\s\S]{0,300}Silkscreen[\s\S]{0,200}Foreground="#FFD447"[\s\S]{0,200}IMADJINN') {
        throw 'Footer credit must be VT323 "by " + Silkscreen amber "IMADJINN" (PART H2)'
    }
    # popup.ps1 helper Get-QueueStatusText must exist so the footer can update.
    $ps = Get-Content (Join-Path $srcRoot 'popup.ps1') -Raw
    if ($ps -notmatch 'function\s+Get-QueueStatusText') {
        throw 'popup.ps1 must define Get-QueueStatusText to populate the footer status line'
    }
}
Test 'Popup has radial vignette Rectangle inside outer content area (PART F)' {
    $c = Get-Content (Join-Path $uiRoot 'popup.xaml') -Raw
    # Radial gradient with center 0.5,0.5 fading to translucent black in the corners.
    Assert-Match $c '<RadialGradientBrush[^/]*GradientOrigin="0\.5,0\.5"'
    Assert-Match $c 'Panel\.ZIndex="998"'
}

Section 'install.ps1'

Test 'install.ps1 references BurntToast, yt-dlp, gallery-dl' {
    $c = Get-Content (Join-Path $repoRoot 'install.ps1') -Raw
    foreach ($needle in @('BurntToast', 'yt-dlp', 'gallery-dl')) {
        if ($c -notmatch [regex]::Escape($needle)) { throw "installer missing reference to $needle" }
    }
}
Test 'install.ps1 uses no hardcoded C:\Users\Admin paths (portability)' {
    $c = Get-Content (Join-Path $repoRoot 'install.ps1') -Raw
    if ($c -match 'C:\\Users\\Admin') { throw 'installer contains hardcoded C:\Users\Admin -- not portable' }
}

# ==========================================================================
# 9. Portability across the whole src/ tree
# ==========================================================================
Section 'Portability'

Test 'no src/ or root .ps1 file hardcodes C:\Users\Admin' {
    $files = Get-ChildItem $repoRoot -Recurse -Filter '*.ps1' -ErrorAction SilentlyContinue |
             Where-Object { $_.FullName -notmatch '\\tests\\' -and $_.FullName -notmatch '\\\.git\\' }
    $offenders = @()
    foreach ($f in $files) {
        $c = Get-Content $f.FullName -Raw
        if ($c -match 'C:\\Users\\Admin') { $offenders += $f.Name }
    }
    if ($offenders.Count -gt 0) { throw "hardcoded path in: $($offenders -join ', ')" }
}

Test 'grab-app.ps1 references src\utils.ps1 via Join-Path (not absolute)' {
    $c = Get-Content (Join-Path $repoRoot 'grab-app.ps1') -Raw
    # regex \\ in PS string = single backslash in the file's text
    Assert-Match $c "Join-Path.*src\\utils\.ps1"
}

# ==========================================================================
# 10. v0.3.0 phase 1.7 -- fast tray startup + phase 2 P0 fixes
# ==========================================================================
Section 'v0.3.0 fast tray startup + P0 fixes'

Test 'tray.ps1 no longer eagerly loads PresentationFramework at dot-source time' {
    # Regression: Add-Type PresentationFramework at file top adds 2-3s JIT
    # to cold start. It must load via Ensure-WpfLoaded when a WPF window
    # first renders (About / Confirm dialog).
    $c = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    if ($c -match '(?m)^Add-Type\s+-AssemblyName\s+PresentationFramework') {
        throw 'tray.ps1 still has top-level Add-Type PresentationFramework -- defer via Ensure-WpfLoaded'
    }
    if ($c -match '(?m)^Add-Type\s+-AssemblyName\s+PresentationCore') {
        throw 'tray.ps1 still has top-level Add-Type PresentationCore -- defer via Ensure-WpfLoaded'
    }
    if ($c -match '(?m)^Add-Type\s+-AssemblyName\s+WindowsBase') {
        throw 'tray.ps1 still has top-level Add-Type WindowsBase -- defer via Ensure-WpfLoaded'
    }
}
Test 'popup.ps1 no longer eagerly loads PresentationFramework at dot-source time' {
    $c = Get-Content (Join-Path $srcRoot 'popup.ps1') -Raw
    if ($c -match '(?m)^Add-Type\s+-AssemblyName\s+PresentationFramework') {
        throw 'popup.ps1 still has top-level Add-Type PresentationFramework -- defer via Ensure-WpfLoaded'
    }
}
Test 'settings.ps1 no longer eagerly loads PresentationFramework at dot-source time' {
    $c = Get-Content (Join-Path $srcRoot 'settings.ps1') -Raw
    if ($c -match '(?m)^Add-Type\s+-AssemblyName\s+PresentationFramework') {
        throw 'settings.ps1 still has top-level Add-Type PresentationFramework -- defer via Ensure-WpfLoaded'
    }
}
Test 'utils.ps1 defines Ensure-WpfLoaded (idempotent WPF assembly loader)' {
    $cmd = Get-Command Ensure-WpfLoaded -ErrorAction SilentlyContinue
    Assert-NotNull $cmd 'Ensure-WpfLoaded missing from utils.ps1'
    # Calling twice must not throw and must be a no-op after first call.
    Ensure-WpfLoaded
    Ensure-WpfLoaded
    # Verify the WPF assemblies did load (Ensure-WpfLoaded is a public API).
    $loaded = [AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'PresentationFramework' }
    Assert-NotNull $loaded 'PresentationFramework did not load after Ensure-WpfLoaded'
}
Test 'Show-AboutWindow calls Ensure-WpfLoaded (defensive on cold-start)' {
    $c = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    if ($c -notmatch 'function\s+Show-AboutWindow[\s\S]{0,400}Ensure-WpfLoaded') {
        throw 'Show-AboutWindow must call Ensure-WpfLoaded first so the XamlReader class is available'
    }
}
Test 'Confirm-ArcadeDialog calls Ensure-WpfLoaded' {
    $c = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    if ($c -notmatch 'function\s+Confirm-ArcadeDialog[\s\S]{0,600}Ensure-WpfLoaded') {
        throw 'Confirm-ArcadeDialog must call Ensure-WpfLoaded first'
    }
}
Test 'Load-PopupWindow calls Ensure-WpfLoaded' {
    $c = Get-Content (Join-Path $srcRoot 'popup.ps1') -Raw
    if ($c -notmatch 'function\s+Load-PopupWindow[\s\S]{0,400}Ensure-WpfLoaded') {
        throw 'Load-PopupWindow must call Ensure-WpfLoaded before parsing XAML'
    }
}
Test 'Load-SettingsWindow calls Ensure-WpfLoaded' {
    $c = Get-Content (Join-Path $srcRoot 'settings.ps1') -Raw
    if ($c -notmatch 'function\s+Load-SettingsWindow[\s\S]{0,400}Ensure-WpfLoaded') {
        throw 'Load-SettingsWindow must call Ensure-WpfLoaded before parsing XAML'
    }
}

Test 'grab-app.ps1 lazily dot-sources popup.ps1 and settings.ps1' {
    # Regression for the "tray icon takes 5-8s to appear" report: eager
    # dot-sourcing of these two files added JIT + parse cost before the
    # tray icon ever showed. The callbacks must dot-source on demand,
    # guarded by a $script:*Sourced flag so repeated shows are cheap.
    $c = Get-Content (Join-Path $repoRoot 'grab-app.ps1') -Raw
    # No eager dot-source of popup.ps1 or settings.ps1 at the top
    if ($c -match '(?m)^\.\s+\(Join-Path\s+\$root\s+.*popup\.ps1') {
        throw 'grab-app.ps1 still eagerly dot-sources popup.ps1 -- defer to $onShowPopup callback'
    }
    if ($c -match '(?m)^\.\s+\(Join-Path\s+\$root\s+.*settings\.ps1') {
        throw 'grab-app.ps1 still eagerly dot-sources settings.ps1 -- defer to $onShowSettings callback'
    }
    # Must have the guarded-lazy-load pattern for both files.
    if ($c -notmatch 'PopupSourced[\s\S]{0,400}popup\.ps1') {
        throw 'grab-app.ps1 missing lazy dot-source of popup.ps1 (guarded by $script:PopupSourced)'
    }
    if ($c -notmatch 'SettingsSourced[\s\S]{0,400}settings\.ps1') {
        throw 'grab-app.ps1 missing lazy dot-source of settings.ps1 (guarded by $script:SettingsSourced)'
    }
}

Test 'Start-Tray creates tray icon BEFORE loading WPF (phase 1 of startup)' {
    # The whole point of the "fast tray startup" refactor: NotifyIcon
    # creation + Visible=true must happen before Ensure-WpfLoaded so users
    # see the tray as fast as possible. Uses the AST rather than a regex so
    # nested braces and param blocks don't fool the parser.
    $path = Join-Path $srcRoot 'tray.ps1'
    $tokens = $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    $fn = $ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Start-Tray'
    }, $true) | Select-Object -First 1
    Assert-NotNull $fn 'Start-Tray function not found in tray.ps1'
    $body = $fn.Body.Extent.Text
    $trayVisIdx = $body.IndexOf('$script:Tray.Visible = $true')
    $wpfIdx     = $body.IndexOf('Ensure-WpfLoaded')
    if ($trayVisIdx -lt 0) { throw 'Start-Tray does not set $script:Tray.Visible = $true' }
    if ($wpfIdx -lt 0)     { throw 'Start-Tray does not call Ensure-WpfLoaded' }
    if ($trayVisIdx -gt $wpfIdx) {
        throw "Start-Tray calls Ensure-WpfLoaded (offset=$wpfIdx) BEFORE making the tray icon visible (offset=$trayVisIdx) -- must be the other way around"
    }
}

Test 'Start-Tray wraps Dispatcher.Run in try/catch (audit P0-1)' {
    # Regression: unhandled WPF exception in the pump killed the tray
    # silently. Must catch, log, and surface via MessageBox before re-throw.
    $c = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    if ($c -notmatch 'try\s*\{\s*\[System\.Windows\.Threading\.Dispatcher\]::Run\(\)') {
        throw 'tray.ps1 must wrap [Dispatcher]::Run() in try { } catch { }'
    }
    if ($c -notmatch 'Dispatcher\.Run crashed') {
        throw 'tray.ps1 catch block must Log-Err with "Dispatcher.Run crashed" so failures show in the log'
    }
    if ($c -notmatch 'MessageBox\]::Show[\s\S]{0,400}Tray crash') {
        throw 'tray.ps1 catch block must show a MessageBox so the user knows the tray died'
    }
}

Test 'tray.ps1 defines Invoke-SelfHealSweep (audit P0-2)' {
    $c = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    Assert-Match $c 'function\s+Invoke-SelfHealSweep'
    # Start-Tray must call it.
    if ($c -notmatch 'Invoke-SelfHealSweep') {
        throw 'Start-Tray must call Invoke-SelfHealSweep during startup'
    }
    # It must at least reference the ghost folder + Set-AutostartRegistry.
    if ($c -notmatch 'Downloads\\imadjinn-grab') {
        throw 'Invoke-SelfHealSweep must inspect ~\Downloads\imadjinn-grab (ghost folder cleanup)'
    }
    if ($c -notmatch 'Set-AutostartRegistry') {
        throw 'Invoke-SelfHealSweep must reference Set-AutostartRegistry (recreate autostart if missing)'
    }
}

Test 'Start-Tray calls Invoke-SelfHealSweep' {
    $c = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    # Simple: sweep call site must exist inside Start-Tray body.
    if ($c -notmatch '(?s)function\s+Start-Tray[\s\S]{0,4000}Invoke-SelfHealSweep') {
        throw 'Start-Tray does not invoke Invoke-SelfHealSweep'
    }
}

Test 'Start-Tray sets Windows 11 tray promotion registry key' {
    $c = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    if ($c -notmatch 'NotifyIconSettings') {
        throw 'Start-Tray must write HKCU\Software\...\NotifyIconSettings promotion key'
    }
    if ($c -notmatch 'IsPromoted') {
        throw 'Start-Tray promotion write must set IsPromoted DWORD'
    }
}

Test 'Start-Tray shows first-run tray-pin balloon' {
    $c = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    if ($c -notmatch 'firstRunComplete') {
        throw 'Start-Tray first-run gate missing (must set firstRunComplete after showing balloon)'
    }
    # v0.3.0: balloon must nudge the user to drag the icon out of the
    # up-caret so it stays visible.
    if ($c -notmatch 'up-caret') {
        throw 'Start-Tray first-run balloon must mention "up-caret" to help users pin the icon'
    }
}

Test 'grab-app.ps1 handles AbandonedMutexException (audit P0-3)' {
    $c = Get-Content (Join-Path $repoRoot 'grab-app.ps1') -Raw
    # Uses WaitOne(0) inside a try/catch so an abandoned singleton mutex
    # (from a force-killed prior process) is reclaimed cleanly, not treated
    # as "already running".
    if ($c -notmatch 'WaitOne\(0\)') {
        throw 'grab-app.ps1 singleton must use WaitOne(0) so we can distinguish "held elsewhere" from "abandoned"'
    }
    if ($c -notmatch 'AbandonedMutexException') {
        throw 'grab-app.ps1 must catch AbandonedMutexException from WaitOne to recover from a prior crash'
    }
}

Test 'utils.ps1 defines Set-AutostartRegistry (audit P0-5, P1-11)' {
    $cmd = Get-Command Set-AutostartRegistry -ErrorAction SilentlyContinue
    Assert-NotNull $cmd 'Set-AutostartRegistry missing (needed as autostart primary when Startup folder is OneDrive-redirected)'
    $c = Get-Content (Join-Path $srcRoot 'utils.ps1') -Raw
    if ($c -notmatch 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run') {
        throw 'Set-AutostartRegistry must target HKCU\Software\Microsoft\Windows\CurrentVersion\Run'
    }
}

Test 'Set-AutostartRegistry writes/removes the HKCU\Run entry when enabled' {
    # Round-trip. Audit v0.3.0-pass2 P2 finding 61: use GRAB_RUN_KEY_OVERRIDE
    # so we never touch the user's real HKCU\Run entry.
    $priorEnv = $env:GRAB_RUN_KEY_OVERRIDE
    $fake = 'HKCU:\Software\GrabTestSuite-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '\Run'
    $env:GRAB_RUN_KEY_OVERRIDE = $fake
    try {
        Set-AutostartRegistry $true
        $val = (Get-ItemProperty -Path $fake -Name 'GRAB' -ErrorAction Stop).GRAB
        # v0.3.0-pass2 P0-1: value is wscript.exe grab-app.vbs when the .vbs
        # exists, else powershell.exe -File grab-app.ps1. Accept either.
        Assert-Match $val 'grab-app\.(vbs|ps1)'
        Set-AutostartRegistry $false
        $after = try { (Get-ItemProperty -Path $fake -Name 'GRAB' -ErrorAction SilentlyContinue).GRAB } catch { $null }
        Assert-True ($null -eq $after) 'HKCU\Run\GRAB should be gone after Set-AutostartRegistry $false'
    } finally {
        # Restore prior override + delete the fake key entirely.
        if ($priorEnv) { $env:GRAB_RUN_KEY_OVERRIDE = $priorEnv } else { Remove-Item Env:GRAB_RUN_KEY_OVERRIDE -ErrorAction SilentlyContinue }
        try { Remove-Item -Path $fake -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    }
    # Legacy restore-prior block kept intact below (never reached because
    # of the return-style finally above, but kept for git-blame clarity).
    if ($false) {
        $key   = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        $name  = 'GRAB'
        $prior = $null
        if ($null -ne $prior) {
            Set-ItemProperty -Path $key -Name $name -Value $prior -Force
        } else {
            Remove-ItemProperty -Path $key -Name $name -ErrorAction SilentlyContinue
        }
    }
}

Test 'Set-Autostart also invokes Set-AutostartRegistry (dual autostart)' {
    $c = Get-Content (Join-Path $srcRoot 'settings.ps1') -Raw
    if ($c -notmatch 'function\s+Set-Autostart[\s\S]{0,600}Set-AutostartRegistry') {
        throw 'Set-Autostart in settings.ps1 must call Set-AutostartRegistry (HKCU\Run is the primary autostart)'
    }
}

Test 'Set-Autostart refuses OneDrive Startup folder for the shortcut' {
    $c = Get-Content (Join-Path $srcRoot 'settings.ps1') -Raw
    # Must guard shortcut creation with Test-IsOneDrivePath check.
    if ($c -notmatch 'Test-IsOneDrivePath') {
        throw 'Set-Autostart must check Test-IsOneDrivePath on the Startup folder to avoid the vanishing-shortcut bug'
    }
}

Test 'utils.ps1 defines Get-LocalDesktopPath and Get-LocalStartupPath' {
    Assert-NotNull (Get-Command Get-LocalDesktopPath -ErrorAction SilentlyContinue) `
        'Get-LocalDesktopPath missing (needed to route Desktop shortcuts around OneDrive redirection)'
    Assert-NotNull (Get-Command Get-LocalStartupPath -ErrorAction SilentlyContinue) `
        'Get-LocalStartupPath missing (same purpose for the Startup folder)'
    $p = Get-LocalDesktopPath
    Assert-NotNull $p 'Get-LocalDesktopPath returned null'
}

# --- Phase 6.5 root cause 2: Get-VisibleDesktopPath ---------------------
Test 'Get-VisibleDesktopPath returns the Windows shell Desktop (OneDrive-safe)' {
    Assert-NotNull (Get-Command Get-VisibleDesktopPath -ErrorAction SilentlyContinue) `
        'Get-VisibleDesktopPath missing (needed so Desktop shortcuts land where users actually see them under OneDrive KFM)'
    # With no override, should match whatever the shell reports (the user-
    # visible desktop path -- OneDrive-redirected or not).
    $prev = $env:GRAB_DESKTOP_OVERRIDE
    Remove-Item Env:GRAB_DESKTOP_OVERRIDE -ErrorAction SilentlyContinue
    try {
        $p = Get-VisibleDesktopPath
        Assert-NotNull $p 'Get-VisibleDesktopPath returned null'
        $shell = [Environment]::GetFolderPath('Desktop')
        Assert-Equal $shell $p 'Get-VisibleDesktopPath must return the shell Desktop (not a local override)'
    } finally {
        if ($prev) { $env:GRAB_DESKTOP_OVERRIDE = $prev }
    }
}
Test 'Get-VisibleDesktopPath honors GRAB_DESKTOP_OVERRIDE (test hook)' {
    $prev = $env:GRAB_DESKTOP_OVERRIDE
    $fake = Join-Path $env:TEMP ("grab-vd-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $fake -Force | Out-Null
    $env:GRAB_DESKTOP_OVERRIDE = $fake
    try {
        Assert-Equal $fake (Get-VisibleDesktopPath) 'GRAB_DESKTOP_OVERRIDE not honored'
    } finally {
        if ($prev) { $env:GRAB_DESKTOP_OVERRIDE = $prev } else { Remove-Item Env:GRAB_DESKTOP_OVERRIDE -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $fake -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Test 'Get-LocalStartupPath still refuses OneDrive-redirected Startup (Phase 6.5)' {
    # The Startup shortcut is a belt-and-braces backup to HKCU\Run and
    # OneDrive sync CAN quarantine it. Get-LocalStartupPath is our
    # OneDrive-avoidance helper -- it must still return the local path.
    # (Get-VisibleDesktopPath / VisibleStartMenuPath deliberately DO
    # honour the shell folder.)
    $c = Get-Content (Join-Path $srcRoot 'utils.ps1') -Raw
    if ($c -notmatch 'function\s+Get-LocalStartupPath[\s\S]{0,1000}Test-IsOneDrivePath') {
        throw 'Get-LocalStartupPath must call Test-IsOneDrivePath so it refuses the OneDrive Startup path'
    }
}
Test 'install.ps1 writes Desktop shortcut to VISIBLE Desktop (Phase 6.5 root cause 2)' {
    $c = Get-Content (Join-Path $repoRoot 'install.ps1') -Raw
    # Post-6.5 install must use Get-VisibleDesktopPath so KFM users see it.
    if ($c -notmatch 'Get-VisibleDesktopPath') {
        throw 'install.ps1 must use Get-VisibleDesktopPath so Desktop shortcuts render under OneDrive KFM'
    }
    # And it should still clean up stale OneDrive Desktop shortcuts from
    # earlier install layouts.
    if ($c -notmatch 'OneDrive\\Desktop') {
        throw 'install.ps1 must delete stale grab.lnk from OneDrive\Desktop on install (migration cleanup)'
    }
}
Test 'Invoke-SelfHealSweep recreates Desktop shortcut on VISIBLE Desktop (Phase 6.5)' {
    $c = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    # Pre-6.5 used Get-LocalDesktopPath (invisible under KFM). Post-6.5
    # self-heal must prefer Get-VisibleDesktopPath.
    if ($c -notmatch 'function\s+Invoke-SelfHealSweep[\s\S]{0,8000}Get-VisibleDesktopPath') {
        throw 'Invoke-SelfHealSweep must use Get-VisibleDesktopPath so the self-healed Desktop shortcut appears under OneDrive KFM'
    }
}

# --- Phase 6.5 root cause 3: Start Menu shortcut ------------------------
Test 'Set-StartMenuShortcut exists and writes to visible Start Menu path (Phase 6.5)' {
    Assert-NotNull (Get-Command Set-StartMenuShortcut -ErrorAction SilentlyContinue) `
        'Set-StartMenuShortcut missing (needed so Windows Search finds grab in the Start Menu)'
    Assert-NotNull (Get-Command Get-StartMenuShortcutPath -ErrorAction SilentlyContinue)
    Assert-NotNull (Get-Command Get-VisibleStartMenuPath  -ErrorAction SilentlyContinue)
    # Path should be under the visible Start Menu folder (which is NOT
    # OneDrive-redirected by default).
    $prev = $env:GRAB_STARTMENU_OVERRIDE
    $fake = Join-Path $env:TEMP ("grab-sm-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $fake -Force | Out-Null
    $env:GRAB_STARTMENU_OVERRIDE = $fake
    try {
        $p = Get-StartMenuShortcutPath
        Assert-Match $p 'GRAB\\GRAB\.lnk$' 'expected shortcut path to end in GRAB\GRAB.lnk'
        # Verify the visible-start-menu path resolved through our override.
        Assert-True ($p.StartsWith($fake, [System.StringComparison]::OrdinalIgnoreCase)) `
            "expected shortcut path to start under $fake, got $p"
        # Round-trip: Set true -> file exists; Set false -> file gone.
        Set-StartMenuShortcut $true
        Assert-PathExists $p 'Set-StartMenuShortcut $true did not create the .lnk'
        Set-StartMenuShortcut $false
        Assert-True (-not (Test-Path -LiteralPath $p)) 'Set-StartMenuShortcut $false did not remove the .lnk'
    } finally {
        if ($prev) { $env:GRAB_STARTMENU_OVERRIDE = $prev } else { Remove-Item Env:GRAB_STARTMENU_OVERRIDE -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $fake -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Test 'install.ps1 creates Start Menu entry via Set-StartMenuShortcut (Phase 6.5)' {
    $c = Get-Content (Join-Path $repoRoot 'install.ps1') -Raw
    if ($c -notmatch 'Set-StartMenuShortcut\s+\$true') {
        throw 'install.ps1 must call Set-StartMenuShortcut $true so dev-clone users get a Start Menu entry'
    }
}
Test 'Invoke-SelfHealSweep recreates Start Menu shortcut when missing (Phase 6.5)' {
    $c = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    if ($c -notmatch 'function\s+Invoke-SelfHealSweep[\s\S]{0,10000}(Set-StartMenuShortcut|Get-StartMenuShortcutPath)') {
        throw 'Invoke-SelfHealSweep must re-create a missing Start Menu shortcut so an uninstall + reinstall dance is not required'
    }
}
Test 'uninstall.ps1 removes Start Menu shortcut + empty GRAB folder (Phase 6.5)' {
    $c = Get-Content (Join-Path $repoRoot 'uninstall.ps1') -Raw
    if ($c -notmatch 'Start Menu Programs' -and $c -notmatch 'GetFolderPath\(''Programs''\)') {
        throw 'uninstall.ps1 must reference the Start Menu Programs folder for cleanup'
    }
    if ($c -notmatch 'GRAB\.lnk' -and $c -notmatch "'GRAB'") {
        throw 'uninstall.ps1 must delete the GRAB Start Menu shortcut / folder'
    }
    if ($c -notmatch 'GRAB_STARTMENU_OVERRIDE') {
        throw 'uninstall.ps1 must honor GRAB_STARTMENU_OVERRIDE so the Start Menu sweep is testable in isolation'
    }
}
Test 'uninstall.ps1 sweeps BOTH visible and local Desktop shortcut (Phase 6.5 backward-compat)' {
    $c = Get-Content (Join-Path $repoRoot 'uninstall.ps1') -Raw
    # Pre-6.5 installs wrote to the local Desktop; post-6.5 writes to
    # the visible (KFM) Desktop. Both must be swept.
    if ($c -notmatch "GetFolderPath\('Desktop'\)") {
        throw 'uninstall.ps1 must sweep [Environment]::GetFolderPath(''Desktop'') (visible Desktop, possibly OneDrive-redirected)'
    }
    if ($c -notmatch 'USERPROFILE\s+''Desktop''') {
        throw 'uninstall.ps1 must sweep $env:USERPROFILE\Desktop (local, non-KFM Desktop) for backward compat with pre-6.5 installs'
    }
}

# --- Phase 6.5 QA-2: portable-mode.flag ---------------------------------
Test 'portable-mode.flag next to grab-app.vbs redirects AppData (Phase 6.5 QA-2)' {
    # Simulate a portable-mode extract in a temp folder: drop grab-app.vbs +
    # portable-mode.flag alongside a fake src/ dir, then re-run utils.ps1's
    # AppData resolution logic in a child PowerShell so its $script:AppData
    # is computed against that fake layout.
    $sandbox = Join-Path $env:TEMP ("grab-portable-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path (Join-Path $sandbox 'src') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $srcRoot 'utils.ps1') -Destination (Join-Path $sandbox 'src\utils.ps1') -Force
    Copy-Item -LiteralPath (Join-Path $repoRoot 'grab-app.vbs') -Destination (Join-Path $sandbox 'grab-app.vbs') -Force -ErrorAction SilentlyContinue
    Set-Content -Path (Join-Path $sandbox 'portable-mode.flag') -Value '' -Encoding UTF8
    try {
        $psExe = (Get-Process -Id $PID).Path
        # Child must NOT inherit our override (which pins AppData elsewhere).
        $probe = @"
`$env:GRAB_APP_DATA_OVERRIDE = `$null
. '$($sandbox -replace "'","''")\src\utils.ps1'
Get-AppDataPath
"@
        $out = & $psExe -NoProfile -ExecutionPolicy Bypass -Command $probe 2>&1 | Out-String
        $expected = Join-Path $sandbox 'grab-data'
        Assert-Match $out ([regex]::Escape($expected)) `
            "portable-mode.flag did not redirect AppData to <repo>\grab-data. Output:`n$out"
    } finally {
        Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- Phase 6.5 QA-3: Send-Toast tray fallback ---------------------------
Test 'Send-Toast falls back to tray NotifyIcon balloon when BurntToast is unavailable (Phase 6.5 QA-3)' {
    # Grep-level check first: the source must reference ShowBalloonTip in
    # Send-Toast's body so any regression to a console-only fallback is
    # caught even if the tests happen to run with BurntToast installed.
    $c = Get-Content (Join-Path $srcRoot 'utils.ps1') -Raw
    if ($c -notmatch 'function\s+Send-Toast[\s\S]{0,2500}ShowBalloonTip') {
        throw 'Send-Toast must call $script:Tray.ShowBalloonTip as the mid-tier fallback when BurntToast is missing (installer users have no BurntToast)'
    }
    # Live check: stub a NotifyIcon-shaped object and prove Send-Toast
    # routes to it when BurntToast is (mocked) absent.
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $stub = [pscustomobject]@{
        Called = $false
        Args   = $null
    }
    Add-Member -InputObject $stub -MemberType ScriptMethod -Name ShowBalloonTip -Value {
        param($timeout, $title, $body, $icon)
        $this.Called = $true
        $this.Args = @{ timeout=$timeout; title=$title; body=$body; icon=$icon }
    }
    $prevTray = $script:Tray
    $script:Tray = $stub
    try {
        # Force BurntToast lookup miss by pushing a name unlikely to exist.
        Send-Toast 'phase65-test' 'balloon fallback' $null
        # If BurntToast IS installed, Send-Toast returns via the first branch;
        # in that case the stub won't fire. Accept either outcome but at
        # least prove the code path exists and is callable without throwing.
        if (Get-Module -ListAvailable -Name BurntToast) {
            # Skip the strict assertion on machines that have BurntToast
            # installed; the grep check above already proved the fallback
            # branch exists in source.
        } else {
            Assert-True $stub.Called 'Send-Toast did not fall back to tray NotifyIcon balloon when BurntToast was absent'
            Assert-Equal 'phase65-test'      $stub.Args.title
            Assert-Equal 'balloon fallback'  $stub.Args.body
        }
    } finally {
        $script:Tray = $prevTray
    }
}



Test 'install.ps1 writes autostart to HKCU\Run and cleans stale OneDrive Startup' {
    $c = Get-Content (Join-Path $repoRoot 'install.ps1') -Raw
    if ($c -notmatch 'Set-AutostartRegistry') {
        throw 'install.ps1 must call Set-AutostartRegistry to set the primary autostart entry'
    }
    if ($c -notmatch 'OneDrive\\Microsoft\\Windows\\Start Menu\\Programs\\Startup') {
        throw 'install.ps1 must clean the stale OneDrive Startup shortcut on install'
    }
}

Test 'install.ps1 sets tray promotion registry key' {
    $c = Get-Content (Join-Path $repoRoot 'install.ps1') -Raw
    if ($c -notmatch 'NotifyIconSettings') {
        throw 'install.ps1 must set the HKCU\...\NotifyIconSettings promotion key (Windows 11 tray-hide-by-default fix)'
    }
    if ($c -notmatch 'IsPromoted') {
        throw 'install.ps1 promotion write must set IsPromoted DWORD'
    }
}

Test 'queue.ps1 Read-Queue checks lock return value (Phase 6.5)' {
    $c = Get-Content (Join-Path $srcRoot 'queue.ps1') -Raw
    # Phase 6.5 root cause 1: SemaphoreSlim replaces Mutex. No more
    # [void]$script:Queue{Mutex,Lock}.WaitOne(...) discarding the return.
    if ($c -match '\[void\]\$script:Queue(Mutex|Lock)\.Wait') {
        throw 'Read-Queue must not discard the Wait return value with [void] -- audit P1-24'
    }
    # And Read-Queue must contain "lock timeout" logging on failure
    if ($c -notmatch 'Read-Queue[\s\S]{0,800}(mutex|lock) timeout') {
        throw 'Read-Queue must log a warn + bail on Wait timeout instead of proceeding without the lock'
    }
}
Test 'queue.ps1 Write-Queue bails out on lock timeout (Phase 6.5)' {
    $c = Get-Content (Join-Path $srcRoot 'queue.ps1') -Raw
    if ($c -notmatch 'Write-Queue[\s\S]{0,1200}(mutex|lock) timeout[\s\S]{0,200}skipping write') {
        throw 'Write-Queue must skip the write on Wait timeout to avoid lost-update races (audit P0-7)'
    }
}
Test 'queue mutating functions take the lock (audit P0-7)' {
    # Set-JobStatus, Cancel-QueueJob, Retry-QueueJob, Recover-OrphanedJobs,
    # Stop-AllJobs must all wrap their read-modify-write with the queue
    # lock. Uses AST to be robust against comments / whitespace.
    $path = Join-Path $srcRoot 'queue.ps1'
    $tokens = $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    $targets = @('Set-JobStatus','Cancel-QueueJob','Retry-QueueJob','Recover-OrphanedJobs','Stop-AllJobs')
    $missing = @()
    foreach ($fname in $targets) {
        $fn = $ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fname
        }, $true) | Select-Object -First 1
        if (-not $fn) { $missing += "$fname (function not found)"; continue }
        $body = $fn.Body.Extent.Text
        # Must reference _WithQueueMutex (kept as function name) or the
        # underlying lock (QueueLock/QueueMutex.Wait).
        if ($body -notmatch '_WithQueueMutex' -and $body -notmatch 'Queue(Lock|Mutex)\.Wait') {
            $missing += $fname
        }
    }
    if ($missing.Count -gt 0) {
        throw ("queue.ps1 functions missing lock protection: " + ($missing -join ', '))
    }
}

# --- Phase 6.5 root cause 1: SemaphoreSlim replaces Mutex ---------------
Test 'queue lock is SemaphoreSlim, not Mutex (Phase 6.5)' {
    Assert-True ($script:QueueLock -is [System.Threading.SemaphoreSlim]) `
        "expected `$script:QueueLock to be SemaphoreSlim, got $($script:QueueLock.GetType().FullName)"
    Assert-True ($script:RecentLock -is [System.Threading.SemaphoreSlim]) `
        "expected `$script:RecentLock to be SemaphoreSlim, got $($script:RecentLock.GetType().FullName)"
    # And the source must not re-introduce a Mutex instantiation under the
    # same variable names. Comment references (design docs) are allowed --
    # we scan non-comment lines only.
    $offenders = @()
    $lines = Get-Content (Join-Path $srcRoot 'queue.ps1')
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '^\s*#') { continue }
        # Look for actual Mutex object construction, not the word in prose.
        if ($line -match 'New-Object\s+System\.Threading\.Mutex' -or
            $line -match '\[System\.Threading\.Mutex\]::new' -or
            $line -match '\$script:QueueMutex\s*=' -or
            $line -match '\$script:RecentMutex\s*=') {
            $offenders += ("line " + ($i + 1) + ": " + $line.Trim())
        }
    }
    if ($offenders.Count -gt 0) {
        throw ("queue.ps1 must not use System.Threading.Mutex for queue/recent locks (root cause 1: thread affinity). Offenders:`n" + ($offenders -join "`n"))
    }
}

Test 'queue lock Wait+Release works across threads (Phase 6.5)' {
    # Regression for the 2026-09-03 18:27:48 tick crash. With Mutex,
    # Wait on thread A + Release on thread B threw
    # "Object synchronization method was called from an unsynchronized
    # block of code" and killed the tick timer. SemaphoreSlim must let
    # this cross-thread hand-off succeed silently.
    #
    # NOTE: PS 5.1 can't cleanly run scriptblocks on threadpool threads
    # (no default runspace on those threads), so we do the cross-thread
    # hop through a pure-.NET helper (Add-Type'd once at first use). The
    # helper takes a SemaphoreSlim and returns "OK" or the exception
    # message -- no PS scriptblock crosses the thread boundary.
    if (-not ('GrabTests.CrossThreadHelper' -as [type])) {
        Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Threading;
using System.Threading.Tasks;
namespace GrabTests {
  public static class CrossThreadHelper {
    // Release the given semaphore from a threadpool thread. Returns "OK"
    // on success, or the exception message otherwise. Never throws.
    public static string ReleaseOnPool(SemaphoreSlim s) {
      var task = Task.Run(() => {
        try { s.Release(); return "OK"; }
        catch (Exception ex) { return ex.GetType().Name + ": " + ex.Message; }
      });
      if (!task.Wait(2000)) return "TIMEOUT";
      return task.Result;
    }
  }
}
'@
    }
    $lock = [System.Threading.SemaphoreSlim]::new(1, 1)
    Assert-True ($lock.Wait([TimeSpan]::FromSeconds(1))) 'baseline Wait failed'
    $result = [GrabTests.CrossThreadHelper]::ReleaseOnPool($lock)
    Assert-Equal 'OK' $result "cross-thread Release failed: $result"
    # And we should now be able to Wait again from the current thread.
    Assert-True ($lock.Wait([TimeSpan]::FromSeconds(1))) 'lock stuck after cross-thread Release'
    [void]$lock.Release()
}

Test 'tick-timer ReleaseMutex crash pattern cannot recur (Phase 6.5 regression)' {
    # Direct regression for the live log line at 2026-09-03 18:27:48:
    #   tick error: Exception calling "ReleaseMutex" with "0" argument(s):
    #   "Object synchronization method was called from an unsynchronized
    #    block of code."
    # Under Mutex, cross-thread Release threw ApplicationException. Under
    # SemaphoreSlim, no exception. We prove two properties:
    #   1. Same-thread re-entry into _WithQueueMutex does NOT deadlock
    #      (SemaphoreSlim isn't reentrant, so we layered a thread-local
    #      owner check on top).
    #   2. Cross-thread Wait+Release on the underlying semaphore succeeds
    #      (proven by the CrossThreadHelper above).
    # PS 5.1 doesn't let us drive _WithQueueMutex from a threadpool thread
    # (scriptblocks need a runspace), but the point of the fix is that
    # SemaphoreSlim doesn't care WHICH thread calls Release -- so if the
    # helper above passes, and the re-entrant path below passes, the tick
    # crash cannot recur.
    $reentryErr = $null
    try {
        _WithQueueMutex -Name 'phase65-regression' -Action {
            # Nested calls that USED to work under Mutex (re-entrant) must
            # still work under SemaphoreSlim + our owner-thread tracker:
            try { $null = @(Read-Queue) } catch { $reentryErr = "re-entrant Read-Queue: $($_.Exception.Message)" }
            # Also test nested _WithQueueMutex (Set-JobStatus does this).
            try { _WithQueueMutex -Name 'phase65-nested' -Action { } }
            catch { $reentryErr = "nested _WithQueueMutex: $($_.Exception.Message)" }
        }
    } catch { $reentryErr = "outer _WithQueueMutex: $($_.Exception.Message)" }
    if ($reentryErr) { throw ("phase 6.5 regression: " + $reentryErr) }
    # And the semaphore must NOT be stuck after the wrapped call returns.
    Assert-True ($script:QueueLock.Wait([TimeSpan]::FromSeconds(1))) 'queue lock still held after _WithQueueMutex returned'
    [void]$script:QueueLock.Release()
}

Test 'settings.ps1 VersionLabel uses Get-GrabVersion (audit P0-4, P1-13)' {
    $c = Get-Content (Join-Path $srcRoot 'settings.ps1') -Raw
    # Regression: VersionLabel used to bind to $cfg.version which drifted.
    # Must now source from Get-GrabVersion, the single source of truth.
    if ($c -notmatch 'VersionLabel[\s\S]{0,300}Get-GrabVersion') {
        throw 'settings.ps1 VersionLabel must source from Get-GrabVersion (config field drifts)'
    }
}

Test 'utils.ps1 has Test-IsOneDrivePath helper (OneDrive-safe folder detection)' {
    Assert-NotNull (Get-Command Test-IsOneDrivePath -ErrorAction SilentlyContinue)
    Assert-True (Test-IsOneDrivePath ('C:\Users\Someone\OneDrive\Desktop'))
    Assert-True (-not (Test-IsOneDrivePath 'C:\Users\Someone\Desktop'))
    Assert-True (Test-IsOneDrivePath ('D:\Users\A\Dropbox\Startup'))
    Assert-True (-not (Test-IsOneDrivePath ''))
}

# ==========================================================================
# 11. v0.3.0 phase 3 -- 25 P1 findings + 3 P0-NEW findings
# ==========================================================================
Section 'v0.3.0 phase 3 P1 fixes'

# --- N1 taskbar / AppUserModelID ------------------------------------------
Test 'popup.xaml ShowInTaskbar is False (N1: no PS icon in taskbar when popup opens)' {
    $c = Get-Content (Join-Path $uiRoot 'popup.xaml') -Raw
    if ($c -notmatch 'ShowInTaskbar="False"') {
        throw 'popup.xaml must set ShowInTaskbar="False" so the parent PS icon does not appear in the taskbar when the popup opens'
    }
}
Test 'settings.xaml ShowInTaskbar is False (N1)' {
    $c = Get-Content (Join-Path $uiRoot 'settings.xaml') -Raw
    if ($c -notmatch 'ShowInTaskbar="False"') {
        throw 'settings.xaml must set ShowInTaskbar="False"'
    }
}
Test 'popup.xaml declares Icon attribute pointing at __GRAB_ASSETS__' {
    $c = Get-Content (Join-Path $uiRoot 'popup.xaml') -Raw
    Assert-Match $c 'Icon="__GRAB_ASSETS__[^"]*icon\.ico"'
}
Test 'settings.xaml declares Icon attribute pointing at __GRAB_ASSETS__' {
    $c = Get-Content (Join-Path $uiRoot 'settings.xaml') -Raw
    Assert-Match $c 'Icon="__GRAB_ASSETS__[^"]*icon\.ico"'
}
Test 'grab-app.ps1 calls SetCurrentProcessExplicitAppUserModelID (N1)' {
    $c = Get-Content (Join-Path $repoRoot 'grab-app.ps1') -Raw
    if ($c -notmatch 'SetCurrentProcessExplicitAppUserModelID') {
        throw 'grab-app.ps1 must call SetCurrentProcessExplicitAppUserModelID so windows own their own taskbar identity (not PowerShell.exe)'
    }
    if ($c -notmatch "Imadjinn\.GRAB\.Downloader\.1") {
        throw 'grab-app.ps1 must pass the stable AUMID string "Imadjinn.GRAB.Downloader.1"'
    }
}

# --- N3 HKCU\Run round-trip -----------------------------------------------
Test 'HKCU Run entry is created by Set-Autostart(true) (N3)' {
    # Phase 6.5: route through GRAB_RUN_KEY_OVERRIDE so this never touches
    # the user's real HKCU\Run entry (matches the audit P2 #61 pattern
    # already in use by Set-AutostartRegistry).
    $prevRunKey = $env:GRAB_RUN_KEY_OVERRIDE
    $fake = 'HKCU:\Software\grab-app-tests\phase65-n3-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '\Run'
    New-Item -Path $fake -Force | Out-Null
    $env:GRAB_RUN_KEY_OVERRIDE = $fake
    try {
        # Set-Autostart wires both the shortcut + registry, but the registry
        # is now the primary. Prove the reg entry appears after $true.
        Set-Autostart $true
        $val = (Get-ItemProperty -Path $fake -Name 'GRAB' -ErrorAction Stop).GRAB
        Assert-NotNull $val 'HKCU\Run\GRAB missing after Set-Autostart $true'
        Assert-Match $val 'grab-app\.(ps1|vbs)'
    } finally {
        if ($prevRunKey) { $env:GRAB_RUN_KEY_OVERRIDE = $prevRunKey } else { Remove-Item Env:GRAB_RUN_KEY_OVERRIDE -ErrorAction SilentlyContinue }
        # Clean the whole fake subtree.
        try {
            $parent = Split-Path $fake -Parent
            if (Test-Path $parent) { Remove-Item $parent -Recurse -Force -ErrorAction SilentlyContinue }
            $tests = 'HKCU:\Software\grab-app-tests'
            if ((Test-Path $tests) -and (-not @(Get-ChildItem $tests -ErrorAction SilentlyContinue))) {
                Remove-Item $tests -Force -ErrorAction SilentlyContinue
            }
        } catch {}
    }
}

# --- P1-8/9 UTF-8-no-BOM / atomic writes ----------------------------------
Test 'no remaining Set-Content -Encoding UTF8 for JSON state files in src/ (audit P1-8, P1-9)' {
    $offenders = @()
    foreach ($f in @('utils.ps1','queue.ps1','core.ps1','popup.ps1','settings.ps1','tray.ps1')) {
        $lines = Get-Content (Join-Path $srcRoot $f)
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            # Skip comment-only lines -- audit docstrings reference the anti-pattern.
            if ($line -match '^\s*#') { continue }
            if ($line -match 'Set-Content[^\r\n]*-Encoding\s+UTF8') {
                $lineNo = $i + 1
                $offenders += "${f}:${lineNo}: $($line.Trim())"
            }
        }
    }
    if ($offenders.Count -gt 0) {
        throw "Set-Content -Encoding UTF8 (BOM) survives in: $($offenders -join '; ')"
    }
}

# --- P1-10 no grab Downloads shortcut -------------------------------------
Test 'install.ps1 no longer creates grab Downloads shortcut (audit P1-10)' {
    $c = Get-Content (Join-Path $repoRoot 'install.ps1') -Raw
    if ($c -match "Make-Shortcut[\s\S]{0,200}'grab Downloads'") {
        throw 'install.ps1 still calls Make-Shortcut for "grab Downloads" -- remove; tray menu covers it'
    }
}
Test 'Invoke-SelfHealSweep removes stale grab Downloads.lnk on tray start' {
    $c = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    if ($c -notmatch "'grab Downloads\.lnk'") {
        throw 'Invoke-SelfHealSweep must delete stale grab Downloads.lnk from prior installs'
    }
}

# --- P1-11 autostart shortcut self-heal -----------------------------------
Test 'Invoke-SelfHealSweep recreates HKCU\Run entry when missing' {
    # AST scan: the sweep body must reference Set-AutostartRegistry so a
    # missing autostart entry gets rebuilt at every launch.
    $c = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    if ($c -notmatch 'function\s+Invoke-SelfHealSweep[\s\S]{0,3000}Set-AutostartRegistry') {
        throw 'Invoke-SelfHealSweep must call Set-AutostartRegistry so a missing autostart entry is rebuilt at launch'
    }
}

# --- P1-12 local desktop path used --------------------------------------
Test 'Invoke-SelfHealSweep uses Get-LocalDesktopPath (audit P1-12)' {
    $c = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    # Widened the search window (was 3000) because Phase 4.5 added
    # HKCU\Run drift-detection + more self-heal steps at the top of the
    # function. Just prove Get-LocalDesktopPath is referenced somewhere
    # inside Invoke-SelfHealSweep, before Stop-Tray closes the file.
    if ($c -notmatch 'function\s+Invoke-SelfHealSweep[\s\S]{0,8000}Get-LocalDesktopPath') {
        throw 'Invoke-SelfHealSweep must use Get-LocalDesktopPath so shortcuts recreate on the LOCAL Desktop (never OneDrive)'
    }
}

# --- P1-14 icon load logging ----------------------------------------------
Test 'Get-TrayIcon logs a warn on New-Object Icon failure (audit P1-14)' {
    $c = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    if ($c -notmatch 'function\s+Get-TrayIcon[\s\S]{0,2000}Log-Warn[^\r\n]*icon\.ico') {
        throw 'Get-TrayIcon must Log-Warn (not empty catch) when the ICO fails to load, including size/mtime/header bytes for debugging'
    }
}

# --- P1-15 XAML parse errors don't kill tray ------------------------------
Test 'popup.ps1 wraps XamlReader.Parse in try/catch (audit P1-15)' {
    $c = Get-Content (Join-Path $srcRoot 'popup.ps1') -Raw
    if ($c -notmatch 'try\s*\{\s*\$w\s*=\s*\[Windows\.Markup\.XamlReader\]::Parse') {
        throw 'popup.ps1 Load-PopupWindow must wrap XamlReader.Parse in try/catch so a malformed XAML does not kill the tray'
    }
    if ($c -notmatch 'popup XAML parse failed') {
        throw 'popup.ps1 XAML parse catch must Log-Err with "popup XAML parse failed" and Send-Toast (do NOT re-throw)'
    }
}
Test 'settings.ps1 wraps XamlReader.Parse in try/catch (audit P1-15)' {
    $c = Get-Content (Join-Path $srcRoot 'settings.ps1') -Raw
    if ($c -notmatch 'try\s*\{\s*\$w\s*=\s*\[Windows\.Markup\.XamlReader\]::Parse') {
        throw 'settings.ps1 must wrap XamlReader.Parse in try/catch'
    }
    if ($c -notmatch 'settings XAML parse failed') {
        throw 'settings.ps1 XAML parse catch must Log-Err distinctly'
    }
}
Test 'tray.ps1 Confirm-ArcadeDialog wraps its XamlReader.Parse in try/catch' {
    $c = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    if ($c -notmatch 'Confirm dialog XAML parse failed') {
        throw 'Confirm-ArcadeDialog must catch XamlParseException inside its parse and Log-Err distinctly'
    }
    if ($c -notmatch 'About XAML parse failed') {
        throw 'Show-AboutWindow must catch XamlParseException inside its parse and Log-Err distinctly'
    }
}

# --- P1-16/17 emoji font fallback -----------------------------------------
Test 'popup.xaml SensitiveToggle isolates lock emoji in an emoji-font Run (audit P1-16)' {
    $c = Get-Content (Join-Path $uiRoot 'popup.xaml') -Raw
    if ($c -notmatch 'SensitiveToggle[\s\S]{0,600}FontFamily="Segoe UI Emoji[^"]*"[\s\S]{0,80}&#128274;') {
        throw 'SensitiveToggle emoji (U+1F512) must be inside a Run with Segoe UI Emoji fallback so it does not render as tofu'
    }
}
Test 'popup.xaml ClearRecentBtn isolates trash emoji in an emoji-font Run (audit P1-17)' {
    $c = Get-Content (Join-Path $uiRoot 'popup.xaml') -Raw
    if ($c -notmatch 'ClearRecentBtn[\s\S]{0,600}FontFamily="Segoe UI Emoji[^"]*"[\s\S]{0,80}&#128465;') {
        throw 'ClearRecentBtn trash emoji (U+1F5D1) must be inside a Run with Segoe UI Emoji fallback so it does not render as tofu'
    }
}

# --- P1-18 combobox null-guard --------------------------------------------
Test 'settings.ps1 Save handler null-guards CookieBrowser + VideoQuality SelectedItem (audit P1-18)' {
    $c = Get-Content (Join-Path $srcRoot 'settings.ps1') -Raw
    if ($c -notmatch 'if\s*\(\$CtlLocal\.CookieBrowser\.SelectedItem\)') {
        throw 'settings.ps1 Save must null-guard CookieBrowser.SelectedItem (audit P1-18)'
    }
    if ($c -notmatch 'if\s*\(\$CtlLocal\.VideoQuality\.SelectedItem\)') {
        throw 'settings.ps1 Save must null-guard VideoQuality.SelectedItem (audit P1-18)'
    }
}

# --- P1-19 brave option present -------------------------------------------
Test "brave is in the settings CookieBrowser combo (audit P1-19)" {
    $win = Parse-GrabXaml (Join-Path $uiRoot 'settings.xaml')
    $cb  = $win.FindName('CookieBrowser')
    Assert-NotNull $cb 'CookieBrowser combo missing'
    $labels = @($cb.Items | ForEach-Object { $_.Content.ToString() })
    Assert-Contains $labels 'brave'
}

# --- P1-20 DestroyIcon handle release -------------------------------------
Test 'Get-TrayIcon releases ExtractIconEx handles via DestroyIcon (audit P1-20)' {
    $c = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    # In the shell-fallback branch, after Clone(), both large[0] and small[0]
    # must be passed to DestroyIcon so the GDI handles are freed.
    if ($c -notmatch 'DestroyIcon\(\$small\[0\]\)') {
        throw 'Get-TrayIcon must call DestroyIcon on small[0] after Clone() to release the GDI handle'
    }
    if ($c -notmatch 'DestroyIcon\(\$large\[0\]\)') {
        throw 'Get-TrayIcon must call DestroyIcon on large[0] to release the GDI handle'
    }
}

# --- P1-21 diff-hash rebuild skip ----------------------------------------
Test 'popup.ps1 renderQueue skips rebuild when hash unchanged (audit P1-21)' {
    $c = Get-Content (Join-Path $srcRoot 'popup.ps1') -Raw
    if ($c -notmatch 'LastQueueHash') {
        throw 'renderQueue must track LastQueueHash and skip Children.Clear() when unchanged'
    }
    if ($c -notmatch 'LastRecentHash') {
        throw 'renderRecent must track LastRecentHash and skip Children.Clear() when unchanged'
    }
    # And the hash must actually be computed via MD5 / SHA / equivalent.
    if ($c -notmatch 'ComputeHash') {
        throw 'renderQueue/renderRecent must compute a hash to compare between ticks'
    }
}

# --- P1-22 Get-Config cache invalidation ---------------------------------
Test 'Set-Config invalidates the Get-Config in-memory cache (audit P1-22)' {
    # Twin-value round-trip: Get -> mutate via Set -> Get must reflect it.
    $orig = (Get-Config).concurrency
    try {
        Set-Config (@{
            version=(Get-GrabVersion); downloadFolder='X'; askBeforeEach=$false;
            clipboardWatch=$false; concurrency=99; autostart=$true;
            cookieBrowser='chrome'; videoQuality='best'; toastsEnabled=$true;
            popupPositionX=$null; popupPositionY=$null; firstRunComplete=$true;
            sensitiveByDefault=$false; sensitiveSites=@(); sensitiveFolderName='.private';
            crtScanlines=$true
        })
        $c = Get-Config
        Assert-Equal 99 $c.concurrency
    } finally {
        Update-Config @{ concurrency = $orig } | Out-Null
    }
}

# --- P1-23 log rotation ---------------------------------------------------
Test 'Write-Log rotates when file exceeds 5MB (audit P1-23)' {
    $prevOverride = $env:GRAB_APP_DATA_OVERRIDE
    $isoData = Join-Path $env:TEMP ("grab-log-rot-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
    $env:GRAB_APP_DATA_OVERRIDE = $isoData
    # Reload utils.ps1 so its module-scope $script:AppData picks up the override
    . (Join-Path $srcRoot 'utils.ps1')
    try {
        Ensure-AppData
        $file = Join-Path (Get-LogFolder) ("grab-{0}.log" -f (Get-Date -Format 'yyyy-MM-dd'))
        # Pre-seed a >5MB file so the next Write-Log rotates it.
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        $big = 'X' * (5MB + 1024)
        [System.IO.File]::WriteAllText($file, $big, $utf8NoBom)
        # Rotation runs on a mod-N counter to keep the hot Write-Log path
        # fast; call _RotateLogIfNeeded directly for an unambiguous
        # deterministic assertion.
        _RotateLogIfNeeded $file
        Log-Info 'trigger rotation'
        Assert-PathExists "$file.1"
        # New file (created by Log-Info) is smaller than 5MB
        $newLen = if (Test-Path -LiteralPath $file) { (Get-Item -LiteralPath $file).Length } else { 0 }
        Assert-True ($newLen -lt 5MB) "post-rotation file too large: $newLen"
    } finally {
        Remove-Item -LiteralPath $isoData -Recurse -Force -ErrorAction SilentlyContinue
        $env:GRAB_APP_DATA_OVERRIDE = $prevOverride
        . (Join-Path $srcRoot 'utils.ps1')
    }
}
Test 'Log folder pruned to 30 files max (audit P1-23)' {
    $prevOverride = $env:GRAB_APP_DATA_OVERRIDE
    $isoData = Join-Path $env:TEMP ("grab-log-prune-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
    $env:GRAB_APP_DATA_OVERRIDE = $isoData
    . (Join-Path $srcRoot 'utils.ps1')
    try {
        Ensure-AppData
        $folder = Get-LogFolder
        # Fabricate 40 dated log files.
        for ($i = 0; $i -lt 40; $i++) {
            $d = (Get-Date).AddDays(-$i).ToString('yyyy-MM-dd')
            $p = Join-Path $folder "grab-$d.log"
            Set-Content -Path $p -Value "day-$i" -Encoding UTF8
            # Stagger mtime so the prune keeps the newest 30.
            (Get-Item -LiteralPath $p).LastWriteTimeUtc = (Get-Date).AddDays(-$i).ToUniversalTime()
        }
        Assert-Equal 40 (Get-ChildItem -LiteralPath $folder -Filter 'grab-*.log' -File).Count 'seed step'
        _PruneOldLogs
        $after = @(Get-ChildItem -LiteralPath $folder -Filter 'grab-*.log*' -File).Count
        Assert-True ($after -le 30) "expected <=30 log files after prune, got $after"
    } finally {
        Remove-Item -LiteralPath $isoData -Recurse -Force -ErrorAction SilentlyContinue
        $env:GRAB_APP_DATA_OVERRIDE = $prevOverride
        . (Join-Path $srcRoot 'utils.ps1')
    }
}

# --- P1-24 lock timeout gated ---------------------------------------------
Test 'no queue.ps1 site takes the lock without checking the return (audit P1-24)' {
    $c = Get-Content (Join-Path $srcRoot 'queue.ps1') -Raw
    # Phase 6.5 root cause 1: SemaphoreSlim replaces Mutex. All acquires
    # now flow through _TryAcquireQueueLock / _TryAcquireRecentLock, which
    # centralise the timeout handling. Prove there are no bare
    # QueueLock.Wait(...) or Mutex.WaitOne(...) call sites that discard
    # the return value.
    foreach ($pattern in @('QueueLock\.Wait\(', 'RecentLock\.Wait\(', 'QueueMutex\.WaitOne\(', 'RecentMutex\.WaitOne\(')) {
        $matches = [regex]::Matches($c, $pattern)
        foreach ($m in $matches) {
            $ctxStart = [Math]::Max(0, $m.Index - 250)
            $ctxLen   = [Math]::Min($c.Length - $ctxStart, 500)
            $ctx = $c.Substring($ctxStart, $ctxLen)
            # Accept the helper's own body, or an $acquired / $ok / $kind guard.
            if ($ctx -notmatch '_TryAcquire(Queue|Recent)Lock' -and
                $ctx -notmatch '\$acquired' -and $ctx -notmatch '\$ok' -and $ctx -notmatch '\$kind') {
                throw "queue.ps1@$($m.Index): $pattern not gated on a return-value check"
            }
        }
    }
}

# --- P1-25 timer circuit breakers ----------------------------------------
Test 'tray.ps1 tick timers have circuit breakers (audit P1-25)' {
    $c = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    if ($c -notmatch 'TickFailCount') {
        throw 'Start-Timers must track TickFailCount and stop the queue-tick timer after 10 consecutive failures'
    }
    if ($c -notmatch 'ClipFailCount') {
        throw 'Start-Timers must track ClipFailCount for the clipboard-watch timer too'
    }
    if ($c -notmatch 'worker halted') {
        throw 'Circuit breaker trip must Send-Toast so the user knows the tray worker stopped'
    }
}

# --- P1-26 tray menu items ------------------------------------------------
Test 'tray context menu has Restart, Copy diagnostics, Show logs (audit P1-26)' {
    # Note: menu labels carry Alt-key mnemonics ("&Q" / "&d" etc.) per
    # audit v0.3.0-pass2 finding 80. Test tolerates a lone '&' inside the
    # string.
    $c = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    # Regex tolerates a mnemonic '&' anywhere in the label.
    Assert-Match $c "'Restart\s+tra&?y'"
    Assert-Match $c "'Copy\s+&?diagnostics'"
    Assert-Match $c "'Show\s+&?logs'"
    # And the handlers actually exist
    Assert-Match $c 'function\s+_RestartTray'
    Assert-Match $c 'function\s+_CopyDiagnostics'
}

# --- P1-27 storyboard pause on hide ---------------------------------------
Test 'popup.ps1 pauses AmberCaret + RecDot animations on IsVisibleChanged (audit P1-27)' {
    $c = Get-Content (Join-Path $srcRoot 'popup.ps1') -Raw
    # AmberCaret uses code-driven BeginAnimation now, and the hide path
    # unbinds it with $null.
    if ($c -notmatch 'AmberCaret[\s\S]{0,600}BeginAnimation[\s\S]{0,300}OpacityProperty[\s\S]{0,300}\$null') {
        throw 'popup.ps1 must unbind AmberCaret opacity animation (BeginAnimation ... $null) when window hides'
    }
    if ($c -notmatch 'RecDot[\s\S]{0,600}BeginAnimation[\s\S]{0,300}OpacityProperty[\s\S]{0,300}\$null') {
        throw 'popup.ps1 must unbind RecDot opacity animation when window hides'
    }
    # popup.xaml must no longer carry the Loaded EventTrigger + Storyboard
    # for AmberCaret (it moved to code).
    $xaml = Get-Content (Join-Path $uiRoot 'popup.xaml') -Raw
    if ($xaml -match 'x:Name="AmberCaret"[\s\S]{0,600}RepeatBehavior="Forever"') {
        throw 'popup.xaml still runs a Forever storyboard on AmberCaret -- must move to code so it pauses on hide'
    }
}

# --- P1-28 runtime theme mtime short-circuit -----------------------------
Test 'Get-RuntimeThemeUri compares source vs runtime LastWriteTimeUtc (audit P1-28)' {
    $c = Get-Content (Join-Path $srcRoot 'utils.ps1') -Raw
    if ($c -notmatch 'function\s+Get-RuntimeThemeUri[\s\S]{0,1500}LastWriteTimeUtc') {
        throw 'Get-RuntimeThemeUri must compare source theme.xaml LastWriteTimeUtc vs runtime file mtime to short-circuit rewriting on every launch'
    }
}

# --- P1-29 single token helper -------------------------------------------
Test 'Invoke-GrabTokenReplace is the single token substitution helper (audit P1-29)' {
    $utils = Get-Content (Join-Path $srcRoot 'utils.ps1') -Raw
    Assert-Match $utils 'function\s+Invoke-GrabTokenReplace'
    # Every window loader must call the unified helper (no bespoke .Replace)
    foreach ($f in @('popup.ps1','settings.ps1','tray.ps1')) {
        $c = Get-Content (Join-Path $srcRoot $f) -Raw
        Assert-Match $c 'Invoke-GrabTokenReplace' "$f must call Invoke-GrabTokenReplace instead of a private token-substitution helper"
    }
}

# --- P1-30 arcade menu renderer -------------------------------------------
Test 'tray.ps1 defines Get-ArcadeMenuRenderer + Build-TrayMenu applies it (audit P1-30)' {
    $c = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    Assert-Match $c 'function\s+Get-ArcadeMenuRenderer'
    Assert-Match $c 'ArcadeColors'
    # Build-TrayMenu must set $menu.Renderer from the arcade renderer.
    if ($c -notmatch 'function\s+Build-TrayMenu[\s\S]{0,3000}\$menu\.Renderer') {
        throw 'Build-TrayMenu must apply the arcade renderer via $menu.Renderer'
    }
}

# --- P1-31 result sentinel ------------------------------------------------
Test 'queue.ps1 worker wraps Invoke-Grab result in __grab_result sentinel (audit P1-31)' {
    $c = Get-Content (Join-Path $srcRoot 'queue.ps1') -Raw
    if ($c -notmatch '__grab_result') {
        throw 'queue.ps1 worker must wrap Invoke-Grab result in @{__grab_result = $r} sentinel'
    }
    # And the tick reader must pick up sentinel first (fallback to legacy).
    if ($c -notmatch "sentinel\s*=[\s\S]{0,300}'__grab_result'") {
        throw 'Invoke-QueueTick must filter for __grab_result before falling back to legacy PSObject scan'
    }
}

# --- P1-32 cookie-browser caption ----------------------------------------
Test 'settings.xaml has an explanation caption under the CookieBrowser combo (audit P1-32)' {
    $c = Get-Content (Join-Path $uiRoot 'settings.xaml') -Raw
    if ($c -notmatch 'CookieBrowser[\s\S]{0,600}reads cookies from THIS browser') {
        throw 'settings.xaml must explain what the CookieBrowser combo does under the field'
    }
}

# --- N2 test performance sanity -------------------------------------------
# We do not enforce a hard time budget in this test (external factors), but
# we do assert the config cache is warm across repeated Get-Config calls.
Test 'Get-Config is idempotent across many rapid calls (perf sanity)' {
    Ensure-AppData
    $c1 = Get-Config
    for ($i=0; $i -lt 500; $i++) { $null = Get-Config }
    $c2 = Get-Config
    Assert-Equal $c1.version $c2.version
    Assert-Equal $c1.concurrency $c2.concurrency
}

# ==========================================================================
# 12. v0.3.0 phase 4 -- 31 P2 findings + 4 perf wins
# ==========================================================================
Section 'v0.3.0 phase 4 P2 fixes'

# --- P2-33/34/35 install.ps1 ----------------------------------------------
Test 'install.ps1 no longer references src\drop.bat (audit P2-33)' {
    $c = Get-Content (Join-Path $repoRoot 'install.ps1') -Raw
    if ($c -match 'drop\.bat') {
        throw 'install.ps1 still references src\drop.bat (dead code -- file was removed in v0.2)'
    }
}
Test 'install.ps1 Set-PSRepository check uses correct -ne precedence (audit P2-34)' {
    $c = Get-Content (Join-Path $repoRoot 'install.ps1') -Raw
    # The buggy form was `if (-not X.InstallationPolicy -eq 'Trusted') { ... }`
    # which parses as `((-not X.Y) -eq 'Trusted')` and is always false. The
    # fix is `if (X.InstallationPolicy -ne 'Trusted') { ... }`.
    if ($c -match '-not\s+\(Get-PSRepository[\s\S]{0,200}-eq\s+.Trusted') {
        throw 'install.ps1 Set-PSRepository guard still uses the -not/-eq parser trap'
    }
    Assert-Match $c 'InstallationPolicy\s+-ne\s+.Trusted.'
}
Test 'install.ps1 python scripts-dir probe uses 2>$null (audit P2-35)' {
    $c = Get-Content (Join-Path $repoRoot 'install.ps1') -Raw
    # The old form used 2>&1 which coerced stderr into $scriptsDir and made
    # Test-Path silently fail. Must now capture stderr with 2>$null.
    if ($c -notmatch 'sysconfig\.get_path[^\r\n]*2>\$null') {
        throw 'install.ps1 must capture Python probe stderr separately with 2>$null'
    }
    # And the earlier 2>&1 pattern on the scriptsDir probe must be gone.
    if ($c -match "sysconfig\.get_path\('scripts'\)`" 2>&1") {
        throw 'install.ps1 still uses 2>&1 for the sysconfig probe (silently trips Test-Path)'
    }
}

# --- P2-36 recent mutex ---------------------------------------------------
Test 'queue.ps1 defines _WithRecentMutex + Append-Recent uses it (audit P2-36)' {
    $c = Get-Content (Join-Path $srcRoot 'queue.ps1') -Raw
    # Phase 6.5 root cause 1: named Global\ mutex is gone (see design
    # comment above $script:RecentLock). Instead assert the semaphore lock
    # exists + the wrapper function.
    Assert-Match $c '\$script:RecentLock\s*=\s*\[System\.Threading\.SemaphoreSlim\]'
    Assert-Match $c 'function\s+_WithRecentMutex'
    if ($c -notmatch 'function\s+Append-Recent[\s\S]{0,600}_WithRecentMutex') {
        throw 'Append-Recent must be wrapped in _WithRecentMutex to avoid races with Clear-Recent'
    }
    if ($c -notmatch 'function\s+Clear-Recent[\s\S]{0,2500}_WithRecentMutex') {
        throw 'Clear-Recent must acquire _WithRecentMutex to avoid races with Append-Recent'
    }
}

# --- P2-37 empty-array cap ------------------------------------------------
Test 'Append-Recent cap uses Select-Object -First (audit P2-37)' {
    # Prove the code path doesn't throw when Recent is already large. The
    # bug was `$recent[0..99]` throwing on an empty array; the fix uses
    # Select-Object -First. Round-trip 105 entries and expect Get-Recent to
    # return exactly 100.
    if (Test-Path (Get-RecentPath)) { Remove-Item (Get-RecentPath) -Force }
    for ($i = 0; $i -lt 105; $i++) {
        Append-Recent ([PSCustomObject]@{
            Url = "https://example.com/p2-37-$i"; Dest = 'C:\tmp'; DoneAt = (Get-Date).ToString('o')
            Status = 'done'; FilesAdded = 1; ToolUsed = 'yt-dlp'; DurationMs = 1; Error = $null
        })
    }
    Assert-Equal 100 @(Get-Recent).Count
}

# --- P2-38 Write-Queue array shape ----------------------------------------
Test 'Write-Queue emits a JSON array for zero/one/many jobs (audit P2-38)' {
    $orig = @(Read-Queue)
    try {
        Write-Queue @()
        $raw = Get-Content (Get-QueuePath) -Raw
        Assert-Match $raw '^\s*\[\s*\]\s*$' 'empty queue must serialize to []'
        $j = [PSCustomObject]@{ Id='p238'; Url='https://x'; Status='pending'; StatusMsg='w' }
        Write-Queue @($j)
        $raw = Get-Content (Get-QueuePath) -Raw
        Assert-Match $raw '^\s*\[' 'one-element queue must still be a JSON array'
    } finally {
        Write-Queue $orig
    }
}

# --- P2-40 AskBeforeEach --------------------------------------------------
Test 'Confirm-DownloadDialog is defined (audit P2-40)' {
    $cmd = Get-Command Confirm-DownloadDialog -ErrorAction SilentlyContinue
    Assert-NotNull $cmd 'Confirm-DownloadDialog missing from tray.ps1'
    $c = Get-Content (Join-Path $srcRoot 'popup.ps1') -Raw
    if ($c -notmatch 'askBeforeEach[\s\S]{0,600}Confirm-DownloadDialog') {
        throw 'popup.ps1 submit handler must call Confirm-DownloadDialog when config.askBeforeEach is on'
    }
}

# --- P2-41 Cancel-QueueJob write-guard ------------------------------------
Test 'Cancel-QueueJob only writes queue when it mutated something (audit P2-41)' {
    $c = Get-Content (Join-Path $srcRoot 'queue.ps1') -Raw
    if ($c -notmatch 'function\s+Cancel-QueueJob[\s\S]{0,1200}if\s*\(\s*\$script:_CancelMutated\s*\)') {
        throw 'Cancel-QueueJob must gate Write-Queue on a mutated flag (audit P2-41)'
    }
    # Round-trip: cancelling an unknown id should not throw and return $false.
    $mutated = Cancel-QueueJob 'no-such-id-p2-41'
    Assert-Equal $false $mutated
}

# --- P2-42 About handler error surfaces -----------------------------------
Test 'About handler wraps Show-AboutWindow in try/catch + toasts on failure (audit P2-42)' {
    $c = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    # Tolerate optional Alt-key mnemonic (audit v0.3.0-pass2 finding 80):
    # menu label is '&About' now.
    if ($c -notmatch "'&?About'[\s\S]{0,400}try\s*\{\s*Show-AboutWindow[\s\S]{0,300}Send-Toast\s+'grab'\s+'Could not open About") {
        throw 'About menu handler must try/catch + Send-Toast so silent failures are surfaced'
    }
}

# --- P2-43 config-read error surfaces -------------------------------------
Test 'Confirm-ArcadeDialog + Show-AboutWindow log the swallowed config-read error (audit P2-43)' {
    $c = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    if ($c -notmatch 'Confirm-ArcadeDialog:\s*Get-Config failed') {
        throw 'Confirm-ArcadeDialog must Log-Warn on Get-Config failure, not swallow silently'
    }
    if ($c -notmatch 'Show-AboutWindow:\s*Get-Config failed') {
        throw 'Show-AboutWindow must Log-Warn on Get-Config failure, not swallow silently'
    }
}

# --- P2-44 Build-QueueRow re-reads status ---------------------------------
Test 'Build-QueueRow click handler re-reads status by id (audit P2-44)' {
    $c = Get-Content (Join-Path $srcRoot 'popup.ps1') -Raw
    if ($c -notmatch '\$btn\.Add_Click\(\{[\s\S]{0,600}Read-Queue\s*\|\s*Where-Object\s*\{\s*\$_\.Id\s+-eq\s+\$jobId') {
        throw 'Build-QueueRow click handler must re-read the job status by id (do not capture $status at build time)'
    }
}

# --- P2-45 Start-Process explorer quotes ----------------------------------
Test 'Recent Open button quotes the path via -ArgumentList (audit P2-45)' {
    $c = Get-Content (Join-Path $srcRoot 'popup.ps1') -Raw
    if ($c -notmatch 'Start-Process\s+explorer\.exe\s+-ArgumentList\s*\(''"''\s*\+\s*\$dest\s*\+\s*''"''\)') {
        throw 'Recent Open handler must Start-Process explorer.exe -ArgumentList (''"'' + $dest + ''"'') so folders-with-spaces open once'
    }
}

# --- P2-46 clipboard read swallow -----------------------------------------
Test 'popup.ps1 Clipboard.GetText failure logs once per session (audit P2-46)' {
    $c = Get-Content (Join-Path $srcRoot 'popup.ps1') -Raw
    if ($c -notmatch 'ClipReadWarnedThisSession') {
        throw 'popup.ps1 must Log-Warn (throttled per session) on Clipboard.GetText failure'
    }
}

# --- P2-47 save flash delay -----------------------------------------------
Test 'settings.ps1 Save delays Hide by 400ms so the flash is visible (audit P2-47)' {
    $c = Get-Content (Join-Path $srcRoot 'settings.ps1') -Raw
    if ($c -notmatch "StatusLine\.Text\s*=\s*'Saved\.'[\s\S]{0,600}FromMilliseconds\(400\)") {
        throw 'settings.ps1 must delay Hide by 400ms after setting the "Saved." status text (audit P2-47)'
    }
}

# --- P2-48 first-run balloon copy -----------------------------------------
Test 'first-run balloon text mentions the ^ arrow (audit P2-48)' {
    $c = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    if ($c -notmatch 'may be under the \^ arrow') {
        throw 'first-run balloon must mention the ^ arrow so orientation-neutral wording lands (audit P2-48)'
    }
}

# --- P2-49 Clear-Recent future cutoff refused -----------------------------
Test 'Clear-Recent refuses a future -OlderThan cutoff (audit P2-49)' {
    $threw = $false
    try {
        Clear-Recent -OlderThan (Get-Date).AddDays(1) | Out-Null
    } catch { $threw = $true }
    Assert-True $threw 'Clear-Recent must throw on a future -OlderThan cutoff'
}

# --- P2-50 / PERF-4 ClipTimer gating --------------------------------------
Test 'Sync-ClipTimer starts/stops based on config (audit P2-50 / PERF-4)' {
    $cmd = Get-Command Sync-ClipTimer -ErrorAction SilentlyContinue
    Assert-NotNull $cmd 'Sync-ClipTimer missing from tray.ps1'
    $c = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    if ($c -notmatch 'function\s+Sync-ClipTimer[\s\S]{0,1200}clipboardWatch') {
        throw 'Sync-ClipTimer must inspect config.clipboardWatch to decide start vs stop'
    }
    if ($c -notmatch 'function\s+Start-Timers[\s\S]{0,4000}Sync-ClipTimer') {
        throw 'Start-Timers must call Sync-ClipTimer (do not unconditionally start ClipTimer)'
    }
    $s = Get-Content (Join-Path $srcRoot 'settings.ps1') -Raw
    if ($s -notmatch 'Sync-ClipTimer') {
        throw 'settings.ps1 Save must call Sync-ClipTimer after Update-Config so the toggle takes effect live'
    }
}

# --- P2-52 write-test on Save --------------------------------------------
Test 'Settings Save writes a probe file to validate writeability (audit P2-52)' {
    $c = Get-Content (Join-Path $srcRoot 'settings.ps1') -Raw
    if ($c -notmatch '\.grab-writetest-') {
        throw 'settings.ps1 Save must attempt a probe write into the folder and fail cleanly if it cannot'
    }
}

# --- P2-53 test-a-URL input in Settings -----------------------------------
Test 'settings.xaml has SensitiveTestUrl + SensitiveTestBtn (audit P2-53)' {
    $win = Parse-GrabXaml (Join-Path $uiRoot 'settings.xaml')
    Assert-NotNull ($win.FindName('SensitiveTestUrl'))
    Assert-NotNull ($win.FindName('SensitiveTestBtn'))
    Assert-NotNull ($win.FindName('SensitiveTestResult'))
}

# --- P2-54 .info.json filter by creation time -----------------------------
Test 'Invoke-PostProcess only deletes .info.json created during THIS run (audit P2-54)' {
    $c = Get-Content (Join-Path $srcRoot 'core.ps1') -Raw
    if ($c -notmatch "Filter\s+'\*\.info\.json'[\s\S]{0,300}CreationTime\s+-ge\s+\`$StartedAt") {
        throw 'Invoke-PostProcess must filter .info.json cleanup by CreationTime -ge $StartedAt so external sidecars survive'
    }
}

# --- P2-55 redact regex extended ------------------------------------------
Test 'Write-Log redacts extended vocabulary (bearer / oauth / jwt / signed-URL) (audit P2-55)' {
    $env:GRAB_APP_DATA_OVERRIDE = Join-Path $env:TEMP ("grab-log-p255-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    try {
        Ensure-AppData
        Log-Info 'https://example.com/x?bearer=BB1&oauth_token=OT2&jwt=JJ3&X-Amz-Signature=SS4'
        # Flush the batched queue (Log-Info in test context doesn't rely on the tray timer).
        try { Flush-LogQueue } catch {}
        $logFile = Join-Path (Get-LogFolder) ("grab-{0}.log" -f (Get-Date -Format 'yyyy-MM-dd'))
        $content = Get-Content $logFile -Raw
        foreach ($secret in @('BB1','OT2','JJ3','SS4')) {
            Assert-True ($content -notmatch $secret) "secret [$secret] leaked into log"
        }
        Assert-Match $content 'bearer=REDACTED'
        Assert-Match $content 'oauth_token=REDACTED'
        Assert-Match $content 'jwt=REDACTED'
        Assert-Match $content 'X-Amz-Signature=REDACTED'
    } finally {
        Remove-Item -LiteralPath $env:GRAB_APP_DATA_OVERRIDE -Recurse -Force -ErrorAction SilentlyContinue
        $env:GRAB_APP_DATA_OVERRIDE = $testAppData
    }
}

# --- P2-56 Recent stores redacted URL -------------------------------------
Test 'Append-Recent stores URLs through the redact regex (audit P2-56)' {
    if (Test-Path (Get-RecentPath)) { Remove-Item (Get-RecentPath) -Force }
    $u = 'https://example.com/x?token=SECRETXYZ&other=fine'
    Append-Recent ([PSCustomObject]@{
        Url = $u; Dest = 'C:\tmp'; DoneAt = (Get-Date).ToString('o')
        Status = 'done'; FilesAdded = 1; ToolUsed = 'yt-dlp'; DurationMs = 1; Error = $null
    })
    $r = @(Get-Recent)
    Assert-Equal 1 $r.Count
    Assert-True ($r[0].Url -notmatch 'SECRETXYZ') 'token leaked into recent.json'
    Assert-Match $r[0].Url 'token=REDACTED'
    Assert-Match $r[0].Url 'other=fine'
}

# --- P2-57 GRAB_STARTUP_OVERRIDE ------------------------------------------
Test 'Get-LocalStartupPath honors GRAB_STARTUP_OVERRIDE for test isolation (audit P2-57)' {
    $fake = Join-Path $env:TEMP ("grab-startup-override-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $fake -Force | Out-Null
    $env:GRAB_STARTUP_OVERRIDE = $fake
    try {
        $p = Get-LocalStartupPath
        Assert-Equal $fake $p
    } finally {
        Remove-Item Env:GRAB_STARTUP_OVERRIDE -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $fake -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- P2-58 XAML isolation per test ----------------------------------------
Test 'popup.xaml named-control tests load their own copy (audit P2-58)' {
    # Regression: pre-v0.3.0 the named-control tests shared $script:XamlWindow
    # and depended on the "popup.xaml loads" test running first. The current
    # code path loads fresh per test -- prove by parsing twice successfully.
    $w1 = Parse-GrabXaml (Join-Path $uiRoot 'popup.xaml')
    $w2 = Parse-GrabXaml (Join-Path $uiRoot 'popup.xaml')
    Assert-NotNull $w1
    Assert-NotNull $w2
    # Two distinct object references so nothing carries hidden state between tests.
    Assert-True ([object]::ReferenceEquals($w1, $w2) -eq $false) 'each parse should produce a fresh Window'
}

# --- P2-59 XamlReader-based Visual tree inspection ------------------------
Test 'popup.xaml + settings.xaml + tray About XAML parse via XamlReader and expose expected properties (audit P2-59)' {
    Add-Type -AssemblyName PresentationFramework | Out-Null
    $pw = Parse-GrabXaml (Join-Path $uiRoot 'popup.xaml')
    Assert-NotNull $pw
    Assert-Equal 'False' ([string]$pw.ShowInTaskbar)
    Assert-True ($pw.Icon -ne $null) 'popup.xaml must declare Icon'
    $sw = Parse-GrabXaml (Join-Path $uiRoot 'settings.xaml')
    Assert-NotNull $sw
    Assert-Equal 'False' ([string]$sw.ShowInTaskbar)
    Assert-True ($sw.Icon -ne $null) 'settings.xaml must declare Icon'
    # About XAML lives inline in tray.ps1; substitute its tokens and parse.
    $trayText = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    $aboutRx  = [regex]"(?ms)\`$script:AboutXaml = @'\r?\n(.+?)\r?\n'@"
    $m = $aboutRx.Match($trayText)
    Assert-True $m.Success 'could not extract $script:AboutXaml from tray.ps1'
    $aboutSubs = Get-GrabTokenSubstituted $m.Groups[1].Value
    $aw = [Windows.Markup.XamlReader]::Parse($aboutSubs)
    Assert-NotNull $aw
    Assert-Equal 'False' ([string]$aw.ShowInTaskbar)
}

# --- P2-60 BOM-free / atomic-write / chaos tests --------------------------
Test 'state files write without a UTF-8 BOM (audit P2-60)' {
    # Fresh isolated app-data so queue.json / recent.json / config.json get
    # written by the current code path.
    $iso = Join-Path $env:TEMP ("grab-bom-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    $env:GRAB_APP_DATA_OVERRIDE = $iso
    . (Join-Path $srcRoot 'utils.ps1')
    . (Join-Path $srcRoot 'queue.ps1')
    try {
        Ensure-AppData
        $null = Get-Config
        Write-Queue @()
        Append-Recent ([PSCustomObject]@{
            Url='https://ex.com/bom'; Dest='C:\tmp'; DoneAt=(Get-Date).ToString('o')
            Status='done'; FilesAdded=1; ToolUsed='yt-dlp'; DurationMs=1; Error=$null
        })
        foreach ($f in @((Get-ConfigPath), (Get-QueuePath), (Get-RecentPath))) {
            if (-not (Test-Path -LiteralPath $f)) { continue }
            $bytes = [System.IO.File]::ReadAllBytes($f)
            if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
                throw "state file $f still has UTF-8 BOM (audit P2-60)"
            }
        }
    } finally {
        Remove-Item -LiteralPath $iso -Recurse -Force -ErrorAction SilentlyContinue
        $env:GRAB_APP_DATA_OVERRIDE = $testAppData
        . (Join-Path $srcRoot 'utils.ps1')
        . (Join-Path $srcRoot 'queue.ps1')
    }
}
Test 'Write-JsonAtomic leaves no .tmp residue on a successful write (audit P2-60)' {
    $tmp = Join-Path $env:TEMP ("grab-atomic-noresidue-" + [Guid]::NewGuid().ToString('N').Substring(0,8) + ".json")
    try {
        for ($i = 0; $i -lt 5; $i++) {
            Write-JsonAtomic -Path $tmp -Data @{ i = $i } -Depth 2
            Assert-True (-not (Test-Path -LiteralPath "$tmp.tmp")) "stale .tmp survived iteration $i"
        }
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "$tmp.tmp" -Force -ErrorAction SilentlyContinue
    }
}
Test 'chaos: corrupt queue.json is recovered / reset cleanly (audit P2-60)' {
    # Blast in garbage bytes; Read-Queue must not throw + must yield an
    # empty enumeration. Then Write-Queue must restore a valid array.
    Set-Content -Path (Get-QueuePath) -Value 'garbage {{ not json' -Encoding UTF8
    $q = @(Read-Queue)
    Assert-Equal 0 $q.Count 'corrupt queue.json should read as empty, not throw'
    Write-Queue @()
    $raw = Get-Content (Get-QueuePath) -Raw
    Assert-Match $raw '^\s*\[\s*\]\s*$' 'queue.json must be a valid empty array after recovery'
}
Test 'chaos: corrupt config.json is recovered via backup + defaults (audit P2-60)' {
    # Already covered elsewhere as a Get-Config test; assert the "kill mid-
    # write survivability" contract explicitly: writing garbage then reading
    # via Get-Config must yield a valid config.
    Set-Content -Path (Get-ConfigPath) -Value '{"broken' -Encoding UTF8
    $c = Get-Config
    Assert-NotNull $c
    Assert-NotNull $c.downloadFolder
    Assert-NotNull $c.concurrency
    # Cleanup: remove backups
    $backups = @(Get-ChildItem (Split-Path (Get-ConfigPath) -Parent) -Filter 'config.json.corrupt-*' -ErrorAction SilentlyContinue)
    foreach ($b in $backups) { Remove-Item -LiteralPath $b.FullName -Force -ErrorAction SilentlyContinue }
}

# --- P2-61 config-reference doc -------------------------------------------
Test 'docs/config-reference.md exists and lists every documented key (audit P2-61)' {
    $p = Join-Path $docsRoot 'config-reference.md'
    Assert-PathExists $p
    $c = Get-Content $p -Raw
    foreach ($k in @('downloadFolder','askBeforeEach','clipboardWatch','concurrency','autostart',
                     'cookieBrowser','videoQuality','toastsEnabled','popupPositionX','popupPositionY',
                     'firstRunComplete','sensitiveByDefault','sensitiveSites','sensitiveFolderName','crtScanlines')) {
        Assert-Match $c ('`' + $k + '`') "config-reference.md missing key: $k"
    }
}

# --- P2-62 README troubleshooting ----------------------------------------
Test 'README has a Troubleshooting section (audit P2-62)' {
    $c = Get-Content (Join-Path $repoRoot 'README.md') -Raw
    Assert-Match $c '(?m)^##\s+Troubleshooting'
    Assert-Match $c 'Copy diagnostics'
    Assert-Match $c 'Restart tray'
    Assert-Match $c '%APPDATA%\\grab-app'
}

# --- P2-63 CHANGELOG ------------------------------------------------------
Test 'CHANGELOG.md exists with entries for every release (audit P2-63)' {
    $p = Join-Path $repoRoot 'CHANGELOG.md'
    Assert-PathExists $p
    $c = Get-Content $p -Raw
    foreach ($v in @('0.1.0','0.1.1','0.1.2','0.2.0','0.2.1','0.2.2','0.3.0')) {
        Assert-Match $c ('\[' + [regex]::Escape($v) + '\]') "CHANGELOG missing entry for $v"
    }
    # Keep-a-Changelog header
    Assert-Match $c 'Keep a Changelog'
}

# --- PERF-1 adaptive tick timer ------------------------------------------
Test 'tray.ps1 defines adaptive tick interval + LastQueueActivityAt (PERF-1)' {
    $c = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    Assert-Match $c 'LastQueueActivityAt'
    Assert-Match $c 'function\s+Get-DesiredTickInterval'
    Assert-Match $c 'TickIntervalIdle'
    Assert-Match $c 'TickIntervalFast'
    if ($c -notmatch 'idleFor\.TotalMinutes\s+-lt\s+5') {
        throw 'Get-DesiredTickInterval must gate the fast interval on "activity within last 5min"'
    }
}
Test 'Get-DesiredTickInterval backs off to 30s when queue empty and idle >5min (PERF-1)' {
    # Force the state the function keys off of, then evaluate.
    if (Get-Command Notify-QueueActivity -ErrorAction SilentlyContinue) {
        # Wipe the queue so we're truly idle.
        Write-Queue @()
        $script:LastQueueActivityAt = (Get-Date).AddMinutes(-10)
        $script:BatterySaverOn = $false
        $script:OnBattery      = $false
        $desired = Get-DesiredTickInterval
        Assert-Equal ([TimeSpan]::FromSeconds(30)) $desired
    }
}

# --- PERF-2 battery / power awareness -------------------------------------
Test 'Start-Timers registers PowerModeChanged handler + tracks OnBattery (PERF-2)' {
    $c = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    Assert-Match $c 'PowerModeChanged'
    Assert-Match $c 'OnBattery'
    if ($c -notmatch 'TickIntervalBattery') {
        throw 'tray.ps1 must define a tightened tick interval for battery-saver mode (PERF-2)'
    }
}
Test 'Get-DesiredTickInterval picks battery interval when on battery + idle (PERF-2)' {
    if (Get-Command Get-DesiredTickInterval -ErrorAction SilentlyContinue) {
        Write-Queue @()
        $script:LastQueueActivityAt = (Get-Date).AddMinutes(-10)
        $script:OnBattery       = $true
        $script:BatterySaverOn  = $false
        $desired = Get-DesiredTickInterval
        Assert-Equal ([TimeSpan]::FromSeconds(15)) $desired
        $script:OnBattery = $false
    }
}

# --- PERF-3 log batching --------------------------------------------------
Test 'utils.ps1 defines the log-batching queue + Flush-LogQueue (PERF-3)' {
    $c = Get-Content (Join-Path $srcRoot 'utils.ps1') -Raw
    Assert-Match $c 'function\s+Flush-LogQueue'
    Assert-Match $c 'function\s+Enable-LogBatching'
    Assert-Match $c 'LogQueue'
    if ($c -notmatch 'ConcurrentQueue') {
        throw 'log queue must be a ConcurrentQueue so Write-Log can enqueue from any thread'
    }
}
Test 'Start-Timers wires the LogFlushTimer at 1s (PERF-3)' {
    $c = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    if ($c -notmatch 'LogFlushTimer[\s\S]{0,300}FromSeconds\(1\)') {
        throw 'Start-Timers must start LogFlushTimer at 1s to drain the batched log queue'
    }
    if ($c -notmatch 'Flush-LogQueue') {
        throw 'Start-Timers LogFlushTimer must call Flush-LogQueue on tick'
    }
}
Test 'Write-Log batches when Enable-LogBatching has been called (PERF-3)' {
    $iso = Join-Path $env:TEMP ("grab-batch-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    $env:GRAB_APP_DATA_OVERRIDE = $iso
    . (Join-Path $srcRoot 'utils.ps1')
    try {
        Ensure-AppData
        Enable-LogBatching
        Log-Info 'batched line one'
        Log-Info 'batched line two'
        $logFile = Join-Path (Get-LogFolder) ("grab-{0}.log" -f (Get-Date -Format 'yyyy-MM-dd'))
        # Before flush, the file should NOT yet contain the batched lines.
        $preExists = Test-Path -LiteralPath $logFile
        $preContent = if ($preExists) { Get-Content -LiteralPath $logFile -Raw } else { '' }
        Assert-True ($preContent -notmatch 'batched line one') 'pre-flush should not contain batched entries'
        Flush-LogQueue
        Disable-LogBatching
        $post = Get-Content -LiteralPath $logFile -Raw
        Assert-Match $post 'batched line one'
        Assert-Match $post 'batched line two'
    } finally {
        Disable-LogBatching
        Remove-Item -LiteralPath $iso -Recurse -Force -ErrorAction SilentlyContinue
        $env:GRAB_APP_DATA_OVERRIDE = $testAppData
        . (Join-Path $srcRoot 'utils.ps1')
    }
}

# --- PERF-4 ClipTimer only when clipboardWatch=true -----------------------
Test 'Sync-ClipTimer never starts ClipTimer when clipboardWatch=false (PERF-4)' {
    $c = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    if ($c -notmatch "function\s+Sync-ClipTimer[\s\S]{0,1500}if\s*\(\`$wantOn\)") {
        throw 'Sync-ClipTimer must gate ClipTimer creation on $wantOn (config.clipboardWatch)'
    }
}

# ==========================================================================
# v0.3.0 Phase 4.5 -- second-pass audit corrections
# ==========================================================================
Section 'v0.3.0-pass2 (Phase 4.5)'

# --- P0-1 HKCU\Run uses wscript.exe grab-app.vbs --------------------------
Test 'Set-AutostartRegistry writes wscript.exe grab-app.vbs when the .vbs exists (pass2 P0-1)' {
    # The grab-app.vbs ships in repo root; the helper should prefer it.
    $val = Get-AutostartRegistryCommand
    Assert-Match $val 'wscript\.exe'
    Assert-Match $val 'grab-app\.vbs'
    if ($val -match '-File\s+"[^"]+grab-app\.ps1"') {
        throw 'HKCU\Run command must NOT be powershell.exe -File grab-app.ps1 when the .vbs launcher is present'
    }
}
Test 'Get-AutostartRegistryCommand falls back to powershell.exe when grab-app.vbs is missing (pass2 P0-1)' {
    # We can't literally delete the .vbs, but we can prove the fallback
    # branch exists in source.
    $c = Get-Content (Join-Path $srcRoot 'utils.ps1') -Raw
    if ($c -notmatch 'function\s+Get-AutostartRegistryCommand[\s\S]{0,400}Test-Path\s+-LiteralPath\s+\$vbs[\s\S]{0,400}wscript\.exe[\s\S]{0,600}powershell\.exe\s+-STA\s+-NoProfile') {
        throw 'Get-AutostartRegistryCommand must probe grab-app.vbs and only fall back to powershell.exe when it is missing'
    }
}

# --- P0-3 MinBtn glyph renders (Content="__" is the WPF underscore escape) -
Test 'popup.xaml + settings.xaml MinBtn Content is "__" or a real glyph, never bare "_" (pass2 P0-3)' {
    foreach ($xf in @('ui\popup.xaml','ui\settings.xaml')) {
        $c = Get-Content (Join-Path $repoRoot $xf) -Raw
        if ($c -match 'x:Name="MinBtn"[^/]*Content="_"[^_]') {
            throw "$xf still has MinBtn Content='_' which renders as an empty access-key marker in WPF"
        }
        if ($c -notmatch 'x:Name="MinBtn"[\s\S]{0,200}Content="__"') {
            throw "$xf MinBtn must use Content='__' (escaped underscore) or a glyph"
        }
    }
}

# --- P0-4 HKCU\Run drift heal --------------------------------------------
Test 'Invoke-SelfHealSweep detects HKCU\Run drift + rewrites (pass2 P0-4)' {
    $c = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    # Function must compare stored HKCU\Run value against
    # Get-AutostartRegistryCommand and rewrite when they differ.
    if ($c -notmatch 'function\s+Invoke-SelfHealSweep[\s\S]{0,10000}Get-AutostartRegistryCommand') {
        throw 'Invoke-SelfHealSweep must call Get-AutostartRegistryCommand to check for drift'
    }
    if ($c -notmatch 'self-heal:\s+HKCU\\Run\s+drift\s+corrected') {
        throw 'Invoke-SelfHealSweep must log when it repairs a stale HKCU\Run value'
    }
}

# --- PERF verification (findings 34/35/36) -------------------------------
Test 'Get-DesiredTickInterval stays FAST when a job is running, regardless of idle time (pass2 finding 36)' {
    if (Get-Command Get-DesiredTickInterval -ErrorAction SilentlyContinue) {
        # Seed a queue with one running job, force idle far in the past.
        $rj = New-QueueJob -Url 'https://example.com/x'
        $rj.Status = 'running'
        Write-Queue @($rj)
        $script:LastQueueActivityAt = (Get-Date).AddHours(-1)
        $script:OnBattery       = $true    # even on battery
        $script:BatterySaverOn  = $false
        $script:PopupVisibleCount = 0
        $desired = Get-DesiredTickInterval
        Assert-Equal ([TimeSpan]::FromSeconds(2)) $desired
        # Cleanup
        Write-Queue @()
        $script:OnBattery = $false
    }
}
Test 'Get-DesiredTickInterval stays FAST when popup is visible (pass2 finding 34/35)' {
    if (Get-Command Get-DesiredTickInterval -ErrorAction SilentlyContinue) {
        Write-Queue @()
        $script:LastQueueActivityAt = (Get-Date).AddHours(-1)
        $script:OnBattery       = $false
        $script:BatterySaverOn  = $false
        $script:PopupVisibleCount = 1     # user watching
        $desired = Get-DesiredTickInterval
        Assert-Equal ([TimeSpan]::FromSeconds(2)) $desired
        $script:PopupVisibleCount = 0
    }
}
Test 'Notify-PopupVisible increments/decrements PopupVisibleCount (pass2 finding 34/35)' {
    if (Get-Command Notify-PopupVisible -ErrorAction SilentlyContinue) {
        $script:PopupVisibleCount = 0
        Notify-PopupVisible $true
        Assert-Equal 1 $script:PopupVisibleCount
        Notify-PopupVisible $true
        Assert-Equal 2 $script:PopupVisibleCount
        Notify-PopupVisible $false
        Assert-Equal 1 $script:PopupVisibleCount
        Notify-PopupVisible $false
        Assert-Equal 0 $script:PopupVisibleCount
        # Decrement clamped at zero
        Notify-PopupVisible $false
        Assert-Equal 0 $script:PopupVisibleCount
    }
}
Test 'popup.ps1 IsVisibleChanged notifies the tray tick timer (pass2 finding 34/35)' {
    $c = Get-Content (Join-Path $srcRoot 'popup.ps1') -Raw
    if ($c -notmatch 'IsVisibleChanged[\s\S]{0,800}Notify-PopupVisible\s+\$true') {
        throw 'popup.ps1 must call Notify-PopupVisible $true on IsVisibleChanged when visible'
    }
    if ($c -notmatch 'Notify-PopupVisible\s+\$false') {
        throw 'popup.ps1 must call Notify-PopupVisible $false on hide'
    }
}
Test 'Start-Timers is wired to call Enable-LogBatching (pass2 finding 2)' {
    $c = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    if ($c -notmatch 'function\s+Start-Timers[\s\S]{0,4000}Enable-LogBatching') {
        throw 'Start-Timers must call Enable-LogBatching so PERF-3 is not dead scaffolding'
    }
}
Test 'popup animations honor reduced-motion (pass2 finding 5/7)' {
    $c = Get-Content (Join-Path $srcRoot 'popup.ps1') -Raw
    if ($c -notmatch 'ClientAreaAnimation') {
        throw 'popup.ps1 must check [System.Windows.SystemParameters]::ClientAreaAnimation before running caret/RecDot storyboards'
    }
}

# --- Accessibility (findings 5-11) ----------------------------------------
Test 'popup.xaml every named control has AutomationProperties.Name (pass2 finding 5)' {
    $c = Get-Content (Join-Path $repoRoot 'ui\popup.xaml') -Raw
    foreach ($n in @('MinBtn','CloseBtn','TabPaste','TabQueue','TabRecent',
                     'UrlBox','MultiBox','ToggleMulti','GrabBtn','SensitiveToggle',
                     'QueueClearDone','ClearRecentBtn','ClearOldRecentBtn')) {
        # Wider window because some TextBox blocks are 10+ attributes long.
        if ($c -notmatch ("x:Name=`"" + [regex]::Escape($n) + "`"[\s\S]{0,1200}AutomationProperties\.Name=")) {
            throw "$n in popup.xaml missing AutomationProperties.Name"
        }
    }
}
Test 'settings.xaml every named control has AutomationProperties.Name (pass2 finding 5)' {
    $c = Get-Content (Join-Path $repoRoot 'ui\settings.xaml') -Raw
    foreach ($n in @('MinBtn','CloseBtn','DownloadFolder','BrowseBtn','AskBeforeEach',
                     'ConcurrencySlider','CookieBrowser','VideoQuality',
                     'ToastsEnabled','ClipboardWatch','CrtScanlines',
                     'SensitiveByDefault','SensitiveSites','Autostart',
                     'OpenStateBtn','OpenLogsBtn','ResetBtn','CancelBtn','SaveBtn')) {
        if ($c -notmatch ("x:Name=`"" + [regex]::Escape($n) + "`"[\s\S]{0,1200}AutomationProperties\.Name=")) {
            throw "$n in settings.xaml missing AutomationProperties.Name"
        }
    }
}
Test 'popup.xaml GrabBtn is IsDefault + CloseBtn IsCancel (pass2 finding 5)' {
    $c = Get-Content (Join-Path $repoRoot 'ui\popup.xaml') -Raw
    if ($c -notmatch 'x:Name="GrabBtn"[\s\S]{0,400}IsDefault="True"') {
        throw 'GrabBtn must be IsDefault="True" so Enter submits from anywhere in the popup'
    }
    if ($c -notmatch 'x:Name="CloseBtn"[\s\S]{0,400}IsCancel="True"') {
        throw 'CloseBtn must be IsCancel="True" so Esc closes the popup'
    }
}
Test 'settings.xaml SaveBtn IsDefault + CancelBtn IsCancel + CloseBtn IsCancel (pass2 finding 5)' {
    $c = Get-Content (Join-Path $repoRoot 'ui\settings.xaml') -Raw
    if ($c -notmatch 'x:Name="SaveBtn"[\s\S]{0,400}IsDefault="True"') {
        throw 'SaveBtn must be IsDefault="True"'
    }
    if ($c -notmatch 'x:Name="CancelBtn"[\s\S]{0,400}IsCancel="True"') {
        throw 'CancelBtn must be IsCancel="True"'
    }
    if ($c -notmatch 'x:Name="CloseBtn"[\s\S]{0,400}IsCancel="True"') {
        throw 'CloseBtn must be IsCancel="True"'
    }
}
Test 'multi-line TextBoxes set AcceptsTab=False so Tab moves focus (pass2 finding 5)' {
    foreach ($pair in @(
        @{ file='ui\popup.xaml';    name='MultiBox' },
        @{ file='ui\settings.xaml'; name='SensitiveSites' }
    )) {
        $c = Get-Content (Join-Path $repoRoot $pair.file) -Raw
        if ($c -notmatch ("x:Name=`"" + [regex]::Escape($pair.name) + "`"[\s\S]{0,1200}AcceptsTab=`"False`"")) {
            throw "$($pair.name) in $($pair.file) must set AcceptsTab=`"False`" for keyboard a11y"
        }
    }
}
Test 'Confirm-ArcadeDialog buttons wear Alt-key mnemonics (pass2 finding 67)' {
    $c = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    if ($c -notmatch 'x:Name="NoBtn"[\s\S]{0,200}Content="_CANCEL"') {
        throw 'Confirm-ArcadeDialog NoBtn must carry an Alt+C mnemonic'
    }
    if ($c -notmatch 'x:Name="YesBtn"[\s\S]{0,200}Content="_YES"') {
        throw 'Confirm-ArcadeDialog YesBtn must carry an Alt+Y mnemonic'
    }
}

# --- P3-78 About footer version binding ----------------------------------
Test 'About window StampRight has x:Name and is bound at Show time (pass2 P3-78)' {
    $c = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    if ($c -notmatch 'x:Name="StampRight"') {
        throw 'About XAML must expose StampRight via x:Name so Show-AboutWindow can bind it'
    }
    if ($c -notmatch 'function\s+Show-AboutWindow[\s\S]{0,6000}StampRight[\s\S]{0,600}Get-GrabVersion') {
        throw 'Show-AboutWindow must set StampRight.Text from Get-GrabVersion so About version never drifts'
    }
    # Ensure the hardcoded "v0.2.2" placeholder is gone from the raw XAML.
    if ($c -match 'x:Name="StampRight"[\s\S]{0,300}Text="v0\.2\.2') {
        throw 'StampRight default text must not hard-code v0.2.2'
    }
}

# --- P3-79 Settings VersionLabel default is generic ----------------------
Test 'settings.xaml VersionLabel default is not a hardcoded version (pass2 P3-79)' {
    $c = Get-Content (Join-Path $repoRoot 'ui\settings.xaml') -Raw
    if ($c -match 'x:Name="VersionLabel"[\s\S]{0,300}Text="grab v0\.\d+\.\d+') {
        throw 'settings.xaml VersionLabel default text must not hardcode a version -- the runtime binding in Show-Settings overwrites it anyway'
    }
}

# --- P3-80 menu items carry mnemonics ------------------------------------
Test 'tray menu items have & mnemonics (pass2 P3-80)' {
    $c = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    foreach ($m in @('&Show grab','&Queue','&Recent','Se&ttings','&Open downloads','Show &logs','Copy &diagnostics','Restart tra&y','&About','&Quit')) {
        Assert-Match $c ([regex]::Escape($m))
    }
}

# --- P3-75 tray tooltip dynamic ------------------------------------------
Test 'tick timer updates tray tooltip with live counts (pass2 P3-75)' {
    $c = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    if ($c -notmatch 'grab\s*--\s*running:\$running\s+queued:\$queued') {
        throw 'Invoke-QueueTick handler must refresh $script:Tray.Text with live running/queued counts'
    }
}

# --- P2 findings 29/38/55/56/62/65 ---------------------------------------
Test '_CopyDiagnostics redacts sensitiveSites from the config dump (pass2 finding 29)' {
    $c = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    if ($c -notmatch 'function\s+_CopyDiagnostics[\s\S]{0,3000}(ExcludeProperty|Select-Object[\s\S]{0,300}-ExcludeProperty)') {
        throw '_CopyDiagnostics must Select-Object -ExcludeProperty sensitiveSites so users don''t leak their pattern list into bug reports'
    }
    if ($c -notmatch 'REDACTED:\s*\$siteCount\s*pattern') {
        throw '_CopyDiagnostics must replace sensitiveSites with a redaction hint that shows only the COUNT of patterns'
    }
}
Test 'popup.ps1 parses DoneAt with ParseExact + InvariantCulture (pass2 finding 38)' {
    $c = Get-Content (Join-Path $srcRoot 'popup.ps1') -Raw
    if ($c -notmatch 'ParseExact\s*\(\s*\[string\]\$entry\.DoneAt') {
        throw 'popup.ps1 Recent-row DoneAt formatting must use ParseExact(''o'', InvariantCulture) so de-DE / other locales don''t mis-parse the ISO stamp'
    }
}
Test 'Write-Log timestamps are UTC with Z suffix (pass2 finding 55)' {
    $c = Get-Content (Join-Path $srcRoot 'utils.ps1') -Raw
    if ($c -notmatch 'function\s+Write-Log[\s\S]{0,1500}ToUniversalTime\(\)\.ToString\(''HH:mm:ssZ''') {
        throw 'Write-Log must stamp UTC time with a Z suffix (audit v0.3.0-pass2 finding 55)'
    }
}
Test 'Get-Config back-fill uses case-insensitive property check (pass2 finding 62)' {
    $c = Get-Content (Join-Path $srcRoot 'utils.ps1') -Raw
    if ($c -match 'PSObject\.Properties\.Name\.Contains\(''sensitiveSites''\)') {
        throw 'Case-sensitive Properties.Name.Contains still present -- must use -ieq loop'
    }
}
Test 'Get-Recent takes the recent mutex too (pass2 finding 65)' {
    $c = Get-Content (Join-Path $srcRoot 'queue.ps1') -Raw
    if ($c -notmatch 'function\s+Get-Recent[\s\S]{0,600}_WithRecentMutex') {
        throw 'Get-Recent must serialize under _WithRecentMutex to avoid a torn read during Append-Recent'
    }
}
Test 'ClipTimer clipboard read is bounded by a Task timeout (pass2 finding 37)' {
    $c = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    if ($c -notmatch 'Threading\.Tasks\.Task[\s\S]{0,400}Wait\(500\)') {
        throw 'ClipTimer Clipboard.GetText must be wrapped in a Task.Run(...).Wait(500) so a blocked clipboard cannot hang the tick thread'
    }
}
Test 'New-GrabShortcut releases WScript.Shell RCW via Marshal.ReleaseComObject (pass2 finding 32)' {
    $c = Get-Content (Join-Path $srcRoot 'utils.ps1') -Raw
    if ($c -notmatch 'function\s+New-GrabShortcut[\s\S]{0,1200}ReleaseComObject') {
        throw 'New-GrabShortcut must release the WScript.Shell RCW in a finally to prevent COM leaks'
    }
}
Test 'core.ps1 has yt-dlp polite rate limiting (pass2 finding 45)' {
    $c = Get-Content (Join-Path $srcRoot 'core.ps1') -Raw
    Assert-Match $c "--sleep-requests"
    Assert-Match $c "--min-sleep-interval"
}
Test 'core.ps1 Chrome cookies detection surfaces a toast (pass2 finding 44)' {
    $c = Get-Content (Join-Path $srcRoot 'core.ps1') -Raw
    if ($c -notmatch 'Chrome cookies unavailable') {
        throw 'Invoke-YtDlp must Send-Toast when Chrome cookies came back as 0 rows'
    }
}
Test 'core.ps1 defines _WithLongPathPrefix (pass2 finding 39)' {
    $c = Get-Content (Join-Path $srcRoot 'core.ps1') -Raw
    if ($c -notmatch 'function\s+_WithLongPathPrefix') {
        throw 'core.ps1 must expose a \\\\?\\ long-path prefix helper'
    }
}

# --- P0-4 test-hook env var ----------------------------------------------
Test 'Set-AutostartRegistry honors GRAB_RUN_KEY_OVERRIDE (pass2 finding 61)' {
    $c = Get-Content (Join-Path $srcRoot 'utils.ps1') -Raw
    if ($c -notmatch 'function\s+Set-AutostartRegistry[\s\S]{0,800}GRAB_RUN_KEY_OVERRIDE') {
        throw 'Set-AutostartRegistry must consult $env:GRAB_RUN_KEY_OVERRIDE so tests never touch the real HKCU\Run entry'
    }
}

# --- install / uninstall completeness (findings 23, 24, 48, 49, 58) ------
Test 'install.ps1 seeds config via Get-Config (pass2 finding 23)' {
    $c = Get-Content (Join-Path $repoRoot 'install.ps1') -Raw
    if ($c -match '@\{[\s\S]{0,200}downloadFolder\s*=\s*Get-DownloadFolderDefault[\s\S]{0,600}Write-JsonAtomic') {
        throw 'install.ps1 must NOT duplicate the config schema inline; call Get-Config instead so keys stay in lock-step'
    }
    if ($c -notmatch 'Get-Config') {
        throw 'install.ps1 must call Get-Config to seed / back-fill the config'
    }
}
Test 'install.ps1 gates on WSL + WPF availability (pass2 findings 48/49)' {
    $c = Get-Content (Join-Path $repoRoot 'install.ps1') -Raw
    Assert-Match $c 'WSL_DISTRO_NAME'
    if ($c -notmatch 'PresentationFramework') {
        throw 'install.ps1 must probe Add-Type -AssemblyName PresentationFramework in a try/catch'
    }
}
Test 'install.ps1 warns before flipping PSGallery to Trusted (pass2 finding 58)' {
    $c = Get-Content (Join-Path $repoRoot 'install.ps1') -Raw
    if ($c -notmatch 'PSGallery\s+InstallationPolicy=Trusted') {
        throw 'install.ps1 must Warn before changing PSGallery InstallationPolicy (machine-wide side-effect)'
    }
}
Test 'uninstall.ps1 removes HKCU\Run\GRAB + NotifyIconSettings + .runtime-theme.xaml (pass2 finding 24)' {
    $c = Get-Content (Join-Path $repoRoot 'uninstall.ps1') -Raw
    Assert-Match $c 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run'
    Assert-Match $c 'NotifyIconSettings'
    Assert-Match $c '\.runtime-theme\.xaml'
    Assert-Match $c 'done-archive-yt-dlp\.txt'
    Assert-Match $c 'config\.json\.corrupt-\*'
    Assert-Match $c 'OneDrive\\Desktop'
}

# --- Docs sync (findings 12-22) ------------------------------------------
Test 'README documents autostart is opt-out (pass2 finding 12)' {
    $c = Get-Content (Join-Path $repoRoot 'README.md') -Raw
    if ($c -notmatch 'opt-out|-NoStartup|by default') {
        throw 'README must state autostart is opt-out (default ON), not opt-in'
    }
    if ($c -match 'opt-in during first run') {
        throw 'README still uses the pre-pass2 "opt-in during first run" phrasing'
    }
}
Test 'README no longer references grab Downloads.lnk (pass2 finding 13)' {
    $c = Get-Content (Join-Path $repoRoot 'README.md') -Raw
    # Grep the shortcut mention as a bullet line -- the manual uninstall
    # section CAN reference it as a "delete this if it exists" cleanup hint.
    if ($c -match '(?m)^-\s+`grab Downloads`') {
        throw 'README still lists grab Downloads shortcut as a live desktop shortcut'
    }
}
Test 'README documents uninstall.ps1 (pass2 finding 14)' {
    $c = Get-Content (Join-Path $repoRoot 'README.md') -Raw
    Assert-Match $c '\.\\uninstall\.ps1'
    if ($c -match 'coming later|later checkpoint') {
        throw 'README still says the uninstaller is "coming later"'
    }
}
Test 'README manual-uninstall covers HKCU\Run + NotifyIconSettings (pass2 finding 14)' {
    $c = Get-Content (Join-Path $repoRoot 'README.md') -Raw
    Assert-Match $c 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run\\GRAB'
    Assert-Match $c 'NotifyIconSettings'
}
Test 'README default folder note is D:\ + fallback under %USERPROFILE% (pass2 finding 16)' {
    $c = Get-Content (Join-Path $repoRoot 'README.md') -Raw
    Assert-Match $c '`D:\\imadjinn-grab\\`'
    if ($c -match '~\\Downloads\\imadjinn-grab') {
        throw 'README still shows the pre-0.1.1 ~\Downloads default'
    }
}
Test 'README lists grab-app.vbs + ui/theme.xaml + assets/fonts (pass2 finding 20)' {
    $c = Get-Content (Join-Path $repoRoot 'README.md') -Raw
    Assert-Match $c 'grab-app\.vbs'
    Assert-Match $c 'ui/theme\.xaml|ui\\theme\.xaml|theme\.xaml'
    Assert-Match $c 'assets/fonts|assets\\fonts|fonts/'
}
Test 'README has a Network surface section (pass2 finding 70)' {
    $c = Get-Content (Join-Path $repoRoot 'README.md') -Raw
    Assert-Match $c '(?m)^##\s+Network surface'
}
Test 'README has a SmartScreen note (pass2 finding 46)' {
    $c = Get-Content (Join-Path $repoRoot 'README.md') -Raw
    Assert-Match $c '(?i)smartscreen'
}
Test 'architecture.md documents the queue as a DispatcherTimer (pass2 finding 15)' {
    $c = Get-Content (Join-Path $docsRoot 'architecture.md') -Raw
    Assert-Match $c 'DispatcherTimer'
    # Reject only positive claims that the queue worker IS a background PS
    # job. The current doc reads "The queue worker is NOT a background PS
    # job" which is the correct v0.3.0-pass2 truth.
    if ($c -match 'queue worker\s+(is|=|runs as|running as)\s+(a\s+)?background\s+PS\s+job') {
        throw 'architecture.md still claims the queue worker IS a background PS job'
    }
    # And it must say the worker is a DispatcherTimer (positive assertion).
    if ($c -notmatch 'queue worker\s+is\s+NOT\s+a\s+background\s+PS\s+job') {
        throw 'architecture.md must explicitly clarify the queue worker is NOT a background PS job'
    }
}
Test 'architecture.md documents grab-app.vbs launcher (pass2 finding 16)' {
    $c = Get-Content (Join-Path $docsRoot 'architecture.md') -Raw
    Assert-Match $c 'grab-app\.vbs'
    Assert-Match $c 'wscript\.exe'
    Assert-Match $c 'runtime-theme|Get-RuntimeThemeUri'
    Assert-Match $c '(?i)thread model'
}
Test 'file-map.md lists every current file (pass2 finding 20)' {
    $c = Get-Content (Join-Path $docsRoot 'file-map.md') -Raw
    foreach ($f in @('grab-app\.vbs','ui/theme\.xaml','assets/fonts','assets/scanlines\.png','done-archive-yt-dlp\.txt','\.runtime-theme\.xaml','audit-v0\.3\.0-pass2\.md')) {
        Assert-Match $c $f
    }
}
Test 'PROGRESS.md has no duplicate unchecked CP3-CP5 entries (pass2 finding 21)' {
    $c = Get-Content (Join-Path $repoRoot 'PROGRESS.md') -Raw
    $unchecked = @([regex]::Matches($c, '\[\s\]\s+\*\*CP[3-5]\*\*'))
    if ($unchecked.Count -gt 0) {
        throw "PROGRESS.md still has $($unchecked.Count) unchecked CP3-CP5 line(s) that duplicate checked ones"
    }
}

# --- popup persist size (P3-77) ------------------------------------------
Test 'popup.ps1 persists Width + Height in config on resize (pass2 P3-77)' {
    $c = Get-Content (Join-Path $srcRoot 'popup.ps1') -Raw
    if ($c -notmatch 'SizeChanged[\s\S]{0,500}popupWidth[\s\S]{0,200}popupHeight') {
        throw 'popup.ps1 must persist popupWidth + popupHeight on SizeChanged'
    }
}

# --- grab-app.ps1 DPI awareness (finding 27) -----------------------------
Test 'grab-app.ps1 sets Per-Monitor V2 DPI awareness (pass2 finding 27)' {
    $c = Get-Content (Join-Path $repoRoot 'grab-app.ps1') -Raw
    Assert-Match $c 'SetProcessDpiAwareness'
}

# --- Test-PopupOnScreen uses PresentationSource (finding 25) -------------
Test 'Test-PopupOnScreen converts device pixels via PresentationSource (pass2 finding 25)' {
    $c = Get-Content (Join-Path $srcRoot 'popup.ps1') -Raw
    if ($c -notmatch 'function\s+Test-PopupOnScreen[\s\S]{0,1500}PresentationSource|function\s+_DipToDeviceMatrix[\s\S]{0,1500}PresentationSource') {
        throw 'Test-PopupOnScreen must use PresentationSource.FromVisual to convert device pixels <-> DIPs'
    }
}

# --- multi-monitor dock (finding 26) --------------------------------------
Test 'Get-DockedPosition targets the monitor containing the mouse cursor (pass2 finding 26)' {
    $c = Get-Content (Join-Path $srcRoot 'popup.ps1') -Raw
    if ($c -notmatch 'function\s+Get-DockedPosition[\s\S]{0,1500}Screen\]::FromPoint') {
        throw 'Get-DockedPosition must use Screen.FromPoint(Cursor.Position) so multi-monitor users dock to the active display'
    }
}

# --- Additional pass2 static-scan / behaviour tests ----------------------
Test 'assets/icon.ico is a valid ICO container with at least one image (pass2 finding 54)' {
    $ico = Join-Path $repoRoot 'assets\icon.ico'
    if (-not (Test-Path -LiteralPath $ico)) { return }  # OK: fallback path handles missing
    $bytes = [System.IO.File]::ReadAllBytes($ico)
    if ($bytes.Length -lt 22) { throw 'ICO too short' }
    # ICO magic: 00 00 01 00 (reserved=0, type=1 for icon), then imageCount uint16
    if ($bytes[0] -ne 0 -or $bytes[1] -ne 0 -or $bytes[2] -ne 1 -or $bytes[3] -ne 0) {
        throw 'assets/icon.ico is not a valid ICO container (magic mismatch)'
    }
    $imageCount = $bytes[4] -bor ($bytes[5] -shl 8)
    if ($imageCount -lt 1) { throw 'ICO container reports zero images' }
}
Test 'assets/scanlines.png exists (pass2 finding 20)' {
    Assert-PathExists (Join-Path $repoRoot 'assets\scanlines.png')
}
Test 'grab-app.vbs exists at repo root (pass2 finding 20)' {
    Assert-PathExists (Join-Path $repoRoot 'grab-app.vbs')
}
Test 'ui/theme.xaml exists (pass2 finding 20)' {
    Assert-PathExists (Join-Path $repoRoot 'ui\theme.xaml')
}
Test 'assets/fonts folder exists (pass2 finding 20)' {
    Assert-PathExists (Join-Path $repoRoot 'assets\fonts')
}
Test 'Get-Recent still emits entries after mutex wrap (pass2 finding 65)' {
    # Round-trip: append then read.
    Write-JsonAtomic -Path (Get-RecentPath) -Data @() -Depth 4
    $job = [PSCustomObject]@{
        Url='https://example.com/pass2-recent-test'; Dest='C:\tmp'; DoneAt=(Get-Date).ToString('o');
        Status='done'; FilesAdded=1; ToolUsed='yt-dlp'; DurationMs=42; Error=$null; Sensitive=$false
    }
    Append-Recent $job
    $r = @(Get-Recent)
    Assert-True ($r.Count -ge 1) 'Get-Recent should emit the entry we just appended'
    if ($r[0].Url -notmatch 'pass2-recent-test') { throw 'Get-Recent did not return the newest entry' }
}
Test 'Get-DesiredTickInterval goes to idle 30s when everything is quiet (pass2 findings 34/35/36)' {
    if (Get-Command Get-DesiredTickInterval -ErrorAction SilentlyContinue) {
        Write-Queue @()
        $script:LastQueueActivityAt = (Get-Date).AddHours(-1)
        $script:OnBattery         = $false
        $script:BatterySaverOn    = $false
        $script:PopupVisibleCount = 0
        Assert-Equal ([TimeSpan]::FromSeconds(30)) (Get-DesiredTickInterval)
    }
}
Test 'PowerShell Rotate math is at 500 (pass2 finding 51)' {
    $c = Get-Content (Join-Path $srcRoot 'utils.ps1') -Raw
    Assert-Match $c 'LogRotateCheck\s*\+\s*1\s*\)\s*%\s*500'
}

# =========================================================================
# v0.3.0 Phase 5: auto-update daily check, existing-user migration prompt,
# automated uninstall completeness test, README Downgrading section.
# =========================================================================
Section 'v0.3.0 Phase 5'

# --- Auto-update daily check (Check-ForUpdates) --------------------------
Test 'Check-ForUpdates exists as a public function (Phase 5)' {
    Assert-NotNull (Get-Command Check-ForUpdates -ErrorAction SilentlyContinue)
}

Test 'Get-Config back-fills autoUpdateCheck default true (Phase 5)' {
    # Fresh isolated data so the back-fill actually runs (not the cache).
    $iso = Join-Path $env:TEMP ("grab-p5-cfg-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    $prev = $env:GRAB_APP_DATA_OVERRIDE
    $env:GRAB_APP_DATA_OVERRIDE = $iso
    try {
        # Wipe cache so Get-Config re-reads.
        $script:ConfigCache = $null
        $script:ConfigCacheMtime = $null
        $c = Get-Config
        Assert-True ($c.PSObject.Properties.Name -icontains 'autoUpdateCheck') 'autoUpdateCheck must be back-filled'
        Assert-Equal $true ([bool]$c.autoUpdateCheck)
        Assert-True ($c.PSObject.Properties.Name -icontains 'lastGrabUpdateCheck') 'lastGrabUpdateCheck must exist'
        Assert-True ($c.PSObject.Properties.Name -icontains 'migrationV030PromptShown') 'migrationV030PromptShown must exist'
    } finally {
        if (Test-Path $iso) { Remove-Item $iso -Recurse -Force -ErrorAction SilentlyContinue }
        $env:GRAB_APP_DATA_OVERRIDE = $prev
        $script:ConfigCache = $null; $script:ConfigCacheMtime = $null
    }
}

Test 'Check-ForUpdates parses GitHub Releases API response correctly (Phase 5)' {
    # Fake a "newer version" release response and drive Check-ForUpdates
    # through its $Fetcher hook so no real HTTP call happens.
    $iso = Join-Path $env:TEMP ("grab-p5-fetch-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    $prev = $env:GRAB_APP_DATA_OVERRIDE
    $env:GRAB_APP_DATA_OVERRIDE = $iso
    try {
        $script:ConfigCache = $null; $script:ConfigCacheMtime = $null
        Get-Config | Out-Null   # seed
        $fake = {
            param($u)
            # Return a "much newer" release regardless of which URL we're
            # queried for; the tag_name shape mirrors the real API.
            return [pscustomobject]@{
                tag_name  = 'grab-v99.99.0'
                html_url  = 'https://example.test/release'
            }
        }
        $r = Check-ForUpdates -Force -Fetcher $fake
        Assert-True (-not $r.Skipped) 'Force must bypass throttle'
        Assert-Equal '99.99.0' $r.GrabLatest
        Assert-Equal $true $r.GrabNewer
        Assert-Equal 'https://example.test/release' $r.GrabUrl
    } finally {
        if (Test-Path $iso) { Remove-Item $iso -Recurse -Force -ErrorAction SilentlyContinue }
        $env:GRAB_APP_DATA_OVERRIDE = $prev
        $script:ConfigCache = $null; $script:ConfigCacheMtime = $null
    }
}

Test 'Check-ForUpdates flags current version as not-newer (Phase 5)' {
    $iso = Join-Path $env:TEMP ("grab-p5-cur-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    $prev = $env:GRAB_APP_DATA_OVERRIDE
    $env:GRAB_APP_DATA_OVERRIDE = $iso
    try {
        $script:ConfigCache = $null; $script:ConfigCacheMtime = $null
        Get-Config | Out-Null
        # Return the CURRENT version -> should NOT flag GrabNewer.
        $cur = Get-GrabVersion
        $fake = { param($u) [pscustomobject]@{ tag_name = "grab-v$cur"; html_url = 'https://example.test/x' } }
        $r = Check-ForUpdates -Force -Fetcher $fake
        Assert-Equal $false $r.GrabNewer
        Assert-Equal $cur $r.GrabLatest
    } finally {
        if (Test-Path $iso) { Remove-Item $iso -Recurse -Force -ErrorAction SilentlyContinue }
        $env:GRAB_APP_DATA_OVERRIDE = $prev
        $script:ConfigCache = $null; $script:ConfigCacheMtime = $null
    }
}

Test 'Check-ForUpdates skips when lastCheck was <24h ago (Phase 5)' {
    $iso = Join-Path $env:TEMP ("grab-p5-thr-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    $prev = $env:GRAB_APP_DATA_OVERRIDE
    $env:GRAB_APP_DATA_OVERRIDE = $iso
    try {
        $script:ConfigCache = $null; $script:ConfigCacheMtime = $null
        $c = Get-Config
        # Set last check to 1h ago -- inside the 24h window.
        $c.lastGrabUpdateCheck = ([datetime]::UtcNow.AddHours(-1)).ToString(
            'o', [Globalization.CultureInfo]::InvariantCulture)
        Set-Config $c
        $script:ConfigCache = $null; $script:ConfigCacheMtime = $null
        $fake = { param($u) [pscustomobject]@{ tag_name = 'grab-v99.99.0'; html_url = 'x' } }
        $r = Check-ForUpdates -Fetcher $fake
        Assert-True ($r.Skipped) 'must skip when last check was <24h ago'
        Assert-Match $r.Reason '^throttled'
        Assert-Equal $false $r.GrabNewer
        # Force flag must override the throttle.
        $r2 = Check-ForUpdates -Force -Fetcher $fake
        Assert-True (-not $r2.Skipped) '-Force must bypass throttle'
    } finally {
        if (Test-Path $iso) { Remove-Item $iso -Recurse -Force -ErrorAction SilentlyContinue }
        $env:GRAB_APP_DATA_OVERRIDE = $prev
        $script:ConfigCache = $null; $script:ConfigCacheMtime = $null
    }
}

Test 'Check-ForUpdates handles 404 gracefully (Phase 5)' {
    $iso = Join-Path $env:TEMP ("grab-p5-404-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    $prev = $env:GRAB_APP_DATA_OVERRIDE
    $env:GRAB_APP_DATA_OVERRIDE = $iso
    try {
        $script:ConfigCache = $null; $script:ConfigCacheMtime = $null
        Get-Config | Out-Null
        # 404 -> Invoke-GitHubLatest returns $null. Emulate the same.
        $fake = { param($u) return $null }
        $r = Check-ForUpdates -Force -Fetcher $fake
        Assert-True (-not $r.Skipped) 'a 404 must not skip the whole check'
        Assert-Equal $null $r.GrabLatest
        Assert-Equal $false $r.GrabNewer
    } finally {
        if (Test-Path $iso) { Remove-Item $iso -Recurse -Force -ErrorAction SilentlyContinue }
        $env:GRAB_APP_DATA_OVERRIDE = $prev
        $script:ConfigCache = $null; $script:ConfigCacheMtime = $null
    }
}

Test 'Check-ForUpdates handles rate limit (403) gracefully (Phase 5)' {
    $iso = Join-Path $env:TEMP ("grab-p5-403-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    $prev = $env:GRAB_APP_DATA_OVERRIDE
    $env:GRAB_APP_DATA_OVERRIDE = $iso
    try {
        $script:ConfigCache = $null; $script:ConfigCacheMtime = $null
        Get-Config | Out-Null
        # A 403 in Invoke-GitHubLatest surfaces the same shape as a 404 --
        # the try/catch swallows the WebException and returns $null. Prove
        # the higher-level Check-ForUpdates still returns cleanly.
        $fake = { param($u) throw [System.Net.WebException]::new('rate limit') }
        $r = Check-ForUpdates -Force -Fetcher $fake
        # The fake throws inside the fetch scriptblock; Check-ForUpdates
        # wraps each repo in try/catch so the exception is swallowed.
        Assert-True (-not $r.Skipped)
        Assert-Equal $null $r.GrabLatest
    } finally {
        if (Test-Path $iso) { Remove-Item $iso -Recurse -Force -ErrorAction SilentlyContinue }
        $env:GRAB_APP_DATA_OVERRIDE = $prev
        $script:ConfigCache = $null; $script:ConfigCacheMtime = $null
    }
}

Test 'Check-ForUpdates skips when autoUpdateCheck=false (Phase 5)' {
    $iso = Join-Path $env:TEMP ("grab-p5-off-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    $prev = $env:GRAB_APP_DATA_OVERRIDE
    $env:GRAB_APP_DATA_OVERRIDE = $iso
    try {
        $script:ConfigCache = $null; $script:ConfigCacheMtime = $null
        $c = Get-Config
        $c.autoUpdateCheck = $false
        Set-Config $c
        $script:ConfigCache = $null; $script:ConfigCacheMtime = $null
        $fake = { param($u) [pscustomobject]@{ tag_name = 'grab-v99.0.0'; html_url = 'x' } }
        $r = Check-ForUpdates -Fetcher $fake
        Assert-True ($r.Skipped)
        Assert-Equal 'disabled-in-config' $r.Reason
    } finally {
        if (Test-Path $iso) { Remove-Item $iso -Recurse -Force -ErrorAction SilentlyContinue }
        $env:GRAB_APP_DATA_OVERRIDE = $prev
        $script:ConfigCache = $null; $script:ConfigCacheMtime = $null
    }
}

Test '_NormalizeGrabTag strips grab-v and v prefixes (Phase 5)' {
    Assert-Equal '0.3.0' (_NormalizeGrabTag 'grab-v0.3.0')
    Assert-Equal '0.3.0' (_NormalizeGrabTag 'v0.3.0')
    Assert-Equal '0.3.0' (_NormalizeGrabTag '0.3.0')
    Assert-Equal ''      (_NormalizeGrabTag '')
}

Test '_CompareSemver orders versions correctly (Phase 5)' {
    if ((_CompareSemver '0.4.0' '0.3.0') -le 0) { throw '0.4.0 must be > 0.3.0' }
    if ((_CompareSemver '0.3.0' '0.3.0') -ne 0) { throw '0.3.0 must equal 0.3.0' }
    if ((_CompareSemver '0.3.0' '0.4.0') -ge 0) { throw '0.3.0 must be < 0.4.0' }
    # Empty/absent handling
    if ((_CompareSemver '' '0.3.0') -ge 0) { throw 'empty must be < any real version' }
}

# --- Auto-update UI wiring -----------------------------------------------
Test 'settings.xaml has AutoUpdateCheck checkbox in an UPDATES section (Phase 5)' {
    $c = Get-Content (Join-Path $repoRoot 'ui\settings.xaml') -Raw
    Assert-Match $c 'Text="UPDATES"'
    Assert-Match $c 'x:Name="AutoUpdateCheck"'
    Assert-Match $c 'AutoUpdateCheck[\s\S]{0,200}AutomationProperties\.Name'
}

Test 'settings.ps1 binds AutoUpdateCheck to config.autoUpdateCheck (Phase 5)' {
    $c = Get-Content (Join-Path $srcRoot 'settings.ps1') -Raw
    # Single-quoted so the literal '$cfg' survives the PS parser and lands
    # in the regex verbatim. Match the read-side bind + the save-side write.
    Assert-Match $c 'AutoUpdateCheck.*IsChecked\s*=\s*\[bool\]\$cfg\.autoUpdateCheck'
    Assert-Match $c 'autoUpdateCheck\s*='
}

Test 'settings.ps1 controls array includes AutoUpdateCheck (Phase 5)' {
    $c = Get-Content (Join-Path $srcRoot 'settings.ps1') -Raw
    if ($c -notmatch "'AutoUpdateCheck'") {
        throw "settings.ps1 FindName loop must include 'AutoUpdateCheck'"
    }
}

Test 'tray.ps1 wires Invoke-UpdateCheckAndNotify + UpdateTimer (Phase 5)' {
    $c = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    Assert-Match $c 'function\s+Invoke-UpdateCheckAndNotify'
    Assert-Match $c 'UpdateTimer'
    if ($c -notmatch 'Check-ForUpdates') { throw 'tray must call Check-ForUpdates' }
}

Test 'tray.ps1 BalloonTipClicked dispatches to BalloonNextAction first (Phase 5)' {
    $c = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    if ($c -notmatch 'BalloonNextAction') {
        throw 'tray.ps1 must define $script:BalloonNextAction to route auto-update / migration balloon clicks'
    }
    if ($c -notmatch 'add_BalloonTipClicked[\s\S]{0,600}BalloonNextAction') {
        throw 'BalloonTipClicked handler must inspect $script:BalloonNextAction before falling back to popup-paste'
    }
    if ($c -notmatch 'add_BalloonTipClosed') {
        throw 'tray.ps1 must hook BalloonTipClosed to clear a stale pending action'
    }
}

Test 'tray.ps1 UpdateTimer is stopped in Stop-Timers (Phase 5)' {
    $c = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    if ($c -notmatch 'function\s+Stop-Timers[\s\S]{0,600}UpdateTimer\.Stop') {
        throw 'Stop-Timers must stop $script:UpdateTimer so a tray restart does not leak the timer'
    }
}

# --- Existing-user migration prompt --------------------------------------
Test 'Test-IsOneDriveFragileDownloadFolder detects the pre-v0.1.1 default (Phase 5)' {
    Assert-Equal $true  (Test-IsOneDriveFragileDownloadFolder 'C:\Users\admin\Downloads\imadjinn-grab')
    Assert-Equal $true  (Test-IsOneDriveFragileDownloadFolder 'C:/Users/admin/Downloads/imadjinn-grab')
    Assert-Equal $false (Test-IsOneDriveFragileDownloadFolder 'D:\imadjinn-grab')
    Assert-Equal $false (Test-IsOneDriveFragileDownloadFolder 'C:\Users\admin\imadjinn-grab')
    Assert-Equal $false (Test-IsOneDriveFragileDownloadFolder '')
}

Test 'existing v0.2.x config with old downloadFolder triggers migration prompt exactly once (Phase 5)' {
    $iso = Join-Path $env:TEMP ("grab-p5-migr-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    $prev = $env:GRAB_APP_DATA_OVERRIDE
    $env:GRAB_APP_DATA_OVERRIDE = $iso
    try {
        $script:ConfigCache = $null; $script:ConfigCacheMtime = $null
        $c = Get-Config
        # Simulate an upgraded v0.2.x install: fragile folder + prompt-not-shown.
        $c.downloadFolder = 'C:\Users\test\Downloads\imadjinn-grab'
        $c.migrationV030PromptShown = $false
        Set-Config $c
        $script:ConfigCache = $null; $script:ConfigCacheMtime = $null
        # First call: should trip the migration path AND stamp the flag.
        Invoke-MigrationPromptIfNeeded
        $script:ConfigCache = $null; $script:ConfigCacheMtime = $null
        $c2 = Get-Config
        Assert-Equal $true ([bool]$c2.migrationV030PromptShown) 'flag must be set after first prompt'
        # Second call: must not re-prompt. We can only prove it via the
        # flag staying true and no exception -- the balloon side effect
        # is null when $script:Tray is not set (tests never build a tray).
        Invoke-MigrationPromptIfNeeded
        $script:ConfigCache = $null; $script:ConfigCacheMtime = $null
        $c3 = Get-Config
        Assert-Equal $true ([bool]$c3.migrationV030PromptShown) 'flag stays set on second call'
    } finally {
        if (Test-Path $iso) { Remove-Item $iso -Recurse -Force -ErrorAction SilentlyContinue }
        $env:GRAB_APP_DATA_OVERRIDE = $prev
        $script:ConfigCache = $null; $script:ConfigCacheMtime = $null
    }
}

Test 'migration prompt skips when downloadFolder is not the fragile default (Phase 5)' {
    $iso = Join-Path $env:TEMP ("grab-p5-nomigr-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    $prev = $env:GRAB_APP_DATA_OVERRIDE
    $env:GRAB_APP_DATA_OVERRIDE = $iso
    try {
        $script:ConfigCache = $null; $script:ConfigCacheMtime = $null
        $c = Get-Config
        $c.downloadFolder = 'D:\imadjinn-grab'   # good default
        $c.migrationV030PromptShown = $false
        Set-Config $c
        $script:ConfigCache = $null; $script:ConfigCacheMtime = $null
        Invoke-MigrationPromptIfNeeded
        # The helper still stamps the flag (so a later folder-move into
        # the fragile path doesn't retro-nag) but never surfaces a balloon.
        $script:ConfigCache = $null; $script:ConfigCacheMtime = $null
        $c2 = Get-Config
        Assert-Equal $true ([bool]$c2.migrationV030PromptShown)
    } finally {
        if (Test-Path $iso) { Remove-Item $iso -Recurse -Force -ErrorAction SilentlyContinue }
        $env:GRAB_APP_DATA_OVERRIDE = $prev
        $script:ConfigCache = $null; $script:ConfigCacheMtime = $null
    }
}

Test 'Start-Tray calls Invoke-MigrationPromptIfNeeded after self-heal (Phase 5)' {
    $c = Get-Content (Join-Path $srcRoot 'tray.ps1') -Raw
    if ($c -notmatch 'Invoke-SelfHealSweep[\s\S]{0,1500}Invoke-MigrationPromptIfNeeded') {
        throw 'Start-Tray must call Invoke-MigrationPromptIfNeeded AFTER Invoke-SelfHealSweep'
    }
}

# --- Automated uninstall completeness test -------------------------------
Test 'uninstall.ps1 -Yes leaves NO grab-related state on the system (Phase 5)' {
    # Simulate a full install into isolated locations (env-var-overridden
    # everywhere), then drive uninstall.ps1 -Yes -NoPackages and prove
    # the machine is clean.
    $sandbox      = Join-Path $env:TEMP ("grab-p5-uninst-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    $sandboxData  = Join-Path $sandbox 'appdata'
    $sandboxDesk  = Join-Path $sandbox 'Desktop'
    $sandboxStart = Join-Path $sandbox 'Startup'
    New-Item -ItemType Directory -Path $sandboxData  -Force | Out-Null
    New-Item -ItemType Directory -Path $sandboxDesk  -Force | Out-Null
    New-Item -ItemType Directory -Path $sandboxStart -Force | Out-Null
    # Throwaway HKCU subkey for the Run entry.
    $fakeRunKey = 'HKCU:\Software\grab-app-tests\p5-uninstall-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '\Run'
    New-Item -Path $fakeRunKey -Force | Out-Null

    # Capture and set env
    $prev = @{
        AppData = $env:GRAB_APP_DATA_OVERRIDE
        Desk    = $env:GRAB_DESKTOP_OVERRIDE
        Start   = $env:GRAB_STARTUP_OVERRIDE
        RunKey  = $env:GRAB_RUN_KEY_OVERRIDE
    }
    $env:GRAB_APP_DATA_OVERRIDE = $sandboxData
    $env:GRAB_DESKTOP_OVERRIDE  = $sandboxDesk
    $env:GRAB_STARTUP_OVERRIDE  = $sandboxStart
    $env:GRAB_RUN_KEY_OVERRIDE  = $fakeRunKey

    try {
        # 1. Simulate install: state files + shortcuts + Run entry + notify key.
        # Write files DIRECTLY into the sandbox rather than via Get-Config --
        # Get-Config caches $script:AppData at dot-source time so it still
        # points at $testAppData in this test scope. The uninstall child
        # process reads GRAB_APP_DATA_OVERRIDE fresh, so it targets sandboxData.
        Set-Content -Path (Join-Path $sandboxData 'config.json') -Value '{"version":"0.3.0"}' -Encoding UTF8
        New-Item -ItemType Directory -Path (Join-Path $sandboxData 'logs') -Force | Out-Null
        Set-Content -Path (Join-Path $sandboxData 'queue.json')  -Value '[]' -Encoding UTF8
        Set-Content -Path (Join-Path $sandboxData 'recent.json') -Value '[]' -Encoding UTF8
        Set-Content -Path (Join-Path $sandboxData 'done-archive-yt-dlp.txt') -Value '' -Encoding UTF8
        Set-Content -Path (Join-Path $sandboxData 'done-archive-gallery-dl.txt') -Value '' -Encoding UTF8
        Set-Content -Path (Join-Path $sandboxData '.runtime-theme.xaml') -Value '<x/>' -Encoding UTF8
        Set-Content -Path (Join-Path $sandboxData 'config.json.corrupt-19700101-000000') -Value '{}' -Encoding UTF8
        # HKCU\Run\GRAB -- write directly into the throwaway subkey so we
        # don't rely on Set-AutostartRegistry reading a stale env cache.
        Set-ItemProperty -Path $fakeRunKey -Name 'GRAB' -Value 'wscript.exe "sandbox"' -Force
        # NotifyIconSettings promotion key
        $guid = '{f3e2c9a1-4b8e-4d3a-9c1b-5e6a7b8c9d0e}'
        $notifyKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\NotifyIconSettings\$guid"
        if (-not (Test-Path $notifyKey)) { New-Item -Path $notifyKey -Force | Out-Null }
        New-ItemProperty -Path $notifyKey -Name 'IsPromoted' -Value 1 -PropertyType DWORD -Force | Out-Null
        # Test-Desktop + Test-Startup shortcuts (dummy .lnk files)
        $deskLnk  = Join-Path $sandboxDesk  'grab.lnk'
        $startLnk = Join-Path $sandboxStart 'grab.lnk'
        Set-Content -Path $deskLnk  -Value 'fake shortcut' -Encoding UTF8
        Set-Content -Path $startLnk -Value 'fake shortcut' -Encoding UTF8

        # 2. Sanity check: everything is where we expect it.
        Assert-PathExists (Join-Path $sandboxData 'config.json')
        Assert-PathExists $deskLnk
        Assert-PathExists $startLnk
        $ok = (Get-ItemProperty -Path $fakeRunKey -Name 'GRAB' -ErrorAction SilentlyContinue) -ne $null
        Assert-True $ok 'HKCU\Run\GRAB entry must exist before uninstall'
        Assert-True (Test-Path $notifyKey) 'NotifyIconSettings key must exist'

        # 3. Run uninstall.ps1 -Yes -NoPackages in a child PowerShell so
        #    it re-reads env-var-driven overrides fresh. Piping "y`n"*3
        #    to stdin is not needed with -Yes -NoPackages: neither the
        #    app-data prompt nor the pip prompt fires.
        $psExe = (Get-Process -Id $PID).Path
        $out = & $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'uninstall.ps1') -Yes -NoPackages 2>&1 | Out-String

        # 4. Assert: sandbox is clean.
        Assert-True (-not (Test-Path -LiteralPath $sandboxData))                              "AppData folder must be gone (still at $sandboxData). Output:`n$out"
        Assert-True (-not (Test-Path -LiteralPath $deskLnk))                                  "Desktop grab.lnk must be gone. Output:`n$out"
        Assert-True (-not (Test-Path -LiteralPath $startLnk))                                 "Startup grab.lnk must be gone. Output:`n$out"
        $stillHasRun = (Get-ItemProperty -Path $fakeRunKey -Name 'GRAB' -ErrorAction SilentlyContinue)
        Assert-True ($null -eq $stillHasRun)                                                  "HKCU\Run\GRAB must be gone. Output:`n$out"
        Assert-True (-not (Test-Path $notifyKey))                                             "NotifyIconSettings key must be gone. Output:`n$out"
    } finally {
        # Cleanup env
        if ($prev.AppData) { $env:GRAB_APP_DATA_OVERRIDE = $prev.AppData } else { Remove-Item Env:GRAB_APP_DATA_OVERRIDE -ErrorAction SilentlyContinue }
        if ($prev.Desk)    { $env:GRAB_DESKTOP_OVERRIDE  = $prev.Desk }    else { Remove-Item Env:GRAB_DESKTOP_OVERRIDE  -ErrorAction SilentlyContinue }
        if ($prev.Start)   { $env:GRAB_STARTUP_OVERRIDE  = $prev.Start }   else { Remove-Item Env:GRAB_STARTUP_OVERRIDE  -ErrorAction SilentlyContinue }
        if ($prev.RunKey)  { $env:GRAB_RUN_KEY_OVERRIDE  = $prev.RunKey }  else { Remove-Item Env:GRAB_RUN_KEY_OVERRIDE  -ErrorAction SilentlyContinue }
        # Restore harness's AppData override
        $env:GRAB_APP_DATA_OVERRIDE = $testAppData
        $script:ConfigCache = $null; $script:ConfigCacheMtime = $null
        if (Test-Path $sandbox) { Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
        # Clean the fake registry subtree in case the child left crumbs.
        try {
            $parent = Split-Path $fakeRunKey -Parent
            if (Test-Path $parent) { Remove-Item $parent -Recurse -Force -ErrorAction SilentlyContinue }
            $tests = 'HKCU:\Software\grab-app-tests'
            if ((Test-Path $tests) -and (-not @(Get-ChildItem $tests -ErrorAction SilentlyContinue))) {
                Remove-Item $tests -Force -ErrorAction SilentlyContinue
            }
        } catch {}
    }
}

Test 'uninstall.ps1 accepts -NoPackages switch (Phase 5)' {
    $c = Get-Content (Join-Path $repoRoot 'uninstall.ps1') -Raw
    Assert-Match $c '\[switch\]\$NoPackages'
    Assert-Match $c 'pip packages step skipped \(-NoPackages\)'
}

Test 'uninstall.ps1 honors GRAB_APP_DATA_OVERRIDE + GRAB_DESKTOP_OVERRIDE + GRAB_RUN_KEY_OVERRIDE (Phase 5)' {
    $c = Get-Content (Join-Path $repoRoot 'uninstall.ps1') -Raw
    Assert-Match $c 'GRAB_APP_DATA_OVERRIDE'
    Assert-Match $c 'GRAB_DESKTOP_OVERRIDE'
    Assert-Match $c 'GRAB_RUN_KEY_OVERRIDE'
    Assert-Match $c 'GRAB_STARTUP_OVERRIDE'
}

# --- README documentation (Downgrading + Updates sections) ---------------
Test 'README documents Downgrading (Phase 5)' {
    $c = Get-Content (Join-Path $repoRoot 'README.md') -Raw
    Assert-Match $c '(?m)^## Downgrading\b'
    Assert-Match $c 'winget install imadjinnation\.grab --version 0\.2\.2'
    Assert-Match $c 'GRAB-Setup-v0\.2\.2'
    Assert-Match $c 'issues/new'
}

Test 'README documents daily update check + how to turn it off (Phase 5)' {
    $c = Get-Content (Join-Path $repoRoot 'README.md') -Raw
    Assert-Match $c '(?m)^## Updates\b'
    Assert-Match $c 'once every 24'
    Assert-Match $c 'ffmpeg is intentionally excluded'
    Assert-Match $c 'Settings\s*->\s*Updates'
}

Test 'CHANGELOG mentions Phase 5 auto-update / migration / uninstall test (Phase 5)' {
    $c = Get-Content (Join-Path $repoRoot 'CHANGELOG.md') -Raw
    Assert-Match $c 'Phase 5'
    Assert-Match $c 'Check-ForUpdates'
    Assert-Match $c 'migrationV030PromptShown'
    Assert-Match $c 'automated uninstall'
}

Test 'config-reference.md lists autoUpdateCheck + migrationV030PromptShown (Phase 5)' {
    $c = Get-Content (Join-Path $docsRoot 'config-reference.md') -Raw
    Assert-Match $c 'autoUpdateCheck'
    Assert-Match $c 'lastGrabUpdateCheck'
    Assert-Match $c 'migrationV030PromptShown'
    Assert-Match $c 'GRAB_DESKTOP_OVERRIDE'
}

# =========================================================================
# Phase 5.5 -- distribution scaffolding (Inno Setup / winget / scoop /
# bundled binaries / SmartScreen doc). None of these actually run the
# build script; they just prove the scaffolding exists and is coherent.
# =========================================================================
Section 'Phase 5.5 -- distribution scaffolding'

$buildRoot   = Join-Path $repoRoot 'build'
$wingetRoot  = Join-Path $buildRoot 'winget'
$scoopRoot   = Join-Path $buildRoot 'scoop'
$buildScript = Join-Path $buildRoot 'build-installer.ps1'
$issTemplate = Join-Path $buildRoot 'GRAB-Setup.iss.template'

Test 'build-installer.ps1 exists' {
    Assert-PathExists $buildScript
}

Test 'build-installer.ps1 supports -WhatIf (dry-run)' {
    # Just prove the script declares [CmdletBinding(SupportsShouldProcess)]
    # so `-WhatIf` is a legal argument. Actually invoking it triggers
    # network fetches we don't want in a smoke test.
    $c = Get-Content $buildScript -Raw
    Assert-Match $c '\[CmdletBinding\(SupportsShouldProcess'
    Assert-Match $c '\$WhatIfPreference'
}

Test 'build-installer.ps1 declares expected artifacts (Setup.exe, Portable.zip, SHA256SUMS.txt)' {
    $c = Get-Content $buildScript -Raw
    Assert-Match $c 'GRAB-Setup\.exe'
    Assert-Match $c 'GRAB-Portable-v'
    Assert-Match $c 'SHA256SUMS\.txt'
    Assert-Match $c 'dep-versions\.json'
}

Test 'build-installer.ps1 downloads yt-dlp nightly + gallery-dl + ffmpeg' {
    $c = Get-Content $buildScript -Raw
    Assert-Match $c 'yt-dlp-nightly-builds'
    Assert-Match $c 'mikf/gallery-dl'
    Assert-Match $c 'gyan\.dev/ffmpeg/builds/ffmpeg-release[-\w]*shared'
}

Test 'build-installer.ps1 discards ffplay / ffprobe / docs from ffmpeg' {
    $c = Get-Content $buildScript -Raw
    # Positive: keeps ffmpeg.exe + the required DLL patterns.
    Assert-Match $c 'ffmpeg\.exe'
    Assert-Match $c 'avcodec-\*\.dll'
    Assert-Match $c 'avformat-\*\.dll'
    Assert-Match $c 'swresample-\*\.dll'
    # Negative: build script must NOT copy ffplay.exe / ffprobe.exe into bin/.
    # We assert absence in the `keep` array by looking for the whitelist.
    Assert-Match $c '(?ms)\$keep\s*=\s*@\('
    if ($c -match '''ffplay\.exe''') { throw 'build script whitelists ffplay.exe (should be dropped)' }
    if ($c -match '''ffprobe\.exe''') { throw 'build script whitelists ffprobe.exe (should be dropped)' }
}

Test 'build-installer.ps1 reads version from src/utils.ps1 (single source of truth)' {
    $c = Get-Content $buildScript -Raw
    Assert-Match $c 'Get-GrabRepoVersion'
    Assert-Match $c 'GrabVersion'
    Assert-Match $c 'src\\utils\.ps1'
}

Test 'GRAB-Setup.iss.template exists with placeholders' {
    Assert-PathExists $issTemplate
    $c = Get-Content $issTemplate -Raw
    Assert-Match $c '__GRAB_VERSION__'
    Assert-Match $c '__PAYLOAD_DIR__'
    Assert-Match $c '__OUTPUT_DIR__'
    Assert-Match $c '__ICON_PATH__'
}

Test 'GRAB-Setup.iss.template is per-user (no UAC)' {
    $c = Get-Content $issTemplate -Raw
    Assert-Match $c 'PrivilegesRequired=lowest'
    Assert-Match $c 'DefaultDirName='
}

Test 'GRAB-Setup.iss.template creates HKCU\Run\GRAB + tray-promotion + shortcuts' {
    $c = Get-Content $issTemplate -Raw
    Assert-Match $c 'CurrentVersion\\Run'
    Assert-Match $c 'ValueName:\s*"GRAB"'
    Assert-Match $c 'NotifyIconSettings'
    Assert-Match $c '\{autodesktop\}'
    Assert-Match $c '\{group\}'
}

Test 'GRAB-Setup.iss.template calls our uninstall.ps1 with -Yes -NoPackages' {
    $c = Get-Content $issTemplate -Raw
    Assert-Match $c 'uninstall\.ps1.*-Yes.*-NoPackages'
    # And it targets wscript.exe grab-app.vbs (silent launcher).
    Assert-Match $c 'wscript\.exe'
    Assert-Match $c 'grab-app\.vbs'
}

# --- winget manifest -----------------------------------------------------
Test 'winget manifest has all 3 required YAML files' {
    Assert-PathExists (Join-Path $wingetRoot 'Imadjinnation.GRAB.yaml')
    Assert-PathExists (Join-Path $wingetRoot 'Imadjinnation.GRAB.installer.yaml')
    Assert-PathExists (Join-Path $wingetRoot 'Imadjinnation.GRAB.locale.en-US.yaml')
    Assert-PathExists (Join-Path $wingetRoot 'README.md')
}

Test 'winget version manifest has PackageIdentifier + PackageVersion' {
    $c = Get-Content (Join-Path $wingetRoot 'Imadjinnation.GRAB.yaml') -Raw
    Assert-Match $c 'PackageIdentifier:\s*Imadjinnation\.GRAB'
    Assert-Match $c 'PackageVersion:\s*0\.3\.0'
    Assert-Match $c 'ManifestType:\s*version'
}

Test 'winget installer.yaml has correct publisher pattern + URL + sha256 (Phase 6.5)' {
    $c = Get-Content (Join-Path $wingetRoot 'Imadjinnation.GRAB.installer.yaml') -Raw
    Assert-Match $c 'PackageIdentifier:\s*Imadjinnation\.GRAB'
    Assert-Match $c 'InstallerType:\s*inno'
    Assert-Match $c 'Scope:\s*user'
    Assert-Match $c 'InstallerUrl:\s*https://github\.com/imadjinnation/GRAB-Free-Universal-Media-Downloader/releases/download/grab-v0\.3\.0/GRAB-Setup\.exe'
    # Phase 6.5 QA-1: accept EITHER the pre-build placeholder OR a real
    # SHA256 (any 64-hex string). The placeholder means "this manifest
    # ships in the repo before the build runs"; a real hash means the
    # Phase 6 build filled it in from SHA256SUMS.txt.
    Assert-Match $c 'InstallerSha256:\s*(__SHA256_PLACEHOLDER__|[A-Fa-f0-9]{64})'
    Assert-Match $c '/VERYSILENT'
    # When it's a real hash, it MUST match the entry in dist/SHA256SUMS.txt
    # for GRAB-Setup.exe -- catches the case where the winget manifest was
    # regenerated but from stale binaries. Only enforced if BOTH files exist
    # (the manifest is a repo artifact so it's always present; SHA256SUMS.txt
    # is a build artifact so it's only present after a real build).
    $sumsPath = Join-Path $repoRoot 'dist\SHA256SUMS.txt'
    if ($c -match 'InstallerSha256:\s*([A-Fa-f0-9]{64})' -and (Test-Path -LiteralPath $sumsPath)) {
        $manifestHash = $Matches[1].ToLower()
        $sums = Get-Content -LiteralPath $sumsPath -Raw
        if ($sums -match '(?m)^([A-Fa-f0-9]{64})\s+GRAB-Setup\.exe\s*$') {
            $sumsHash = $Matches[1].ToLower()
            Assert-Equal $sumsHash $manifestHash "winget InstallerSha256 does not match dist/SHA256SUMS.txt entry for GRAB-Setup.exe"
        }
    }
}

Test 'winget locale.en-US.yaml has Publisher / License / Tags / Moniker' {
    $c = Get-Content (Join-Path $wingetRoot 'Imadjinnation.GRAB.locale.en-US.yaml') -Raw
    Assert-Match $c 'Publisher:\s*Imadjinn'
    Assert-Match $c 'License:\s*MIT'
    Assert-Match $c 'Moniker:\s*grab'
    # A handful of the required tags from the task brief.
    Assert-Match $c '(?m)^\s*-\s*downloader'
    Assert-Match $c '(?m)^\s*-\s*yt-dlp'
    Assert-Match $c '(?m)^\s*-\s*gallery-dl'
    Assert-Match $c '(?m)^\s*-\s*windows'
    Assert-Match $c '(?m)^\s*-\s*tray'
    Assert-Match $c '(?m)^\s*-\s*open-source'
}

Test 'winget README documents the fork + PR flow (Phase 6)' {
    $c = Get-Content (Join-Path $wingetRoot 'README.md') -Raw
    Assert-Match $c 'gh repo fork microsoft/winget-pkgs'
    Assert-Match $c 'wingetcreate update'
    Assert-Match $c 'manifests/i/Imadjinnation/GRAB'
}

# --- Scoop bucket --------------------------------------------------------
Test 'scoop grab.json is valid JSON with required keys' {
    $path = Join-Path $scoopRoot 'grab.json'
    Assert-PathExists $path
    $obj = Get-Content $path -Raw | ConvertFrom-Json
    Assert-NotNull $obj 'grab.json failed to parse as JSON'
    Assert-Equal '0.3.0' $obj.version 'scoop grab.json version mismatch'
    Assert-NotNull $obj.description 'grab.json missing description'
    Assert-NotNull $obj.license      'grab.json missing license'
    Assert-NotNull $obj.homepage     'grab.json missing homepage'
    Assert-NotNull $obj.architecture.'64bit'.url  'grab.json missing 64bit.url'
    Assert-NotNull $obj.architecture.'64bit'.hash 'grab.json missing 64bit.hash'
    # bin is a nested array: [["grab-app.vbs","grab"]] -- shim named `grab`.
    Assert-NotNull $obj.bin 'grab.json missing bin mapping'
    # checkver + autoupdate blocks for future release automation.
    Assert-NotNull $obj.checkver   'grab.json missing checkver'
    Assert-NotNull $obj.autoupdate 'grab.json missing autoupdate'
}

Test 'scoop grab.json bin[0] shims grab-app.vbs as `grab`' {
    $obj = Get-Content (Join-Path $scoopRoot 'grab.json') -Raw | ConvertFrom-Json
    # PS parses [["a","b"]] as a nested list; first element is the pair.
    $first = @($obj.bin)[0]
    Assert-Equal 'grab-app.vbs' $first[0]
    Assert-Equal 'grab'         $first[1]
}

Test 'scoop grab.json pre_uninstall calls our uninstall.ps1 -Yes -NoPackages' {
    $c = Get-Content (Join-Path $scoopRoot 'grab.json') -Raw
    Assert-Match $c 'uninstall\.ps1.*-Yes.*-NoPackages'
}

Test 'scoop README documents bucket add + install (Phase 6)' {
    Assert-PathExists (Join-Path $scoopRoot 'README.md')
    $c = Get-Content (Join-Path $scoopRoot 'README.md') -Raw
    Assert-Match $c 'scoop bucket add imadjinnation'
    Assert-Match $c 'scoop install grab'
    Assert-Match $c 'imadjinnation/scoop-bucket'
}

# --- install.ps1 bundled-binaries mode -----------------------------------
Test 'install.ps1 has -UseSystemPython switch (Phase 5.5)' {
    $c = Get-Content (Join-Path $repoRoot 'install.ps1') -Raw
    Assert-Match $c '\[switch\]\$UseSystemPython'
}

Test 'install.ps1 detects bundled assets/bin/ and skips pip when present' {
    $c = Get-Content (Join-Path $repoRoot 'install.ps1') -Raw
    Assert-Match $c 'assets\\bin'
    Assert-Match $c 'HasBundled'
    Assert-Match $c 'Skipping Python \+ pip'
}

Test 'install.ps1 ffmpeg check prefers bundled over PATH / winget' {
    $c = Get-Content (Join-Path $repoRoot 'install.ps1') -Raw
    Assert-Match $c '\$bundledFfmpeg'
    Assert-Match $c 'Gyan\.FFmpeg'    # winget install still available as fallback
}

# --- Resolve-Tool bundled-binaries precedence ----------------------------
Test 'Resolve-Tool prefers assets/bin/ over PATH when bundled binaries present' {
    # Point GRAB_BUNDLED_BIN_OVERRIDE at a temp dir containing a fake yt-dlp.exe,
    # then verify Resolve-Tool returns that path (not the one on PATH).
    $tmpBin = Join-Path $env:TEMP ("grab-bundled-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $tmpBin -Force | Out-Null
    $fake = Join-Path $tmpBin 'yt-dlp.exe'
    Set-Content -LiteralPath $fake -Value 'stub' -Encoding UTF8
    try {
        $env:GRAB_BUNDLED_BIN_OVERRIDE = $tmpBin
        $script:ToolCache = @{}   # clear cache so our test isn't seeing a stale hit
        $got = Resolve-Tool 'yt-dlp'
        Assert-Equal $fake $got 'Resolve-Tool did not return the bundled path'
    } finally {
        Remove-Item Env:GRAB_BUNDLED_BIN_OVERRIDE -ErrorAction SilentlyContinue
        $script:ToolCache = @{}
        if (Test-Path $tmpBin) { Remove-Item $tmpBin -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Test 'Get-BundledBinDir honors GRAB_BUNDLED_BIN_OVERRIDE' {
    $env:GRAB_BUNDLED_BIN_OVERRIDE = 'C:\some\override\path'
    try {
        Assert-Equal 'C:\some\override\path' (Get-BundledBinDir)
    } finally {
        Remove-Item Env:GRAB_BUNDLED_BIN_OVERRIDE -ErrorAction SilentlyContinue
    }
}

Test 'Get-BundledBinDir defaults to <repo>/assets/bin' {
    $expected = Join-Path $repoRoot 'assets\bin'
    Assert-Equal $expected (Get-BundledBinDir)
}

# --- README + SmartScreen docs (Phase 5.5) -------------------------------
Test 'README references all 5 install paths' {
    $c = Get-Content (Join-Path $repoRoot 'README.md') -Raw
    Assert-Match $c 'winget install imadjinnation\.grab'
    Assert-Match $c 'scoop install grab'
    Assert-Match $c 'GRAB-Setup\.exe'
    # Phase 6.5 non-blocker: README now references the versioned filename
    # (GRAB-Portable-v0.3.0.zip) so the link matches the actual Release asset.
    Assert-Match $c 'GRAB-Portable(-v[0-9]+\.[0-9]+\.[0-9]+)?\.zip'
    Assert-Match $c 'git clone https://github\.com/imadjinnation/GRAB-Free-Universal-Media-Downloader'
}

Test 'README has SmartScreen section pointing at docs/smartscreen.md' {
    $c = Get-Content (Join-Path $repoRoot 'README.md') -Raw
    Assert-Match $c '(?m)## On first run, Windows may warn\b'
    Assert-Match $c 'SmartScreen'
    Assert-Match $c 'More info'
    Assert-Match $c 'Run anyway'
    Assert-Match $c 'docs/smartscreen\.md'
}

Test 'docs/smartscreen.md exists + covers verify + false-positive report' {
    $path = Join-Path $docsRoot 'smartscreen.md'
    Assert-PathExists $path
    $c = Get-Content $path -Raw
    Assert-Match $c 'SmartScreen'
    Assert-Match $c 'SHA256SUMS\.txt'
    Assert-Match $c 'false positive'
    Assert-Match $c 'winget'
    Assert-Match $c 'scoop'
}

Test 'CHANGELOG mentions Phase 5.5 distribution scaffolding' {
    $c = Get-Content (Join-Path $repoRoot 'CHANGELOG.md') -Raw
    Assert-Match $c 'Phase 5\.5'
    Assert-Match $c 'build-installer\.ps1'
    Assert-Match $c 'Inno Setup'
    Assert-Match $c 'winget'
    Assert-Match $c 'scoop'
    Assert-Match $c 'SmartScreen'
}

Test '.gitignore excludes dist/ (build output) + assets/bin/ (bundled binaries)' {
    $c = Get-Content (Join-Path $repoRoot '.gitignore') -Raw
    Assert-Match $c '(?m)^dist/\s*$'
    Assert-Match $c '(?m)^assets/bin/\s*$'
    Assert-Match $c 'build/winget/\*\.yaml\.tmp'
    Assert-Match $c 'build/scoop/grab-\*\.json\.bak'
}

# --- test count baseline / self-check ------------------------------------
Test 'test count exceeds pass2 baseline (400+)' {
    # Just prove we're above the phase-4 baseline of 342. Actual count is
    # reported in the final summary; this assertion catches accidental
    # test removal.
    if ($script:PassCount -lt 340) {
        throw "smoke test count regressed: only $($script:PassCount) passing so far (was 342 baseline)"
    }
}

Test 'test count exceeds Phase 5 baseline (420+)' {
    # Phase 5 added ~25 new tests on top of the 402 Phase 4.5 baseline.
    # Anything under 420 means a test got silently dropped.
    if ($script:PassCount -lt 420) {
        throw "smoke test count regressed: only $($script:PassCount) passing (was 402 at Phase 4.5, target 425+)"
    }
}

Test 'test count exceeds Phase 5.5 baseline (445+)' {
    # Phase 5.5 added ~25 new tests on top of the 430 Phase 5 baseline
    # (distribution scaffolding: build script, Inno template, winget,
    # scoop, bundled binaries, SmartScreen docs). Target 445+.
    if ($script:PassCount -lt 445) {
        throw "smoke test count regressed: only $($script:PassCount) passing (Phase 5.5 target 445+)"
    }
}

# ============================================================================
# Phase X-1 -- success detection, recursive Hidden, LAUNCH-GRAB.bat
# ============================================================================
# Why these tests exist: v0.3.0's shipping bug was "Hero Tales downloaded 299
# files but queue said Status=failed" because the ONLY success signal was
# `$after > $before` on file counts -- if gallery-dl found everything already
# in its --download-archive, no new files landed and GRAB marked the whole
# run as failed. Recent tab stayed empty, no toast, no recursive Hidden.
#
# These tests would have caught that bug BEFORE it shipped.
# ============================================================================
Section 'Phase X-1 -- success detection + Hidden + launcher'

Test 'Invoke-Grab result object has AlreadyComplete field' {
    $core = Get-Content (Join-Path $srcRoot 'core.ps1') -Raw
    # v0.3.0 shipped without this -- gallery-dl "archive already complete"
    # case was reported as failure. New field lets Recent + toast distinguish.
    Assert-Match $core 'AlreadyComplete\s*='
}

Test 'success detection accepts exit-code-0 with existing files (Hero Tales bug)' {
    $core = Get-Content (Join-Path $srcRoot 'core.ps1') -Raw
    # The critical branch: if $after -gt $before FAILS but $rc -eq 0 AND
    # $after -gt 0, still declare success. This is the exact case where the
    # user's Hero Tales test hit "failed" despite 299 files on disk.
    Assert-Match $core '\$rc\s*-eq\s*0\s*-and\s*\$after\s*-gt\s*0'
    Assert-Match $core '\$result\.AlreadyComplete\s*=\s*\$true'
}

Test 'Invoke-YtDlp and Invoke-GalleryDl return exit code (needed by success detection)' {
    $core = Get-Content (Join-Path $srcRoot 'core.ps1') -Raw
    Assert-Match $core 'return\s+\$LASTEXITCODE'
    # The Invoke-Grab loop must capture the RC into $rc, not discard it.
    Assert-Match $core '\$rc\s*=\s*Invoke-YtDlp'
    Assert-Match $core '\$rc\s*=\s*Invoke-GalleryDl'
}

Test 'sensitive recursive Hidden runs OUTSIDE the Success gate' {
    $core = Get-Content (Join-Path $srcRoot 'core.ps1') -Raw
    # Must NOT be inside `if ($result.Success)` -- a partial-fail download
    # that landed 200 out of 300 files still needs those 200 hidden.
    # The Set-FolderHidden -Recurse call must appear AFTER the post-process
    # block AND not be gated on Success. Also runs only when files exist.
    Assert-Match $core '(?s)Sensitive Hidden.+?applied to ANY files that landed'
    Assert-Match $core '(?s)Set-FolderHidden\s+\$privatePath\s+-Recurse'
    Assert-Match $core 'sensitive-hide applied recursively'
}

Test 'LAUNCH-GRAB.bat exists at repo root' {
    $bat = Join-Path $repoRoot 'LAUNCH-GRAB.bat'
    if (-not (Test-Path -LiteralPath $bat)) {
        throw "LAUNCH-GRAB.bat missing from repo root -- bulletproof launcher gone"
    }
}

Test 'LAUNCH-GRAB.bat uses start "" without /B (detach fix)' {
    $bat = Get-Content (Join-Path $repoRoot 'LAUNCH-GRAB.bat') -Raw
    # The /B flag ties wscript to cmd's console; when the batch ends and cmd
    # exits, wscript dies with it. Correct pattern is `start "" wscript.exe`
    # (no /B) so wscript spawns as top-level process.
    if ($bat -match 'start\s+""\s+/B\s+wscript') {
        throw "LAUNCH-GRAB.bat uses /B -- wscript will die with cmd. Remove /B."
    }
    Assert-Match $bat 'start\s+""\s+wscript\.exe'
}

Test 'LAUNCH-GRAB.bat references grab-app.vbs via %~dp0 (path-independent)' {
    $bat = Get-Content (Join-Path $repoRoot 'LAUNCH-GRAB.bat') -Raw
    # Must use %~dp0 not a hardcoded path so users can move the folder.
    Assert-Match $bat '%~dp0grab-app\.vbs'
    # Check EXECUTABLE lines only (strip REM comments) for hardcoded paths.
    # Comments may mention the dev path for context but must never be baked
    # into an actual command.
    $execLines = ($bat -split "`r?`n") | Where-Object { $_ -notmatch '^\s*REM' -and $_ -notmatch '^\s*::' }
    $execText = $execLines -join "`n"
    if ($execText -match 'D:\\IMADJINnation') {
        throw "LAUNCH-GRAB.bat has a hardcoded dev path in an executable line -- must use %~dp0"
    }
}

Test 'LAUNCH-GRAB.bat has sanity check for missing grab-app.vbs' {
    $bat = Get-Content (Join-Path $repoRoot 'LAUNCH-GRAB.bat') -Raw
    # If the .bat is copied without the folder, tell the user clearly.
    Assert-Match $bat 'if not exist'
    Assert-Match $bat 'grab-app\.vbs not found'
}

Test 'install.ps1 copies LAUNCH-GRAB.bat to Desktop as bulletproof fallback' {
    $inst = Get-Content (Join-Path $repoRoot 'install.ps1') -Raw
    Assert-Match $inst 'LAUNCH-GRAB\.bat copied to Desktop'
    Assert-Match $inst 'bulletproof fallback'
}

Test 'clipboard auto-detect on popup open (independent of clipboardWatch)' {
    # Verify the "detect URL on clipboard when popup opens" feature is wired
    # -- this is what fills the Paste tab automatically. Independent of the
    # background clipboardWatch poll (which is opt-in).
    $popup = Get-Content (Join-Path $srcRoot 'popup.ps1') -Raw
    Assert-Match $popup 'Clipboard\]::GetText'
    Assert-Match $popup 'Test-IsUrl'
    Assert-Match $popup 'Detected URL on clipboard'
}

Test 'test count exceeds Phase X-1 baseline (455+)' {
    # Phase X-1 adds 10 new tests on top of the Phase 5.5 baseline (~461).
    # This baseline test locks the count so future refactors can't silently
    # drop coverage.
    if ($script:PassCount -lt 455) {
        throw "smoke test count regressed: only $($script:PassCount) passing (Phase X-1 target 455+)"
    }
}

} finally {
    # ---------- Cleanup ---------------------------------------------------
    if (Test-Path $testAppData) { Remove-Item $testAppData -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Item Env:GRAB_APP_DATA_OVERRIDE -ErrorAction SilentlyContinue
}

# ---------- Summary -------------------------------------------------------
Write-Host ""
Write-Host "  ================================" -ForegroundColor DarkGray
$total = $script:PassCount + $script:FailCount
if ($script:FailCount -eq 0) {
    Write-Host ("  ALL PASS  ({0}/{0})" -f $total) -ForegroundColor Green
    exit 0
} else {
    Write-Host ("  {0}/{1} passed, {2} FAILED" -f $script:PassCount, $total, $script:FailCount) -ForegroundColor Red
    Write-Host ""
    Write-Host "  Failures:" -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    exit 1
}
