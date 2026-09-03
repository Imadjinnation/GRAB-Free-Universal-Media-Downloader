# grab — Progress log

Version history and checkpoint notes. Latest at the top.

---

## v0.1.2 · 2026-09-02 · Polish pass (video quality, wrapping labels, dark About)

Small three-item polish. Kept the current dark theme + warm gradient accent (`#F5A87A` -> `#E85F62`) untouched; new design language is being decided separately in another conversation.

**Changes**
- **Video quality picker.** New `videoQuality` config key (`best` / `2160p` / `1440p` / `1080p` / `720p` / `480p` / `audio`, default `best`). Back-filled onto legacy configs. Wired into `Invoke-YtDlp` as a `--format` mapping (yt-dlp only; `Invoke-GalleryDl` untouched). New **VIDEO** section in Settings (ComboBox between COOKIES and NOTIFICATIONS) with caption "Falls back to next-best if the exact resolution isn't available."
- **Settings label wrapping.** Added `TextWrapping="Wrap"` to the `FieldLabel` style and introduced a `Caption` style with wrapping. Fixes the SAFETY/PRIVACY blurb ("Sensitive downloads route into a hidden .private/ folder…") getting cut off at `MinWidth=440` -- no window widening.
- **Dark About dialog.** Replaced the ugly `[System.Windows.Forms.MessageBox]::Show(...)` call in `src/tray.ps1` with an inline WPF `Show-AboutWindow` (380x260, dark card `#111114`, rounded 14px corners, drop shadow, gradient dot + "grab" wordmark, drag-to-move, gradient OK button matching popup). Placeholder body copy in place until finalized.

**Tests added (5)**
1. `Get-Config back-fills videoQuality with default "best"`
2. `Get-Config back-fills videoQuality on legacy configs that lack the key`
3. `Invoke-YtDlp has a --format branch for every documented quality tier` (static-scan for each of the 7 mappings)
4. `settings.xaml has the VideoQuality combobox with all 7 options`
5. `settings.xaml SAFETY/PRIVACY description wraps` (static-scan for `TextWrapping="Wrap"` on FieldLabel style or inline)
6. `About handler in tray.ps1 no longer uses WinForms MessageBox`

**Test count:** 150 / 150 pass (was 144).

**Files touched**
- `src/utils.ps1` -- default + back-fill for `videoQuality`
- `src/core.ps1` -- `Invoke-YtDlp` reads `$cfg.videoQuality` and maps to `--format`
- `src/settings.ps1` -- `VideoQuality` control load / save / reset
- `src/tray.ps1` -- `Show-AboutWindow` (inline WPF) replaces MessageBox
- `ui/settings.xaml` -- new VIDEO section, wrapping FieldLabel + Caption styles
- `tests/smoke.ps1` -- 6 new tests in a `v0.1.2 polish` section

No new files created (About XAML lives inline in `tray.ps1`), so `docs/file-map.md` unchanged.

---

## v0.1.0 · 2026-09-02 · Foundation (in progress)

**Phase 2a / 2b build kickoff.** Restarted from previous script prototypes (`imadjinn-grab.ps1`, popup, drop shortcuts) after UX audit surfaced the need for a proper tray app, batch handling, non-intrusive popup, portable install.

### Design decisions (locked)

| Decision | Choice | Reason |
|---|---|---|
| Tech stack | PowerShell + WPF (custom, no Electron) | User burnt by Electron on Teleprompter; must be git-shareable |
| Popup position | Docked bottom-right | Never disrupts center-screen work |
| Global hotkey | None | User preference; tray-only summon |
| Autostart | ON by default (opt-out) | Since no hotkey, tray must always be present |
| Clipboard watch | Toast prompt (opt-in) | Safe default — never downloads without confirmation |
| Default folder | `%USERPROFILE%\Downloads\imadjinn-grab\` | Changeable in Settings |
| "Ask before download" | OFF by default | User request |
| State location | `%APPDATA%\grab-app\` | Portable, gitignored |

### Checkpoints

- [x] **CP1** — Foundation: scaffold, installer, portable core (T01-T03) — 2026-09-02
- [x] **CP2** — Tray + popup shell + queue engine (T04-T06) — 2026-09-02
- [x] **RETRO-TEST** — 101-test smoke harness built, all green (retroactive CP1+CP2 coverage) — 2026-09-02
- [x] **DEEP-FIX** — WPF Dispatcher.Run, DPI-aware dock, TitleBar hit-testing, closure regression, `if`-in-hash-literal crash, folder-management redesign (Category\Domain layout, single imadjinn.json per chapter) — 2026-09-02
- [x] **CP3** — Queue + Recent tabs live (T07-T09) — 2026-09-02
- [x] **AUDIT-FIX** — 9 critical/high bugs from full-codebase audit + 7 regression tests (StartedAt, TitleBar drag `$_`, firstRunComplete lifetime, bracket-wildcard misses, per-engine archives, cookie=none guard, crash-recovery sweep, arglist quoting) — 2026-09-02
- [x] **CP4** — Settings panel (folder picker, concurrency, cookie browser, toasts toggle, clipboard-watch toggle, autostart toggle, reset), first-run onboarding, autostart shortcut round-trip, structured logging already-existing verified (T10-T12, T15-T18) — 2026-09-02
- [x] **YT-DLP-NIGHTLY-FIX** — Two yt-dlp exes on PATH; winget's stale 2026.07 was winning tiebreak, capping YouTube at 360p. Resolve-Tool now prefers Python Scripts dir; install.ps1 installs `yt-dlp[default] --pre` (nightly + `yt-dlp-ejs` JS solver). Live-tested: 1080p `visionos` client works without PO Token. — 2026-09-02
- [x] **CP5** — Uninstall script (interactive + `-Yes` + `-KeepState`), disk-space low-warning, log-token redaction, popup refresh timer only when visible, dead-code cleanup, docs sync (T14, T19) — 2026-09-02
- [x] **v0.3.0 Phase 4.5** — Second-pass audit: 4 P0s (HKCU\Run uses .vbs + drift heal, MinBtn underscore, popup-visibility gating for adaptive tick), 33 P1 (a11y first pass, doc sync, uninstall completeness, HiDPI/multi-monitor, security), 33 P2 (Chrome cookies detection, rate limiting, long-path prefix, UTC timestamps, InvariantCulture datetime parsing, COM leak fix, LTSC/WSL install gate), 10 P3. Test count 342 → 402. See `docs/audit-v0.3.0-pass2.md`.

### RULE (locked in 2026-09-02): test after every checkpoint

Every CP finishes with `powershell -File tests\smoke.ps1` returning exit 0. New features add tests in the same commit. See `tests/README.md` for what's covered and how to add more.

### CP1 organization audit — 2026-09-02

Findings + fixes applied before continuing to CP2:

- Locked file/folder naming conventions (see `docs/file-map.md`).
- Added `LICENSE` (MIT).
- Created `ui/` folder for XAML with a `README.md` that documents the load pattern + design tokens.
- Added `assets/README.md` documenting the icon inventory and licensing.
- Added `docs/architecture.md` — component map + data flow diagrams.
- Added `docs/file-map.md` — canonical index of every file (built + planned). **New rule: any file addition updates this in the same commit.**
- Renamed `docs/SITE-COVERAGE.md` -> `docs/site-coverage.md` (subfolder-doc convention).
- README gained a "Repository structure" section + "Where to look next" nav.

### Location

Started at `D:\IMADJINnation\tools\grab-app\`. **Moved to `D:\IMADJINnation\grab\`** as a top-level member tool, sibling to `lighting-helper/`. `tools/` is reserved for internal IMADJINnation site-build helpers only.

### Notes for future me

- The previous popup files (`tools/grab-gui-paste.ps1`, `tools/grab-gui-drop.ps1`, `tools/grab-gui-drop.bat`, `tools/install-grab-shortcuts.ps1`) will be superseded but left in place until the new app is verified end-to-end. Remove in CP5.
- The `tools/imadjinn-grab.ps1` wrapper still works standalone via `grab` shell shortcut. Its logic gets ported into `grab/src/core.ps1` (T03). Retire the old file in CP5.
- `.claude/launch.json` should get a new preview target for the tray once we settle a stable entry point.
