"""Points OBS at the game you're playing and runs the replay buffer only while you play."""
import logging
import threading
import time

from .obs import ObsError, ObsRequestError

log = logging.getLogger("ultron")


class Watcher(threading.Thread):
    def __init__(self, cfg: dict, obs, games):
        super().__init__(daemon=True, name="watcher")
        self.cfg, self.obs, self.games = cfg, obs, games
        self.game: tuple[str, str] | None = None  # (name, exe) of the game being played
        self._was_game = False
        self._problems: dict[str, str] = {}  # repeating problems, logged once each

    @property
    def in_game(self) -> bool:
        return self.game is not None

    def run(self):
        while True:
            try:
                self.tick()
            except Exception:
                log.exception("watcher check failed")
            time.sleep(self.cfg.get("poll_seconds", 3))

    def _problem(self, key: str, msg: str | None):
        if msg and self._problems.get(key) != msg:
            log.warning(msg)
        if msg:
            self._problems[key] = msg
        else:
            self._problems.pop(key, None)

    def tick(self):
        found = self.games.detect()
        still = self.game and next((g for g in found if g[1] == self.game[1]), None)
        game = still or (found[0] if found else None)
        if game and game != self.game:
            log.info("Detected %s (%s)", *game)
        elif not game and self.game:
            log.info("%s closed", self.game[0])
        self.game = game

        try:
            if game:
                self.retarget(game)
                if not self._was_game:
                    self.switch_scene("game_scene")
            elif self._was_game:
                self.switch_scene("idle_scene")
            self.sync_replay_buffer(bool(game))
            self._was_game = bool(game)
            self._problem("obs", None)
        except ObsRequestError as e:
            self._problem("obs", f"OBS: {e}")
        except ObsError as e:
            self._problem("obs", f"{e}; retrying")

    # OBS names windows "title:class:exe". Use OBS's own entry for the game's window;
    # until it has one, match the executable alone ("::exe").
    def window_for(self, exe: str) -> tuple[str, bool]:
        try:
            items = self.obs.call("GetInputPropertiesListPropertyItems", {
                "inputName": self.cfg["game_capture_source"], "propertyName": "window"}).get("propertyItems", [])
        except ObsRequestError:
            items = []
        for item in items:
            v = item["itemValue"].lower()
            if v.endswith(":" + exe) and not v.startswith("::"):
                return item["itemValue"], True
        return "::" + exe, False

    def sync(self, name: str, wanted: dict) -> bool:
        """Change a source only where it differs, so a hand edit or relaunch gets corrected."""
        if not name:
            return False
        try:
            settings = self.obs.call("GetInputSettings", {"inputName": name})["inputSettings"]
        except ObsRequestError as e:
            self._problem("source:" + name, f'Source "{name}": {e}')
            return False
        self._problem("source:" + name, None)
        if all(settings.get(k) == v for k, v in wanted.items()):
            return False
        self.obs.call("SetInputSettings", {"inputName": name, "inputSettings": wanted})
        return True

    def retarget(self, game: tuple[str, str]):
        # Game Capture shows the game when it can hook it; Game Window (Window Capture,
        # underneath) shows games it can't hook, e.g. Clickteam games like FNAF.
        window, exact = self.window_for(game[1])
        changed = [
            self.sync(self.cfg["game_capture_source"], {"capture_mode": "window", "window": window, "priority": 2}),
            self.sync(self.cfg.get("game_window_source", ""), {"window": window, "priority": 2}),
            self.sync(self.cfg.get("game_audio_source", ""), {"window": window, "priority": 2}),
        ]
        if any(changed):
            log.info("Pointed OBS at %s (%s)%s", game[0], game[1],
                     f' window "{window}"' if exact else " - waiting for its window")

    def switch_scene(self, which: str):
        sw = self.cfg.get("switch_scenes", {})
        scene = sw.get(which)
        if not sw.get("enabled") or not scene:
            return
        if self.obs.call("GetCurrentProgramScene").get("currentProgramSceneName") != scene:
            self.obs.call("SetCurrentProgramScene", {"sceneName": scene})
            log.info('Switched to scene "%s"', scene)

    def sync_replay_buffer(self, want: bool):
        if not self.cfg.get("replay_buffer", True):
            return
        try:
            if self.obs.call("GetReplayBufferStatus").get("outputActive") != want:
                self.obs.call("StartReplayBuffer" if want else "StopReplayBuffer")
                log.info("Started the replay buffer" if want else "Stopped the replay buffer")
            self._problem("replay", None)
        except ObsRequestError as e:  # e.g. the replay buffer is off in OBS's settings
            self._problem("replay", f"Replay buffer: {e}")
