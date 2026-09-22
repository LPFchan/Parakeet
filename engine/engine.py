"""Live transcription engine.

Reads mono float32 PCM at 16 kHz from stdin, writes JSON lines to stdout:
  {"partial": "..."}  text that may still change
  {"final": "..."}    text that is locked in
  {"ready": true}     model loaded

Every TICK seconds of new audio, the whole pending buffer is re-transcribed.
Text is locked in when the model's own word timestamps show a pause, when a
new sentence has started, or when the buffer grows past MAX_BUFFER.
"""

import json
import os
import sys
import threading
import time

import numpy as np

# Photon posts usage stats to api.moondream.ai; point it nowhere.
os.environ.setdefault("MOONDREAM_API_BASE_URL", "http://127.0.0.1:9")

import moondream as md  # noqa: E402

SR = 16_000
TICK = 0.2          # seconds of new audio between re-transcriptions
PAUSE = 0.8         # silence after the last word that locks everything in
SETTLE = 1.0        # a sentence must end this long before "now" to lock in
MAX_BUFFER = 20.0   # force a cut in run-on speech
FORCE_KEEP = 3.0    # on a forced cut, keep this much audio unlocked
IDLE_FLUSH = 1.0    # wall-clock seconds without audio before locking in
MARGIN = 0.08       # keep a little audio before a cut (one encoder frame)


class Buffer:
    def __init__(self):
        self.lock = threading.Lock()
        self.chunks = []
        self.closed = False
        self.last_audio = time.monotonic()

    def reader(self, stream):
        while data := stream.read(SR // 10 * 4):
            samples = np.frombuffer(data[: len(data) // 4 * 4], np.float32)
            # Loud mixes and resampling overshoot past full scale; Photon rejects that.
            samples = np.clip(np.nan_to_num(samples), -1.0, 1.0)
            with self.lock:
                self.chunks.append(samples)
                self.last_audio = time.monotonic()
        self.closed = True

    def take(self):
        with self.lock:
            chunks, self.chunks = self.chunks, []
            return chunks, self.last_audio


def emit(**msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def main():
    device = os.environ.get("PARAKEET_DEVICE", "mps")
    speech = md.photon("moondream/parakeet-redux", device=device)
    speech.transcribe(audio=np.zeros(SR, np.float32), sample_rate=SR)  # warm up
    emit(ready=True)

    buf = Buffer()
    threading.Thread(target=buf.reader, args=(sys.stdin.buffer,), daemon=True).start()

    audio = np.zeros(0, np.float32)
    since_tick = 0
    last_partial = ""

    def cut(seconds, margin=MARGIN):
        nonlocal audio
        audio = audio[max(0, int((seconds - margin) * SR)):]

    while True:
        chunks, last_audio = buf.take()
        for c in chunks:
            audio = np.concatenate([audio, c])
            since_tick += len(c)

        idle = time.monotonic() - last_audio > IDLE_FLUSH
        if since_tick < TICK * SR and not (idle and len(audio)):
            if buf.closed and not chunks:
                break
            time.sleep(0.02)
            continue
        since_tick = 0

        dur = len(audio) / SR
        segments = []
        # The tap streams digital silence when nothing plays; don't spin the GPU on it.
        if np.abs(audio).max(initial=0) > 1e-4:
            result = speech.transcribe(audio=audio, sample_rate=SR, timestamps="word")
            segments = [s for s in result["segments"] if s["words"]]

        if not segments:
            # Nothing said yet. Keep enough tail that a sentence which is just
            # starting survives until the model can recognise its first word.
            audio = audio[-int(2.0 * SR):]
            if idle:
                audio = audio[:0]
            if last_partial:
                emit(partial="")
                last_partial = ""
            continue

        last_end = segments[-1]["words"][-1]["end"]

        if idle or dur - last_end >= PAUSE:
            emit(final=" ".join(s["text"] for s in segments))
            # Keep what follows the last word: the next sentence may be starting.
            cut(last_end, margin=0)
        elif len(segments) > 1 and dur - segments[-2]["end"] >= SETTLE:
            emit(final=" ".join(s["text"] for s in segments[:-1]))
            cut(segments[-1]["start"])
        elif dur > MAX_BUFFER:
            words = [w for s in segments for w in s["words"]]
            keep = [w for w in words if w["end"] <= dur - FORCE_KEEP]
            if keep:
                emit(final=" ".join(w["word"] for w in keep))
                cut(keep[-1]["end"])
        else:
            text = " ".join(s["text"] for s in segments)
            if text != last_partial:
                emit(partial=text)
                last_partial = text
            continue
        last_partial = ""

    speech.close()


if __name__ == "__main__":
    main()
