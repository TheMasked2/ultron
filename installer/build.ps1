# Builds installer\Output\UltronSetup.exe and ultron-update.zip (what the updater applies).
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

# The update package: the installer's app files (not config.toml or uv.exe), forward-slash names.
if (-not $UiTest) {
    $root = Resolve-Path "$PSScriptRoot\.."
    $files = [ordered]@{}
    Get-ChildItem "$root\ultron\*.py" | ForEach-Object { $files["ultron/$($_.Name)"] = $_.FullName }
    foreach ($f in 'pyproject.toml', 'uv.lock', 'setup.ps1', 'env.ps1', 'run.ps1', 'run.cmd', 'start-hidden.vbs', 'restart.ps1', 'README.md') { $files[$f] = "$root\$f" }
    $files['models/wake/ultron.onnx'] = "$root\models\wake\ultron.onnx"
    $files['obs-setup.ps1'] = "$PSScriptRoot\obs-setup.ps1"
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $zipPath = "$PSScriptRoot\Output\ultron-update.zip"
    Remove-Item $zipPath -ErrorAction SilentlyContinue
    $zip = [IO.Compression.ZipFile]::Open($zipPath, 'Create')
    try {
        foreach ($e in $files.GetEnumerator()) { [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $e.Value, $e.Key) }
        $w = [IO.StreamWriter]::new($zip.CreateEntry('version.txt').Open()); $w.Write("1.0.$count"); $w.Dispose()
    } finally { $zip.Dispose() }
    Get-Item $zipPath | Select-Object Name, @{n = 'MB'; e = { [math]::Round($_.Length / 1MB, 1) } }
}
Get-Item "$PSScriptRoot\Output\$name.exe" | Select-Object Name, @{n = 'MB'; e = { [math]::Round($_.Length / 1MB, 1) } }
