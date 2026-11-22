#!/usr/bin/env python3
"""Rewrite a diarized transcript (diarize.py output) as clean English.

usage: clean.py talk.dia.txt [SPEAKER_00=Name ...]

Sends the turns in chunks to an OpenAI-compatible server (llama-server,
e.g. started by llmsrv.sh) and writes talk.en.txt. Every chunk must come
back with the same speaker labels in the same order, else its raw text is
kept and a warning printed. LLM_URL overrides http://127.0.0.1:8080/v1.
"""
import json
import os
import re
import sys
import urllib.request

URL = os.environ.get("LLM_URL", "http://127.0.0.1:8080/v1")
CHUNK_WORDS = 1500
TURN = re.compile(r"^\[(\d\d:\d\d:\d\d)\] ([^:]+): ?(.*)$")

PROMPT = """You are a copy editor. Below are turns of a spoken interview \
transcribed by speech recognition, one turn per line as \
"[hh:mm:ss] SPEAKER: text".

Rewrite the text of each turn as correct written English:
- fix punctuation, capitalization, spelling and grammar;
- drop filler words (um, uh, like, you know) and stutter repeats;
- fix obvious mis-heard words from context, keep names as heard;
- keep the speaker's meaning, tone and first person; do not summarize, \
add, merge, split or reorder turns.

Return exactly the same number of lines, each starting with the same \
"[hh:mm:ss] SPEAKER:" prefix as the input, and nothing else."""


def parse(path):
    turns = []
    with open(path) as f:
        for line in f:
            m = TURN.match(line.strip())
            if m:
                turns.append(list(m.groups()))
    return turns


def chunks(turns):
    out, n = [], 0
    for t in turns:
        out.append(t)
        n += len(t[2].split())
        if n >= CHUNK_WORDS:
            yield out
            out, n = [], 0
    if out:
        yield out


def ask(model, text):
    body = {
        "model": model,
        "messages": [{"role": "system", "content": PROMPT},
                     {"role": "user", "content": text}],
        "temperature": 0.2,
        "chat_template_kwargs": {"enable_thinking": False},
    }
    req = urllib.request.Request(
        URL + "/chat/completions", json.dumps(body).encode(),
        {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=1800) as r:
        return json.load(r)["choices"][0]["message"]["content"]


def edit(model, chunk):
    """Edited copy of chunk, or None if the labels do not come back."""
    text = "\n".join(f"[{ts}] {spk}: {t}" for ts, spk, t in chunk)
    for _ in range(2):
        got = [TURN.match(l.strip()) for l in ask(model, text).splitlines()]
        got = [m.groups() for m in got if m]
        if [g[:2] for g in got] == [tuple(c[:2]) for c in chunk]:
            return [list(g) for g in got]
    return None


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    src = sys.argv[1]
    names = dict(a.split("=", 1) for a in sys.argv[2:])
    turns = parse(src)
    with urllib.request.urlopen(URL + "/models", timeout=10) as r:
        model = json.load(r)["data"][0]["id"]

    done = []
    for i, chunk in enumerate(chunks(turns)):
        print(f"chunk {i}: {chunk[0][0]}, {len(chunk)} turns", flush=True)
        got = edit(model, chunk)
        if got is None:
            print(f"  warning: labels changed, kept raw text", flush=True)
            got = chunk
        done += got

    dst = re.sub(r"(\.dia)?\.txt$", "", src) + ".en.txt"
    with open(dst, "w") as f:
        for ts, spk, text in done:
            f.write(f"[{ts}] {names.get(spk, spk)}: {text}\n\n")
    print(f"{dst}: {len(done)} turns, model {model}")


if __name__ == "__main__":
    main()
