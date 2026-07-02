#!/usr/bin/env python3
import os
import signal
import sys
import time

running = True
mode = ""


def record(event):
    marker = os.environ.get("TYPST_NVIM_RACE_MARKER")
    if not marker:
        return
    parent = os.path.dirname(marker)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(marker, "a", encoding="utf-8") as handle:
        handle.write(f"{event}:{os.getpid()}\n")


def stop(_signum, _frame):
    global running
    record(f"{mode}-term")
    running = False
    time.sleep(0.25)


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)

args = sys.argv[1:]
if "--version" in args:
    print("typst 0.0.0-test")
    sys.exit(0)

mode = args[0] if args else "compile"
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
        handle.write(b"%PDF-1.4\n% fake typst.nvim race fixture\n")


if mode == "watch":
    record("watch-start")
    emit(f"watching {main}\nwriting to {output}\n\n[12:00:00] compiling ...\n")
    write_output()
    emit("[12:00:00] compiled successfully in 1.00 ms\n")
else:
    mode = "compile"
    record("compile-start")
    write_output()

while running:
    time.sleep(0.05)

record(f"{mode}-exit")
sys.exit(0)
