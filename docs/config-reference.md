# grab config reference

The file lives at `%APPDATA%\grab-app\config.json`. Every writable key + its default + what it does.

Written atomically (UTF-8, no BOM) via `Write-JsonAtomic`. Deleting the file causes GRAB to rewrite fresh defaults on next launch; a malformed file gets backed up to `config.json.corrupt-YYYYMMDD-HHMMSS` and replaced with defaults.

## Keys

| Key | Default | Effect |
|---|---|---|
| `version` | matches `Get-GrabVersion` | Stamp of the release that last wrote this file. GRAB migrates the value forward on load; not user-editable. |
| `downloadFolder` | `D:\imadjinn-grab` if `D:\` exists, else `%USERPROFILE%\imadjinn-grab` | Root folder for downloads. Category + domain subfolders are added underneath. |
| `askBeforeEach` | `false` | When `true`, every submit from the Paste tab opens a per-download confirmation dialog (URL / destination / sensitive-toggle preview + "Grab it" / "Choose folder..." / "Cancel"). |
| `clipboardWatch` | `false` | Watches the clipboard for a URL and toasts when one appears. The clip timer only runs while this is `true` (audit PERF-4). |
| `concurrency` | `3` | Max number of jobs the queue tick will run in parallel. |
| `autostart` | `true` | Registers the app with Windows startup (HKCU\Run + a Startup-folder shortcut when the folder is not OneDrive-redirected). |
| `cookieBrowser` | `chrome` | Which browser's cookies to hand yt-dlp / gallery-dl. Options: `chrome`, `firefox`, `edge`, `brave`, `none`. `none` disables `--cookies-from-browser` entirely. |
| `videoQuality` | `best` | yt-dlp format ceiling. Options: `best`, `2160p`, `1440p`, `1080p`, `720p`, `480p`, `audio`. `audio` extracts to mp3. |
| `toastsEnabled` | `true` | When `false`, Send-Toast becomes a no-op (used for headless-y setups). |
| `popupPositionX` | `null` | Last X coordinate the popup window was dragged to. Null = dock to bottom-right of the primary work area. |
| `popupPositionY` | `null` | Last Y coordinate. Same rules as X. |
| `firstRunComplete` | `false` | Gate for the first-run tray-pin balloon; set to `true` after the balloon fires. |
| `sensitiveByDefault` | `false` | Route EVERY download into the `.private` hidden subfolder, regardless of URL patterns. |
| `sensitiveSites` | `[]` | Array of case-insensitive URL substring patterns that auto-route to `.private`. One entry per line in the Settings textarea. |
| `sensitiveFolderName` | `.private` | Folder name inserted between category and domain for sensitive downloads. Windows `Hidden` attribute is applied. |
| `crtScanlines` | `true` | Toggles the static CRT scanline overlay in the popup / settings / About windows. |

## Migration + back-fill

Every load runs through `Get-Config` in `src/utils.ps1`:

1. If the file is missing, write fresh defaults.
2. If it exists, parse it. On parse failure, back up + rewrite defaults.
3. Back-fill new keys that legacy configs lack (`sensitiveSites`, `sensitiveByDefault`, `sensitiveFolderName`, `videoQuality`, `crtScanlines`).
4. If `version` differs from `Get-GrabVersion`, bump + persist.

The parsed object is cached in-process; the cache invalidates on `LastWriteTimeUtc` change (external edits still get picked up).

## Precedence

- CLI flags to `Invoke-Grab` (like `-Sensitive`, `-Tool`, `-Dest`) OVERRIDE config values for that one call.
- `Test-IsSensitiveUrl` uses `sensitiveByDefault || sensitiveSites match` -- either fires.

## Test overrides

- `GRAB_APP_DATA_OVERRIDE` -- redirects the config + queue + recent + logs to a temp folder (tests only).
- `GRAB_TESTS_SKIP_ENGINES` -- skips actual yt-dlp / gallery-dl invocation.
- `GRAB_STARTUP_OVERRIDE` -- points `Get-LocalStartupPath` at a temp folder so `Set-Autostart` doesn't touch the user's real Startup folder in tests.
