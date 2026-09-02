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
    Add-Type -AssemblyName PresentationFramework | Out-Null
    [xml]$x = Get-Content (Join-Path $uiRoot 'popup.xaml') -Raw
    $reader = New-Object System.Xml.XmlNodeReader $x
    $win = [Windows.Markup.XamlReader]::Load($reader)
    Assert-NotNull $win
    Assert-Equal 480 ([int]$win.Width)
    Assert-Equal 420 ([int]$win.Height)
    $script:XamlWindow = $win
}

$expectedControls = @('TitleBar','MinBtn','CloseBtn','TabPaste','TabQueue','TabRecent',
    'PastePanel','QueuePanel','RecentPanel','UrlBox','MultiBox',
    'SingleInputBorder','MultiInputBorder','Hint','StatusLine','ToggleMulti','GrabBtn')
foreach ($c in $expectedControls) {
    Test "popup.xaml has named control: $c" {
        if (-not $script:XamlWindow) { throw 'xaml load pass must run first' }
        $ctl = $script:XamlWindow.FindName($c)
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
                    'Resolve-Tool','Log-Info','Send-Toast')
    'core.ps1'  = @('Invoke-Grab','Get-FileCount')
    'queue.ps1' = @('Add-QueueJob','Read-Queue','Write-Queue','Cancel-QueueJob',
                    'Retry-QueueJob','Clear-QueueDone','Append-Recent','Get-Recent',
                    'Invoke-QueueTick','Stop-AllJobs')
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
    Assert-Equal '0.1.0' $c.version
    Assert-Equal $false  $c.askBeforeEach
    Assert-Equal $false  $c.clipboardWatch
    Assert-Equal 3       $c.concurrency
    Assert-NotNull $c.downloadFolder
    Assert-True (Test-Path (Get-ConfigPath)) 'config.json should be written'
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
    $cfg = Get-Config
    $expected = Join-Path $cfg.downloadFolder (Join-Path 'Comics' 'allporncomic.com')
    # We invoke on a URL that will fail cleanly (fake domain in the .com TLD
    # so category+domain still parse to Comics/... for the assertion below).
    # Use the real allporncomic URL structure but a bogus path to fail fast.
    $r = Invoke-Grab -Url 'https://allporncomic.com/porncomic/does-not-exist-xyz/' -NoCookies
    Assert-Equal $expected $r.Destination
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

Test 'grab-app.ps1 declares the singleton mutex correctly (prevents multi-tray bug)' {
    # Regression: earlier I forgot to pre-declare $script:GotLock and every
    # instance thought it was second, so NONE ran. Also, if this check is
    # missing entirely, restarts stack up N tray icons.
    $content = Get-Content (Join-Path $repoRoot 'grab-app.ps1') -Raw
    if ($content -notmatch 'GrabAppTraySingleton') {
        throw 'grab-app.ps1 missing named-mutex singleton (users can end up with duplicate tray icons)'
    }
    if ($content -notmatch '\$script:GotLock\s*=\s*\$false') {
        throw 'grab-app.ps1 must pre-declare $script:GotLock = $false before [ref] uses it (PS 5.1 quirk)'
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
    Add-Type -AssemblyName PresentationFramework | Out-Null
    [xml]$x = Get-Content (Join-Path $uiRoot 'settings.xaml') -Raw
    $reader = New-Object System.Xml.XmlNodeReader $x
    $win = [Windows.Markup.XamlReader]::Load($reader)
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
