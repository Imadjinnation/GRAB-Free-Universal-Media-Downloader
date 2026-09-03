# GRAB Second-Pass Audit — v0.3.0 (Phase 4 in flight)

**Status: CLOSED in Phase 4.5 (2026-09-03).** All 80 findings addressed. Test count 342 → 402. See CHANGELOG.md `[0.3.0] Phase 4.5 corrections` section for the per-finding summary.

**Total NEW findings: 80** — P0: 4 · P1: 33 · P2: 33 · P3: 10.

Second-pass audit angles the first audit missed: accessibility, HiDPI/multi-monitor, i18n, antivirus/signing, path edge cases, network edge cases, uninstall completeness, dead code, doc-drift, security nuances, launcher choice (.vbs vs powershell.exe -File).

## P0 (4)

1. **utils.ps1:197-211** — HKCU\Run writes `powershell.exe -File grab-app.ps1` (never .vbs) → login flash on every autostart. Should use grab-app.vbs like _RestartTray does.
2. **utils.ps1:453-541** — `Enable-LogBatching`/`Disable-LogBatching`/`Flush-LogQueue` DEFINED BUT NEVER CALLED (grep confirms). PERF-3 shipped as dead scaffolding — every Write-Log still synchronous.
3. **popup.xaml:215-216 / settings.xaml:146-147** — `Content="_"` on MinBtn renders BLANK (WPF underscore = access-key marker). Should be `__` or an em-dash glyph.
4. **utils.ps1:200-201** — HKCU\Run entry captures current absolute path. If user moves the repo folder, autostart silently fails at login. Self-heal doesn't detect drift.

## P1 (33) — key clusters

**Accessibility (findings 5-11):** Zero `AutomationProperties.Name` anywhere. GrabBtn missing `IsDefault="True"` — Enter only submits when focus is in UrlBox. Cancel buttons missing `IsCancel="True"`. `AcceptsReturn="True"` without `AcceptsTab="False"` traps keyboard users. Tab strip has no keyboard nav. Storyboards don't check `ClientAreaAnimation` (reduced-motion preference). Palette ignores Windows HighContrast.

**Docs are 1-2 phases behind reality (findings 12-22):**
- README says autostart is opt-in — reality: opt-out (default ON)
- README documents `grab Downloads.lnk` shortcut (removed v0.3.0)
- README says uninstaller is "coming later" — has existed since v0.1.0
- Manual-uninstall instructions omit HKCU\Run, NotifyIconSettings, backup files
- README default folder says `~/Downloads/imadjinn-grab`, reality is `D:\imadjinn-grab` (via Get-DownloadFolderDefault)
- `docs/architecture.md:83` claims queue worker is background PS job — WRONG, it's a DispatcherTimer
- `docs/architecture.md:78` shows powershell.exe launch — reality is wscript.exe grab-app.vbs
- References to non-existent `src/drop.bat` in README + file-map (dead)
- grab-app.vbs + ui/theme.xaml + assets/fonts/ + assets/scanlines.png ABSENT from repo tree
- PROGRESS.md has duplicate unchecked CP3-CP5 entries below the checked ones
- file-map says "101 tests", reality 302+

**Config schema drift (finding 23):** install.ps1's default schema is missing 5 keys that Get-Config back-fills. Fix: install.ps1 calls Get-Config to seed rather than duplicating the schema.

**Uninstall incompleteness (finding 24):** uninstall.ps1 does not remove HKCU\Run\GRAB, NotifyIconSettings registry key, .runtime-theme.xaml, config.json.corrupt-* backups, per-engine done-archive files, OneDrive stale shortcuts.

**Multi-monitor + HiDPI (findings 25-27):** Test-PopupOnScreen compares DIPs to device pixels (wrong on 150% scaling monitors). Get-DockedPosition uses primary WorkingArea only — users with taskbar on secondary always dock to primary. No DPI-awareness declaration.

**Perf critique on in-flight Phase 4 (findings 34-36):**
- PERF-1 if shipped as "30s when idle" without popup visibility gating → ROLLBACK required (Queue tab appears frozen while user watches progress)
- PERF-2 if throttling active downloads → ROLLBACK required
- PERF-3 shipped as dead scaffolding (finding #2) — must complete wiring OR delete

**Security (finding 29):** _CopyDiagnostics copies raw config.json including user's sensitive-sites patterns → leaks user privacy prefs into any bug report. Log tail may include pre-redaction URLs.

**Version drift (finding 78):** About window's StampRight text HARDCODED "v0.2.2 · SEP 2026" in XAML with no x:Name binding — About shows v0.2.2 forever until someone manually bumps.

**Dead switch (finding 30):** askBeforeEach STILL not wired (per audit #P2-40 which said "implement it"). Phase 4 either wired it or should be pushed harder.

## P2 (33) — highlights

- Windows MAX_PATH (260 chars) not handled for deep comic-chapter downloads
- Chrome v127+ cookie encryption — no detection or user warning
- yt-dlp 429 retries immediately (no `--sleep-requests`)
- Install.ps1 changes machine-wide PSGallery trust policy without warning
- Timestamps use local time — Portable Apps case shows DST drift
- Test #61: Set-Autostart round-trip writes to REAL HKCU\Run despite $GRAB_STARTUP_OVERRIDE (only shortcut is redirected)
- _RestartTray race: spawns child before releasing mutex → child sees "already running" → exits → nothing restarts on some systems
- Append-Recent reads recent.json without _WithRecentMutex (only write is mutex-protected)
- COM leaks: WScript.Shell RCWs never released
- Get-CategoryForUrl routes Reddit to Social but Reddit is video-heavy

## P3 (10)

- About footer version hardcoded in XAML with no binding (fix required: give StampRight x:Name, bind at Show)
- Menu items missing `&` mnemonics
- Popup position remembered but not size (ResizeMode allows resize)
- Tray tooltip static string
- Comments in tray.ps1 reference user's specific hardware (RTX 3050 6GB) — should be generic

## Patterns

1. **Documentation is 1-2 phases behind code.** Doc-sync should be a phase-close gate.
2. **Consistency between code paths sharing intent has drifted.** vbs launcher used in some places, not others; token replacer unified but URI builders still 3× copies.
3. **Accessibility is entirely absent.** No AutomationProperties.Name, no IsDefault/IsCancel, no HighContrast, no reduced-motion.
4. **Scaffolding shipped without wiring.** Batched log flush, `Get-Queue` alias, `askBeforeEach`.
5. **Version drift high in About + Settings XAML** — three files hardcode v0.2.2.

## Suggested Phase 4.5 execution order

1. Fix P0s: HKCU uses .vbs, MinBtn underscore, About stamp binding, HKCU path drift-heal (4 findings, ~30 min)
2. Complete OR delete PERF-3 log batching (dead scaffolding)
3. Correct PERF-1/2 spec — visibility gating + never throttle active work
4. README + architecture + file-map sync
5. Accessibility first pass (all 7 a11y findings)
6. Uninstall completeness + config-schema drift consolidation

## Phase 4 rollback matrix

| Phase 4 change | Roll back if… |
|---|---|
| Enable-LogBatching without wiring | LEAVE — 4.5 completes it |
| Adaptive tick "30s idle" WITHOUT popup-visibility gate | ROLL BACK |
| Battery-saver throttling on ACTIVE downloads | ROLL BACK |
| askBeforeEach implementation | KEEP if implemented; delete config key + UI if not implemented |
