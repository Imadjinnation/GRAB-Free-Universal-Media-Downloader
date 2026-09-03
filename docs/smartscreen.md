# SmartScreen: why GRAB isn't signed (and how to safely run it)

## TL;DR

If you install GRAB via **winget** or **scoop**, you'll see no warning. If you download `GRAB-Setup.exe` or `GRAB-Portable-v0.3.0.zip` directly from the GitHub Release, Windows will show a one-time "Windows protected your PC" dialog. Click **More info** -> **Run anyway**. GRAB installs normally after that.

## Why the warning appears

Windows SmartScreen flags any executable that:

1. Isn't signed by a Microsoft-approved Extended Validation (EV) code signing certificate, **and**
2. Hasn't built up "reputation" through wide download activity yet.

GRAB is a **free, open-source, indie tool**. Signing a Windows binary requires a $200-$400/year EV certificate from an approved CA (DigiCert, Sectigo, etc.), with hardware token delivery, business verification, and yearly renewal. For a hobby project without revenue, that isn't a sensible expense to pass on to users.

**We deliberately choose not to sign.** The tradeoff is that first-run users see one dialog once per machine.

## How to safely proceed

### Direct download (`.exe` or `.zip`)

1. Right-click the downloaded file -> **Properties** -> check the **Unblock** box at the bottom if present -> **OK**. (Windows sometimes marks web downloads as "from another computer.")
2. Double-click the file.
3. When SmartScreen shows "Windows protected your PC":
   - Click the small **More info** link (easy to miss -- it's under the app name).
   - The dialog expands to show "Publisher: Unknown publisher" and a **Run anyway** button.
   - Click **Run anyway**.
4. The wizard proceeds normally. Windows remembers your decision; the dialog won't appear again for this binary.

### winget install (no dialog)

```powershell
winget install imadjinnation.grab
```

Winget's own trust chain vouches for the download, so SmartScreen doesn't fire on the install itself. (The bundled `GRAB-Setup.exe` may still show reputation warnings on very fresh releases; winget handles it silently.)

### scoop install (no dialog)

```powershell
scoop bucket add imadjinnation https://github.com/imadjinnation/scoop-bucket
scoop install grab
```

Scoop unpacks the portable zip into `~\scoop\apps\grab\current\` without running an installer, so SmartScreen isn't in the loop.

## How to verify what you downloaded

Every GitHub Release ships a `SHA256SUMS.txt` next to the binaries. Verify locally:

```powershell
# Compare the sha256 of your download against the release's SHA256SUMS.txt.
Get-FileHash .\GRAB-Setup.exe -Algorithm SHA256 | Format-List

# Then open SHA256SUMS.txt from the release and diff.
```

The sha256s in `SHA256SUMS.txt` are also linked from the release notes so you can cross-check from a different network / machine.

## Third-party scan (Phase 6+)

Every release will also carry a VirusTotal badge in the release notes. Phase 5.5 lays the plumbing; Phase 6 wires it up. Until then, you can paste the download URL into <https://www.virustotal.com/gui/home/upload> and see a live scan.

## Source is public

Everything GRAB does is in this repository. If you're security-cautious, the highest-trust path is:

```powershell
git clone https://github.com/imadjinnation/GRAB-Free-Universal-Media-Downloader.git grab
cd grab
# Read the code first, then:
.\install.ps1
```

`install.ps1` writes only to `%APPDATA%\grab-app\`, `%USERPROFILE%\Desktop\`, and `HKCU\Software\Microsoft\Windows\CurrentVersion\Run\GRAB`. No `HKLM`, no `Program Files`, no admin. See [README.md](../README.md#network-surface) for the full network / filesystem / registry footprint.

## Reporting a false positive

If a specific antivirus product flags GRAB (rare but happens to unsigned tools that shell out to Python-packaged binaries), please open a GitHub issue with:

- AV product + version
- The exact detection name (e.g. `Trojan:Win32/Wacatac.B!ml`)
- The file that was flagged (`GRAB-Setup.exe`, `yt-dlp.exe`, `gallery-dl.exe`, etc.)

Then submit the file to the AV vendor's false-positive form. Once cleared upstream, the warning drops for every user on that AV in the next signature update.
