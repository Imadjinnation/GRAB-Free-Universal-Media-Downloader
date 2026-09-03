# grab

Universal media downloader for filmmakers. Paste any link, get the file. Works with videos, image galleries, comics, manga, social media posts — anything ~1000 supported sites can hand out.

Built as a **calm, always-available system-tray app**. No browser extensions, no popup ads, no premium tiers. Everything free and open-source underneath.

---

## What it does

- Auto-picks the right engine per link: **yt-dlp** for videos, **gallery-dl** for image galleries, retries the other on failure
- Uses your **Chrome or Firefox cookies** so private/login-only content works
- **Bulk-friendly**: paste 50 links, drop a .txt of URLs, or feed a manga series URL and get every chapter
- **Non-intrusive**: lives quietly in the system tray, only appears when you summon it
- **Duplicate-safe**: skips files you've already downloaded
- **Transparent**: shows which engine ran, real success detection (no false "done" messages)

## Install (3 steps)

Requires **Windows 10/11** and **Python 3.10+**.

```powershell
git clone https://github.com/YOUR-USER/imadjinn-grab.git
cd imadjinn-grab
.\install.ps1
```

The installer:
1. Verifies Python is present
2. Installs `yt-dlp`, `gallery-dl`, and the `BurntToast` PowerShell module (for notifications)
3. Detects or installs `ffmpeg` via winget
4. Puts a **grab** icon in your system tray
5. Adds itself to Windows startup by default (opt-out with `install.ps1 -NoStartup`, or disable later in Settings > Startup)
6. Creates a desktop shortcut for quick access

## First run — SmartScreen dialog

Because grab is an unsigned PowerShell app, the first time you run it Windows SmartScreen may pop up "Windows protected your PC." That's expected for any tool that isn't Microsoft-signed. Click **More info**, then **Run anyway**. You'll see this at most once per install. (A future release ships a signed installer + VirusTotal badge — tracked in Phase 5.5.)

## Use it

**System tray:** left-click the icon → paste popup. Right-click → menu (Show grab, Queue, Recent, Settings, Open downloads, Show logs, Copy diagnostics, Restart tray, About, Quit). Every menu item has an Alt-key shortcut (Alt+S opens grab, Alt+Q jumps to Queue, etc.).

**Desktop shortcut** (created by `install.ps1`):
- `grab` — launches the tray (safe to double-click; a singleton lock ensures only one instance ever runs)

The tray uses the `wscript.exe` VBS launcher when it's on disk so there's no black console flash at login; the fallback is `powershell.exe -File grab-app.ps1`.

## Uninstall

Run `.\uninstall.ps1` from the repo:

```powershell
.\uninstall.ps1               # interactive (prompts before removing state / pip packages)
.\uninstall.ps1 -Yes          # remove everything, no prompts
.\uninstall.ps1 -KeepState    # only remove shortcuts + tray; keep %APPDATA%\grab-app
.\uninstall.ps1 -RevertPSGallery   # also flips PSGallery back to Untrusted
```

**Your downloads are never touched.**

Manual removal (if the script is missing or you need to clean up a broken install):

1. Right-click the tray icon → **Quit** (or Task Manager → end `powershell.exe -File grab-app.ps1` / `wscript.exe grab-app.vbs`).
2. Delete the desktop shortcut `grab.lnk`.
3. Delete `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\grab.lnk` if present.
4. Registry: remove `HKCU\Software\Microsoft\Windows\CurrentVersion\Run\GRAB` and `HKCU\Software\Microsoft\Windows\CurrentVersion\NotifyIconSettings\{f3e2c9a1-4b8e-4d3a-9c1b-5e6a7b8c9d0e}`.
5. Delete `%APPDATA%\grab-app\` (settings, queue, recent history, logs, `.runtime-theme.xaml`, `done-archive-*.txt`, `config.json.corrupt-*` backups).

## What lives where

| Path | Purpose |
|---|---|
| `%APPDATA%\grab-app\config.json` | Your settings (see [docs/config-reference.md](docs/config-reference.md)) |
| `%APPDATA%\grab-app\queue.json` | Active + queued downloads |
| `%APPDATA%\grab-app\recent.json` | Recent history (URLs are token-redacted before persist) |
| `%APPDATA%\grab-app\logs\` | Per-day activity logs (rotated at 5MB, pruned to 30 days) |
| `%APPDATA%\grab-app\done-archive-yt-dlp.txt` | Per-engine dedup database |
| `%APPDATA%\grab-app\done-archive-gallery-dl.txt` | Per-engine dedup database |
| `%APPDATA%\grab-app\.runtime-theme.xaml` | Cached theme.xaml with font URIs resolved (regenerated on demand) |
| `D:\imadjinn-grab\` *(default if `D:\` exists, else `%USERPROFILE%\imadjinn-grab\`)* | Default download folder — change in Settings |

Downloads are laid out as `<downloadFolder>\<Category>\<Domain>\...`. Sensitive downloads add a `.private\` (hidden) folder between category and domain.

## Repository structure

```
grab/
├── README.md                you are here
├── PROGRESS.md              version log + design decisions
├── CHANGELOG.md             Keep-a-Changelog release notes
├── LICENSE                  MIT
├── install.ps1              one-command bootstrapper
├── uninstall.ps1            clean removal (leaves downloads)
├── grab-app.ps1             main entry — launches tray
├── grab-app.vbs             silent wscript.exe wrapper (no console flash)
│
├── src/                     PowerShell logic
│   ├── utils.ps1            config, paths, tool discovery, logging, toasts, shortcut helper
│   ├── core.ps1             Invoke-Grab (engine wrapper with fallback chain, sensitive routing)
│   ├── queue.ps1            queue state + tick worker + Recent list
│   ├── tray.ps1             system tray, right-click menu, About + Confirm dialogs, timers
│   ├── popup.ps1            popup window controller (Paste/Queue/Recent tabs)
│   └── settings.ps1         settings window
│
├── ui/                      WPF XAML markup (see ui/README.md)
│   ├── theme.xaml           shared arcade design tokens (palette, ArcadePrimary/Ghost/Danger/…)
│   ├── popup.xaml
│   └── settings.xaml
│
├── assets/                  icons + images (see assets/README.md)
│   ├── icon.ico             tray icon (multi-res)
│   ├── icon-32.png          popup accent
│   ├── scanlines.png        CRT overlay (legacy; runtime uses a LinearGradientBrush)
│   ├── fonts/               bundled Silkscreen / VT323 / Inter
│   └── gallery-dl-config.json
│
└── docs/                    user + contributor docs
    ├── architecture.md      component map + data flow
    ├── site-coverage.md     which engine handles which sites
    ├── file-map.md          canonical index of every file
    ├── config-reference.md  every config.json key
    └── audit-v0.3.0-pass2.md   audit tracking
```

**Runtime state** lives at `%APPDATA%\grab-app\` (never in the repo) — see [file-map.md](docs/file-map.md).

## Network surface

Every outbound connection GRAB makes:

| Purpose | Endpoint | Frequency |
|---|---|---|
| Video downloads | Whatever host the URL points at (yt-dlp) | Per download |
| Gallery downloads | Whatever host the URL points at (gallery-dl) | Per download |
| pip package install/upgrade | `pypi.org`, `files.pythonhosted.org` | `install.ps1` only |
| BurntToast module install | `powershellgallery.com` | `install.ps1` only, first run |
| ffmpeg install | `winget` sources → Gyan.FFmpeg | `install.ps1` only, when winget agrees |

The tray itself makes **no** outbound connections. No telemetry, no update checks, no analytics. Your `HTTPS_PROXY` / `HTTP_PROXY` env vars are inherited by yt-dlp / gallery-dl automatically.

## Troubleshooting

**Is grab running?**
- Look for the icon in the system tray at the corner of your screen (may be under the `^` arrow — drag it out onto the taskbar to keep it visible).
- Or open Task Manager (Ctrl+Shift+Esc) and search for `wscript.exe` running `grab-app.vbs`, or `powershell.exe` running with `-File grab-app.ps1`.

**How do I quit?**
- Right-click the tray icon → **Quit**.

**Where do my downloads go?**
- Default: `D:\imadjinn-grab\` (if `D:\` exists) or `%USERPROFILE%\imadjinn-grab\`.
- Change it in Settings → Downloads → Default download folder.
- Downloads are laid out as `<downloadFolder>\<Category>\<Domain>\`. Sensitive downloads add a `.private\` (hidden) folder between category and domain.

**Where does grab's state live?**
- `%APPDATA%\grab-app\` — config, queue, recent history, logs, and per-engine download archives.

**Something looks wrong — how do I clear the queue or start fresh?**
- Clear the queue: right-click tray → **Restart tray** (drops any interrupted `running` entries and reloads state).
- Reset settings: right-click tray → **Quit**, then delete `%APPDATA%\grab-app\config.json` and relaunch. GRAB will rewrite fresh defaults.
- Full nuke: quit, then delete the entire `%APPDATA%\grab-app\` folder. Your downloads on disk are never touched.

**Where are the logs?**
- `%APPDATA%\grab-app\logs\grab-YYYY-MM-DD.log` (per-day, rotated at 5MB, pruned to 30 days). Timestamps are UTC with a `Z` suffix.
- Right-click tray → **Show logs** opens the folder in Explorer.
- Right-click tray → **Copy diagnostics** puts grab version, config.json (sensitiveSites redacted), and last 100 log lines (URL tokens already redacted) on your clipboard — paste into a bug report.

**Tray icon didn't show up after login?**
- Autostart lives in two places: `HKCU\Software\Microsoft\Windows\CurrentVersion\Run\GRAB` (primary, always set when autostart is on) and, when your Startup folder isn't OneDrive-redirected, a `grab.lnk` shortcut in `shell:startup`. The tray's self-heal sweep rewrites HKCU\Run on every launch if the value drifts (e.g. after you moved the repo), and recreates the shortcut. If both are missing, re-run `install.ps1`.

**"Nothing downloaded" every time?**
- Open Settings → Cookies → **Browser used to read login cookies**: pick whichever browser you're actually logged into on the target site. `none` disables cookies entirely.
- Chrome v127+ encrypted its cookie DB with an OS-bound key. If you see `"Chrome cookies unavailable"` in a toast, switch to Firefox or Edge in Settings.
- Try Settings → Video → **Preferred video quality**: `best` is the safest default; some sites reject specific ceilings.
- Check the log for a specific engine error message.

## Where to look next

- Adding a new site? → [docs/site-coverage.md](docs/site-coverage.md)
- Changing the UI or wiring? → [docs/architecture.md](docs/architecture.md)
- Adding or moving a file? → [docs/file-map.md](docs/file-map.md) *(update the same commit)*
- Every config.json key? → [docs/config-reference.md](docs/config-reference.md)
- Version history? → [CHANGELOG.md](CHANGELOG.md)

## Why does this exist?

Downloading media from the modern internet has become absurdly hostile. Every site invents new anti-scraping tactics, cookies get locked, formats change weekly. `grab` bundles the best open-source tools (yt-dlp, gallery-dl) with an auto-picking wrapper and a calm UI, so filmmakers can collect references without becoming download engineers.

## License

MIT — see [LICENSE](LICENSE).

## Credits

Built on the shoulders of:

- [yt-dlp](https://github.com/yt-dlp/yt-dlp) — video downloader
- [gallery-dl](https://github.com/mikf/gallery-dl) — image/gallery downloader
- [BurntToast](https://github.com/Windos/BurntToast) — Windows toasts from PowerShell
- [ffmpeg](https://ffmpeg.org/) — media processing
