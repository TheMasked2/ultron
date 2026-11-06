import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def load(path: Path = ROOT / "config.toml") -> dict:
    # utf-8-sig: the installer may save the file with a byte order mark.
    return tomllib.loads(path.read_text(encoding="utf-8-sig"))
