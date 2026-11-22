#!/usr/bin/env python3
"""Audio or video file to a speaker-labelled transcript, raw and clean.

usage: transcribe.py [-n SPEAKERS] [-l LANG] [--no-clean] file [SPEAKER_00=Name ...]

Steps, each skipped when its output already exists:
  ffmpeg      file   -> file.wav       (16 kHz mono)
  whisper-cli wav    -> file.json      (large-v3-turbo, DTW word times)
  diarize.py  json   -> file.dia.txt   (pyannote speaker labels, raw text)
  clean.py    dia    -> file.en.txt    (LLM rewrite, needs llama-server)
Run with the pyannote venv python. WHISPER_MODEL overrides the model path.
"""
import argparse
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MODEL = os.environ.get(
    "WHISPER_MODEL",
    os.path.expanduser("~/models/whisper/ggml-large-v3-turbo.bin"))


def run(cmd):
    print("+", " ".join(cmd), flush=True)
    subprocess.run(cmd, check=True)


def main():
    ap = argparse.ArgumentParser(usage=__doc__)
    ap.add_argument("-n", "--speakers")
    ap.add_argument("-l", "--lang", default="auto")
    ap.add_argument("--no-clean", action="store_true")
    ap.add_argument("file")
    ap.add_argument("names", nargs="*")
    a = ap.parse_args()

    base, ext = os.path.splitext(a.file)
    # never overwrite the input when it is already a wav
    wav = base + (".16k.wav" if ext.lower() == ".wav" else ".wav")
    if not os.path.exists(wav):
        run(["ffmpeg", "-nostdin", "-loglevel", "error", "-i", a.file,
             "-vn", "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", wav])
    wbase = os.path.splitext(wav)[0]
    if not os.path.exists(wbase + ".json"):
        # -mc 0 stops repetition loops; -dtw needs flash attention off
        run(["whisper-cli", "-m", MODEL, "-l", a.lang, "-t", "8", "-np",
             "-mc", "0", "-nfa", "-ojf", "-dtw", "large.v3.turbo",
             "-of", wbase, "-f", wav])
    if not os.path.exists(wbase + ".dia.txt"):
        run([sys.executable, os.path.join(HERE, "diarize.py"), wav,
             wbase + ".json"] + ([a.speakers] if a.speakers else []))
    if not a.no_clean:
        run([sys.executable, os.path.join(HERE, "clean.py"),
             wbase + ".dia.txt"] + a.names)


if __name__ == "__main__":
    main()
