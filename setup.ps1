# One-time setup: uv (into .\tools if missing), Python 3.12, packages and models,
# all kept in this folder. The installer runs this too.
# Not "Stop": uv prints progress to stderr, which PowerShell would treat as a failure.
$ErrorActionPreference = "Continue"
$env:UV_NO_PROGRESS = "1"   # plain lines, no spinners (the installer shows them)

if (-not (Test-Path "$PSScriptRoot\tools\uv.exe") -and -not (Get-Command uv -ErrorAction SilentlyContinue)) {
    "Downloading uv..."
    $env:UV_INSTALL_DIR = "$PSScriptRoot\tools"
    $env:UV_NO_MODIFY_PATH = "1"
    Invoke-RestMethod https://astral.sh/uv/install.ps1 | Invoke-Expression
}

. "$PSScriptRoot\env.ps1"

# --no-registry/--no-bin keep Python out of the registry and off PATH. On exFAT uv
# also prints "Failed to create Python minor version link directory": exFAT has
# no junctions, Python itself is installed fine, so that error is ignored.
& $uv python find 3.12 *> $null
if ($LASTEXITCODE -ne 0) {
    "Downloading Python 3.12..."
    & $uv python install 3.12 --no-registry --no-bin 2>&1 |
        Where-Object { "$_" -notmatch 'minor version link|Incorrect function' } | ForEach-Object { "$_" }
    & $uv python find 3.12 *> $null
    if ($LASTEXITCODE -ne 0) { throw "Python 3.12 could not be installed." }
}
# Windows' Smart App Control can refuse a Python it doesn't know; find out before relying on it.
$python = (& $uv python find 3.12 2>$null | Select-Object -Last 1)
& $python -c "pass" 2>$null
if ($LASTEXITCODE -ne 0) { throw "Windows won't run the downloaded Python ($python)." }

# Older installs could end up on another program's Python; rebuild those on Ultron's own.
$venvCfg = "$PSScriptRoot\.venv\pyvenv.cfg"
if (Test-Path $venvCfg) {
    $venvHome = ((Get-Content $venvCfg) -match '^home\s*=' -replace '^home\s*=\s*', '') | Select-Object -First 1
    if ($venvHome -and -not $venvHome.StartsWith("$PSScriptRoot\.cache\python", [StringComparison]::OrdinalIgnoreCase)) {
        "Moving Ultron to its own Python (was $venvHome)..."
        Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -like "$PSScriptRoot\.venv\*" } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
        Start-Sleep 1
        # Set aside, not deleted: if installing the packages fails, the old one comes back.
        Remove-Item -Recurse -Force "$PSScriptRoot\.venv-old" -ErrorAction SilentlyContinue
        Rename-Item "$PSScriptRoot\.venv" ".venv-old"
    }
}

"Installing packages (this takes a few minutes)..."
& $uv sync --project $PSScriptRoot --python 3.12 2>&1 | ForEach-Object { "$_" }
if ($LASTEXITCODE -ne 0) {
    if (Test-Path "$PSScriptRoot\.venv-old") {
        Remove-Item -Recurse -Force "$PSScriptRoot\.venv" -ErrorAction SilentlyContinue
        Rename-Item "$PSScriptRoot\.venv-old" ".venv"
        "Kept the previous Python setup."
    }
    throw "Installing packages failed."
}
Remove-Item -Recurse -Force "$PSScriptRoot\.venv-old" -ErrorAction SilentlyContinue

"Downloading the wake word and speech models..."
& $uv run --project $PSScriptRoot python -c @"
import openwakeword.utils, tomllib
cfg = tomllib.loads(open(r'$PSScriptRoot\config.toml', encoding='utf-8-sig').read())
# Ultron's own wake word ships with it. No built-in model has this name, so this only
# fetches the helper models every wake word needs (an empty list would fetch them all).
openwakeword.utils.download_models([cfg['wake']['model']])
from faster_whisper import WhisperModel
WhisperModel(cfg['stt']['model'], device='cpu', compute_type='int8')
print('Models ready.')
"@ 2>&1 | ForEach-Object { "$_" }
if ($LASTEXITCODE -ne 0) { throw "Downloading the models failed." }
