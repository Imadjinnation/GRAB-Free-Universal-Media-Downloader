# File map

Canonical index of every file in the project. If you add a file, add it here in the same commit.

Legend: **✓** built · **·** planned · **★** entry point

## Repository root

| Path | Status | Purpose |
|---|---|---|
| `README.md` | ✓ | User-facing intro, install steps, credits |
| `PROGRESS.md` | ✓ | Version log + checkpoint notes (author-facing) |
| `LICENSE` | ✓ | MIT license |
| `.gitignore` | ✓ | Excludes runtime state and editor junk |
| `install.ps1` | ✓ | Portable one-command installer (Python check, pip installs, BurntToast, shortcuts, autostart) |
| `uninstall.ps1` | ✓ | Removes tray + shortcuts + autostart, asks before removing app-data + pip packages, leaves downloads untouched. Supports `-Yes` (silent full removal) and `-KeepState` (only touch shortcuts). |
| `grab-app.ps1` | ✓ **★** | Main entry point — loads config, starts tray, wires callbacks |

## `tests/` — smoke tests

| Path | Status | Purpose |
|---|---|---|
| `tests/README.md` | ✓ | How to run tests; the "green smoke.ps1 before checkpoint" rule; PS gotchas learned |
| `tests/smoke.ps1` | ✓ | 101-test zero-dependency harness (parse, XAML load, function exports, config/queue/recent CRUD, portability, install) |

## `src/` — PowerShell source

| Path | Status | Purpose |
|---|---|---|
| `src/utils.ps1` | ✓ | Shared helpers: config load/save, path resolution, tool discovery, logging, toasts, URL routing |
| `src/core.ps1` | ✓ | `Invoke-Grab` — engine wrapper with fallback chain and real-file success detection |
| `src/queue.ps1` | ✓ | Queue state + tick worker: reads/writes queue.json, dispatches PS jobs with concurrency limit, updates state, appends to recent.json |
| `src/tray.ps1` | ✓ | System tray NotifyIcon: custom icon (falls back to shell32), right-click menu, left-click summons popup, timers for queue tick + clipboard watch |
| `src/popup.ps1` | ✓ | Loads `ui/popup.xaml`, wires Paste / Queue / Recent tabs, custom titlebar (drag/min/close), remembers window position |
| `src/settings.ps1` | ✓ | Loads `ui/settings.xaml`, drives config edits, toggles autostart shortcut, hosts first-run onboarding |
| `src/drop.bat` | · | Drag-drop launcher wrapper (drops resolve to grab-app.ps1 via this) |

## `ui/` — WPF XAML markup

| Path | Status | Purpose |
|---|---|---|
| `ui/README.md` | ✓ | Design tokens + XAML-load pattern reference |
| `ui/popup.xaml` | ✓ | Main popup: dark card, custom titlebar, tab strip (Paste / Queue / Recent), gradient primary button, ghost secondary |
| `ui/settings.xaml` | ✓ | Settings window layout (download folder, cookies, toasts, clipboard, autostart, reset) |
| `ui/onboarding.xaml` | · | First-run wizard layout (optional; may inline into settings) |

## `assets/` — icons and images

| Path | Status | Purpose |
|---|---|---|
| `assets/README.md` | ✓ | Asset conventions + license note |
| `assets/gallery-dl-config.json` | ✓ | Per-extractor directory template overrides for gallery-dl (fixes chapter collisions on sites like allporncomic) |
| `assets/icon.ico` | · | System tray icon (16 + 32 + 48px) — falls back to shell32.dll,176 when absent |
| `assets/icon-32.png` | · | Popup accent dot / small logo |
| `assets/favicon.png` | · | Web-facing icon (docs, README) |

## `docs/` — user + contributor documentation

| Path | Status | Purpose |
|---|---|---|
| `docs/architecture.md` | ✓ | Component map + data flow diagrams |
| `docs/site-coverage.md` | ✓ | Which engine handles which sites |
| `docs/file-map.md` | ✓ | This file — canonical index |
| `docs/troubleshooting.md` | · | Common errors + fixes (cookies, ffmpeg missing, etc.) |
| `docs/screenshots.md` | · | Visual walkthrough (added in CP5 after UI is stable) |

## Runtime state — *not in the repo*

Lives at `%APPDATA%\grab-app\` on every user's machine. Excluded via `.gitignore` even if a file lands here by accident.

| Path | Purpose |
|---|---|
| `config.json` | User settings (folder, toggles, concurrency, position) |
| `queue.json` | Live queue: pending, running, done, failed |
| `recent.json` | Last N successful downloads (for Recent tab) |
| `done-archive.txt` | Deduplication database (yt-dlp/gallery-dl `--download-archive`) |
| `logs/grab-YYYY-MM-DD.log` | Per-day activity log (rotating daily) |
