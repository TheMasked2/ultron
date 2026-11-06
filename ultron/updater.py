"""Keeps an installed Ultron up to date from the GitHub releases.

Only an installed copy updates: the installer writes version.txt, a git checkout has none.
Each release carries ultron-update.zip (the app files, never config.toml). A new one is
downloaded right away but applied only when no game runs and OBS isn't recording, so an
update never cuts into a match. Then Ultron restarts.

Updates don't run the installer: Windows' Smart App Control blocks unsigned programs
(UltronSetup.exe) with no way to allow them, while Ultron's own Python can copy files.
"""
import json
import logging
import os
import shutil
import subprocess
import tempfile
import threading
import time
import urllib.request
import zipfile
from pathlib import Path, PurePosixPath

from .config import ROOT
from .obs import ObsError

log = logging.getLogger("ultron")
REPO = "TheMasked2/ultron"
LATEST = f"https://api.github.com/repos/{REPO}/releases/latest"
ASSET = "ultron-update.zip"
# What an update may write; everything else in the zip is refused.
ALLOWED = {"ultron", "models", "pyproject.toml", "uv.lock", "setup.ps1", "env.ps1", "run.ps1", "run.cmd",
           "start-hidden.vbs", "restart.ps1", "README.md", "obs-setup.ps1", "version.txt"}
UNINSTALL_KEY = r"Software\Microsoft\Windows\CurrentVersion\Uninstall\{D7E2A915-3C4B-4F6E-8A1D-5B9C0E7F2A63}_is1"


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
    version = rel["tag_name"].lstrip("v")
    asset = next((a for a in rel["assets"] if a["name"] == ASSET), None)
    if not asset:  # releases from before the updater
        return version, "", 0
    url = asset["browser_download_url"]
    if not url.startswith(f"https://github.com/{REPO}/releases/download/"):
        raise ValueError(f"unexpected download url {url}")
    return version, url, asset["size"]


def members(z: zipfile.ZipFile) -> list[str]:
    """The zip's files, refusing anything that would land outside the allowed paths."""
    names = [n for n in z.namelist() if not n.endswith("/")]
    for n in names:
        p = PurePosixPath(n)
        if "\\" in n or ":" in n or p.is_absolute() or ".." in p.parts or p.parts[0] not in ALLOWED:
            raise ValueError(f"update contains an unexpected file: {n}")
    for need in ("ultron/__main__.py", "version.txt"):
        if need not in names:
            raise ValueError(f"update is missing {need}")
    return names


def uv_env() -> dict:
    """The same folders env.ps1 sets, so uv works on this install's Python and cache."""
    return os.environ | {"UV_PYTHON_INSTALL_DIR": str(ROOT / ".cache" / "python"), "UV_CACHE_DIR": str(ROOT / ".cache" / "uv"),
                         "UV_LINK_MODE": "copy", "HF_HOME": str(ROOT / "models"), "UV_NO_PROGRESS": "1"}


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
                log.warning("Update failed: %s", e)
            time.sleep(max(1.0, float(self.cfg.get("check_hours", 6))) * 3600)

    def check(self, install: bool = True) -> str | None:
        """Returns the newer version, or None when up to date."""
        new, url, size = latest()
        if parse(new) <= parse(self.version):
            return None
        if not url or not self.cfg.get("auto", True) or not install:
            if self._told != new:
                log.info("Ultron %s is available (you have %s): https://github.com/%s/releases/latest",
                         new, self.version, REPO)
                self._told = new
            return new
        package = self.download(new, url, size)
        self.wait_until_idle()
        sync = self.apply(package)
        self.add_settings()
        log.info("Updated Ultron %s -> %s; restarting%s", self.version, new, " (packages too)" if sync else "")
        self.set_uninstall_version(new)
        self.restart(sync)
        return new

    def download(self, version: str, url: str, size: int) -> Path:
        path = Path(tempfile.gettempdir()) / f"ultron-update-{version}.zip"
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
            log.info("Update ready; applying it once no game runs and OBS isn't recording")
        while self.busy():
            time.sleep(30)

    def apply(self, package: Path, root: Path | None = None) -> bool:
        """Copies the update over the install, all or nothing. True: uv.lock changed."""
        root = root or ROOT
        with zipfile.ZipFile(package) as z:
            names = members(z)
            lock = root / "uv.lock"
            old_lock = lock.read_bytes() if lock.exists() else b""
            backup = root / "cache" / "update-backup"
            shutil.rmtree(backup, ignore_errors=True)
            created = []
            try:
                for n in names:
                    dst = root / n
                    if dst.exists():
                        (backup / n).parent.mkdir(parents=True, exist_ok=True)
                        shutil.copy2(dst, backup / n)
                    else:
                        created.append(dst)
                    dst.parent.mkdir(parents=True, exist_ok=True)
                    dst.write_bytes(z.read(n))
            except Exception:
                for n in names:
                    if (backup / n).exists():
                        shutil.copy2(backup / n, root / n)
                for dst in created:
                    dst.unlink(missing_ok=True)
                raise
        return (lock.read_bytes() if lock.exists() else b"") != old_lock

    def add_settings(self, root: Path | None = None):
        """Updates never replace config.toml; show the [update] settings in older ones."""
        cfg = (root or ROOT) / "config.toml"
        try:
            text = cfg.read_text(encoding="utf-8-sig")
            if "[update]" not in text:
                cfg.write_text(text.rstrip("\n") + "\n\n[update]\n"
                               "auto = true              # update from GitHub releases by itself (only when no game runs and OBS isn't recording)\n"
                               "check_hours = 6          # how often to look for a new release; with auto = false it's only written to the log\n",
                               encoding="utf-8")
        except OSError:
            pass

    def set_uninstall_version(self, version: str):
        """Settings > Apps shows the version the installer wrote; keep it current."""
        try:
            import winreg
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, UNINSTALL_KEY, 0, winreg.KEY_SET_VALUE) as k:
                winreg.SetValueEx(k, "DisplayVersion", 0, winreg.REG_SZ, version)
        except OSError:
            pass

    def restart(self, sync: bool):
        """A helper waits for this process to end (the venv's files are locked while it
        runs), syncs packages if uv.lock changed, then starts Ultron again."""
        uv = ROOT / "tools" / "uv.exe"
        steps = [f"ping -n 4 127.0.0.1 >nul"]
        if sync and uv.exists():
            steps.append(f'"{uv}" sync --project "{ROOT}" --python 3.12 >> "{ROOT / "ultron.out"}" 2>&1')
        steps.append(f'wscript.exe "{ROOT / "start-hidden.vbs"}"')
        (ROOT / "ultron.pid").unlink(missing_ok=True)
        subprocess.Popen(f'cmd.exe /d /c "{" & ".join(steps)}"', env=uv_env(), cwd=str(ROOT),
                         creationflags=subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.CREATE_NO_WINDOW,
                         close_fds=True)
        logging.shutdown()
        os._exit(0)
