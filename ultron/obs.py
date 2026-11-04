"""OBS over obs-websocket: one connection, shared by the game watcher and voice commands."""
import logging
import os
import threading
from urllib.parse import urlparse

log = logging.getLogger("ultron")
logging.getLogger("obsws_python").setLevel(logging.CRITICAL)  # we log failures ourselves


class ObsError(Exception):
    """OBS can't be reached."""


class ObsRequestError(ObsError):
    """OBS answered, but refused the request (missing source, replay buffer disabled, ...)."""


class Obs:
    def __init__(self, url: str):
        u = urlparse(url)
        self.host, self.port = u.hostname or "localhost", u.port or 4455
        self._client = None
        self._lock = threading.Lock()

    @property
    def connected(self) -> bool:
        return self._client is not None

    def _connect(self):
        import obsws_python as obsws
        self._client = obsws.ReqClient(host=self.host, port=self.port, timeout=5,
                                       password=os.environ.get("OBS_WEBSOCKET_PASSWORD", ""))
        log.info("Connected to OBS")

    def _drop(self):
        if self._client:
            try:
                self._client.disconnect()
            except Exception:
                pass
            self._client = None
            log.info("Disconnected from OBS")

    def call(self, request: str, data: dict | None = None) -> dict:
        from obsws_python.error import OBSSDKRequestError
        with self._lock:
            # A connection that went stale (OBS restarted) gets one fresh retry.
            for retry in (self._client is not None, False):
                try:
                    if self._client is None:
                        self._connect()
                    return self._client.send(request, data, raw=True) or {}
                except OBSSDKRequestError as e:
                    raise ObsRequestError(f"{request}: {e.comment or e.code}") from None
                except Exception as e:
                    self._drop()
                    if not retry:
                        raise ObsError(f"OBS not reachable ({type(e).__name__})") from None
