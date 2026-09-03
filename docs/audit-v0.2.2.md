# GRAB Deep Hygiene Audit — v0.2.2

Audit run: 2026-09-03. Total findings: **88** ({P0: 7, P1: 25, P2: 31, P3: 25}).

Files audited: `grab-app.ps1`, `install.ps1`, `uninstall.ps1`, `src/utils.ps1`, `src/core.ps1`, `src/queue.ps1`, `src/popup.ps1`, `src/settings.ps1`, `src/tray.ps1`, `ui/popup.xaml`, `ui/settings.xaml`, `ui/theme.xaml`, `tests/smoke.ps1`. Live state: `%APPDATA%\grab-app\`, both Startup folders, `HKCU\...\Run`, ghost `C:\Users\Admin\Downloads\imadjinn-grab\`, real download root `D:\imadjinn-grab\`, iconcache DBs, running processes.

---

## P0 — Breaks normal use (7)

1. **[P0-Reliability] tray.ps1:613** — `Dispatcher.Run()` has no try/catch. Any WPF exception during pump = tray dies silently. **Fix:** wrap in try/catch + Log-Err + toast/MessageBox before exit.
2. **[P0-Self-heal] tray.ps1:559-614** — No self-heal on startup for autostart shortcut, desktop shortcut, download folder, icon cache. **Fix:** `Ensure-Installation` in Start-Tray.
3. **[P0-Reliability] grab-app.ps1:19-24** — Singleton mutex not properly released on force-kill/logoff → orphaned mutex blocks next relaunch silently. **Fix:** WaitOne(0) treats AbandonedMutexException as "I own it".
4. **[P0-UX] install.ps1:141 / utils.ps1:46** — Config `version` hardcoded `'0.1.0'` while About says `v0.2.2`. **Fix:** Central `$script:GrabVersion` constant used everywhere; migration bumps stale field.
5. **[P0-UX] Windows-11 tray-hide-by-default** — No manifest hint, no first-run promotion prompt. **Fix:** Registry promotion flag OR first-run balloon with pin-instruction illustration.
6. **[P0-Data integrity] tests/smoke.ps1:445-455** — Test `Invoke-Grab default Dest follows Category\Domain layout` creates real folders in USER's `~/Downloads/imadjinn-grab\`. This is the CONFIRMED source of the ghost folder. **Fix:** Tests must override `downloadFolder`; add finally-block cleanup.
7. **[P0-Reliability] queue.ps1:125-153, 155-168, 367-388, 390-401** — `Set-JobStatus`, `Cancel-QueueJob`, `Retry-QueueJob`, `Recover-OrphanedJobs`, `Stop-AllJobs` all skip the queue mutex → lost-update race with tick timer. **Fix:** Take mutex around every read-modify-write.

---

## P1 — Visible frequently (25)

8. **[P1-Reliability] utils.ps1:65, 114 / queue.ps1:66, 197, 266** — `Set-Content -Encoding UTF8` writes UTF-8 BOM. External tools trip. **Fix:** Use `System.IO.File.WriteAllText` with `UTF8Encoding($false)`.
9. **[P1-Data integrity] queue.ps1:66-67, 114 / utils.ps1:114** — Non-atomic writes to state JSONs → kill mid-write = corrupt file. **Fix:** Write to `.tmp` then `File.Replace` (atomic rename on NTFS).
10. **[P1-UX] install.ps1:186-201 / uninstall.ps1:62** — Two desktop shortcuts (`grab` + `grab Downloads`). **Fix:** Ship only `grab.lnk`. Use tray menu for downloads folder.
11. **[P1-Self-heal] settings.ps1:23-46** — Autostart shortcut can silently disappear (OneDrive, group policy, cleanup) — nothing rebuilds it. **Fix:** On tray start, if config.autostart && shortcut missing → recreate + Log-Warn.
12. **[P1-Self-heal] install.ps1:186-202** — Desktop shortcuts vanished (OneDrive Desktop redirection). **Fix:** Detect via `HKCU\...\User Shell Folders\Desktop`; write to both candidate paths.
13. **[P1-UX] settings.ps1:280 / settings.xaml:275** — VersionLabel binds to `$cfg.version` = stuck at 0.1.0. **Fix:** See #4.
14. **[P1-Reliability] tray.ps1:35-38** — `New-Object System.Drawing.Icon $iconPath` swallow-catches. **Fix:** Log-Warn on failure.
15. **[P1-Reliability] popup.ps1:288-292 / settings.ps1:75-79** — XAML parse errors kill the tray. **Fix:** Catch XamlParseException, toast, don't re-throw.
16. **[P1-UX] popup.xaml:349-355** — `SensitiveToggle` uses emoji `🔒` — bundled font has no glyph → tofu risk. **Fix:** Isolate emoji Run with `Segoe UI Emoji` fallback stack.
17. **[P1-UX] popup.xaml:425** — CLEAR ALL button label starts with emoji `🗑` — same tofu risk. **Fix:** Same.
18. **[P1-Reliability] settings.ps1:167-168** — `SelectedItem.Content` throws when null (race under Reset). **Fix:** Null-guard.
19. **[P1-UX] settings.xaml:189-194** — "brave" browser option but no validation the current yt-dlp version supports it. **Fix:** Runtime probe or version pin check.
20. **[P1-Data integrity] tray.ps1:32-58** — `Get-TrayIcon` leaks icon handles (declares `DestroyIcon` but never calls). **Fix:** Call `DestroyIcon` after Clone.
21. **[P1-UX] popup.ps1:456 / 490-491** — 2-second timer rebuilds Queue+Recent StackPanels every tick even when nothing changed → flicker + resets scroll. **Fix:** Diff by job.Id + hash; skip when unchanged.
22. **[P1-Performance] utils.ps1:42-110** — `Get-Config` re-reads config.json on EVERY call (queue tick, clipboard tick, every popup row build). **Fix:** In-memory cache with mtime check; bust on Set-Config.
23. **[P1-Data integrity] Log growth unbounded** — no rotation. **Fix:** Cap at 5MB per file, keep 30 days, delete older.
24. **[P1-Reliability] queue.ps1:42, 61** — `$script:QueueMutex.WaitOne(2000)` return value ignored — on timeout, code proceeds WITHOUT lock. **Fix:** Bail out with Log-Warn on timeout.
25. **[P1-Reliability] tray.ps1:527-531 / 535-548** — DispatcherTimer keeps firing even at 100% error rate → log floods. **Fix:** Circuit breaker: stop after 10 consecutive failures + toast.
26. **[P1-UX] tray.ps1:509** — Only "Quit" menu item; no Restart / Show diagnostics / Copy logs. **Fix:** Add Restart, Copy diagnostics, Show logs.
27. **[P1-UX] popup.xaml + settings.xaml** — `AmberCaret` storyboard animates forever even when hidden → battery drain. **Fix:** Pause on `IsVisibleChanged`.
28. **[P1-Self-heal] utils.ps1:139-168** — `Get-RuntimeThemeUri` doesn't check source mtime for staleness. **Fix:** Compare `LastWriteTimeUtc`.
29. **[P1-Self-heal] popup.ps1:281-292, settings.ps1:71-79, tray.ps1:260-268** — Three separate token-substitution helpers with subtle drift (root cause of the font substitution bug we hit). **Fix:** Single `Invoke-GrabTokenReplace` in utils.ps1.
30. **[P1-UX] tray.ps1:496-514** — Tray context menu is WinForms → arcade theme.xaml MenuItem styles never apply → native Windows chrome. **Fix:** Wire WPF-hosted menu OR document as known.
31. **[P1-Reliability] queue.ps1:283 / 293-308** — Result parse picks first PSObject with `.Success` property → stray objects in pipeline confuse it. **Fix:** Wrap in `@{ __grab_result = $r }` sentinel.
32. **[P1-UX] settings.ps1:167 / settings.xaml:186-194** — Cookie-browser combo has no explanation. **Fix:** Add caption explaining what it does.

---

## P2 — Edge case (31)

33-63 — see full list in the audit output. Highlights:
- **P2-Reliability** install.ps1:169 — dead reference to non-existent `src\drop.bat`
- **P2-Reliability** install.ps1:100-103 — `Set-PSRepository` condition parses wrong → never runs → hangs on BurntToast install
- **P2-Data integrity** queue.ps1:181-198 — `Append-Recent` no mutex → concurrent completions lose entries
- **P2-Self-heal** No `HKCU\...\Run` registry autostart redundancy
- **P2-UX** `AskBeforeEach` is a config key + checkbox but NEVER queried → dead switch
- **P2-Security** Redact regex misses bearer/access_token/id_token/oauth_token/session/jwt/code/X-Amz-*
- **P2-Security** `recent.json` stores full URLs in plain text (any URL with query token leaks)
- **P2-Testing** `Set-Autostart` round-trip test touches user's REAL Startup folder
- **P2-Testing** Most XAML tests use regex on file text vs. rendering + inspecting

---

## P3 — Polish (25)

64-88 — see full list. Highlights: auto-update, tooltip queue count, persist window size, keyboard shortcuts, better P/Invoke handle cleanup, delete stale `.runtime-theme.xaml`, `Cancel-QueueJob` no-op writes, About window error toast, first-run balloon multi-monitor awareness.

---

## Patterns

- **16 empty catch blocks** — half of them swallow errors that produced this session's silent failures
- **Version drift systemic** — same string in 4+ places, guaranteed to drift
- **UTF-8 BOM quirk** — 5 sites write JSON with BOM
- **Font-URI substitution duplicated 3×** — direct cause of theme.xaml font fallback bug
- **Tests write to user's real profile** — direct cause of ghost `C:\Downloads\imadjinn-grab\`
- **Queue mutation without mutex in 5 places** — race with Invoke-QueueTick

## High-ROI single fixes (each eliminates many findings)

1. **Central `$script:GrabVersion` constant** — kills #4, #13, #63, #69
2. **Atomic UTF-8-no-BOM writer** — kills #8, #9, #36
3. **`Get-Config` cache with mtime invalidation** — kills #22 + reduces hot-loop I/O
4. **`Ensure-Installation` startup self-heal** — kills #2, #11, #12, #39
5. **`Invoke-GrabTokenReplace` unified helper** — kills #29, prevents font-substitution regression
6. **Tests override `downloadFolder`** — kills #6, prevents future ghost folders

## Disproportionately fragile files

- `src/tray.ps1` (29 KB) — 6 P0/P1 findings; primary loop + WinForms tray + WPF dialogs + 3 token helpers
- `src/popup.ps1` (29 KB) — 8 P0/P1/P2 findings; WPF closures + row builder + timer + file-URI helpers
- `tests/smoke.ps1` (94 KB) — 5 findings; primary regression net AND source of user-visible bugs
