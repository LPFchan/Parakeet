# Parakeet

Live captions for everything your Mac plays, running fully on-device with
[moondream/parakeet-redux](https://huggingface.co/moondream/parakeet-redux)
or one of the other speech models listed below.
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
the menu bar icon has a Captions on/off switch, a Model picker, Copy
Transcript and Quit.

The same controls work from a terminal, without touching the menu:

```sh
alias parakeet="$PWD/build/Parakeet.app/Contents/MacOS/Parakeet"
parakeet status
parakeet captions on|off
parakeet model redux|ane|nemotron|multilingual
```

## Models

| Model | Runs on | CPU | Notes |
| --- | --- | --- | --- |
| `redux` | GPU (Python) | ~35% | moondream/parakeet-redux; English |
| `ane` | Neural Engine | ~35% | Parakeet TDT v2 (original NVIDIA weights); English |
| `nemotron` | Neural Engine | ~5% | Nemotron Speech Streaming; English |
| `multilingual` | Neural Engine | ~9% | Nemotron 3.5 ASR; detects the language (Korean, Japanese, English and ~30 more) |

The two Parakeet models re-read the last few seconds every 0.2 s, which keeps
their text clean but costs CPU. The Nemotron models are built for live audio:
each 0.56 s of sound is processed once and words are never rewritten, so they
are far cheaper, but text updates every 0.56 s and numbers come out as words.
The Neural Engine models run in-process via
[FluidAudio](https://github.com/FluidInference/FluidAudio) and download on
first use. The default is `multilingual`; the choice is remembered.

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

`Parakeet --bench clip.wav [nemotron|auto|ko-KR|…]` plays a 16 kHz float32
WAV into an engine in real time and prints what it heard and its CPU use
(no model argument = `ane`).

Engine errors go to `~/Library/Logs/Parakeet/engine.log`.

The `redux` model runs from this checkout's `.venv`, so rebuild the app if
you move the folder.
