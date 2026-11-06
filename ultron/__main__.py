import argparse
import ctypes
import logging
import logging.handlers
import os
import sys
import time

from . import commands
from .config import ROOT, load
from .games import Games
from .obs import Obs
from . import updater
from .voice import TextIO
from .watcher import Watcher

log = logging.getLogger("ultron")
PID_FILE = ROOT / "ultron.pid"

k32 = ctypes.windll.kernel32
k32.GetCurrentProcess.restype = ctypes.c_void_p
k32.SetPriorityClass.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
k32.OpenProcess.restype = ctypes.c_void_p
k32.QueryFullProcessImageNameW.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_wchar_p, ctypes.POINTER(ctypes.c_uint32)]
k32.CloseHandle.argtypes = [ctypes.c_void_p]


def _is_python(pid: int) -> bool:
    # Not os.kill(pid, 0): on Windows that terminates the process.
    handle = k32.OpenProcess(0x1000, False, pid)
    if not handle:
        return False
    try:
        buf, size = ctypes.create_unicode_buffer(1024), ctypes.c_uint32(1024)
        return bool(k32.QueryFullProcessImageNameW(handle, 0, buf, ctypes.byref(size))) and "python" in buf.value.lower()
    finally:
        k32.CloseHandle(handle)


def ensure_single_instance():
    """Two Ultrons would both steer OBS, so only one may run."""
    try:
        pid = int(PID_FILE.read_text())
        if pid != os.getpid() and _is_python(pid):
            print(f"Ultron is already running (pid {pid}).")
            sys.exit(0)
    except (OSError, ValueError):
        pass
    PID_FILE.write_text(str(os.getpid()))


def start_voice(cfg, attempts: int = 6):
    """At logon the mic may not be ready yet, so retry for about a minute."""
    from .voice import VoiceIO
    for attempt in range(1, attempts + 1):
        try:
            return VoiceIO(cfg)
        except Exception:
            log.exception("voice start failed (attempt %d of %d)", attempt, attempts)
            if attempt == attempts:
                raise
            time.sleep(10)


def main():
    ap = argparse.ArgumentParser(prog="ultron")
    ap.add_argument("--dry-run", action="store_true", help="print the games running now and exit")
    ap.add_argument("--text", action="store_true", help="type commands instead of speaking; the game watcher stays off")
    ap.add_argument("--game", action="store_true", help="with --text: act as if a game is running")
    ap.add_argument("--no-voice", action="store_true", help="only the game watcher, no microphone")
    ap.add_argument("--check-update", action="store_true", help="say whether a newer release exists and exit")
    args = ap.parse_args()

    handler = logging.handlers.RotatingFileHandler(ROOT / "ultron.log", maxBytes=1_000_000, backupCount=1, encoding="utf-8")
    logging.basicConfig(handlers=[handler], level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    k32.SetPriorityClass(k32.GetCurrentProcess(), 0x4000)  # below normal: games always win the CPU
    cfg = load()

    games = Games(cfg["games"], ROOT / "cache")
    games.load()
    if args.dry_run:
        print(f"Game list: {len(games.by_exe)} Windows executables")
        found = games.detect()
        print("\n".join(f"Detected: {n} ({e})" for n, e in found) if found else "No games running")
        return

    if args.check_update:
        mine = updater.installed()
        new = updater.latest()[0]
        print(f"Installed: {mine or 'not installed (no version.txt)'}, latest release: {new}")
        return

    obs = Obs(cfg["obs"]["url"])
    watcher = None
    if not args.text:
        ensure_single_instance()
        watcher = Watcher(cfg["watcher"], obs, games)
        watcher.start()
        log.info("Ultron %s started (pid %d, %d game executables)",
                 updater.installed() or "(dev)", os.getpid(), len(games.by_exe))
        if updater.installed():
            updater.Updater(cfg.get("update", {}), obs, watcher).start()
    if args.no_voice:
        while True:
            time.sleep(3600)

    io = TextIO() if args.text else start_voice(cfg)
    table = commands.build(cfg.get("phrases", {}))
    game_only = cfg["voice"].get("game_only", [])
    print("Ultron is listening." if not args.text else "Type a command (exit to quit).")
    while True:
        try:
            io.wait()
            text = io.hear()
            if not text:
                continue
            if args.text and text in ("exit", "quit"):
                break
            in_game = args.game or bool(watcher and watcher.in_game)
            result = commands.handle(text, table, obs, in_game, game_only)
            log.info("heard: %s%s", text, "" if result is not None else " (not a command, ignored)")
            if result is not None:
                io.tone("ok" if result else "no")
        except (KeyboardInterrupt, EOFError) as e:
            log.info("Ultron stopped (%s)", type(e).__name__)
            break
        except Exception:
            log.exception("command failed")


if __name__ == "__main__":
    main()
