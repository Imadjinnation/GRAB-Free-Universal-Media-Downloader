@echo off
REM ============================================================================
REM  LAUNCH-GRAB.bat -- Bulletproof GRAB launcher
REM ============================================================================
REM  Purpose: single-file, dependency-free way to start GRAB regardless of
REM  broken shortcuts, missing registry entries, or Windows tray shenanigans.
REM
REM  How it works:
REM   1. Calls wscript.exe with the VBS launcher directly (no console window)
REM   2. VBS spawns powershell -STA -File grab-app.ps1
REM   3. GRAB's built-in singleton mutex ensures only one tray runs
REM   4. If GRAB is already alive, this launch silently no-ops
REM
REM  Works even if: shortcuts deleted, HKCU\Run wiped, NotifyIcon promotion
REM  reset, Windows Search doesn't index it. All you need is this file + the
REM  grab folder in the same location.
REM
REM  Location: keep this file at D:\IMADJINnation\grab\LAUNCH-GRAB.bat.
REM  Feel free to right-click -> Send to -> Desktop (create shortcut) for
REM  a Desktop icon that also works.
REM ============================================================================

REM Change to script directory (makes paths robust)
cd /d "%~dp0"

REM Verify grab-app.vbs is present (belt + braces sanity check)
if not exist "%~dp0grab-app.vbs" (
    echo GRAB launcher error: grab-app.vbs not found next to this file.
    echo Expected at: %~dp0grab-app.vbs
    echo.
    echo Something moved/deleted the file. Reinstall GRAB or restore from git.
    pause
    exit /b 1
)

REM Launch via wscript.exe (detached — /B would tie wscript to this cmd's
REM console; when cmd exits after this .bat, wscript dies with it. Without
REM /B, wscript spawns as its own top-level process. wscript.exe itself
REM has no window either way, so the user sees nothing regardless.)
start "" wscript.exe "%~dp0grab-app.vbs"

REM Exit silently
exit /b 0
