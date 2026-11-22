#!/usr/bin/env python3
"""Label a whisper.cpp transcript with speakers found by pyannote.

usage: diarize.py audio.wav transcript.json [num_speakers]

transcript.json comes from `whisper-cli -ojf -nfa -dtw large.v3.turbo`
(per-word timing; -dtw needs -nfa), or `-ojf` or
`-oj` (per segment). Writes audio.rttm (speaker
turns, reused on the next run) and audio.dia.txt (one paragraph per turn).
Needs HF_TOKEN, or a cached `hf auth login`, with the
pyannote/speaker-diarization-community-1 terms accepted.
"""
import json
import os
import sys


def load_turns(wav, rttm, num_speakers):
    if os.path.exists(rttm):
        turns = []
        with open(rttm) as f:
            for line in f:
                p = line.split()
                start, dur = float(p[3]), float(p[4])
                turns.append((start, start + dur, p[7]))
        return turns

    import torch
    import torchaudio
    from pyannote.audio import Pipeline
    from pyannote.audio.pipelines.utils.hook import ProgressHook

    pipeline = Pipeline.from_pretrained(
        "pyannote/speaker-diarization-community-1",
        token=os.environ.get("HF_TOKEN"))
    waveform, rate = torchaudio.load(wav)
    kw = {"num_speakers": num_speakers} if num_speakers else {}
    with ProgressHook() as hook:
        out = pipeline({"waveform": waveform, "sample_rate": rate},
                       hook=hook, **kw)
    turns = [(t.start, t.end, spk)
             for t, spk in out.exclusive_speaker_diarization]
    with open(rttm, "w") as f:
        for start, end, spk in turns:
            f.write(f"SPEAKER audio 1 {start:.3f} {end - start:.3f} "
                    f"<NA> <NA> {spk} <NA> <NA>\n")
    return turns


def speaker_of(start, end, turns):
    """Speaker with the most overlap; nearest turn when nobody overlaps."""
    best, best_ov = None, 0.0
    for ts, te, spk in turns:
        ov = min(end, te) - max(start, ts)
        if ov > best_ov:
            best, best_ov = spk, ov
    if best is None and turns:
        mid = (start + end) / 2
        best = min(turns, key=lambda t: max(t[0] - mid, mid - t[1]))[2]
    return best or "UNKNOWN"


def words(segs):
    """(text, start, end) per word from `-ojf` tokens, else per segment."""
    for seg in segs:
        if "tokens" not in seg:
            text = seg["text"].strip()
            if text:
                yield (text, seg["offsets"]["from"] / 1000,
                       seg["offsets"]["to"] / 1000)
            continue
        word = None
        for tok in seg["tokens"]:
            if tok["text"].startswith("[_"):
                continue
            t, o = tok["text"], tok["offsets"]
            # -dtw time (centiseconds) beats the segment-guessed offsets
            if tok.get("t_dtw", -1) >= 0:
                o = {"from": tok["t_dtw"] * 10, "to": tok["t_dtw"] * 10}
            if word is None or t.startswith(" "):
                if word and word[0].strip():
                    yield (word[0].strip(), word[1] / 1000, word[2] / 1000)
                word = [t, o["from"], o["to"]]
            else:
                word[0] += t
                word[2] = o["to"]
        if word and word[0].strip():
            yield (word[0].strip(), word[1] / 1000, word[2] / 1000)


def hms(s):
    s = int(s)
    return f"{s // 3600:02d}:{s // 60 % 60:02d}:{s % 60:02d}"


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    wav, js = sys.argv[1], sys.argv[2]
    num_speakers = int(sys.argv[3]) if len(sys.argv) > 3 else None
    base = os.path.splitext(wav)[0]
    turns = load_turns(wav, base + ".rttm", num_speakers)

    with open(js) as f:
        segs = json.load(f)["transcription"]

    paras = []  # [speaker, start_seconds, [texts]]
    for text, start, end in words(segs):
        spk = speaker_of(start, end, turns)
        if paras and paras[-1][0] == spk:
            paras[-1][2].append(text)
        else:
            paras.append([spk, start, [text]])

    with open(base + ".dia.txt", "w") as f:
        for spk, start, texts in paras:
            f.write(f"[{hms(start)}] {spk}: {' '.join(texts)}\n\n")
    print(f"{base}.dia.txt: {len(paras)} turns, "
          f"{len({p[0] for p in paras})} speakers")


if __name__ == "__main__":
    main()
