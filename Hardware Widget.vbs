' Launches the always-on-top hardware widget with no visible console window.
Dim sh, fso, here
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
sh.CurrentDirectory = here
' window mode 0 = hidden, wait = False
sh.Run "powershell -NoProfile -ExecutionPolicy Bypass -STA -File """ & here & "\widget.ps1""", 0, False
