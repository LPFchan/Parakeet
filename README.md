# Parakeet

Live captions for everything your Mac plays, running fully on-device with
[moondream/parakeet-redux](https://huggingface.co/moondream/parakeet-redux).
English only for now (the model covers 25 European languages, no CJK).
macOS 15+, Apple silicon.

## Setup

```sh
uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python "moondream>=2.4.1" numpy
scripts/build-app.sh
open build/Parakeet.app
```

The first launch downloads the model (~180 MB) and asks for permission to
record system audio. Captions appear in a floating box you can drag anywhere,
typing in as they arrive and scrolling up line by line;
the menu bar icon has a Captions on/off switch, Copy Transcript and Quit.

## How it works

- `app/` — Swift menu bar app. Captures all system audio with a Core Audio
  process tap, converts it to 16 kHz mono, and pipes it to the engine.
- `engine/engine.py` — re-transcribes the pending audio every 0.2 s and
  prints JSON lines (`partial` / `final`). Text is locked in when the model's
  word timestamps show a pause, when a new sentence has started, or after 20 s
  of nonstop speech.

Photon's own live mode waits 4 s before its first preview, so the engine runs
its own loop instead. Photon also posts usage counts (no audio or text) to
api.moondream.ai; the engine points that at a dead local address.

### Experimental: Neural Engine build

`scripts/build-app.sh ane` builds `build/Parakeet ANE.app`, which skips Python
and runs the same loop in-process (`app/Sources/Parakeet/AneEngine.swift`)
on [FluidAudio](https://github.com/FluidInference/FluidAudio)'s CoreML
Parakeet TDT v2 (English-only, the original NVIDIA weights, not redux). The
encoder runs on the Neural Engine; the model (~450 MB) downloads on first
launch.

### Experimental: streaming builds

These use models built for live audio: each 0.56 s of sound is processed
once and words are never rewritten, so they use far less CPU (~5–9% of one
core vs ~35%). Text updates every 0.56 s, and numbers come out as words.

- `scripts/build-app.sh nemotron` → `build/Parakeet Nemotron.app`: NVIDIA
  Nemotron Speech Streaming 0.6B, English.
- `scripts/build-app.sh multilingual` → `build/Parakeet Multilingual.app`:
  NVIDIA Nemotron 3.5 ASR, which detects the language on its own (Korean,
  Japanese, English and ~30 more). The model downloads on first launch.

`Parakeet --bench clip.wav [nemotron|auto|ko-KR|…]` plays a 16 kHz float32
WAV into an engine in real time and prints what it heard and its CPU use.

Engine errors go to `~/Library/Logs/Parakeet/engine.log`.

The app runs the engine from this checkout's `.venv`, so rebuild the app if
you move the folder.
