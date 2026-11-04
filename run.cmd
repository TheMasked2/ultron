@echo off
rem Start Ultron without PowerShell. --text: type commands; --dry-run: show detected games.
set "HF_HOME=%~dp0models"
pushd "%~dp0"
".venv\Scripts\python.exe" -m ultron %*
popd
