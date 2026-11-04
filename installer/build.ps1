# Builds installer\Output\UltronSetup.exe.
#   .\installer\build.ps1 [-UvExe <path>] [-UiTest]
# -UiTest builds an installer that shows every page but never installs anything.
param([string]$UvExe, [switch]$UiTest)
$ErrorActionPreference = "Stop"

$iscc = (Get-Command iscc -ErrorAction SilentlyContinue).Source
foreach ($p in "R:\tools\InnoSetup\ISCC.exe", "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe") {
    if (-not $iscc -and (Test-Path $p)) { $iscc = $p }
}
if (-not $iscc) { throw "Inno Setup 6 not found (jrsoftware.org)." }

if (-not $UvExe) {
    $UvExe = if (Test-Path "$PSScriptRoot\..\tools\uv.exe") { "$PSScriptRoot\..\tools\uv.exe" } else { (Get-Command uv).Source }
}

$count = git -C "$PSScriptRoot\.." rev-list --count HEAD 2>$null
if (-not $count) { $count = 0 }
$defs = @("/DAppVersion=1.0.$count", "/DUvExe=$((Resolve-Path $UvExe).Path)")
$name = "UltronSetup"
if ($UiTest) { $defs += "/DUiTest"; $name = "UltronSetup-UiTest"; $defs += "/F$name" }
& $iscc /Q @defs "$PSScriptRoot\setup.iss"
if ($LASTEXITCODE) { throw "Inno Setup failed ($LASTEXITCODE)" }
Get-Item "$PSScriptRoot\Output\$name.exe" | Select-Object Name, @{n = 'MB'; e = { [math]::Round($_.Length / 1MB, 1) } }
