# winget manifest for GRAB

Ship path: microsoft/winget-pkgs -> `manifests/i/Imadjinnation/GRAB/0.3.0/`.

## Files

| File | Purpose |
|---|---|
| `Imadjinnation.GRAB.yaml`               | Version manifest -- winget's entry point. Bump `PackageVersion` per release. |
| `Imadjinnation.GRAB.installer.yaml`     | Installer manifest -- URL + SHA256 of the GRAB-Setup.exe hosted on the GitHub Release. |
| `Imadjinnation.GRAB.locale.en-US.yaml`  | English metadata: publisher, description, tags, moniker. |

## Phase 6 release procedure

After `build-installer.ps1` produces `dist/GRAB-Setup.exe` and `dist/SHA256SUMS.txt`, and the release is tagged `grab-v0.3.0` on GitHub with the .exe attached:

```powershell
# 1. Get the sha256 you'll paste into the installer manifest.
Get-Content dist\SHA256SUMS.txt

# 2. Edit build/winget/Imadjinnation.GRAB.installer.yaml -- replace
#    __SHA256_PLACEHOLDER__ with the sha256 of GRAB-Setup.exe.
#    (Automated via `wingetcreate update` in Phase 6+, but manual is fine.)

# 3. Fork microsoft/winget-pkgs on GitHub (one-time).
gh repo fork microsoft/winget-pkgs --clone --remote

# 4. Clone the fork + create a branch.
cd winget-pkgs
git checkout -b add-imadjinnation-grab-0.3.0

# 5. Copy the three manifests into the correct nested path.
$dest = 'manifests/i/Imadjinnation/GRAB/0.3.0'
New-Item -ItemType Directory -Path $dest -Force | Out-Null
Copy-Item ..\GRAB-Free-Universal-Media-Downloader\build\winget\*.yaml $dest

# 6. Validate locally with winget's own tool (optional; the CI does this too).
#    winget validate --manifest $dest
winget validate --manifest manifests/i/Imadjinnation/GRAB/0.3.0

# 7. Commit + push + open the PR.
git add manifests/i/Imadjinnation/GRAB/0.3.0
git commit -m "New version: Imadjinnation.GRAB version 0.3.0"
git push -u origin add-imadjinnation-grab-0.3.0

gh pr create --repo microsoft/winget-pkgs --title "New version: Imadjinnation.GRAB version 0.3.0" --body @"
### Summary
Adding a new version (0.3.0) of Imadjinnation.GRAB, a free universal media
downloader tray app for Windows.

### Validation
- [x] Local `winget validate` passes
- [x] Installer sha256 matches release asset
- [x] Silent install switches documented (Inno Setup /VERYSILENT /NORESTART)
"@
```

## Future releases

For v0.3.1+, the fastest path is `wingetcreate update`:

```powershell
wingetcreate update Imadjinnation.GRAB `
    --version 0.3.1 `
    --urls https://github.com/imadjinnation/GRAB-Free-Universal-Media-Downloader/releases/download/grab-v0.3.1/GRAB-Setup.exe `
    --submit
```

This auto-forks, updates the sha256, opens the PR. Requires a GitHub token in
`WINGETCREATE_TOKEN` with `public_repo` scope.

## Editing rules

- `PackageIdentifier` is **case-sensitive**. `Imadjinnation.GRAB` (not `imadjinnation.grab`).
- Every YAML file MUST end with a trailing newline (Winget CI rejects otherwise).
- Do NOT include a BOM. Save as UTF-8 no-BOM.
- Do NOT change `ManifestVersion` mid-release without also bumping the schema comment.
