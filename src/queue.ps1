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

# Audit P2-36: recent.json is also mutated by two paths (Append-Recent from
# the queue tick after a job finishes; Clear-Recent from popup buttons). A
# dedicated named mutex serializes those two so a completing job doesn't
# race a manual "Clear all" click.
$script:RecentMutex = New-Object System.Threading.Mutex($false, 'Global\GrabAppRecentMutex')

function _WithRecentMutex {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    $acquired = $false
    try { $acquired = $script:RecentMutex.WaitOne(2000) }
    catch [System.Threading.AbandonedMutexException] { $acquired = $true }
    if (-not $acquired) {
        Log-Warn "recent mutex timeout in ${Name}; skipping"
        return
    }
    try { & $Action } finally { try { $script:RecentMutex.ReleaseMutex() } catch {} }
}

function Read-Queue {
    # Emits queue entries using standard PS enumeration semantics:
    #   - empty state -> emits nothing
    #   - single entry -> emits 1 object
    #   - N entries -> emits N objects
    # Callers who need an array should wrap with @(Read-Queue).
    # Pipeline callers (Read-Queue | Where {...}) work naturally.
    # Do NOT use `,$arr` here -- it breaks pipeline usage by delivering the
    # whole array as ONE pipeline object instead of enumerating it.
    # v0.3.0: WaitOne return + AbandonedMutexException are both checked
    # (audit P1-24: pre-v0.3.0 we proceeded without a lock on timeout).
    $path = Get-QueuePath
    $acquired = $false
    try { $acquired = $script:QueueMutex.WaitOne(2000) }
    catch [System.Threading.AbandonedMutexException] { $acquired = $true }
    if (-not $acquired) {
        Log-Warn 'Read-Queue: mutex timeout after 2s; skipping read'
        return
    }
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
    } finally { try { $script:QueueMutex.ReleaseMutex() } catch {} }
}

function Write-Queue([array]$queue) {
    $path = Get-QueuePath
    Ensure-AppData
    # WaitOne can return $false on timeout OR throw AbandonedMutexException
    # if a prior owner exited without releasing (audit P0-3). v0.3.0: on
    # timeout we now SKIP the write and log -- proceeding without the lock
    # is what created the lost-update races the audit flagged (P0-7). The
    # skipped write survives: the tick timer re-picks up whatever state
    # existed on disk two seconds later.
    $acquired = $false
    try { $acquired = $script:QueueMutex.WaitOne(2000) }
    catch [System.Threading.AbandonedMutexException] { $acquired = $true }
    if (-not $acquired) {
        Log-Warn 'Write-Queue: mutex timeout after 2s; skipping write to avoid lost-update race'
        return
    }
    try {
        # Audit P2-38: force array shape for every queue.json write.
        # ConvertTo-Json on a single PSCustomObject produces a bare object,
        # not an array; on an empty array it can produce nothing. So we
        # normalise: serialize each entry individually, then join with
        # commas inside brackets. This is the same shape Read-Queue expects
        # regardless of Count (0, 1, or many).
        if ($queue.Count -eq 0) {
            $json = '[]'
        } else {
            $parts = @()
            foreach ($item in $queue) { $parts += ($item | ConvertTo-Json -Depth 6) }
            $json = '[' + ($parts -join ',') + ']'
        }
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        $tmp = "$path.tmp"
        [System.IO.File]::WriteAllText($tmp, $json, $utf8NoBom)
        if (Test-Path -LiteralPath $path) {
            [GrabApp.AtomicIO]::ReplaceMove($tmp, $path)
        } else {
            [System.IO.File]::Move($tmp, $path)
        }
    } finally {
        try { $script:QueueMutex.ReleaseMutex() } catch {}
    }
}

# ---------- Mutex-wrapped read-modify-write helper -----------------------
# Every mutating call site (Set-JobStatus, Cancel-QueueJob, Retry-QueueJob,
# Recover-OrphanedJobs, Stop-AllJobs) needs to (1) take the mutex,
# (2) read queue, (3) mutate, (4) write, (5) release. Skipping the mutex
# there produced the lost-update race the audit flagged (P0-7): a tick
# timer read + Set-JobStatus running interleaved could clobber each other.
# System.Threading.Mutex is re-entrant on the same thread, so calling
# Read-Queue / Write-Queue inside a wrapped block just recurses safely.
function _WithQueueMutex {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    $acquired = $false
    try { $acquired = $script:QueueMutex.WaitOne(2000) }
    catch [System.Threading.AbandonedMutexException] { $acquired = $true }
    if (-not $acquired) {
        Log-Warn "queue mutex timeout in ${Name}; skipping"
        return
    }
    try { & $Action } finally { try { $script:QueueMutex.ReleaseMutex() } catch {} }
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
    # Audit PERF-1: notify the tray so its adaptive TickTimer resets to
    # the fast interval whenever new work arrives. Guarded so queue.ps1
    # still works when dot-sourced from a test without a running tray.
    if ($added -gt 0 -and (Get-Command Notify-QueueActivity -ErrorAction SilentlyContinue)) {
        try { Notify-QueueActivity } catch {}
    }
    return $added
}

function Get-Queue { Read-Queue }

function Set-JobStatus([string]$id, [hashtable]$updates) {
    $result = $false
    _WithQueueMutex -Name 'Set-JobStatus' -Action {
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
        $script:_SetJobStatusResult = $changed
    }
    if (Test-Path Variable:script:_SetJobStatusResult) {
        $result = $script:_SetJobStatusResult
        Remove-Variable -Name _SetJobStatusResult -Scope Script -ErrorAction SilentlyContinue
    }
    return $result
}

function Cancel-QueueJob([string]$id) {
    # Audit P2-41: only Write-Queue when we actually mutated something. The
    # pre-v0.3.0 body always wrote back, which meant a Cancel for an id that
    # was already gone (e.g. clicked twice, race with tick) still spent one
    # atomic replace + mutex acquisition. Also return $true/$false so callers
    # can tell success from "id not found".
    $mutated = $false
    _WithQueueMutex -Name 'Cancel-QueueJob' -Action {
        $queue = @(Read-Queue)
        foreach ($j in $queue) {
            if ($j.Id -eq $id) {
                if ($j.Status -eq 'running' -and $j.JobId) {
                    try { Stop-Job -Id $j.JobId -ErrorAction SilentlyContinue; Remove-Job -Id $j.JobId -Force -ErrorAction SilentlyContinue } catch {}
                }
                $j.Status    = 'cancelled'
                $j.StatusMsg = 'Cancelled by user'
                $j.DoneAt    = (Get-Date).ToString('o')
                $script:_CancelMutated = $true
                break
            }
        }
        if ($script:_CancelMutated) { Write-Queue $queue }
    }
    if (Test-Path Variable:script:_CancelMutated) {
        $mutated = [bool]$script:_CancelMutated
        Remove-Variable -Name _CancelMutated -Scope Script -ErrorAction SilentlyContinue
    }
    return $mutated
}

function Retry-QueueJob([string]$id) {
    _WithQueueMutex -Name 'Retry-QueueJob' -Action {
        # Inline the update so we get one mutex acquisition, not two
        # (Set-JobStatus takes it again -- recursive is fine but slower).
        $queue = @(Read-Queue)
        for ($i = 0; $i -lt $queue.Count; $i++) {
            if ($queue[$i].Id -eq $id) {
                $queue[$i].Status      = 'pending'
                $queue[$i].StatusMsg   = 'Waiting to start'
                $queue[$i].StartedAt   = $null
                $queue[$i].DoneAt      = $null
                $queue[$i].DurationMs  = 0
                $queue[$i].FilesAdded  = 0
                $queue[$i].ToolUsed    = $null
                $queue[$i].UsedCookies = $null
                $queue[$i].Error       = $null
                $queue[$i].JobId       = $null
                Write-Queue $queue
                break
            }
        }
    }
}

function Clear-QueueDone {
    $queue = @(Read-Queue | Where-Object { $_.Status -in @('pending','running') })
    Write-Queue $queue
    # Where-Object output re-enumerates so @() is fine here; different case than Read-Queue direct.
}

# ---------- Recent list ---------------------------------------------------

function Append-Recent([object]$job) {
    # Audit P2-36: serialize with _WithRecentMutex so a concurrent Clear-Recent
    # click can't race the append.
    _WithRecentMutex -Name 'Append-Recent' -Action {
        $path = Get-RecentPath
        Ensure-AppData
        $recent = if (Test-Path $path) {
            $raw = Get-Content $path -Raw -Encoding UTF8
            if ($raw) { @($raw | ConvertFrom-Json) } else { @() }
        } else { @() }
        $entry = [PSCustomObject]@{
            # Audit P2-56: redact tokens / signed-URL params before persisting.
            # Recent history is a personal artifact but it should never carry
            # short-lived credentials.
            Url         = Get-RedactedUrl $job.Url
            Dest        = $job.Dest
            DoneAt      = $job.DoneAt
            Status      = $job.Status
            FilesAdded  = $job.FilesAdded
            ToolUsed    = $job.ToolUsed
            DurationMs  = $job.DurationMs
            Error       = $job.Error
        }
        $recent = @($entry) + @($recent)
        # Audit P2-37: `$recent[0..99]` throws on an empty array. Select-Object
        # -First is safe for any Count including 0. Also handles the just-in-case
        # case where a fresh recent.json somehow held zero entries but we tried
        # to cap anyway.
        if ($recent.Count -gt 100) { $recent = @($recent | Select-Object -First 100) }
        # Atomic write (UTF-8 no BOM); a mid-write kill no longer leaves a truncated
        # recent.json for the next Get-Recent to trip over.
        Write-JsonAtomic -Path $path -Data $recent -Depth 4
    }
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
    # Audit P2-49: `Clear-Recent -OlderThan (Get-Date).AddDays(1)` used to
    # drop EVERY entry (cutoff is in the future -> nothing qualifies as
    # "recent enough to keep"). Refuse a future cutoff outright so a typo
    # doesn't wipe a user's whole Recent list.
    if ($PSBoundParameters.ContainsKey('OlderThan') -and $OlderThan -gt (Get-Date)) {
        throw "Clear-Recent: -OlderThan must be in the past (got '$($OlderThan.ToString('o'))'); refusing to wipe Recent."
    }
    # Audit P2-36: share the recent mutex with Append-Recent so a completing
    # job doesn't race a manual Clear. Marshal state via $script:* so the
    # scriptblock scope doesn't need to close over local params (avoiding
    # the "$OlderThan is null default" trap when the caller didn't pass it).
    $script:_ClearRecentHasOlderThan = $PSBoundParameters.ContainsKey('OlderThan')
    $script:_ClearRecentOlderThan    = if ($script:_ClearRecentHasOlderThan) { $OlderThan } else { [datetime]::MinValue }
    $script:_ClearRecentPath         = Get-RecentPath
    $script:_ClearRecentResult       = 0
    _WithRecentMutex -Name 'Clear-Recent' -Action {
        $psb = @{}
        if ($script:_ClearRecentHasOlderThan) { $psb['OlderThan'] = $true }
        $script:_ClearRecentResult = _Clear-RecentBody `
            -Path $script:_ClearRecentPath `
            -PSB $psb `
            -OlderThan $script:_ClearRecentOlderThan
    }
    $result = [int]$script:_ClearRecentResult
    Remove-Variable -Name _ClearRecentResult      -Scope Script -ErrorAction SilentlyContinue
    Remove-Variable -Name _ClearRecentHasOlderThan -Scope Script -ErrorAction SilentlyContinue
    Remove-Variable -Name _ClearRecentOlderThan   -Scope Script -ErrorAction SilentlyContinue
    Remove-Variable -Name _ClearRecentPath        -Scope Script -ErrorAction SilentlyContinue
    return $result
}
function _Clear-RecentBody {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$PSB,
        [datetime]$OlderThan
    )
    Ensure-AppData
    $path = $Path
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
    if ($PSB.ContainsKey('OlderThan')) {
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
    # Write via the atomic UTF-8-no-BOM helper. Empty and single-item arrays
    # both need the explicit '[' wrapping because ConvertTo-Json emits a bare
    # object for one element (and nothing for zero); Write-JsonAtomic itself
    # only handles arbitrary objects, so wrap first, then hand it the string.
    if ($kept.Count -eq 0) {
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        $tmp = "$path.tmp"
        [System.IO.File]::WriteAllText($tmp, '[]', $utf8NoBom)
        if (Test-Path -LiteralPath $path) {
            [GrabApp.AtomicIO]::ReplaceMove($tmp, $path)
        } else {
            [System.IO.File]::Move($tmp, $path)
        }
    } elseif ($kept.Count -eq 1) {
        $json = $kept | ConvertTo-Json -Depth 4
        if ($json -notmatch '^\s*\[') { $json = "[$json]" }
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        $tmp = "$path.tmp"
        [System.IO.File]::WriteAllText($tmp, $json, $utf8NoBom)
        if (Test-Path -LiteralPath $path) {
            [GrabApp.AtomicIO]::ReplaceMove($tmp, $path)
        } else {
            [System.IO.File]::Move($tmp, $path)
        }
    } else {
        Write-JsonAtomic -Path $path -Data $kept -Depth 4
    }
    Log-Info ("recent cleared: removed=$removed" + $(if ($PSB.ContainsKey('OlderThan')) { " (older than $($OlderThan.ToString('o')))" } else { ' (all)' }))
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
                # Sentinel-wrapped result (audit P1-31): the worker returns
                # @{ __grab_result = $r }, so we pick THAT hashtable, then
                # unwrap. Prevents earlier bug where any random PSObject with
                # a .Success property in the pipeline (e.g. from a helper
                # library) could pose as the download result and confuse
                # completion accounting.
                $sentinel = $out | Where-Object {
                    ($_ -is [hashtable] -and $_.ContainsKey('__grab_result')) -or
                    ($_ -is [System.Collections.IDictionary] -and $_.Keys -contains '__grab_result')
                } | Select-Object -Last 1
                if ($sentinel) {
                    $result = $sentinel['__grab_result']
                } else {
                    # Backward-compat fallback: pre-v0.3.0 the worker emitted
                    # the raw PSCustomObject; keep picking it up so any queue
                    # entries mid-flight during upgrade still complete cleanly.
                    $result = $out | Where-Object { $_ -is [PSCustomObject] -and $_.PSObject.Properties['Success'] } | Select-Object -Last 1
                }
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
            $r = Invoke-Grab @params
            # Sentinel-wrap the result (audit P1-31) so the tick-timer parser
            # can pluck it by well-known key instead of guessing at any
            # PSObject with a .Success property.
            @{ __grab_result = $r }
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
    _WithQueueMutex -Name 'Recover-OrphanedJobs' -Action {
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
}

function Stop-AllJobs {
    # Called on app quit -- kill any running PS jobs cleanly.
    _WithQueueMutex -Name 'Stop-AllJobs' -Action {
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
}
