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

"Installing packages (this takes a few minutes)..."
& $uv sync --project $PSScriptRoot --python 3.12 2>&1 | ForEach-Object { "$_" }
if ($LASTEXITCODE -ne 0) { throw "Installing packages failed." }

"Downloading the wake word and speech models..."
& $uv run --project $PSScriptRoot python -c @"
import openwakeword.utils, tomllib
cfg = tomllib.load(open(r'$PSScriptRoot\config.toml', 'rb'))
openwakeword.utils.download_models([cfg['wake']['fallback']])
from faster_whisper import WhisperModel
WhisperModel(cfg['stt']['model'], device='cpu', compute_type='int8')
print('Models ready.')
"@ 2>&1 | ForEach-Object { "$_" }
if ($LASTEXITCODE -ne 0) { throw "Downloading the models failed." }
