# Architecture

How the pieces fit together. Read this first if you're modifying more than one file.

## The mental model

grab is a **background service (tray) + on-demand UI (popup)** that shells out to two well-established engines (yt-dlp + gallery-dl). It is deliberately thin — the heavy lifting is done by the engines and by Windows itself. This app is glue with a nice face.

## Component map

```
                        ┌─────────────────────────────────────┐
                        │  grab-app.ps1  (entry point)        │
                        │  - loads config                     │
                        │  - starts tray                      │
                        └───────────────┬─────────────────────┘
                                        │
              ┌─────────────────────────┴─────────────────────┐
              │                                               │
     ┌────────▼─────────┐                          ┌──────────▼──────────┐
     │  src/tray.ps1    │                          │  src/queue.ps1      │
     │  NotifyIcon      │                          │  Background worker  │
     │  Right-click menu│                          │  Reads queue.json,  │
     │  Clipboard watch │                          │  spawns downloads,  │
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
     │  (helpers)       │  logging, toast notifications, URL routing
     └──────────────────┘

State (never in the git repo, always at %APPDATA%\grab-app\):
     ┌──────────────────────────────────────────────────────────────────┐
     │  config.json  queue.json  recent.json  done-archive.txt  logs/   │
     └──────────────────────────────────────────────────────────────────┘
```

## Data flow — a single URL download

1. **User pastes** a URL into the popup's Paste tab and hits Enter
2. **popup.ps1** appends a job entry to `%APPDATA%\grab-app\queue.json` (status = pending)
3. **queue.ps1** (running as a background worker) sees the new entry, picks it up when a concurrency slot is free
4. **queue.ps1** calls `Invoke-Grab` from **core.ps1** with the URL
5. **core.ps1** consults **utils.ps1**'s `Pick-Tool` to choose yt-dlp or gallery-dl, then runs it with cookies
6. If the first attempt produces no new files, **core.ps1** retries: without cookies -> other tool + cookies -> other tool without cookies
7. On success, **core.ps1** returns a result object; **queue.ps1** updates the queue entry to `done` and appends to `recent.json`
8. **utils.ps1** `Send-Toast` fires a Windows notification via BurntToast
9. **popup.ps1**'s Queue tab (if open) polls `queue.json` and reflects the new status live

## Data flow — the tray watching your clipboard

1. **tray.ps1** subscribes to a clipboard-change timer (1 second polling)
2. On URL-shaped clipboard content, if `config.clipboardWatch = true`, it fires a toast: "URL detected -- click to grab"
3. Clicking the toast triggers the same "add to queue" path as the popup would

## Startup sequence

```
Windows boots
  └─ shell:startup fires grab.lnk (created by install.ps1)
      └─ powershell.exe -File grab-app.ps1
          ├─ dot-source src/utils.ps1                 (helpers)
          ├─ ensure %APPDATA%\grab-app\ exists
          ├─ load config.json (create defaults if first run)
          ├─ if !firstRunComplete -> src/settings.ps1 shows onboarding
          ├─ start queue worker (background PS job)   src/queue.ps1
          └─ start tray (foreground UI thread)        src/tray.ps1
```

## Design constraints (things NOT to change lightly)

- **Everything shells out to engine binaries** (yt-dlp/gallery-dl). No custom HTTP scraping in this codebase.
- **State lives outside the repo.** Any state file written inside the git tree is a bug.
- **Success is proven by file count.** Never trust exit codes from the engines (they raise on non-fatal warnings).
- **UI never blocks downloads.** Popup can close, tray can be dismissed — the queue worker keeps running independently.
- **No hardcoded user paths.** Every reference to Python / user profile / desktop goes through utils or environment variables.
