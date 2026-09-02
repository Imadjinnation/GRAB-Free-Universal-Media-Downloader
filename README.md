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
5. Adds itself to Windows startup (opt-in during first run)
6. Creates desktop shortcuts for quick access

## Use it

**System tray:** left-click the icon → paste popup. Right-click → menu (Show grab, Queue, Recent, Settings, Open downloads, About, Quit).

**Desktop shortcuts** (created by `install.ps1`):
- `grab` — launches the tray (safe to double-click; a singleton lock ensures only one instance ever runs)
- `grab Downloads` — opens the download folder in Explorer

## Uninstall

An automated uninstaller ships in a later checkpoint (see `PROGRESS.md`). To clean up by hand today:

1. Right-click the tray icon → **Quit**
2. Delete `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\grab.lnk` (autostart entry)
3. Delete the desktop shortcuts `grab.lnk` and `grab Downloads.lnk`
4. Delete `%APPDATA%\grab-app\` (all your grab state — configs, queue, logs)

**Your downloads are never touched.**

## What lives where

| Path | Purpose |
|---|---|
| `%APPDATA%\grab-app\config.json` | Your settings |
| `%APPDATA%\grab-app\queue.json` | Active + queued downloads |
| `%APPDATA%\grab-app\recent.json` | Recent history |
| `%APPDATA%\grab-app\logs\` | Per-day activity logs |
| `%APPDATA%\grab-app\done-archive.txt` | Deduplication database |
| `%USERPROFILE%\Downloads\imadjinn-grab\` | Default download folder (change in Settings) |

## Repository structure

```
grab/
├── README.md              you are here
├── PROGRESS.md            version log + design decisions
├── LICENSE                MIT
├── install.ps1            one-command bootstrapper
├── uninstall.ps1          clean removal (leaves downloads)
├── grab-app.ps1           main entry — launches tray
│
├── src/                   PowerShell logic
│   ├── utils.ps1          config, paths, tool discovery, logging, toasts
│   ├── core.ps1           Invoke-Grab (engine wrapper with fallback chain)
│   ├── queue.ps1          background worker + queue state
│   ├── tray.ps1           system tray, right-click menu, clipboard watch
│   ├── popup.ps1          popup window controller
│   ├── settings.ps1       settings window + first-run wizard
│   └── drop.bat           drag-drop launcher wrapper
│
├── ui/                    WPF XAML markup (see ui/README.md)
│   ├── popup.xaml
│   └── settings.xaml
│
├── assets/                icons + images (see assets/README.md)
│   ├── icon.ico           tray icon
│   └── icon-32.png        popup accent
│
└── docs/                  user + contributor docs
    ├── architecture.md    component map + data flow
    ├── site-coverage.md   which engine handles which sites
    ├── file-map.md        canonical index of every file
    └── troubleshooting.md common errors + fixes
```

**Runtime state** lives at `%APPDATA%\grab-app\` (never in the repo) — see [file-map.md](docs/file-map.md) for the full inventory.

## Where to look next

- Adding a new site? → [docs/site-coverage.md](docs/site-coverage.md)
- Changing the UI or wiring? → [docs/architecture.md](docs/architecture.md)
- Adding or moving a file? → [docs/file-map.md](docs/file-map.md) *(update the same commit)*
- Something broke? → [docs/troubleshooting.md](docs/troubleshooting.md)
- Version history? → [PROGRESS.md](PROGRESS.md)

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
