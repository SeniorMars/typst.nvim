#!/usr/bin/env python3
import os
import sys

args = sys.argv[1:]
if "--version" in args:
    print("typst 0.0.0-test")
    sys.exit(0)

mode = args[0] if args else ""
main = args[-2] if len(args) >= 2 else "main.typ"
output = args[-1] if len(args) >= 1 else "main.pdf"


def emit(text):
    sys.stderr.write(text)
    sys.stderr.flush()


def write_output():
    parent = os.path.dirname(output)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(output, "wb") as handle:
        handle.write(b"%PDF-1.4\n% fake typst.nvim partial watch-exit fixture\n")


write_output()

if mode != "watch":
    sys.exit(0)

emit(f"watching {main}\nwriting to {output}\n\n[12:00:00] compiling ...\n")
emit("[12:00:00] compiled successfully in 1.00 ms")
sys.exit(0)
