"""Keeps an installed Ultron up to date from the GitHub releases.

Only an installed copy updates: the installer writes version.txt, a git checkout has none.
A new release is downloaded right away but installed only when no game runs and OBS
isn't recording, so an update never cuts into a match. The installer then restarts Ultron.
"""
import json
import logging
import os
import subprocess
import tempfile
import threading
import time
import urllib.request
from pathlib import Path

from .config import ROOT
from .obs import ObsError

log = logging.getLogger("ultron")
REPO = "TheMasked2/ultron"
LATEST = f"https://api.github.com/repos/{REPO}/releases/latest"
ASSET = "UltronSetup.exe"


def parse(version: str) -> tuple[int, ...]:
    return tuple(int(x) for x in version.strip().lstrip("v").split("."))


def installed() -> str | None:
    try:
        return (ROOT / "version.txt").read_text(encoding="utf-8").strip() or None
    except OSError:
        return None


def latest() -> tuple[str, str, int]:
    """(version, download url, size) of the newest release."""
    req = urllib.request.Request(LATEST, headers={"User-Agent": "Ultron updater",
                                                  "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        rel = json.loads(r.read())
    asset = next(a for a in rel["assets"] if a["name"] == ASSET)
    url = asset["browser_download_url"]
    if not url.startswith(f"https://github.com/{REPO}/releases/download/"):
        raise ValueError(f"unexpected download url {url}")
    return rel["tag_name"].lstrip("v"), url, asset["size"]


class Updater(threading.Thread):
    def __init__(self, cfg: dict, obs, watcher):
        super().__init__(daemon=True, name="updater")
        self.cfg, self.obs, self.watcher = cfg, obs, watcher
        self.version = installed()
        self._told = None  # version we already logged as available

    def run(self):
        time.sleep(60)  # let startup and the first game check settle
        while True:
            try:
                self.check()
            except Exception as e:
                log.warning("Update check failed: %s", e)
            time.sleep(max(1.0, float(self.cfg.get("check_hours", 6))) * 3600)

    def check(self, install: bool = True) -> str | None:
        """Returns the newer version, or None when up to date."""
        new, url, size = latest()
        if parse(new) <= parse(self.version):
            return None
        if not self.cfg.get("auto", True) or not install:
            if self._told != new:
                log.info("Ultron %s is available (you have %s): https://github.com/%s/releases/latest",
                         new, self.version, REPO)
                self._told = new
            return new
        setup = self.download(new, url, size)
        self.wait_until_idle()
        log.info("Updating Ultron %s -> %s", self.version, new)
        # Detached, from the temp folder: the installer stops every process in Ultron's
        # folder (this one included), then restarts Ultron when it's done.
        subprocess.Popen([str(setup), "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/UPDATE=1"],
                         creationflags=subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP,
                         close_fds=True, cwd=tempfile.gettempdir())
        return new

    def download(self, version: str, url: str, size: int) -> Path:
        path = Path(tempfile.gettempdir()) / f"UltronSetup-{version}.exe"
        if path.exists() and path.stat().st_size == size:
            return path
        part = path.with_suffix(".part")
        req = urllib.request.Request(url, headers={"User-Agent": "Ultron updater"})
        with urllib.request.urlopen(req, timeout=60) as r, open(part, "wb") as f:
            while chunk := r.read(1 << 16):
                f.write(chunk)
        if part.stat().st_size != size:
            part.unlink(missing_ok=True)
            raise ValueError(f"download of {version} is incomplete")
        os.replace(part, path)
        log.info("Downloaded Ultron %s", version)
        return path

    def busy(self) -> bool:
        if self.watcher and self.watcher.in_game:
            return True
        try:
            return bool(self.obs.call("GetRecordStatus").get("outputActive"))
        except ObsError:
            return False  # OBS closed: nothing to interrupt

    def wait_until_idle(self):
        if self.busy():
            log.info("Update ready; installing once no game runs and OBS isn't recording")
        while self.busy():
            time.sleep(30)
