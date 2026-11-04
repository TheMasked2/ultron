# Builds the installer and publishes it as a GitHub release, so the README's
# download link points at it. Needs gh (signed in) and a clean, committed tree.
#   .\installer\release.ps1
$ErrorActionPreference = "Stop"
$repo = Resolve-Path "$PSScriptRoot\.."
if (git -C $repo status --porcelain) { throw "Commit your changes first." }
& "$PSScriptRoot\build.ps1"
$v = "1.0.$(git -C $repo rev-list --count HEAD)"
git -C $repo push
Push-Location $repo
try {
    gh release create "v$v" "$PSScriptRoot\Output\UltronSetup.exe" --title "Ultron $v" --notes-file "$PSScriptRoot\release-notes.md"
    if ($LASTEXITCODE) { throw "gh release failed ($LASTEXITCODE)" }
} finally { Pop-Location }
