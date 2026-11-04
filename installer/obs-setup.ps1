# Sets OBS up for game clipping: WebSocket server with a password, the replay
# buffer, and the "Game Capture" / "Game Window" / "Game Audio" sources. Anything already set up
# is kept (an existing WebSocket password stays, so other tools keep working).
#
#   .\obs-setup.ps1 -Check            report what would change, change nothing
#   .\obs-setup.ps1 -CloseObs         set everything up, closing OBS if a file must change
#   -Scene Game                       put the sources in this scene (created if missing) and switch to it;
#                                     without it they go in the current scene
#   -Tracks Simple|Editing|Full|Custom   audio tracks to record (default Keep: don't touch them).
#                                     Fixed slots: 1 everything mixed, 2 mic, 3 game, 4 Discord,
#                                     5 music, 6 browser. Simple: 1 only. Editing: 1-3, plus 4 with
#                                     -DiscordTrack and 5 with -MusicTrack; Desktop Audio stays in
#                                     the mix. Full: all six, Desktop Audio muted (only those apps
#                                     are recorded). Custom: -TrackCount 1-6, sources left as they are.
#   -ListScenes                       print the scenes of the current scene collection ("scene:<name>")
#
# Exit codes (the installers use them): 0 done, 2 OBS not installed,
# 3 OBS never opened yet, 4 OBS must be closed first, 5 couldn't talk to OBS.
# The same script ships with Jarvis and OBS Game Watcher; keep the copies identical.
param(
    [int]$ReplaySeconds = 120,
    [switch]$ForceLength,           # also change the length if the replay buffer is already on
    [string]$CaptureSource = "Game Capture",
    [string]$WindowSource = "Game Window", # Window Capture fallback for games Game Capture can't hook
    [string]$AudioSource = "Game Audio",
    [string]$VoiceSource = "Discord Audio",   # Discord only, for the Discord track
    [string]$MusicSource = "Music Audio",     # music player, for the music track
    [string]$BrowserSource = "Browser Audio", # default browser (Full only)
    [string]$Scene = "",
    [ValidateSet('Keep', 'Simple', 'Editing', 'Full', 'Custom')][string]$Tracks = 'Keep',
    [switch]$DiscordTrack,
    [switch]$MusicTrack,
    [int]$TrackCount = 1,
    [switch]$CloseObs,              # allowed to close a running OBS
    [switch]$ListScenes,
    [switch]$Check
)
$ErrorActionPreference = "Stop"

# Straight to stdout, so functions can print without it ending up in their return value.
function Say($msg) { [Console]::Out.WriteLine($msg) }

# ---------- Find OBS and its settings ----------

$obsDir = $null
foreach ($key in 'HKLM:\SOFTWARE\OBS Studio', 'HKLM:\SOFTWARE\WOW6432Node\OBS Studio') {
    $v = (Get-ItemProperty $key -ErrorAction SilentlyContinue).'(default)'
    if ($v -and (Test-Path "$v\bin\64bit\obs64.exe")) { $obsDir = $v; break }
}
if (-not $obsDir -and (Test-Path "$env:ProgramFiles\obs-studio\bin\64bit\obs64.exe")) { $obsDir = "$env:ProgramFiles\obs-studio" }
if (-not $obsDir) { Say "OBS Studio is not installed. Get it from https://obsproject.com and run this again."; exit 2 }
$obsExe = "$obsDir\bin\64bit\obs64.exe"

$cfgRoot = "$env:APPDATA\obs-studio"

function Read-Ini($path) {
    $bytes = [IO.File]::ReadAllBytes($path)
    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $text = [Text.UTF8Encoding]::new($false).GetString($bytes, $(if ($bom) { 3 } else { 0 }), $bytes.Length - $(if ($bom) { 3 } else { 0 }))
    @{ Path = $path; Bom = $bom; Nl = $(if ($text -match "`r`n") { "`r`n" } else { "`n" }); Lines = [Collections.Generic.List[string]]($text -split "`r?`n") }
}

function Get-IniValue($ini, $section, $key) {
    $in = $false
    foreach ($line in $ini.Lines) {
        if ($line -match '^\[(.+)\]$') { $in = $Matches[1] -eq $section; continue }
        if ($in -and $line -match "^$([regex]::Escape($key))=(.*)$") { return $Matches[1] }
    }
    return $null
}

function Set-IniValue($ini, $section, $key, $value) {
    $lines = $ini.Lines; $start = -1; $end = $lines.Count
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\[(.+)\]$') {
            if ($start -ge 0) { $end = $i; break }
            if ($Matches[1] -eq $section) { $start = $i }
        }
    }
    if ($start -lt 0) {
        if ($lines.Count -and $lines[$lines.Count - 1] -eq '') { $lines.RemoveAt($lines.Count - 1) }
        $lines.Add("[$section]"); $lines.Add("$key=$value"); $lines.Add(''); return
    }
    for ($i = $start + 1; $i -lt $end; $i++) {
        if ($lines[$i] -match "^$([regex]::Escape($key))=") { $lines[$i] = "$key=$value"; return }
    }
    $at = $end; while ($at -gt $start + 1 -and $lines[$at - 1] -eq '') { $at-- }
    $lines.Insert($at, "$key=$value")
}

function Save-Ini($ini) {
    $body = [Text.UTF8Encoding]::new($false).GetBytes(($ini.Lines -join $ini.Nl))
    $out = if ($ini.Bom) { [byte[]]([byte[]](0xEF, 0xBB, 0xBF) + $body) } else { $body }
    [IO.File]::WriteAllBytes($ini.Path, $out)
}

# Profiles can live elsewhere (OBS 31+: Settings > General > locations).
$profilesRoot = $cfgRoot
if (Test-Path "$cfgRoot\global.ini") {
    $loc = Get-IniValue (Read-Ini "$cfgRoot\global.ini") 'Locations' 'Profiles'
    if ($loc) { $profilesRoot = Join-Path ($loc -replace '\\\\', '\') 'obs-studio' }
}
if ($ListScenes) {
    $scenesRoot = "$cfgRoot\basic\scenes"
    if (Test-Path "$cfgRoot\global.ini") {
        $loc = Get-IniValue (Read-Ini "$cfgRoot\global.ini") 'Locations' 'SceneCollections'
        if ($loc) { $scenesRoot = Join-Path ($loc -replace '\\\\', '\') 'obs-studio\basic\scenes' }
    }
    $file = $null
    foreach ($f in "$cfgRoot\user.ini", "$cfgRoot\global.ini") {
        if (Test-Path $f) { $file = Get-IniValue (Read-Ini $f) 'Basic' 'SceneCollectionFile'; if ($file) { break } }
    }
    if ($file -and $file -notlike '*.json') { $file += '.json' }   # older OBS leaves the extension off
    if ($file -and (Test-Path "$scenesRoot\$file")) {
        $data = [IO.File]::ReadAllText("$scenesRoot\$file") | ConvertFrom-Json
        foreach ($s in $data.scene_order) { Say "scene:$($s.name)" }
    }
    exit 0
}

$profileDir = $null
foreach ($f in "$cfgRoot\user.ini", "$cfgRoot\global.ini") {
    if (Test-Path $f) { $profileDir = Get-IniValue (Read-Ini $f) 'Basic' 'ProfileDir'; if ($profileDir) { break } }
}
$basicIni = if ($profileDir) { "$profilesRoot\basic\profiles\$profileDir\basic.ini" }
if (-not $basicIni -or -not (Test-Path $basicIni)) {
    Say "OBS hasn't been opened yet. Open OBS once (you can skip its setup wizard), close it, then try again."
    exit 3
}

# ---------- Work out what has to change ----------

$wsFile = "$cfgRoot\plugin_config\obs-websocket\config.json"
$ws = if (Test-Path $wsFile) { Get-Content $wsFile -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
$wsChange = -not ($ws.server_enabled -and $ws.auth_required -and $ws.server_password)
$password = $ws.server_password
if (-not $password) {
    $chars = [char[]]'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create(); $b = [byte[]]::new(20); $rng.GetBytes($b)
    $password = -join ($b | ForEach-Object { $chars[$_ % $chars.Length] })
}
$port = if ($ws.server_port) { [int]$ws.server_port } else { 4455 }

$ini = Read-Ini $basicIni
$mode = Get-IniValue $ini 'Output' 'Mode'
$section = if ($mode -eq 'Advanced') { 'AdvOut' } else { 'SimpleOutput' }
$rbOn = (Get-IniValue $ini $section 'RecRB') -eq 'true'
$rbTime = Get-IniValue $ini $section 'RecRBTime'
$rbChange = -not $rbOn -or ($ForceLength -and $rbTime -ne "$ReplaySeconds")

Say "OBS $((Get-Item $obsExe).VersionInfo.ProductVersion), profile '$profileDir' ($(if ($mode) { $mode } else { 'Simple' }) output)"
Say $(if ($wsChange) { "WebSocket server: will turn on (port $port, with a password)" } else { "WebSocket server: already on (keeping its password)" })
Say $(if ($rbChange) { "Replay buffer: will turn on, $ReplaySeconds seconds" } else { "Replay buffer: already on ($rbTime seconds)" })

# Audio tracks: which tracks recordings and replays get, and their names.
$slotNames = @{ 1 = 'Mix'; 2 = 'Mic'; 3 = 'Game'; 4 = 'Discord'; 5 = 'Music'; 6 = 'Browser' }
$discord = $Tracks -eq 'Full' -or ($Tracks -eq 'Editing' -and $DiscordTrack)
$music = $Tracks -eq 'Full' -or ($Tracks -eq 'Editing' -and $MusicTrack)
$slots = @(switch ($Tracks) {
    'Simple'  { @(1) }
    'Editing' { @(1, 2, 3) + @(if ($discord) { 4 }) + @(if ($music) { 5 }) }
    'Full'    { @(1, 2, 3, 4, 5, 6) }
    'Custom'  { @(1..([Math]::Max(1, [Math]::Min(6, $TrackCount)))) }
    default   { @() }
})
$iniSets = @()
function Want($sec, $key, $val) { if ((Get-IniValue $ini $sec $key) -ne $val) { $script:iniSets += , @($sec, $key, $val) } }
if ($Tracks -ne 'Keep') {
    $mask = 0; foreach ($s in $slots) { $mask = $mask -bor (1 -shl ($s - 1)) }
    Want $section 'RecTracks' "$mask"
    # Simple output's "Same as stream" quality records track 1 only.
    $q = Get-IniValue $ini 'SimpleOutput' 'RecQuality'
    if ($section -eq 'SimpleOutput' -and $slots.Count -gt 1 -and (-not $q -or $q -eq 'Stream')) {
        Want 'SimpleOutput' 'RecQuality' 'Small'
        $enc = Get-IniValue $ini 'SimpleOutput' 'StreamEncoder'
        if ($enc -and -not (Get-IniValue $ini 'SimpleOutput' 'RecEncoder')) { Want 'SimpleOutput' 'RecEncoder' $enc }
    }
    if ($Tracks -ne 'Custom') { foreach ($s in $slots) { Want 'AdvOut' "Track${s}Name" $slotNames[$s] } }
}
$tracksChange = $iniSets.Count -gt 0
if ($Tracks -ne 'Keep') {
    $desc = if ($Tracks -eq 'Custom') { "$($slots.Count) tracks" } else { ($slots | ForEach-Object { "$_ $($slotNames[$_])" }) -join ', ' }
    Say $(if ($tracksChange) { "Audio tracks: will record $desc" } else { "Audio tracks: already $desc" })
}

$envNow = [Environment]::GetEnvironmentVariable('OBS_WEBSOCKET_PASSWORD', 'User')
$envChange = $envNow -ne $password
Say $(if ($envChange) { "OBS_WEBSOCKET_PASSWORD: will be saved for your Windows user" } else { "OBS_WEBSOCKET_PASSWORD: already set" })

if ($Check) { Say "Check only: nothing changed."; exit 0 }

# ---------- Change the files (OBS must be closed: it rewrites them on exit) ----------

$running = Get-Process obs64 -ErrorAction SilentlyContinue
if (($wsChange -or $rbChange -or $tracksChange) -and $running) {
    if (-not $CloseObs) { Say "OBS has to close for a moment to change its settings."; exit 4 }
    Say "Closing OBS..."
    $running | ForEach-Object { [void]$_.CloseMainWindow() }
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Process obs64 -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
    if (Get-Process obs64 -ErrorAction SilentlyContinue) {
        Say "OBS didn't close. Stop any recording, close OBS yourself (also from the tray), then try again."
        exit 4
    }
    $running = $null
}

if ($wsChange) {
    New-Item -ItemType Directory -Force (Split-Path $wsFile) | Out-Null
    foreach ($p in @{ server_enabled = $true; auth_required = $true; server_password = $password; server_port = $port; first_load = $false }.GetEnumerator()) {
        $ws | Add-Member -NotePropertyName $p.Key -NotePropertyValue $p.Value -Force
    }
    [IO.File]::WriteAllText($wsFile, ($ws | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    Say "Turned on the WebSocket server."
}
if ($rbChange -or $tracksChange) {
    if ($rbChange) {
        Set-IniValue $ini $section 'RecRB' 'true'
        if (-not $rbOn -or $ForceLength) { Set-IniValue $ini $section 'RecRBTime' "$ReplaySeconds" }
    }
    foreach ($s in $iniSets) { Set-IniValue $ini $s[0] $s[1] $s[2] }
    Save-Ini $ini
    if ($rbChange) { Say "Turned on the replay buffer." }
    if ($tracksChange) { Say "Set the recording audio tracks." }
}
if ($envChange) {
    [Environment]::SetEnvironmentVariable('OBS_WEBSOCKET_PASSWORD', $password, 'User')
    Say "Saved OBS_WEBSOCKET_PASSWORD."
}
$env:OBS_WEBSOCKET_PASSWORD = $password

# ---------- Sources, over the WebSocket ----------

if (-not $running) {
    Say "Starting OBS..."
    Start-Process $obsExe -WorkingDirectory (Split-Path $obsExe)
}

$none = [Threading.CancellationToken]::None
function Receive($sock) {
    $buf = [byte[]]::new(65536); $ms = [IO.MemoryStream]::new()
    do {
        $t = $sock.ReceiveAsync([ArraySegment[byte]]::new($buf), $none)
        if (-not $t.Wait(10000)) { throw "OBS stopped answering." }
        $ms.Write($buf, 0, $t.Result.Count)
    } until ($t.Result.EndOfMessage)
    [Text.Encoding]::UTF8.GetString($ms.ToArray()) | ConvertFrom-Json
}
function Send($sock, $obj) {
    $bytes = [Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Depth 10 -Compress))
    [void]$sock.SendAsync([ArraySegment[byte]]::new($bytes), 'Text', $true, $none).Wait(10000)
}
$script:reqId = 0
function Request($sock, $type, $data = @{}) {
    $id = "$(++$script:reqId)"
    Send $sock @{ op = 6; d = @{ requestType = $type; requestId = $id; requestData = $data } }
    do { $m = Receive $sock } until ($m.op -eq 7 -and $m.d.requestId -eq $id)
    if (-not $m.d.requestStatus.result) { throw "$type failed: $($m.d.requestStatus.comment)" }
    $m.d.responseData
}
function B64Sha($s) { [Convert]::ToBase64String([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($s))) }

$sock = $null
$deadline = (Get-Date).AddSeconds(60)
while (-not $sock -and (Get-Date) -lt $deadline) {
    try {
        $c = [Net.WebSockets.ClientWebSocket]::new()
        $c.Options.AddSubProtocol('obswebsocket.json')
        if ($c.ConnectAsync([Uri]"ws://localhost:$port", $none).Wait(5000) -and $c.State -eq 'Open') {
            $hello = Receive $c
            $identify = @{ rpcVersion = 1; eventSubscriptions = 0 }
            $a = $hello.d.authentication
            if ($a) { $identify.authentication = B64Sha ((B64Sha ($password + $a.salt)) + $a.challenge) }
            Send $c @{ op = 1; d = $identify }
            $m = Receive $c
            if ($m.op -eq 2) { $sock = $c } else { throw "OBS refused the WebSocket password." }
        }
    } catch {
        if ("$_" -match 'refused the WebSocket password') { Say "$_"; exit 5 }
    }
    if (-not $sock) { Start-Sleep 2 }
}
if (-not $sock) { Say "Couldn't connect to OBS on port $port. Is OBS open?"; exit 5 }

try {
    # A freshly started OBS answers "not ready" until its scenes are loaded.
    $readyBy = (Get-Date).AddSeconds(60)
    while ($true) {
        try { $inputList = @((Request $sock 'GetInputList').inputs); break }
        catch { if ("$_" -notmatch 'not ready' -or (Get-Date) -gt $readyBy) { throw }; Start-Sleep 1 }
    }
    $inputs = @($inputList | ForEach-Object { $_.inputName })
    $kinds = @((Request $sock 'GetInputKindList').inputKinds)
    $current = (Request $sock 'GetCurrentProgramScene').currentProgramSceneName
    $target = $current
    if ($Scene) {
        $target = $Scene
        if (@((Request $sock 'GetSceneList').scenes | ForEach-Object { $_.sceneName }) -notcontains $Scene) {
            [void](Request $sock 'CreateScene' @{ sceneName = $Scene })
            Say "Created the scene '$Scene'."
        }
        if ($current -ne $Scene) {
            [void](Request $sock 'SetCurrentProgramScene' @{ sceneName = $Scene })
            Say "Switched OBS to the scene '$Scene'."
        }
    }

    # Puts a source in the target scene (creating it if it doesn't exist anywhere yet).
    # Returns the new scene item's id, or nothing if it was already in the scene.
    function Add-ToScene($name, $kind, $settings) {
        $have = (Request $sock 'GetSceneItemList' @{ sceneName = $target }).sceneItems | Where-Object { $_.sourceName -eq $name }
        if ($have) { Say "Source '$name': already in '$target'."; return }
        if ($inputs -contains $name) {
            $id = (Request $sock 'CreateSceneItem' @{ sceneName = $target; sourceName = $name }).sceneItemId
        } else {
            $id = (Request $sock 'CreateInput' @{ sceneName = $target; inputName = $name; inputKind = $kind
                inputSettings = $settings; sceneItemEnabled = $true }).sceneItemId
            $script:inputs += $name
        }
        Say "Added '$name' to the scene '$target'."
        $id
    }

    # Game Capture, with the Window Capture fallback (for games Game Capture can't hook)
    # underneath it; both scaled to fit the canvas so they line up.
    $new = @()
    if ($CaptureSource) { $cap = Add-ToScene $CaptureSource 'game_capture' @{ capture_mode = 'window'; priority = 2 }; if ($cap) { $new += $cap } }
    if ($CaptureSource -and $WindowSource) {
        $win = Add-ToScene $WindowSource 'window_capture' @{ priority = 2; method = 2 }
        if ($win) {
            $cap = (Request $sock 'GetSceneItemList' @{ sceneName = $target }).sceneItems |
                Where-Object { $_.sourceName -eq $CaptureSource } | Select-Object -First 1
            [void](Request $sock 'SetSceneItemIndex' @{ sceneName = $target; sceneItemId = $win; sceneItemIndex = $cap.sceneItemIndex })
            $new += $win
        }
    }
    if ($new) {
        $video = Request $sock 'GetVideoSettings'
        $fit = @{ boundsType = 'OBS_BOUNDS_SCALE_INNER'; boundsAlignment = 0; alignment = 5
            boundsWidth = $video.baseWidth; boundsHeight = $video.baseHeight; positionX = 0; positionY = 0 }
        foreach ($id in $new) {
            [void](Request $sock 'SetSceneItemTransform' @{ sceneName = $target; sceneItemId = $id; sceneItemTransform = $fit })
        }
    }

    # App captures for the Discord, music and browser tracks. One the user already made
    # (matched by its program) is reused instead of adding a second one.
    $appAudio = $kinds -contains 'wasapi_process_output_capture'
    $musicExes = 'Spotify.exe', 'AppleMusic.exe', 'iTunes.exe', 'foobar2000.exe', 'MusicBee.exe', 'TIDAL.exe', 'Deezer.exe'
    $prog = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice' -ErrorAction SilentlyContinue).ProgId
    $browserExe = switch -Wildcard ("$prog") {
        'ChromeHTML*' { 'chrome.exe' } 'FirefoxURL*' { 'firefox.exe' } 'Opera*' { 'opera.exe' }
        'Brave*' { 'brave.exe' } 'Vivaldi*' { 'vivaldi.exe' } default { 'msedge.exe' }
    }
    $browserClass = if ($browserExe -eq 'firefox.exe') { 'MozillaWindowClass' } else { 'Chrome_WidgetWin_1' }
    $apps = @()
    if ($discord) { $apps += @{ Name = $VoiceSource; Slot = 4; Exes = @('Discord.exe'); Window = 'Discord:Chrome_WidgetWin_1:Discord.exe' } }
    if ($music) { $apps += @{ Name = $MusicSource; Slot = 5; Exes = $musicExes; Window = 'Spotify:Chrome_WidgetWin_1:Spotify.exe' } }
    if ($Tracks -eq 'Full') { $apps += @{ Name = $BrowserSource; Slot = 6; Exes = @($browserExe); Window = "Browser:${browserClass}:$browserExe" } }
    $captures = @($inputList | Where-Object { $_.inputKind -eq 'wasapi_process_output_capture' -and $_.inputName -ne $AudioSource } |
        ForEach-Object { @{ Name = $_.inputName; Window = "$((Request $sock 'GetInputSettings' @{ inputName = $_.inputName }).inputSettings.window)" } })
    foreach ($a in $apps) {
        $found = $captures | Where-Object { $w = $_.Window; $a.Exes | Where-Object { $w -like "*:$_" } } | Select-Object -First 1
        if ($found) { $a.Name = $found.Name }
    }
    if (-not $appAudio -and ($AudioSource -or $apps)) {
        Say "This OBS version has no Application Audio Capture; app sound stays in Desktop Audio."
        $apps = @()
    } else {
        if ($AudioSource) { [void](Add-ToScene $AudioSource 'wasapi_process_output_capture' @{ priority = 2 }) }
        foreach ($a in $apps) { [void](Add-ToScene $a.Name 'wasapi_process_output_capture' @{ window = $a.Window; priority = 2 }) }
    }

    # Which tracks each audio source is on. Full records apps only: Desktop Audio is muted.
    # Otherwise Desktop Audio already contains the apps, so they only join the mix
    # (track 1) when there's no unmuted Desktop Audio.
    if ('Simple', 'Editing', 'Full' -contains $Tracks) {
        $desktops = @($inputList | Where-Object { $_.inputKind -eq 'wasapi_output_capture' })
        if ($Tracks -eq 'Full') {
            foreach ($dk in $desktops) { [void](Request $sock 'SetInputMute' @{ inputName = $dk.inputName; inputMuted = $true }) }
            if ($desktops) { Say "Muted Desktop Audio (Full records each app on its own)." }
        }
        $hasDesktop = $Tracks -ne 'Full' -and @($desktops | Where-Object {
            -not (Request $sock 'GetInputMute' @{ inputName = $_.inputName }).inputMuted }).Count -gt 0
        $mix = if ($hasDesktop) { @() } else { @(1) }
        $plan = [ordered]@{}
        foreach ($i in $inputList) {
            if ($i.inputKind -eq 'wasapi_output_capture') { $plan[$i.inputName] = @(if ($Tracks -ne 'Full') { 1 }) }
            elseif ($i.inputKind -eq 'wasapi_input_capture') { $plan[$i.inputName] = @(1) + @(if ($Tracks -ne 'Simple') { 2 }) }
        }
        if ($AudioSource -and $inputs -contains $AudioSource) { $plan[$AudioSource] = $mix + @(if ($Tracks -ne 'Simple') { 3 }) }
        foreach ($a in $apps) { if ($inputs -contains $a.Name) { $plan[$a.Name] = $mix + @($a.Slot) } }
        foreach ($p in $plan.GetEnumerator()) {
            $on = @{}; foreach ($n in 1..6) { $on["$n"] = $p.Value -contains $n }
            [void](Request $sock 'SetInputAudioTracks' @{ inputName = $p.Key; inputAudioTracks = $on })
            Say "Audio '$($p.Key)': $(if ($p.Value) { 'track ' + ($p.Value -join ', ') } else { 'no track' })"
        }
    }
} catch {
    Say "$_"; exit 5
} finally {
    [void]$sock.CloseAsync('NormalClosure', '', $none).Wait(3000)
}
Say "OBS is set up."
exit 0
