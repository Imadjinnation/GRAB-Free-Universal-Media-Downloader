# Tests

Zero-dependency smoke tests for grab-app. No external framework, no `Install-Module` requirements. Just a single `smoke.ps1` you can run any time to verify the codebase is intact.

## Rule (locked in from 2026-09-02)

**Every checkpoint (CP1..CPn) MUST finish with a green `smoke.ps1` run before it can be considered done.** Any new feature that touches state, engines, or file structure adds a test in `smoke.ps1`. No exceptions.

Rationale: bugs cascade fast in a multi-file PowerShell app. Catching them at the seam where they were introduced is 10x cheaper than debugging them three checkpoints later.

## Run

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\smoke.ps1
```

Exit code `0` = all pass. `1` = at least one failure (details printed).

## What it checks (101 tests, current)

| Section | Coverage |
|---|---|
| Project structure | All 18 committed files exist; file-map indexes every real .ps1; README references every entry-point |
| Script parse | 8 .ps1 files parse cleanly (catches syntax errors before runtime) |
| XAML load | popup.xaml loads via WPF; all 17 named controls resolve |
| Function exports | Every module (utils/core/queue/tray/popup) exports the functions the rest of the app depends on |
| utils.ps1 | Config lifecycle, path helpers, URL parsing, site routing, tool discovery, logging |
| queue.ps1 | Queue CRUD, dedupe (both against existing and within one batch), retry, cancel, clear-done, corrupt-json handling, recent history capping at 100 |
| core.ps1 | Invoke-Grab parameter contract, Get-FileCount correctness |
| install.ps1 | References the right dependencies; no hardcoded user paths |
| Portability | No `.ps1` in the tree hardcodes `C:\Users\Admin`; entry point uses Join-Path |

## Isolation

Tests set `$env:GRAB_APP_DATA_OVERRIDE` to a fresh `%TEMP%\grab-tests-<random>\` folder, so your real `%APPDATA%\grab-app\` state (config, queue, recent, logs) is never touched. Cleanup happens even if a test throws.

## Adding a test

1. Open `smoke.ps1`
2. Pick or create a `Section 'name'` block
3. Add:
   ```powershell
   Test 'short human-readable claim' {
       # ... setup ...
       Assert-Equal <expected> <actual>
       # or Assert-True / Assert-NotNull / Assert-Contains / Assert-Match / Assert-PathExists
   }
   ```
4. Re-run and confirm it passes (and fails when you break the code under it)

## Design notes and PowerShell gotchas learned

Documenting what tests caught so it doesn't happen again:

- **`$var++` leaks** the pre-increment value to the pipeline. Use `$var = $var + 1` inside functions.
- **`return ,$arr` prevents unwrap on assignment but breaks pipeline use.** Where-Object treats the whole array as one input object. Use standard emit (one object at a time) and let callers wrap with `@(...)`.
- **`[System.Collections.ArrayList]@(f)`** where f uses the `,$arr` trick results in an ArrayList containing the whole array as its single element. Not what you want.
- **Empty array from function `return @()`** collapses to `$null` at the caller. Callers must use `@(f)` if they want an empty array back.
- **`.Parameters.Keys`** returns a KeyCollection, not an array. Wrap with `@()` before using `-contains`.
- **PowerShell 5.1 has no `??` operator.** Use a `_fb($a,$b)` helper.
- **PowerShell 5.1 doesn't like unicode chars in string literals** without a UTF-8 BOM. Use ASCII equivalents in `.ps1` files or save with BOM.
