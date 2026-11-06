## New in 1.0.11

- **Automatic updates.** Ultron checks for new releases every 6 hours and updates itself, only while no game runs and OBS isn't recording. It's the "Keep Ultron up to date" checkbox in the installer, or `auto` under `[update]` in `config.toml`. From this version on you won't need to download new installers.
- **Several games open:** OBS now records the game whose window is in front. Before, it stayed on the first game it found (paused in Aimlabs, switched to VALORANT, still recording Aimlabs).

Coming from 1.0.8 or older: install this one by hand once.

## New in 1.0.8

- Fixed: Ultron could fail to connect when OBS had a different WebSocket password than the one Ultron had picked up. It now reads the saved password every time it connects.
- The log now says what's wrong: OBS not open, password refused, or no password saved (fix the last two with **Set up OBS again** in the Start menu)
- Better speech recognition for the commands; "click that" now clips too
- The installer saves its setup output to `install.log` in the Ultron folder

## Install

1. Install [OBS Studio](https://obsproject.com) 28 or newer and open it once.
2. Download **UltronSetup.exe** below and run it. The installer isn't code-signed, so Windows may say "Windows protected your PC": click **More info → Run anyway**.
3. Leave **Set up OBS for me** on, choose your clip length, scene and audio tracks.
4. Start a game and say **"Ultron, clip that"**.

## What's in it

- Automatic game detection (Discord's list of detectable games) that points OBS's Game Capture, Game Window and Game Audio at the running game
- Replay buffer only while a game is running
- Voice commands: clip that, start / stop / pause / unpause recording
- Local "Ultron" wake word (97.7% recall on unseen voices, about one false wake per 2.7 hours)
- OBS setup wizard: new or existing scene, audio track presets from one mix up to one track per app
- Offers to remove OBS Game Watcher, which Ultron replaces

Everything runs locally. No account, no upload.
