#!/usr/bin/env python3
"""
Generate a deterministic coding-style prompt for bench_model.py.

The recipe is a header line, a sequence of trivial `fn_NNNN(x): return x + N`
functions, and a single trailing question. With the Qwen3.6 tokenizer, the
body costs ~17.9 tokens per function. Use -n to dial the prompt size:

  -n 215   -> ~4 067  tokens   (default; matches tools/coding_prompt.txt)
  -n 1700  -> ~30 400 tokens   (matches tools/coding_prompt_32k.txt)
  -n 5105  -> ~91 380 tokens   (matches tools/coding_prompt_96k.txt)
  -n 6395  -> ~114 480 tokens  (matches tools/coding_prompt_120k.txt)
"""
import argparse
import sys


def build(n: int) -> str:
    parts = ["You are a coding assistant. Below is some code.\n\n"]
    for i in range(n):
        parts.append(f"def fn_{i:04d}(x):\n    return x + {i}\n")
    parts.append("\nDescribe the pattern in one sentence.")
    return "".join(parts)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-n", "--functions", type=int, default=215,
                    help="number of fn_NNNN definitions to emit (default: 215)")
    ap.add_argument("-o", "--output", default="-",
                    help="output file (default: stdout)")
    args = ap.parse_args()

    text = build(args.functions)
    if args.output == "-":
        sys.stdout.write(text)
    else:
        with open(args.output, "w") as f:
            f.write(text)


if __name__ == "__main__":
    main()
