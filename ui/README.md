# UI

XAML markup files for every WPF window in the app. Code-behind (event handlers, wiring) lives in `../src/`, keeping layout and logic in separate files so a redesign never risks breaking behavior.

## Files (planned)

| File | Window | Loaded by |
|---|---|---|
| `popup.xaml` | Main popup with Paste / Queue / Recent tabs | `src/popup.ps1` |
| `settings.xaml` | Settings window (default folder, concurrency, toggles) | `src/settings.ps1` |
| `onboarding.xaml` | First-run wizard | `src/settings.ps1` (optional) |

## Loading pattern (used by every WPF window in this app)

```powershell
Add-Type -AssemblyName PresentationFramework
[xml]$xaml = Get-Content "$PSScriptRoot\..\ui\popup.xaml" -Raw
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$btn = $window.FindName('SubmitBtn')
$btn.Add_Click({ ... })

$window.ShowDialog() | Out-Null
```

## Design tokens (kept consistent across all XAML files)

| Token | Value |
|---|---|
| Background | `#111114` |
| Card border | `#26262A` |
| Accent gradient | `#F5A87A -> #E85F62` |
| Text primary | `#F5F5F7` |
| Text muted | `#8E8E93` |
| Text disabled | `#5E5E63` |
| Input background | `#1A1A1D` |
| Corner radius (card) | `16` |
| Corner radius (button) | `9` |
| Base font | Segoe UI Variable Text / Segoe UI fallback |
| Header font | Segoe UI Variable Display / Segoe UI fallback |
