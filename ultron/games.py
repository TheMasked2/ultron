"""Which game is running, using Discord's public list of detectable games.

The list is cached in cache/detectable.json and refreshed daily. Processes are
listed straight from Windows (no tasklist or PowerShell), so a check costs ~1 ms.
"""
import ctypes
import json
import logging
import time
import urllib.request
from ctypes import wintypes
from pathlib import Path

log = logging.getLogger("ultron")
DETECTABLE_URL = "https://discord.com/api/v9/applications/detectable"
DAY = 24 * 3600


class _Entry(ctypes.Structure):  # PROCESSENTRY32W
    _fields_ = [("dwSize", wintypes.DWORD), ("cntUsage", wintypes.DWORD), ("th32ProcessID", wintypes.DWORD),
                ("th32DefaultHeapID", ctypes.c_size_t), ("th32ModuleID", wintypes.DWORD),
                ("cntThreads", wintypes.DWORD), ("th32ParentProcessID", wintypes.DWORD),
                ("pcPriClassBase", ctypes.c_long), ("dwFlags", wintypes.DWORD), ("szExeFile", ctypes.c_wchar * 260)]


_k32 = ctypes.WinDLL("kernel32", use_last_error=True)
_k32.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
_k32.CreateToolhelp32Snapshot.argtypes = [wintypes.DWORD, wintypes.DWORD]
_k32.Process32FirstW.argtypes = _k32.Process32NextW.argtypes = [wintypes.HANDLE, ctypes.POINTER(_Entry)]
_k32.OpenProcess.restype = wintypes.HANDLE
_k32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
_k32.QueryFullProcessImageNameW.argtypes = [wintypes.HANDLE, wintypes.DWORD, wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD)]
_k32.CloseHandle.argtypes = [wintypes.HANDLE]
_INVALID = wintypes.HANDLE(-1).value
_u32 = ctypes.WinDLL("user32")
_u32.GetForegroundWindow.restype = wintypes.HWND
_u32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]


def foreground_pid() -> int:
    """Process that owns the window in front (the one you're playing), 0 if none."""
    hwnd = _u32.GetForegroundWindow()
    if not hwnd:
        return 0
    pid = wintypes.DWORD()
    _u32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
    return pid.value


def processes() -> list[tuple[int, str]]:
    """(pid, lowercase exe name) of every running process."""
    snap = _k32.CreateToolhelp32Snapshot(2, 0)  # TH32CS_SNAPPROCESS
    if not snap or snap == _INVALID:
        return []
    try:
        e, out = _Entry(), []
        e.dwSize = ctypes.sizeof(e)
        ok = _k32.Process32FirstW(snap, ctypes.byref(e))
        while ok:
            out.append((e.th32ProcessID, e.szExeFile.lower()))
            ok = _k32.Process32NextW(snap, ctypes.byref(e))
        return out
    finally:
        _k32.CloseHandle(snap)


def process_path(pid: int) -> str:
    """Full exe path, lowercase with forward slashes; "" when hidden (anti-cheat) or gone."""
    h = _k32.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
    if not h:
        return ""
    try:
        buf, size = ctypes.create_unicode_buffer(1024), wintypes.DWORD(1024)
        ok = _k32.QueryFullProcessImageNameW(h, 0, buf, ctypes.byref(size))
        return buf.value.lower().replace("\\", "/") if ok else ""
    finally:
        _k32.CloseHandle(h)


class Games:
    def __init__(self, cfg: dict, cache_dir: Path):
        self.cfg = cfg
        self.cache = cache_dir / "detectable.json"
        self.by_exe: dict[str, list[tuple[str, str]]] = {}  # exe -> [(game name, path suffix)]
        self.loaded_at = 0.0
        self._paths: dict[int, str] = {}
        self.foreground = ""  # exe of the detected game whose window is in front, "" if none

    def load(self):
        data = None
        if not (self.cache.exists() and time.time() - self.cache.stat().st_mtime < DAY):
            try:
                req = urllib.request.Request(DETECTABLE_URL, headers={"User-Agent": "Ultron game detection"})
                with urllib.request.urlopen(req, timeout=30) as r:
                    raw = r.read()
                data = json.loads(raw)
                self.cache.parent.mkdir(parents=True, exist_ok=True)
                self.cache.write_bytes(raw)
                log.info("Downloaded Discord game list (%d games)", len(data))
            except Exception as e:
                log.warning("Could not download the game list: %s", e)
        if data is None and self.cache.exists():
            data = json.loads(self.cache.read_bytes())

        ignore = {e.lower() for e in self.cfg.get("ignore", [])}
        by_exe: dict[str, list[tuple[str, str]]] = {}

        def add(name: str, exe_path: str):
            suffix = exe_path.lower().replace("\\", "/").lstrip(">")
            base = suffix.rsplit("/", 1)[-1]
            if base.endswith(".exe") and base not in ignore:
                by_exe.setdefault(base, []).append((name, suffix))

        for app in data or []:
            for exe in app.get("executables") or []:
                if exe.get("os") == "win32":
                    add(app["name"], exe["name"])
        for g in self.cfg.get("extra", []):
            if g.get("exe"):
                add(g.get("name") or g["exe"], g["exe"])
        self.by_exe, self.loaded_at = by_exe, time.time()

    def detect(self) -> list[tuple[str, str]]:
        """(game name, exe) of the games running now."""
        if time.time() - self.loaded_at > DAY:
            self.load()
        procs = processes()
        fg = foreground_pid()
        fg_exe = next((exe for pid, exe in procs if pid == fg), "")
        alive = {pid for pid, _ in procs}
        for pid in [p for p in self._paths if p not in alive]:
            del self._paths[pid]
        found, seen = [], set()
        for pid, exe in procs:
            entries = self.by_exe.get(exe)
            if not entries or exe in seen:
                continue
            match = next((e for e in entries if "/" not in e[1]), None)
            if not match:
                if pid not in self._paths:
                    self._paths[pid] = process_path(pid)
                path = self._paths[pid]
                # Anti-cheat protected games (e.g. VALORANT) hide their path; trust the name then.
                match = (next((e for e in entries if path.endswith("/" + e[1]) or path == e[1]), None)
                         if path else entries[0])
            if match:
                found.append((match[0], exe))
                seen.add(exe)
        self.foreground = fg_exe if fg_exe in seen else ""
        return found
