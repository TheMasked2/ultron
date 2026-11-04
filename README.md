# Ultron

Open source game clipping for Windows, built on OBS. While you play, Ultron points
OBS at your game and keeps the last minutes in OBS's replay buffer. Say
**"Ultron, clip that"** (or press OBS's Save Replay hotkey) to save them.

Everything runs locally: game detection, the wake word and speech recognition.
No account, no upload, no AI service.

## Install

1. Install [OBS Studio](https://obsproject.com) and open it once.
2. Download **[UltronSetup.exe](https://github.com/TheMasked2/ultron/releases/latest/download/UltronSetup.exe)**
   (or pick a version under [Releases](https://github.com/TheMasked2/ultron/releases)) and run it.
   Windows may say "Windows protected your PC" because the installer isn't signed:
   click **More info → Run anyway**.
3. Click through the wizard. Leave **Set up OBS for me** on. It:
   - turns on OBS's WebSocket server and replay buffer (anything already set up is kept)
   - asks for the **clip length**
   - asks for the **scene**: a new one (default "Game") or one you have
   - asks for the **audio tracks**: one mixed track; separate tracks for editing
     (1 everything, 2 mic, 3 game, optionally 4 Discord and 5 music); each app
     separate (1 everything, 2 mic, 3 game, 4 Discord, 5 music, 6 browser, with
     Desktop Audio muted, so other programs aren't heard); a custom count; or keep
     your settings. Track 1 is always the full mix, so clips sound right anywhere.
   - adds the Game Capture, Game Window and Game Audio sources

   If OBS is open it asks to close it for a moment. The last page lists the OBS
   choices before anything is installed.
4. Setup downloads Python and the speech models (a few hundred MB).
5. Start a game and say "Ultron, clip that".

The Start menu has the settings (`config.toml`), the log, "Restart Ultron" (after
editing the settings), "Repair" (download the models again) and "Set up OBS again".
Uninstall from Settings → Apps; your `config.toml` is kept.

If OBS Game Watcher is installed, the installer offers to remove it: Ultron does
the same job, and both would steer OBS at once.

## How it works

1. Every 3 seconds it lists running programs (straight from Windows, about 1 ms)
   and matches them against [Discord's public list of detectable games](https://discord.com/api/v9/applications/detectable)
   (cached, refreshed daily). No Discord login is involved.
2. When a game runs, it points these OBS sources at the game's window, and
   corrects them if they drift (changed by hand, game relaunched):
   - **Game Capture**
   - **Game Window** (Window Capture, underneath): shows games Game Capture can't hook,
     e.g. Clickteam games like Five Nights at Freddy's
   - **Game Audio** (Application Audio Capture): game sound on its own track
3. It runs the replay buffer only while a game is running, so a clip always has
   game footage.
4. Optionally it switches scenes when a game starts and stops.

Anti-cheat protected games (e.g. VALORANT) hide their file path; those are matched
on the executable name alone. A game Discord doesn't know (one you're making, say)
goes under `extra` in `[games]`.

## Voice commands

| Say | Does |
|---|---|
| clip that / clip it / save that | Saves the replay buffer (only while a game runs) |
| start / stop recording | OBS recording (starting only while a game runs) |
| pause / unpause recording | Pauses and resumes a recording |

Say the wake word first: **"Ultron"**. A rising tone means done, a falling tone
means it couldn't (no game running, OBS closed, ...). The log says why. Anything
else you say is ignored: Ultron only does OBS.

The phrases are yours to change under `[phrases]` in `config.toml`.

**Wake word:** "Ultron" (`models\wake\ultron.onnx`, trained with openWakeWord on
synthetic voices: 97.7% recall on unseen voices, about one false wake per 2.7 hours
of other audio). If it wakes by accident, raise `threshold` under `[wake]`; if it
misses you, lower it. Without the model file Ultron falls back to **"Hey Jarvis"**.

## Light on the game

- Below-normal process priority: the game always wins the CPU.
- Speech recognition uses Whisper `base.en` on 2 CPU threads, only after the wake word.
- No speech output: tones only, no voice model.
- One process: game detection, OBS control and voice share it.

## Manual setup and running

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

To build the installer: `.\installer\build.ps1` (needs [Inno Setup 6](https://jrsoftware.org));
`-UiTest` builds one that shows every page but never installs. To publish it as a
GitHub release (what the download link points at): `.\installer\release.ps1`.

## Configuration (`config.toml`)

| Section | What |
|---|---|
| `[wake]` | Wake word model, fallback and sensitivity |
| `[audio]` | Mic, tone loudness, when listening stops |
| `[stt]` | Speech model and CPU threads |
| `[obs]` | OBS WebSocket address (password: `OBS_WEBSOCKET_PASSWORD` user environment variable) |
| `[voice]` | Commands that only work while a game runs |
| `[phrases]` | What you can say |
| `[watcher]` | Source names, poll interval, replay buffer, scene switching |
| `[games]` | Programs that aren't games (`ignore`), games Discord doesn't know (`extra`) |

## Files

| File | What it does |
|---|---|
| `ultron/__main__.py` | Startup, single instance, the listen loop |
| `ultron/games.py` | Discord game list and process matching |
| `ultron/watcher.py` | Points OBS at the game, runs the replay buffer |
| `ultron/obs.py` | The shared OBS WebSocket connection |
| `ultron/voice.py` | Wake word, speech recognition, tones |
| `ultron/commands.py` | The voice commands |
| `ultron.log` | What was detected, heard and done |
| `installer/` | The Setup.exe (Inno Setup), `obs-setup.ps1` and the OBS wizard pages |

## Works well with

- [Jarvis](https://github.com/TheMasked2/jarvis): a voice assistant for the rest
  of your PC (music, volume, apps, questions).
