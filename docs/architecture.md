# Architecture

How the pieces fit together. Read this first if you're modifying more than one file.

## The mental model

grab is a **background service (tray) + on-demand UI (popup)** that shells out to two well-established engines (yt-dlp + gallery-dl). It is deliberately thin — the heavy lifting is done by the engines and by Windows itself. This app is glue with a nice face.

## Component map

```
                        ┌─────────────────────────────────────┐
                        │  grab-app.vbs -> grab-app.ps1       │
                        │  - loads config                     │
                        │  - starts tray                      │
                        └───────────────┬─────────────────────┘
                                        │
              ┌─────────────────────────┴─────────────────────┐
              │                                               │
     ┌────────▼─────────┐                          ┌──────────▼──────────┐
     │  src/tray.ps1    │                          │  src/queue.ps1      │
     │  NotifyIcon      │                          │  Queue state + tick │
     │  Right-click menu│                          │  worker (dispatcher │
     │  Clipboard timer │                          │  timer on STA)      │
     │  Adaptive tick   │                          │  Spawns PS jobs,    │
     │  Summons popup   │                          │  enforces limits    │
     └────────┬─────────┘                          └──────────┬──────────┘
              │                                               │
     ┌────────▼─────────┐                          ┌──────────▼──────────┐
     │  src/popup.ps1   │                          │  src/core.ps1       │
     │  Loads popup.xaml│                          │  Invoke-Grab wraps  │
     │  Wires Paste /   │─────── adds jobs ───────>│  yt-dlp/gallery-dl  │
     │  Queue / Recent  │                          │  with fallback +    │
     └──────────────────┘                          │  real success check │
                                                   └──────────┬──────────┘
                                                              │
                                                              │  shells out
                                                              ▼
                                                   ┌──────────────────────┐
                                                   │  yt-dlp / gallery-dl │
                                                   │  (Python packages)   │
                                                   └──────────────────────┘

Shared, dot-sourced by everything above:
     ┌──────────────────┐
     │  src/utils.ps1   │  config load/save, path helpers, tool discovery,
     │  (helpers)       │  logging, toast notifications, URL routing,
     │                  │  shortcut helper (New-GrabShortcut), theme URIs
     └──────────────────┘

State (never in the git repo, always at %APPDATA%\grab-app\):
     ┌──────────────────────────────────────────────────────────────────┐
     │  config.json  queue.json  recent.json  logs/                     │
     │  done-archive-yt-dlp.txt  done-archive-gallery-dl.txt            │
     │  .runtime-theme.xaml (regenerated on demand)                     │
     └──────────────────────────────────────────────────────────────────┘
```

## Thread model

**Everything visible to the user runs on ONE STA thread**: the WinForms NotifyIcon + WPF windows share a single `System.Windows.Threading.Dispatcher` primary loop (see `Start-Tray` in `src/tray.ps1`). WPF's Dispatcher.Run() pumps both the Win32 message queue (NotifyIcon events) and the WPF dispatcher queue (popup + settings + About), so windows attach lazily without a second thread.

**The queue worker is NOT a background PS job.** It's a `System.Windows.Threading.DispatcherTimer` (created in `Start-Timers` inside `src/tray.ps1`) that ticks on the STA thread every 2 seconds (adaptive: backs off to 15s on battery, 30s on idle, but stays at 2s while any job is `running` or the popup is visible — see audit v0.3.0-pass2 findings 34-36). Each tick reads `queue.json`, marshals PS jobs, and updates state.

**Downloads themselves DO run on background PS jobs.** Every `pending` entry that the tick promotes to `running` gets a `Start-Job` invocation of `Invoke-Grab`. The tick polls those jobs for completion via `Get-Job`/`Receive-Job` and reflects the outcome back into `queue.json`.

**Concurrency across processes** is serialized by two named mutexes:
- `Global\GrabAppTraySingleton` — one tray process at a time (grab-app.ps1).
- `Global\GrabAppQueueMutex` — one writer of queue.json at a time. Reads take it too so a torn read can't happen mid-write.
- `Global\GrabAppRecentMutex` — one writer of recent.json at a time; Get-Recent also takes it.

## The .vbs launcher

`grab-app.vbs` is a two-line WScript wrapper that spawns `powershell.exe -File grab-app.ps1` with `intWindowStyle = 0` (hidden). This sidesteps the "black console flash" that Windows Terminal introduces even when `-WindowStyle Hidden` is passed to powershell.exe directly. Every autostart / desktop-shortcut / self-heal path prefers `wscript.exe "<repo>\grab-app.vbs"` when the .vbs is present, and falls back to `powershell.exe -File grab-app.ps1` only when it isn't (older checkouts).

## The runtime theme

`ui/theme.xaml` embeds `__GRAB_FONTS__#Silkscreen` etc. as font-family tokens. WPF's `<ResourceDictionary Source="…"/>` loader reads that file DIRECTLY from disk, so the tokens have to be resolved BEFORE the merged-dictionary loader sees them. `Get-RuntimeThemeUri` (utils.ps1) materialises a substituted copy at `%APPDATA%\grab-app\.runtime-theme.xaml` and hands its `file:///` URI back to the window loaders. The runtime file is only rewritten when its content or mtime disagrees with the source.

## Data flow — a single URL download

1. **User pastes** a URL into the popup's Paste tab and hits Enter (or Alt-G — GrabBtn is `IsDefault="True"`).
2. **popup.ps1** appends a job entry to `%APPDATA%\grab-app\queue.json` (status = pending).
3. **queue.ps1 `Invoke-QueueTick`** (called by tray.ps1's DispatcherTimer) sees the new entry, promotes it to `running` when a concurrency slot is free, and `Start-Job`s `Invoke-Grab`.
4. **core.ps1 `Invoke-Grab`** consults **utils.ps1**'s `Pick-Tool` to choose yt-dlp or gallery-dl, then runs it with cookies.
5. If the first attempt produces no new files, **core.ps1** retries: without cookies -> other tool + cookies -> other tool without cookies.
6. On success, **core.ps1** returns a result object; **queue.ps1** updates the queue entry to `done` and appends to `recent.json` (URL tokens redacted; sensitive downloads never touch Recent).
7. **utils.ps1 `Send-Toast`** fires a Windows notification via BurntToast (falls back to a console line when BurntToast isn't installed).
8. **popup.ps1**'s Queue tab (if open) polls `queue.json` and reflects the new status live via a 2s DispatcherTimer that only ticks while the popup is `IsVisible`.

## Data flow — the tray watching your clipboard

1. **tray.ps1** creates a DispatcherTimer (`Sync-ClipTimer`) at 1.5s only when `config.clipboardWatch = true`. The timer creation is gated by the config value (audit PERF-4).
2. On URL-shaped clipboard content, the timer fires a toast: "URL detected -- click the tray icon to grab: `<site>`".
3. Clicking the tray icon (or the toast) summons the popup with the clipboard URL pre-filled.

## Startup sequence

```
Windows boots
  └─ HKCU\Software\Microsoft\Windows\CurrentVersion\Run\GRAB
     (primary, survives OneDrive folder-sync tricks)
     -> wscript.exe "<repo>\grab-app.vbs"
        -> powershell.exe -STA -NoProfile -WindowStyle Hidden -File grab-app.ps1
          ├─ Global\GrabAppTraySingleton mutex acquire (silent exit if lost)
          ├─ [GrabAppDpiNative]::SetProcessDpiAwareness(2)   Per-Monitor V2
          ├─ SetCurrentProcessExplicitAppUserModelID("Imadjinn.GRAB.Downloader.1")
          ├─ dot-source src/utils.ps1                        (helpers)
          ├─ dot-source src/core.ps1, queue.ps1, tray.ps1
          ├─ Ensure-AppData / Get-Config                     (creates + back-fills)
          ├─ if !firstRunComplete -> src/settings.ps1 shows onboarding (deferred)
          ├─ Start-Tray phase 1: NotifyIcon visible ASAP (~1-1.5s cold)
          ├─ Start-Tray phase 2: Ensure-WpfLoaded + Dispatcher
          ├─ Invoke-SelfHealSweep                            (HKCU\Run drift, shortcut,
          │                                                    OneDrive stale, ghost folder)
          ├─ Recover-OrphanedJobs                            (reset stuck 'running' entries)
          ├─ Start-Timers                                    (adaptive tick + clip + log-flush)
          └─ Dispatcher.Run()                                (blocks until Quit)
```

## Design constraints (things NOT to change lightly)

- **Everything shells out to engine binaries** (yt-dlp/gallery-dl). No custom HTTP scraping in this codebase.
- **State lives outside the repo.** Any state file written inside the git tree is a bug.
- **Success is proven by file count.** Never trust exit codes from the engines (they raise on non-fatal warnings).
- **UI never blocks downloads.** Popup can close, tray can be dismissed — the queue tick keeps running, downloads keep progressing.
- **No hardcoded user paths.** Every reference to Python / user profile / desktop goes through utils or environment variables.
- **`wscript.exe grab-app.vbs`** is the preferred launcher everywhere (autostart, desktop shortcut, restart-tray). `powershell.exe -File grab-app.ps1` is the fallback only.
- **Single version constant.** `Get-GrabVersion` in `src/utils.ps1` is the source of truth. Every version-carrying surface (About footer, Settings VersionLabel, config schema, installer) reads from it.
