"""The voice commands: OBS clips and recording, nothing else.

The phrases live in config.toml under [phrases]. A phrase counts when the sentence
ends with it, so "oh my god clip that" clips.
"""
import logging
import re

from .obs import ObsError

log = logging.getLogger("ultron")


def clip(obs) -> tuple[bool, str]:
    if not obs.call("GetReplayBufferStatus").get("outputActive"):
        return False, "replay buffer isn't running"
    obs.call("SaveReplayBuffer")
    return True, "clipped"


def record(obs, start: bool) -> tuple[bool, str]:
    active = obs.call("GetRecordStatus").get("outputActive")
    if start == active:
        return False, "already recording" if active else "not recording"
    obs.call("StartRecord" if start else "StopRecord")
    return True, "recording started" if start else "recording stopped"


def pause(obs, paused: bool) -> tuple[bool, str]:
    status = obs.call("GetRecordStatus")
    if not status.get("outputActive"):
        return False, "not recording"
    if paused == status.get("outputPaused"):
        return False, "already paused" if paused else "not paused"
    obs.call("PauseRecord" if paused else "ResumeRecord")
    return True, "recording paused" if paused else "recording resumed"


ACTIONS = {
    "clip": lambda obs: clip(obs),
    "start_recording": lambda obs: record(obs, True),
    "stop_recording": lambda obs: record(obs, False),
    "pause_recording": lambda obs: pause(obs, True),
    "resume_recording": lambda obs: pause(obs, False),
}

_FILLER_START = re.compile(r"^((hey|hi|ok|okay|yo) )?(ultron )?(please )?")
_FILLER_END = re.compile(r" (please|ultron|thanks|thank you)$")


def normalize(text: str) -> str:
    text = re.sub(r"[^\w\s]", "", text.lower().replace("-", " "))
    text = re.sub(r"\s+", " ", text).strip()
    return _FILLER_END.sub("", _FILLER_START.sub("", text))


def build(phrases: dict) -> list:
    table = []
    for action, said in phrases.items():
        if action not in ACTIONS:
            log.warning("config.toml [phrases]: unknown action %r, ignored", action)
            continue
        options = "|".join(re.escape(normalize(p)) for p in sorted(said, key=len, reverse=True))
        table.append((re.compile(rf"(?:^|\s)(?:{options})$"), action))
    return table


def handle(text: str, table: list, obs, in_game: bool, game_only: list) -> bool | None:
    """True: done. False: refused or failed. None: not a command (ignored)."""
    norm = normalize(text)
    for pattern, action in table:
        if not pattern.search(norm):
            continue
        if action in game_only and not in_game:
            log.info("%s: refused, no game running", action)
            return False
        try:
            ok, what = ACTIONS[action](obs)
        except ObsError as e:
            ok, what = False, str(e)
        log.info("%s: %s", action, what)
        return ok
    return None
