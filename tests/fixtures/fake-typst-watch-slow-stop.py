#!/usr/bin/env python3
import os
import signal
import sys
import time

running = True


def stop(_signum, _frame):
    global running
    running = False
    time.sleep(0.4)


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)

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
        handle.write(b"%PDF-1.4\n% fake typst.nvim slow-stop watch fixture\n")


def record_start():
    marker = os.environ.get("TYPST_NVIM_SLOW_WATCH_MARKER")
    if not marker:
        return
    parent = os.path.dirname(marker)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(marker, "a", encoding="utf-8") as handle:
        handle.write(f"{os.getpid()}\n")


if mode != "watch":
    write_output()
    sys.exit(0)

record_start()
emit(f"watching {main}\nwriting to {output}\n\n[12:00:00] compiling ...\n")
write_output()
emit("[12:00:00] compiled successfully in 1.00 ms\n")

while running:
    time.sleep(0.05)

sys.exit(0)
