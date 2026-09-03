# Scoop bucket for GRAB

Ship path: a companion repo at `github.com/imadjinnation/scoop-bucket` (create in Phase 6). Users then run:

```powershell
scoop bucket add imadjinnation https://github.com/imadjinnation/scoop-bucket
scoop install grab
```

## Files

| File | Purpose |
|---|---|
| `grab.json` | Scoop package manifest -- URL, hash, `bin` mapping, checkver / autoupdate blocks for future releases. |

## Phase 6 release procedure

1. Create the bucket repo (one-time):

    ```powershell
    gh repo create imadjinnation/scoop-bucket --public `
        --description "Scoop bucket for GRAB and future Imadjinn tools." `
        --add-readme
    ```

2. After `build-installer.ps1` produces the portable zip and `dist/SHA256SUMS.txt`:

    ```powershell
    # Extract the sha256 line for the zip:
    $line = Get-Content dist\SHA256SUMS.txt | Where-Object { $_ -match 'GRAB-Portable-v.*\.zip$' }
    $sha  = ($line -split '\s+')[0]

    # Update grab.json's 64bit.hash to sha256:$sha (or use `scoop checkhash`
    # from the bucket after the release is public).
    ```

3. Copy the manifest into the bucket:

    ```powershell
    Copy-Item build\scoop\grab.json ..\scoop-bucket\bucket\grab.json
    cd ..\scoop-bucket
    git add bucket/grab.json
    git commit -m "grab: v0.3.0"
    git push
    ```

4. Verify end-to-end on a clean machine:

    ```powershell
    scoop bucket add imadjinnation https://github.com/imadjinnation/scoop-bucket
    scoop install grab
    grab           # should launch the tray
    scoop uninstall grab
    ```

## Auto-update

`grab.json`'s `checkver` + `autoupdate` blocks let a Scoop bucket owner run:

```powershell
cd ..\scoop-bucket
scoop bucket known                 # sanity check
.\bin\checkver.ps1 -u grab         # bumps version + rewrites URL/hash
git commit -am "grab: auto-update to $(scoop info grab | Select-String Version)"
git push
```

so every future GRAB release is picked up without a hand-edit. Requires the release tag convention `grab-v<semver>` and `SHA256SUMS.txt` present on the release, both of which `build-installer.ps1` produces.

## Editing rules

- `hash` MUST be prefixed with `sha256:` or Scoop rejects the manifest.
- `bin`'s two-element inner array is `["file", "alias"]` so `grab` becomes a shim on user's PATH.
- `pre_uninstall` runs GRAB's own `uninstall.ps1 -Yes -NoPackages` so autostart / tray-promotion registry entries are cleared cleanly. `-NoPackages` keeps shared pip / PS modules alone.
