# Restarts Ultron: ends the running one and starts it hidden again (after editing config.toml).
Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -like "$PSScriptRoot\*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Start-Process wscript.exe "`"$PSScriptRoot\start-hidden.vbs`""
