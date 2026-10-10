#!/usr/bin/env python3
# workflow-dev — a persistent-context development workflow for Claude Code
# Copyright (C) 2026  lbecjx
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See LICENSE for the full text.
#
# Generates the nine sounds scripts/attention-alert.sh plays (WD-0052).
# Kept for provenance only: the .wav files are committed, and neither CI nor any
# test runs this file, so the plugin never needs Python or a speech engine at
# runtime.
#
#   attention-need.wav        "I need your input."       workflow-dev waits on your answer
#   attention-away.wav        "Hello? Are you there?" … "I need your input."
#                                                        the same, mid autonomous run
#   attention-permission.wav  "I need your permission."  a permission dialog is open
#   attention-commit.wav      "Ready to commit."         commit/PR text waits for a yes
#   attention-pr.wav          "Pull request created!"    the PR is open
#   attention-done.wav        "Task completed."          something is ready to review
#   attention-passed.wav      "Validation passed."       the quality gate passed
#   attention-fail.wav        "Something went wrong."    a check failed or the run is stuck
#   attention-story.wav       fanfare + "Congrats! Story complete."   the story is done
#
# The voice is Piper's `en_GB-cori-high` (rhasspy/piper-voices on Hugging Face):
# its MODEL_CARD states the dataset license as public domain (LibriVox
# recordings), trained from scratch, and its author publishes the model as
# public domain. Voices fine-tuned from `lessac` were rejected: that dataset's
# license restricts use. The fanfare is our own synthesis, under this repo's
# license.
#
# To regenerate (Piper 1.8.0):
#   python3 -m venv /tmp/piper && /tmp/piper/bin/pip install piper-tts==1.8.0
#   /tmp/piper/bin/python -m piper.download_voices --download-dir /tmp/voices en_GB-cori-high
#   /tmp/piper/bin/python assets/make-attention-sounds.py /tmp/voices/en_GB-cori-high.onnx

import math
import shutil
import struct
import sys
import tempfile
import wave
from pathlib import Path

RATE = 22050
HERE = Path(__file__).resolve().parent

# Slower and softer than Piper's defaults: a calm voice, not an alarm.
LENGTH_SCALE = 1.25
NOISE_SCALE = 0.5
VOLUME = 0.9

PHRASES = {
    "attention-need": "I need your input.",
    "away-call": "Hello? Are you there?",
    "attention-permission": "I need your permission.",
    "attention-commit": "Ready to commit.",
    "attention-pr": "Pull request created!",
    "attention-done": "Task completed.",
    "attention-passed": "Validation passed.",
    "attention-fail": "Something went wrong.",
    "story-voice": "Congrats! Story complete.",
}

# Rising fanfare: C5 E5 G5, then a held C major chord an octave up.
FANFARE = [  # (start s, [frequencies Hz], length s)
    (0.00, [523.25], 0.14),
    (0.12, [659.25], 0.14),
    (0.24, [783.99], 0.14),
    (0.38, [1046.50, 1318.51, 1567.98], 0.90),
]
FANFARE_SECONDS = 1.35


def fanfare_samples():
    def tone(freq, t):
        # Odd harmonics, fading with order: a soft brass colour.
        return sum(math.sin(2 * math.pi * freq * k * t) / k for k in (1, 3, 5)) * 0.8

    out = []
    for i in range(int(RATE * FANFARE_SECONDS)):
        t = i / RATE
        v = 0.0
        for start, freqs, length in FANFARE:
            local = t - start
            if 0 <= local < length:
                env = min(1.0, local / 0.01) * math.exp(-local * (2.5 if length > 0.5 else 6.0))
                v += env * sum(tone(f, local) for f in freqs) / len(freqs)
        out.append(v)
    peak = max(abs(x) for x in out) or 1.0
    return [x / peak * 0.5 for x in out]


def render_voice(model):
    from piper import PiperVoice, SynthesisConfig
    import piper.phonemize_espeak as pe

    # espeak-ng keeps its data path in a short fixed buffer: copy the data to a
    # short temp path before loading.
    short = Path(tempfile.mkdtemp(prefix="esd", dir="/tmp")) / "d"
    shutil.copytree(pe.ESPEAK_DATA_DIR, short)
    try:
        voice = PiperVoice.load(model, espeak_data_dir=short)
        cfg = SynthesisConfig(length_scale=LENGTH_SCALE, noise_scale=NOISE_SCALE, volume=VOLUME)
        clips = {}
        for name, text in PHRASES.items():
            tmp = short.parent / f"{name}.wav"
            with wave.open(str(tmp), "wb") as w:
                voice.synthesize_wav(text, w, syn_config=cfg)
            with wave.open(str(tmp)) as w:
                assert w.getframerate() == RATE and w.getsampwidth() == 2 and w.getnchannels() == 1
                clips[name] = w.readframes(w.getnframes())
        return clips
    finally:
        shutil.rmtree(short.parent)


def write(name, frames):
    with wave.open(str(HERE / f"{name}.wav"), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(frames)


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: make-attention-sounds.py <path to en_GB-cori-high.onnx>")
    clips = render_voice(sys.argv[1])
    # Spoken as one sentence the question's rising tone ran into the request and
    # sounded wrong; two clips with a pause read as someone calling, then asking.
    pause = b"\0\0" * int(RATE * 0.45)
    write("attention-away", clips["away-call"] + pause + clips["attention-need"])
    for name in ("attention-need", "attention-permission", "attention-commit", "attention-pr", "attention-done", "attention-passed", "attention-fail"):
        write(name, clips[name])
    fanfare = b"".join(struct.pack("<h", int(round(x * 32767))) for x in fanfare_samples())
    gap = b"\0\0" * int(RATE * 0.05)
    write("attention-story", fanfare + gap + clips["story-voice"])


if __name__ == "__main__":
    main()
