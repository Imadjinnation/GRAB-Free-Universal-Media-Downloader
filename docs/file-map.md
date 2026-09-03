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
| `install.ps1` | ✓ | Portable one-command installer (Python check, WSL/WPF gate, pip installs, BurntToast, shortcuts, autostart) |
| `uninstall.ps1` | ✓ | Removes tray + shortcuts + autostart + HKCU\Run\GRAB + tray-promotion NotifyIconSettings; asks before removing app-data + pip packages; supports `-Yes` (silent), `-KeepState` (only shortcuts), `-RevertPSGallery` (revert Trusted policy). |
| `grab-app.ps1` | ✓ **★** | Main entry point — DPI awareness, AUMID, singleton mutex, loads config, starts tray |
| `grab-app.vbs` | ✓ **★** | WScript silent wrapper that spawns grab-app.ps1 with hidden window (no console flash on Windows Terminal). Preferred launcher everywhere. |
| `CHANGELOG.md` | ✓ | Version-by-version release notes (Keep-a-Changelog format) |

## `tests/` — smoke tests

| Path | Status | Purpose |
|---|---|---|
| `tests/README.md` | ✓ | How to run tests; the "green smoke.ps1 before checkpoint" rule; PS gotchas learned |
| `tests/smoke.ps1` | ✓ | 480+-test zero-dependency harness (parse, XAML load, function exports, config/queue/recent CRUD, portability, install, a11y static-scan, adaptive-tick behavior, Phase 6.5 root-cause regressions) |

## `src/` — PowerShell source

| Path | Status | Purpose |
|---|---|---|
| `src/utils.ps1` | ✓ | Shared helpers: config load/save + cache, path resolution, tool discovery, logging (batched with UTC timestamps), toasts, URL routing, HKCU\Run autostart, `New-GrabShortcut` (releases WScript.Shell RCW), runtime-theme URI |
| `src/core.ps1` | ✓ | `Invoke-Grab` — engine wrapper with fallback chain and real-file success detection; long-path helper; yt-dlp rate-limit + Chrome-cookie sniff |
| `src/queue.ps1` | ✓ | Queue state + tick worker: reads/writes queue.json under mutex, dispatches PS jobs with concurrency limit, updates state, appends to recent.json under mutex, Clear-Recent |
| `src/tray.ps1` | ✓ | System tray NotifyIcon: custom icon (falls back to shell32), right-click menu with mnemonics, left-click summons popup, About/Confirm dialogs (WPF, arcade), timers (adaptive tick + clipboard + log flush), self-heal sweep (HKCU\Run drift + OneDrive stale + shortcut) |
| `src/popup.ps1` | ✓ | Loads `ui/popup.xaml`, wires Paste / Queue / Recent tabs, custom titlebar (drag/min/close), remembers window position AND size, DPI-aware multi-monitor dock, notifies tray tick when visible |
| `src/settings.ps1` | ✓ | Loads `ui/settings.xaml`, drives config edits, toggles autostart shortcut (both HKCU\Run and shell:startup), hosts first-run onboarding |

## `ui/` — WPF XAML markup

| Path | Status | Purpose |
|---|---|---|
| `ui/README.md` | ✓ | Design tokens + XAML-load pattern reference |
| `ui/theme.xaml` | ✓ | Shared arcade design tokens (palette, ArcadePrimary/Ghost/Danger/Combo/Slider/Check/Text/Tab, section headers, scrollbars, tooltips). Merged by every window. |
| `ui/popup.xaml` | ✓ | Main popup: dark card, custom titlebar, tab strip (Paste / Queue / Recent), gradient primary button, ghost secondary, AutomationProperties on every named control, IsDefault/IsCancel dispatch |
| `ui/settings.xaml` | ✓ | Settings window layout (download folder, cookies, video quality, notifications, clipboard, display, safety, autostart), AutomationProperties on every named control |
| `ui/onboarding.xaml` | · | First-run wizard layout (optional; may inline into settings) |

## `assets/` — icons and images

| Path | Status | Purpose |
|---|---|---|
| `assets/README.md` | ✓ | Asset conventions + license note |
| `assets/gallery-dl-config.json` | ✓ | Per-extractor directory template overrides for gallery-dl (fixes chapter collisions on sites like allporncomic) |
| `assets/icon.ico` | ✓ | System tray icon (multi-res 16 + 32 + 48 px) |
| `assets/scanlines.png` | ✓ | Legacy CRT overlay tile (runtime now uses a LinearGradientBrush directly) |
| `assets/fonts/` | ✓ | Bundled TTFs — Silkscreen (wordmark), VT323 (tabs/labels), Inter (body) |
| `assets/favicon.png` | · | Web-facing icon (docs, README) |

## `docs/` — user + contributor documentation

| Path | Status | Purpose |
|---|---|---|
| `docs/architecture.md` | ✓ | Component map, data flow, thread model, .vbs launcher, runtime theme, startup sequence |
| `docs/site-coverage.md` | ✓ | Which engine handles which sites |
| `docs/file-map.md` | ✓ | This file — canonical index |
| `docs/config-reference.md` | ✓ | Every config.json key + default + effect |
| `docs/audit-v0.2.2.md` | ✓ | v0.2.2 audit findings + progress log |
| `docs/audit-v0.3.0-pass2.md` | ✓ | v0.3.0 second-pass audit (80 findings; closed in Phase 4.5) |
| `docs/smartscreen.md` | ✓ | Why the installer/portable-zip triggers SmartScreen on first run + how to safely accept the dialog + how to verify SHA256 |
| `docs/troubleshooting.md` | · | Common errors + fixes (cookies, ffmpeg missing, etc.) |
| `docs/screenshots.md` | · | Visual walkthrough (added in CP5 after UI is stable) |
| `docs/i18n.md` | · | Placeholder for future i18n effort (audit v0.3.0-pass2 finding 57) |

## Runtime state — *not in the repo*

Lives at `%APPDATA%\grab-app\` on every user's machine. Excluded via `.gitignore` even if a file lands here by accident.

| Path | Purpose |
|---|---|
| `config.json` | User settings (folder, toggles, concurrency, position, size) |
| `queue.json` | Live queue: pending, running, done, failed |
| `recent.json` | Last 100 successful downloads (URL tokens redacted) |
| `done-archive-yt-dlp.txt` | Deduplication database (yt-dlp `--download-archive`) |
| `done-archive-gallery-dl.txt` | Deduplication database (gallery-dl `--download-archive`) |
| `logs/grab-YYYY-MM-DD.log` | Per-day activity log (UTC timestamps, rotated at 5MB, pruned to 30 days) |
| `.runtime-theme.xaml` | Cached copy of ui/theme.xaml with `__GRAB_FONTS__` resolved to a `file:///` URI. Regenerated on demand. |
| `config.json.corrupt-<stamp>` | Backup of a corrupt config that Get-Config rewrote with defaults. Safe to delete after inspecting. |
