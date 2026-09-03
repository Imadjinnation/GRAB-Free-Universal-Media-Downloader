# Changelog

All notable changes to grab. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - 2026-09 - Hygiene Pass (Phase 4.5 second-audit corrections included)

### Phase 4.5 corrections (80-finding second-pass audit)

- P0: HKCU\Run\GRAB now writes `wscript.exe grab-app.vbs` (was `powershell.exe -File`) so no black console flash at login; drift-detection in `Invoke-SelfHealSweep` rewrites the entry when the user moves the repo.
- P0: MinBtn `Content="_"` (empty in WPF) fixed to `Content="__"` in popup + settings.
- P0: PERF-1 tick timer now gates on ANY `running` job AND on popup visibility — active downloads never throttle, and the Queue tab stays responsive while the user watches progress.
- P1: First accessibility pass. `AutomationProperties.Name` on every named control in popup/settings; `IsDefault` on GrabBtn/SaveBtn; `IsCancel` on CancelBtn/CloseBtn; `AcceptsTab="False"` on multi-line TextBoxes; reduced-motion check in popup animations; tab strip keyboard nav.
- P1: About window's `StampRight` is bound at Show time to `Get-GrabVersion` so it never drifts.
- P1: Settings VersionLabel default text is generic "grab" (was hardcoded "grab v0.1.0").
- P1: Uninstall completeness — now removes HKCU\Run\GRAB, NotifyIconSettings promotion key, `.runtime-theme.xaml`, per-engine `done-archive-*.txt`, config.json.corrupt-* backups; catches wscript.exe tray processes; optional `-RevertPSGallery`.
- P1: install.ps1 config seed goes through `Get-Config` (single source of truth) instead of duplicating the schema; WSL + WPF gate added.
- P1: DPI-aware multi-monitor dock (mouse-cursor-relative), `PresentationSource.FromVisual` for DIP<->device conversion in Test-PopupOnScreen, `SetProcessDpiAwareness(2)` at grab-app.ps1 top.
- P1: `_CopyDiagnostics` redacts `sensitiveSites` array from the config dump; UTC timestamps; tooltip documents what is/is not redacted.
- P1: `Set-PSRepository -Trusted` in install.ps1 now warns before flipping the machine-wide policy; `uninstall.ps1 -RevertPSGallery` restores Untrusted.
- P1: Chrome v127+ cookie encryption detection — when yt-dlp reports 0 cookies with `--cookies-from-browser chrome`, a toast tells the user to switch browsers in Settings.
- P1: yt-dlp polite rate limiting (`--sleep-requests 1 --min-sleep-interval 3 --max-sleep-interval 8`).
- P2: `Get-Recent` reads under the recent mutex; datetime parsing now uses `[datetime]::ParseExact('o', InvariantCulture)`; log timestamps are UTC 'Z'; `Get-Queue` dead alias removed; WScript.Shell RCWs released via `New-GrabShortcut`; case-insensitive property check for config back-fill.
- P2: `\\?\` long-path prefix helper for deep comic-chapter downloads.
- P2: Clipboard reads in tick timer are wrapped in a bounded `Task.Wait(500)` so a browser extension can't hang the tick thread.
- P3: Tray tooltip shows live `running:N queued:M` counts; menu items get Alt-key mnemonics (`&S`, `&Q`, `&R`, `&O`, `&A`, `&Q` etc.); popup persists Width/Height in addition to X/Y; Confirm dialog supports Alt+Y / Alt+N mnemonics; About "Open downloads" now toasts when the folder is empty instead of opening a blank Explorer window.
- Docs: README rewrite covers autostart is opt-out, `wscript.exe grab-app.vbs` launcher, SmartScreen first-run note, network-surface table. `docs/architecture.md` rewrite: queue worker is a DispatcherTimer (not a Start-Job), thread model, .vbs launcher, runtime-theme lifecycle. `docs/file-map.md` updated with `grab-app.vbs`, `ui/theme.xaml`, `assets/fonts/`, `assets/scanlines.png`, and current test count.

### Added
- Adaptive queue tick timer: backs off from 2s to 30s when idle, tightens to 15s on battery (PERF-1 / PERF-2).
- Battery-saver / suspend-resume awareness via `SystemEvents.PowerModeChanged` (PERF-2).
- Batched log writes with a 1s flush timer (PERF-3).
- Clipboard-watch timer only runs when `clipboardWatch=true`; toggling in Settings starts/stops it live (PERF-4 / P2-50).
- Ask-before-each downloads: `askBeforeEach=true` opens an arcade-styled per-URL confirmation with "Grab it / Choose folder / Cancel" (P2-40).
- Per-download `Confirm-DownloadDialog` in `tray.ps1` (WPF, matches arcade theme).
- Tray "Copy diagnostics", "Show logs", "Restart tray" menu items (P1-26).
- Self-heal sweep at every launch: recreates missing autostart entries, ghost-folder cleanup, stale-shortcut cleanup (P0-2).
- Crash-recovery: orphaned `running` queue entries get reset to `pending` on startup so the tick worker retries them (high-8).
- Circuit breaker: tick + clip timers halt after 10 consecutive failures and toast the user (P1-25).
- `Get-RuntimeThemeUri`: writes a substituted copy of `theme.xaml` so theme-styled controls actually resolve their font tokens (v0.2.2 -> v0.3.0 font-token bug).
- Unified `Invoke-GrabTokenReplace` helper (P1-29): every window loader now shares one token substitution path.
- Arcade tray menu renderer via `Get-ArcadeMenuRenderer` (P1-30): the last piece of native Windows chrome replaced.
- Result sentinel `{ __grab_result = $r }` on worker output so the tick reader never picks up a foreign PSObject by accident (P1-31).
- `Get-Config` cache invalidated on file mtime; `Set-Config` refreshes it in lock-step (P0-4 / P1-22).
- Sensitive URL substring routing with case-insensitive matching + per-domain `.private` subfolder.
- Test-a-URL input in Settings for previewing sensitive-pattern matches (P2-53).
- Save button now flashes "Saved." for 400ms before hiding (P2-47).
- Settings write-test on the download folder before Save persists (P2-52).
- Test infrastructure: `GRAB_STARTUP_OVERRIDE` for Set-Autostart isolation (P2-57).
- `CHANGELOG.md`, `docs/config-reference.md`, README troubleshooting section (P2-61 / P2-62 / P2-63).

### Changed
- URL redaction regex expanded: now catches bearer / oauth / access / id tokens, JWT, session, X-Amz-* signed-URL params, `code`, etc. (P2-55).
- `recent.json` stores URLs run through the same redactor so short-lived credentials don't persist (P2-56).
- `Cancel-QueueJob` only writes queue.json when it actually mutated an entry; returns bool (P2-41).
- `Append-Recent` guarded by a dedicated `Global\GrabAppRecentMutex`; empty-array cap now uses `Select-Object -First` (P2-36 / P2-37).
- `Clear-Recent` refuses future cutoffs (P2-49); shares the recent mutex.
- `Write-Queue` forces array shape via `,@(...)` wrap (P2-38).
- `Confirm-DownloadDialog` opens quoted paths through `Start-Process -ArgumentList` so folders-with-spaces open once, not twice (P2-45).
- Clipboard-read failure on popup open is logged once per session instead of silently swallowed (P2-46).
- First-run balloon text is orientation-neutral ("at the corner of your screen (may be under the ^ arrow)"), P2-48.
- About / config-read swallowed errors now log (P2-42 / P2-43).
- `.info.json` sidecar cleanup filters by CreationTime so only THIS run's sidecars are deleted (P2-54).
- Dead reference to `src/drop.bat` removed from `install.ps1` (P2-33).
- `Set-PSRepository` policy check corrected: parser-safe `-ne` shape (P2-34).
- Python scripts-dir probe uses `2>$null` and explicit null-check instead of coercing stderr into the string result (P2-35).

### Fixed
- `firstRunComplete` set right after the balloon fires (crit-3): users who reboot instead of Quit no longer see the greeting every login.
- WPF TitleBar drag: no more `$_` reference (crit-2); WPF handlers don't populate `$_`, so `DragMove` now fires reliably.
- `$grabStartedAt` captured up front so post-process manifest logic uses the correct "touched by this run" cutoff (crit-1).
- Log rotation: per-day file rotates when it exceeds 5MB; log folder pruned to 30 days (P1-23).
- Named mutex WaitOne return checked + `AbandonedMutexException` treated as reclaim (P0-3 / P1-24).
- Dispatcher.Run wrapped in try/catch + last-resort MessageBox so a WPF exception no longer kills the tray silently (P0-1).
- `Get-TrayIcon` releases ExtractIconEx handles via `DestroyIcon` (P1-20).
- Diff-hash render skip in popup avoids the scroll-position reset every tick (P1-21).
- `renderQueue` / `renderRecent` hashes projection fields only, so cosmetic churn on unrendered fields doesn't invalidate the cache.
- Emoji Runs isolated in `Segoe UI Emoji` so the sensitive-toggle lock + clear-recent trash icons don't render as tofu (P1-16 / P1-17).
- Popup + Settings + About XAML wrap `XamlReader.Parse` in try/catch and toast on failure instead of taking down the tray (P1-15).
- `Get-Config` recovers from corrupt JSON by backing up + writing defaults (v0.2.2 crash).
- Fast tray startup: WPF assemblies deferred via `Ensure-WpfLoaded`; tray icon appears in ~1-2s vs. 5-8s (v0.3.0 phase 1.7).
- Ghost `%USERPROFILE%\Downloads\imadjinn-grab` folder cleaned on self-heal when empty (P0-6).

### Removed
- Standalone `grab Downloads.lnk` desktop shortcut (P1-10): tray menu covers it.
- `[System.Windows.Forms.MessageBox]::Show` for user decisions; replaced with `Confirm-ArcadeDialog`. One sanctioned exception: the tray-crash last-resort inside the Dispatcher.Run catch block.

## [0.2.2] - 2026-09 - Mockup-match arcade UI + audio category + self-heal audit

### Added
- Full arcade UI redesign matching the design-review mockup: warm-amber halo behind wordmark, cream ink, phosphor teal, LED status dots on queue rows.
- Audio category routing (SoundCloud, Bandcamp, podcast feeds, direct .mp3/.flac/etc URLs).
- 52px 4-layer About wordmark stack.
- Clear-Recent (all) and Clear-Recent (>30 days) buttons on the Recent tab.
- CRT scanlines overlay (config: `crtScanlines`).
- Full self-heal audit sweep on every launch.

### Changed
- Palette: cool white `#F4F0FF` -> cream `#F5EBD0`; pure cyan `#00E5FF` -> phosphor teal `#00E5D2`; shipped orange `#FFB800` -> warm amber `#FFD447`.
- Tab underlines are magenta with per-tab active color (amber / cyan / green).
- `Test-IsSensitiveUrl` matches URL patterns case-insensitively via substring.

## [0.2.1] - 2026-09 - Theme + arcade colors + scanlines

### Added
- Shared `ui/theme.xaml` ResourceDictionary with the full arcade palette + templates for every native control (`ArcadePrimary`, `ArcadeGhost`, `ArcadeDanger`, `ArcadeCombo`, `ArcadeSlider`, `ArcadeCheck`, `ArcadeText`, `ArcadeTab`).
- Re-styled `ScrollBar` / `ContextMenu` / `MenuItem` / `ToolTip` so no Windows-native chrome leaks.
- `Confirm-ArcadeDialog` replaces `MessageBox.Show` for user decisions.

## [0.2.0] - 2026-09 - Visual redesign + fonts

### Added
- Silkscreen / VT323 / Inter fonts bundled under `assets/fonts/`.
- Multi-res `assets/icon.ico`.
- Chromatic aberration wordmark (3 stacked TextBlocks).

## [0.1.2] - 2026-09 - Polish

### Added
- Video-quality picker in Settings (best / 2160p / 1440p / 1080p / 720p / 480p / audio).
- Wrapping labels so long safety copy doesn't overflow.
- Dark About window.

## [0.1.1] - 2026-09 - Safety features + default folder move

### Added
- Sensitive-URL routing to `.private` hidden subfolder.
- `sensitiveSites` config array + `sensitiveByDefault` toggle.

### Changed
- Default download folder moved from `~\Downloads\imadjinn-grab` to `D:\imadjinn-grab` (OneDrive-safe).

## [0.1.0] - 2026-09 - First cut

### Added
- Universal media downloader tray app.
- yt-dlp / gallery-dl auto-picker with fallback chain.
- WPF popup with Paste / Queue / Recent tabs.
- Settings window.
- Windows toast notifications via BurntToast.
- Portable one-command bootstrapper (`install.ps1`).
