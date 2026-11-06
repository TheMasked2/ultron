# Ultron

**Open source game clipping for Windows, built on OBS.**

![Windows 10/11](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D6)
![Python 3.12](https://img.shields.io/badge/Python-3.12-3776AB)
![OBS Studio 28+](https://img.shields.io/badge/OBS%20Studio-28%2B-302E31)
![License: MIT](https://img.shields.io/badge/License-MIT-green)

While you play, Ultron points OBS at your game and keeps the last minutes in OBS's
replay buffer. Say **"Ultron, clip that"** and the moment is saved.

- **Automatic game capture.** Recognises thousands of games, and points OBS's capture and audio at whichever one is running.
- **Replay buffer only while you play.** Every clip has game footage, and nothing records while you're not gaming.
- **Clip by voice.** You never take your hands off the game. Recording works by voice too.
- **One-click OBS setup.** Scene, sources, clip length and audio tracks (one mix, or a separate track per app for editing).
- **Local and private.** Game detection, the wake word and speech recognition all run on your PC. No account, no upload, no cloud service.
- **Light on the game.** Below-normal priority, a small speech model, no voice output.

## Contents

- [Install](#install)
- [Voice commands](#voice-commands)
- [How it works](#how-it-works)
- [Configuration](#configuration)
- [Development](#development)
- [License](#license)

## Install

**You need:** Windows 10 or 11, [OBS Studio](https://obsproject.com) 28 or newer
(opened at least once) and a microphone.

1. Download **[UltronSetup.exe](https://github.com/TheMasked2/ultron/releases/latest/download/UltronSetup.exe)**
   (or pick a version under [Releases](https://github.com/TheMasked2/ultron/releases)) and run it.
   The installer isn't code-signed, so Windows may say "Windows protected your PC":
   click **More info → Run anyway**.
2. Click through the wizard. Leave **Set up OBS for me** on. It:
   - turns on OBS's WebSocket server and replay buffer (anything already set up is kept)
   - asks for the **clip length**
   - asks for the **scene**: a new one (default "Game") or one you already have
   - asks for the **audio tracks** (see below)
   - adds the Game Capture, Game Window and Game Audio sources

   If OBS is open it asks to close it for a moment. The last page lists every OBS
   change before anything is installed.
3. Setup downloads Python and the speech model (a few hundred MB, a few minutes).
4. Start a game and say **"Ultron, clip that"**.

| Audio track preset | Tracks |
|---|---|
| Simple | 1 mixed track |
| Editing | 1 everything, 2 mic, 3 game; optionally 4 Discord and 5 music |
| Every app separate | 1 everything, 2 mic, 3 game, 4 Discord, 5 music, 6 browser. Desktop Audio is muted, so other programs aren't heard |
| Custom / Keep | Your own track count, or leave OBS as it is |

Track 1 is always the full mix, so clips sound right in any player.

**Updates.** With **Keep Ultron up to date** on (the default), Ultron checks this
repo's releases every 6 hours and updates itself, but only while no game runs and
OBS isn't recording. Then it restarts. Your `config.toml` is never replaced. Turn it off with `auto = false`
under `[update]`, and new versions are only mentioned in the log.

The Start menu has the settings (`config.toml`), the log, **Restart Ultron** (after
editing the settings), **Repair** (download the models again) and **Set up OBS again**.
Uninstall from Settings → Apps; your `config.toml` is kept.

Upgrading from OBS Game Watcher? The installer offers to remove it, since Ultron does
the same job and both would steer OBS at once.

## Voice commands

Say the wake word **"Ultron"**, then the command, in one breath or after the tone.

| Say | Does |
|---|---|
| clip that / clip it / save that | Saves the replay buffer (while a game runs) |
| start recording / stop recording | OBS recording (starting only while a game runs) |
| pause recording / unpause recording | Pauses and resumes a recording |

A rising tone means done, a falling tone means it couldn't (no game running, OBS
closed, ...). `ultron.log` says why. Anything else is ignored: Ultron only controls
OBS. OBS's own Save Replay hotkey keeps working too.

The phrases are yours to change under `[phrases]` in `config.toml`.

**Wake word accuracy.** The "Ultron" model (`models\wake\ultron.onnx`) was trained
with [openWakeWord](https://github.com/dscripka/openWakeWord) on synthetic voices.
On voices it never heard in training it catches 97.7% of wake words, with about one
false wake per 2.7 hours of other audio. If it wakes by accident, raise `threshold`
under `[wake]`; if it misses you, lower it.

## How it works

1. Every 3 seconds Ultron lists the running programs (straight from Windows, about
   1 ms) and matches them against [Discord's public list of detectable games](https://discord.com/api/v9/applications/detectable),
   cached and refreshed daily. No Discord login is involved.
2. When a game runs, it points these OBS sources at the game's window, and corrects
   them if they drift (changed by hand, game relaunched):
   - **Game Capture**
   - **Game Window** (Window Capture, underneath): shows games Game Capture can't
     hook, such as Clickteam games like Five Nights at Freddy's
   - **Game Audio** (Application Audio Capture): the game's sound on its own track
   With several games open, it follows the one whose window is in front; while
   you're on the desktop or Discord it keeps the last game you played.
3. It runs the replay buffer only while a game is running.
4. Optionally it switches scenes when a game starts and stops.

Anti-cheat protected games (VALORANT, for example) hide their file path; those are
matched on the executable name alone. A game Discord doesn't know (one you're making,
say) goes under `extra` in `[games]`.

**Performance.** Ultron runs at below-normal priority, so the game always wins the
CPU. Speech recognition (Whisper `base.en`, 2 CPU threads) runs only after the wake
word. Game detection, OBS control and voice share one process.

## Configuration

Settings live in `config.toml` in the install folder. Restart Ultron after editing.

| Section | What |
|---|---|
| `[wake]` | Wake word model, fallback and sensitivity |
| `[audio]` | Microphone, tone loudness, when listening stops |
| `[stt]` | Speech model and CPU threads |
| `[obs]` | OBS WebSocket address (password: the `OBS_WEBSOCKET_PASSWORD` user environment variable) |
| `[update]` | Automatic updates on or off, how often to check |
| `[voice]` | Commands that only work while a game runs |
| `[phrases]` | What you can say |
| `[watcher]` | Source names, poll interval, replay buffer, scene switching |
| `[games]` | Programs that aren't games (`ignore`), games Discord doesn't know (`extra`) |

## Development

```powershell
.\setup.ps1                          # once: uv, Python 3.12, packages, models (kept in this folder)
.\installer\obs-setup.ps1 -CloseObs  # set OBS up (-Check only reports; see the script for options)
.\run.ps1                            # run in the foreground
.\run.ps1 --dry-run                  # show which games are detected right now, change nothing
.\run.ps1 --text --game              # type commands instead of speaking (no game watcher)
.\run.ps1 --no-voice                 # only the game watcher, no microphone
```

If PowerShell says a script "is not digitally signed", run it as
`powershell -ExecutionPolicy Bypass -File .\setup.ps1`.

- **Installer:** `.\installer\build.ps1` (needs [Inno Setup 6](https://jrsoftware.org)).
  `-UiTest` builds one that shows every page but never installs.
- **Release:** `.\installer\release.ps1` builds it and publishes a GitHub release,
  which is what the download link points at.

| File | What it does |
|---|---|
| `ultron/__main__.py` | Startup, single instance, the listen loop |
| `ultron/games.py` | Discord game list and process matching |
| `ultron/watcher.py` | Points OBS at the game, runs the replay buffer |
| `ultron/obs.py` | The shared OBS WebSocket connection |
| `ultron/voice.py` | Wake word, speech recognition, tones |
| `ultron/commands.py` | The voice commands |
| `installer/` | Setup.exe (Inno Setup), `obs-setup.ps1` and the OBS wizard pages |

## Works well with

- Jarvis: a voice assistant for the rest of
  your PC (music, volume, apps, questions).

## License

[MIT](LICENSE). Built on [OBS Studio](https://obsproject.com),
[openWakeWord](https://github.com/dscripka/openWakeWord),
[faster-whisper](https://github.com/SYSTRAN/faster-whisper) and
[obsws-python](https://github.com/aatikturk/obsws-python).
