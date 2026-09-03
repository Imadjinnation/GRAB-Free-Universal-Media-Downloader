' grab-app.vbs
' Silent launcher for grab-app.ps1.
'
' Why this exists: `powershell.exe -WindowStyle Hidden` works only under the
' legacy conhost.exe console host. Windows 11 defaults new sessions to Windows
' Terminal (wt.exe) which IGNORES -WindowStyle Hidden, so the tray app briefly
' (or persistently) surfaces a black terminal tab on startup / autostart /
' shortcut launch. VBScript run via wscript.exe has no console at all, and
' WshShell.Run intWindowStyle=0 launches PowerShell truly hidden.
'
' All GRAB shortcuts (Desktop, Start Menu, shell:startup autostart) should
' target this file, NOT powershell.exe directly.

Option Explicit

Dim shell, fso, scriptDir, entry, cmd
Set shell = CreateObject("WScript.Shell")
Set fso   = CreateObject("Scripting.FileSystemObject")

' Resolve grab-app.ps1 sitting next to this .vbs, regardless of where the
' shortcut was invoked from.
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
entry     = fso.BuildPath(scriptDir, "grab-app.ps1")

If Not fso.FileExists(entry) Then
    ' Loud failure -- if the .ps1 is missing something is very wrong, tell the
    ' user with a message box rather than dying silently.
    MsgBox "grab-app.ps1 not found next to grab-app.vbs." & vbCrLf & _
           "Expected: " & entry, vbCritical, "grab -- launcher error"
    WScript.Quit 1
End If

' -STA is REQUIRED for WPF windows on the same thread.
' -NoProfile skips any user PowerShell profile that could slow startup or
' inject noise.
' -ExecutionPolicy Bypass so unsigned .ps1 files run without prompting.
cmd = "powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File """ & _
      entry & """"

' intWindowStyle=0 (SW_HIDE) => no window ever renders.
' bWaitOnReturn=False so this .vbs exits immediately -- grab-app.ps1 keeps
' running in the background as the tray process.
shell.Run cmd, 0, False

Set shell = Nothing
Set fso   = Nothing
