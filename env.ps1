# Keeps Python, packages and models inside this folder.
$env:UV_PYTHON_INSTALL_DIR = "$PSScriptRoot\.cache\python"
$env:UV_CACHE_DIR = "$PSScriptRoot\.cache\uv"
$env:UV_LINK_MODE = "copy"   # exFAT has no hardlinks
$env:HF_HOME = "$PSScriptRoot\models"

# uv: the copy in .\tools (the installer puts one there), else one on PATH.
$uv = "$PSScriptRoot\tools\uv.exe"
if (-not (Test-Path $uv)) { $uv = (Get-Command uv -ErrorAction SilentlyContinue).Source }
if (-not $uv) { throw "uv not found. Run setup.ps1 first." }
