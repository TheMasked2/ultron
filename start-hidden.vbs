' Starts Ultron with no console window. Used by the Windows Startup shortcut.
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
Set shell = CreateObject("WScript.Shell")
shell.CurrentDirectory = dir
' A password saved after logon isn't in this process yet; read it from the user's settings.
Set env = shell.Environment("Process")
If env("OBS_WEBSOCKET_PASSWORD") = "" Then env("OBS_WEBSOCKET_PASSWORD") = shell.Environment("User")("OBS_WEBSOCKET_PASSWORD")
' Console output (crashes Python couldn't log) goes to ultron.out.
shell.Run "cmd /c """"" & dir & "\run.cmd"" >> """ & dir & "\ultron.out"" 2>&1""", 0, False
