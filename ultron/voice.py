"""Listening: wake word, then a short command. Ultron answers with tones, not speech."""
import collections
import logging
import queue

from .config import ROOT

log = logging.getLogger("ultron")
RATE = 16000
FRAME = 1280  # 80 ms, the chunk size openWakeWord expects


class TextIO:
    """Type commands instead of speaking (for testing without a mic)."""

    def wait(self):
        pass

    def hear(self) -> str:
        return input("you> ").strip()

    def tone(self, kind: str):
        print(f"[{kind} tone]")


def skip_unused_imports():
    """Cut startup from ~55 s to a few: openWakeWord imports scikit-learn (~30 s) for
    custom verifier training, and faster-whisper imports PyAV (~17 s) to decode audio
    files. Ultron uses neither: it passes raw microphone audio."""
    import sys
    import types
    if "openwakeword" not in sys.modules:
        stub = types.ModuleType("openwakeword.custom_verifier_model")
        stub.train_custom_verifier = None
        sys.modules["openwakeword.custom_verifier_model"] = stub
    sys.modules.setdefault("av", types.ModuleType("av"))


def wake_model(cfg: dict) -> str:
    """A trained model in models/wake/<name>.onnx, else a built-in openWakeWord one."""
    name = cfg["wake"]["model"]
    path = ROOT / "models" / "wake" / f"{name}.onnx"
    if path.is_file():
        return str(path)
    fallback = cfg["wake"].get("fallback", "hey_jarvis")
    if name != fallback:
        log.warning("wake word model %s not found, using %s", path, fallback)
    return fallback


class VoiceIO(TextIO):
    # (frequency Hz, seconds) per note
    TONES = {"wake": [(880, 0.08)], "ok": [(660, 0.07), (990, 0.1)], "no": [(330, 0.09), (220, 0.14)]}

    def __init__(self, cfg: dict):
        skip_unused_imports()
        import numpy as np
        import sounddevice as sd
        from faster_whisper import WhisperModel
        from openwakeword.model import Model

        self.np, self.sd = np, sd
        self.audio, self.stt_cfg = cfg["audio"], cfg["stt"]
        self.threshold = cfg["wake"]["threshold"]
        self.volume = max(0, min(100, int(self.audio.get("tone_volume", 15)))) / 100
        self.wake = Model(wakeword_models=[wake_model(cfg)], inference_framework="onnx")
        self.stt = WhisperModel(self.stt_cfg["model"], device="cpu", compute_type="int8",
                                cpu_threads=self.stt_cfg["cpu_threads"])
        self.q: queue.Queue = queue.Queue()
        self.stream = sd.InputStream(
            samplerate=RATE, channels=1, dtype="int16", blocksize=FRAME,
            device=self.audio["input_device"] or None,
            callback=lambda indata, *_: self.q.put(indata[:, 0].copy()),
        )
        self.stream.start()

    def tone(self, kind: str):
        np, rate = self.np, 44100
        parts = []
        for freq, sec in self.TONES[kind]:
            t = np.arange(int(rate * sec)) / rate
            note = np.sin(2 * np.pi * freq * t)
            fade = np.minimum(1, np.minimum(t, sec - t) / 0.01)  # no clicks
            parts.append(note * fade)
        # Not blocking: after the wake tone the command may already be arriving.
        self.sd.play((np.concatenate(parts) * self.volume).astype(np.float32), rate)

    def wait(self):
        self.wake.reset()
        while True:
            if max(self.wake.predict(self.q.get()).values()) >= self.threshold:
                self.wake.reset()
                self.tone("wake")
                return

    def hear(self) -> str:
        np = self.np
        per_frame = FRAME / RATE
        preroll = collections.deque(maxlen=4)
        frames, started, silent, elapsed = [], False, 0.0, 0.0
        while True:
            frame = self.q.get()
            elapsed += per_frame
            loud = np.sqrt(np.mean(frame.astype(np.float32) ** 2)) > self.audio["silence_rms"]
            if loud and not started:
                started = True
                frames.extend(preroll)
            if started:
                frames.append(frame)
                silent = 0.0 if loud else silent + per_frame
                if silent >= self.audio["end_silence_sec"] or elapsed >= self.audio["max_utterance_sec"]:
                    break
            else:
                preroll.append(frame)
                if elapsed >= self.audio["no_speech_timeout_sec"]:
                    return ""
        audio = np.concatenate(frames).astype(np.float32) / 32768
        segments, _ = self.stt.transcribe(audio, language="en", beam_size=1, vad_filter=True)
        return " ".join(s.text.strip() for s in segments).strip()
