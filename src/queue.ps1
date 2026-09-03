# src/queue.ps1
# Queue state + background worker. Single-process design: the tray runs a
# timer that dispatches pending jobs to PowerShell background jobs, watches
# them, and updates the JSON state file.
#
# State schema (queue.json is an array of these):
#   Id           [guid]     unique per job
#   Url          [string]
#   Dest         [string]   folder where files land (per-job override or null = default)
#   Tool         [string]   'auto' | 'yt-dlp' | 'gallery-dl'
#   Status       [string]   pending | running | done | failed | cancelled
#   StatusMsg    [string]   short one-line status for UI
#   AddedAt      [datetime]
#   StartedAt    [datetime?]
#   DoneAt       [datetime?]
#   DurationMs   [int]
#   FilesAdded   [int]
#   Error        [string?]
#   ToolUsed     [string?]  which tool actually produced files
#   UsedCookies  [bool?]
#   JobId        [int?]     underlying PS Job id while running
#
# Dot-source: . "$PSScriptRoot\queue.ps1"

. "$PSScriptRoot\utils.ps1"
. "$PSScriptRoot\core.ps1"

# ---------- Locking + safe file IO ----------------------------------------
# queue.json is read/written from multiple call sites; a mutex serializes access.
$script:QueueMutex = New-Object System.Threading.Mutex($false, 'Global\GrabAppQueueMutex')

function Read-Queue {
    # Emits queue entries using standard PS enumeration semantics:
    #   - empty state -> emits nothing
    #   - single entry -> emits 1 object
    #   - N entries -> emits N objects
    # Callers who need an array should wrap with @(Read-Queue).
    # Pipeline callers (Read-Queue | Where {...}) work naturally.
    # Do NOT use `,$arr` here -- it breaks pipeline usage by delivering the
    # whole array as ONE pipeline object instead of enumerating it.
    $path = Get-QueuePath
    [void]$script:QueueMutex.WaitOne(2000)
    try {
        if (-not (Test-Path $path)) { return }
        $raw = Get-Content $path -Raw -Encoding UTF8
        if (-not $raw) { return }
        try {
            $arr = $raw | ConvertFrom-Json
        } catch {
            return
        }
        if ($null -eq $arr) { return }
        # Emit one object at a time so downstream pipelines behave.
        $arr | ForEach-Object { $_ }
    } finally { $script:QueueMutex.ReleaseMutex() }
}

function Write-Queue([array]$queue) {
    $path = Get-QueuePath
    Ensure-AppData
    [void]$script:QueueMutex.WaitOne(2000)
    try {
        $json = if ($queue.Count -eq 0) { '[]' } else { $queue | ConvertTo-Json -Depth 6 }
        # Force array even for a single element
        if ($queue.Count -eq 1 -and $json -notmatch '^\s*\[') { $json = "[$json]" }
        Set-Content -Path $path -Value $json -Encoding UTF8
    } finally { $script:QueueMutex.ReleaseMutex() }
}

# ---------- Public API ----------------------------------------------------

function New-QueueJob {
    param(
        [Parameter(Mandatory)][string]$Url,
        [string]$Dest = $null,
        [ValidateSet('auto','yt-dlp','gallery-dl')][string]$Tool = 'auto',
        [bool]$Sensitive = $false
    )
    [PSCustomObject]@{
        Id          = [guid]::NewGuid().ToString()
        Url         = $Url
        Dest        = $Dest
        Tool        = $Tool
        Sensitive   = [bool]$Sensitive
        Status      = 'pending'
        StatusMsg   = 'Waiting to start'
        AddedAt     = (Get-Date).ToString('o')
        StartedAt   = $null
        DoneAt      = $null
        DurationMs  = 0
        FilesAdded  = 0
        Error       = $null
        ToolUsed    = $null
        UsedCookies = $null
        JobId       = $null
    }
}

function Add-QueueJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Urls,
        [string]$Dest = $null,
        [ValidateSet('auto','yt-dlp','gallery-dl')][string]$Tool = 'auto',
        [switch]$Sensitive     # force route to .private for these URLs
    )
    $queue = @(Read-Queue)
    $active = @{}
    foreach ($j in $queue) { if ($j.Status -in @('pending','running')) { $active[$j.Url] = $true } }
    $added = 0
    foreach ($u in $Urls) {
        if (-not (Test-IsUrl $u))     { continue }
        if ($active.ContainsKey($u))  { continue }
        $queue = $queue + @(New-QueueJob -Url $u -Dest $Dest -Tool $Tool -Sensitive:$Sensitive)
        $active[$u] = $true
        $added = $added + 1
        Log-Info ("queued " + $u + $(if ($Sensitive) { ' [SENSITIVE]' } else { '' }))
    }
    Write-Queue $queue
    return $added
}

function Get-Queue { Read-Queue }

function Set-JobStatus([string]$id, [hashtable]$updates) {
    $queue = @(Read-Queue)
    $changed = $false
    for ($i = 0; $i -lt $queue.Count; $i++) {
        if ($queue[$i].Id -eq $id) {
            foreach ($k in $updates.Keys) { $queue[$i].$k = $updates[$k] }
            $changed = $true
            break
        }
    }
    if ($changed) { Write-Queue $queue }
    return $changed
}

function Cancel-QueueJob([string]$id) {
    $queue = @(Read-Queue)
    foreach ($j in $queue) {
        if ($j.Id -eq $id) {
            if ($j.Status -eq 'running' -and $j.JobId) {
                try { Stop-Job -Id $j.JobId -ErrorAction SilentlyContinue; Remove-Job -Id $j.JobId -Force -ErrorAction SilentlyContinue } catch {}
            }
            $j.Status    = 'cancelled'
            $j.StatusMsg = 'Cancelled by user'
            $j.DoneAt    = (Get-Date).ToString('o')
            break
        }
    }
    Write-Queue $queue
}

function Retry-QueueJob([string]$id) {
    Set-JobStatus $id @{
        Status      = 'pending'
        StatusMsg   = 'Waiting to start'
        StartedAt   = $null
        DoneAt      = $null
        DurationMs  = 0
        FilesAdded  = 0
        ToolUsed    = $null
        UsedCookies = $null
        Error       = $null
        JobId       = $null
    } | Out-Null
}

function Clear-QueueDone {
    $queue = @(Read-Queue | Where-Object { $_.Status -in @('pending','running') })
    Write-Queue $queue
    # Where-Object output re-enumerates so @() is fine here; different case than Read-Queue direct.
}

# ---------- Recent list ---------------------------------------------------

function Append-Recent([object]$job) {
    $path = Get-RecentPath
    Ensure-AppData
    $recent = if (Test-Path $path) {
        $raw = Get-Content $path -Raw -Encoding UTF8
        if ($raw) { @($raw | ConvertFrom-Json) } else { @() }
    } else { @() }
    $entry = [PSCustomObject]@{
        Url         = $job.Url
        Dest        = $job.Dest
        DoneAt      = $job.DoneAt
        Status      = $job.Status
        FilesAdded  = $job.FilesAdded
        ToolUsed    = $job.ToolUsed
        DurationMs  = $job.DurationMs
        Error       = $job.Error
    }
    $recent = @($entry) + $recent
    if ($recent.Count -gt 100) { $recent = $recent[0..99] }  # cap at 100
    $recent | ConvertTo-Json -Depth 4 | Set-Content -Path $path -Encoding UTF8
}

function Get-Recent {
    # Same convention as Read-Queue: emit entries one at a time.
    $path = Get-RecentPath
    if (-not (Test-Path $path)) { return }
    $raw = Get-Content $path -Raw -Encoding UTF8
    if (-not $raw) { return }
    $r = $raw | ConvertFrom-Json
    if ($null -eq $r) { return }
    $r | ForEach-Object { $_ }
}

function Clear-Recent {
    # Purge Recent entries. Two modes:
    #   Clear-Recent                          -> empty every entry
    #   Clear-Recent -OlderThan (Get-Date)... -> drop only entries whose
    #                                            DoneAt is older than the
    #                                            supplied cutoff.
    # ONLY touches recent.json -- downloaded files on disk are untouched.
    # Returns the number of entries removed (0 on empty / no-op).
    param(
        [datetime]$OlderThan
    )
    $path = Get-RecentPath
    Ensure-AppData
    if (-not (Test-Path $path)) { return 0 }
    $raw = Get-Content $path -Raw -Encoding UTF8
    if (-not $raw) { return 0 }
    $existing = @()
    try {
        # PS 5.1 quirk: `$raw | ConvertFrom-Json` places a JSON-array result on
        # the pipeline as ONE object (the array), so `@(...)` around it yields
        # a 1-element array containing the array. Assign first, then coerce
        # based on the actual runtime type. Same fix pattern as Read-Queue.
        $parsed = $raw | ConvertFrom-Json
        $existing = if ($null -eq $parsed) { @() }
                    elseif ($parsed -is [array]) { $parsed }
                    else { @($parsed) }
    } catch {
        # Corrupt json: treat as "clear everything" -- write empty array.
        $existing = @()
    }
    $before = @($existing).Count
    if ($PSBoundParameters.ContainsKey('OlderThan')) {
        $kept = @($existing | Where-Object {
            $ok = $false
            if ($_.DoneAt) {
                try {
                    $dt = [datetime]$_.DoneAt
                    if ($dt -ge $OlderThan) { $ok = $true }
                } catch {
                    # Unparseable stamp -- keep it (better than losing history).
                    $ok = $true
                }
            } else {
                # Missing stamp -- keep, same defensive rationale.
                $ok = $true
            }
            $ok
        })
    } else {
        $kept = @()
    }
    $removed = $before - $kept.Count
    # Always write, even for a full clear, so recent.json is a valid empty array.
    $json = if ($kept.Count -eq 0) { '[]' } else { $kept | ConvertTo-Json -Depth 4 }
    if ($kept.Count -eq 1 -and $json -notmatch '^\s*\[') { $json = "[$json]" }
    Set-Content -Path $path -Value $json -Encoding UTF8
    Log-Info ("recent cleared: removed=$removed" + $(if ($PSBoundParameters.ContainsKey('OlderThan')) { " (older than $($OlderThan.ToString('o')))" } else { ' (all)' }))
    return $removed
}

# ---------- Worker tick ---------------------------------------------------
# Call from a timer (e.g. tray's Timer.Tick). Idempotent, cheap, safe to
# call every second.

function Invoke-QueueTick {
    $cfg = Get-Config
    $queue = @(Read-Queue)
    $changed = $false

    # 1. Poll running jobs -- did any finish?
    foreach ($j in $queue) {
        if ($j.Status -ne 'running' -or -not $j.JobId) { continue }
        $ps = Get-Job -Id $j.JobId -ErrorAction SilentlyContinue
        if (-not $ps) {
            # Job disappeared -- mark failed
            $j.Status = 'failed'; $j.StatusMsg = 'Worker vanished'
            $j.DoneAt = (Get-Date).ToString('o'); $j.Error = 'PS job not found'
            $changed = $true; continue
        }
        if ($ps.State -in @('Completed','Failed','Stopped')) {
            try {
                $out = Receive-Job -Id $j.JobId -ErrorAction SilentlyContinue
                # The child job returned an Invoke-Grab result object as its LAST output.
                $result = $out | Where-Object { $_ -is [PSCustomObject] -and $_.PSObject.Properties['Success'] } | Select-Object -Last 1
                if ($result -and $result.Success) {
                    $j.Status      = 'done'
                    $j.StatusMsg   = "Grabbed $($result.FilesAdded) file(s)"
                    $j.FilesAdded  = $result.FilesAdded
                    $j.ToolUsed    = $result.Tool
                    $j.UsedCookies = $result.UsedCookies
                    $j.Dest        = $result.Destination
                    $j.DurationMs  = $result.DurationMs
                } else {
                    $j.Status    = 'failed'
                    $j.StatusMsg = 'Nothing downloaded'
                    $j.Error     = if ($result) { $result.Error } else { 'No result returned' }
                    $j.DurationMs= if ($result) { $result.DurationMs } else { 0 }
                }
            } catch {
                $j.Status = 'failed'; $j.StatusMsg = 'Worker error'
                $j.Error = $_.Exception.Message
            }
            $j.DoneAt = (Get-Date).ToString('o')
            Remove-Job -Id $j.JobId -Force -ErrorAction SilentlyContinue
            $j.JobId  = $null

            # Fire completion side-effects.
            # PRIVACY: sensitive downloads are NEVER appended to Recent
            # (the whole point is to leave no history trail). User can still
            # re-download by pasting the URL again.
            if (-not [bool]$j.Sensitive) {
                Append-Recent $j
            }
            if ($j.Status -eq 'done') {
                Send-Toast 'Grab complete' "$($j.FilesAdded) file(s) from $(Get-SiteName $j.Url)"
            } else {
                Send-Toast 'Grab failed' "$(Get-SiteName $j.Url) - $($j.StatusMsg)"
            }
            $changed = $true
        }
    }

    # 2. Start new pending jobs up to concurrency limit
    $running = @($queue | Where-Object { $_.Status -eq 'running' }).Count
    $limit = [int]($cfg.concurrency)
    if ($limit -lt 1) { $limit = 1 }

    foreach ($j in $queue) {
        if ($running -ge $limit) { break }
        if ($j.Status -ne 'pending') { continue }

        $srcRoot = $PSScriptRoot
        $scriptBlock = {
            param($SrcRoot, $Url, $Dest, $Tool, $Sensitive)
            . "$SrcRoot\utils.ps1"
            . "$SrcRoot\core.ps1"
            $params = @{ Url = $Url }
            if ($Dest) { $params['Dest'] = $Dest }
            if ($Tool -and $Tool -ne 'auto') { $params['Tool'] = $Tool }
            if ($Sensitive) { $params['Sensitive'] = $true }
            Invoke-Grab @params
        }
        $sensitiveFlag = [bool]$j.Sensitive
        $job = Start-Job -ScriptBlock $scriptBlock -ArgumentList $srcRoot, $j.Url, $j.Dest, $j.Tool, $sensitiveFlag
        $j.Status    = 'running'
        $j.StatusMsg = 'Downloading'
        $j.StartedAt = (Get-Date).ToString('o')
        $j.JobId     = $job.Id
        $running = $running + 1   # avoid $running++ leaking to output
        $changed = $true
        Log-Info "started job $($j.Url)"
    }

    if ($changed) { Write-Queue $queue }
}

function Recover-OrphanedJobs {
    # Call on tray startup. Rewrites any queue entry stuck in 'running'
    # (because a previous process crashed / was killed / the machine rebooted
    # while a job was in-flight) back to 'pending' so the tick worker can
    # cleanly retry it. Without this, Invoke-QueueTick sees no matching PS
    # Job and marks them 'failed' with "Worker vanished" instead of retrying.
    $queue = @(Read-Queue)
    $changed = 0
    foreach ($j in $queue) {
        if ($j.Status -eq 'running') {
            $j.Status    = 'pending'
            $j.StatusMsg = 'Resuming after restart'
            $j.StartedAt = $null
            $j.JobId     = $null
            $changed++
        }
    }
    if ($changed -gt 0) {
        Write-Queue $queue
        Log-Info "recovered $changed orphaned running job(s)"
    }
}

function Stop-AllJobs {
    # Called on app quit -- kill any running PS jobs cleanly.
    $queue = @(Read-Queue)
    foreach ($j in $queue) {
        if ($j.Status -eq 'running' -and $j.JobId) {
            try { Stop-Job -Id $j.JobId -ErrorAction SilentlyContinue; Remove-Job -Id $j.JobId -Force -ErrorAction SilentlyContinue } catch {}
            $j.Status = 'pending'; $j.StatusMsg = 'Interrupted (will retry on next launch)'
            $j.JobId = $null
        }
    }
    Write-Queue $queue
}
