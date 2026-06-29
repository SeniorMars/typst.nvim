#!/usr/bin/env python3
import os
import signal
import sys
import time

running = True


def record(event):
    marker = os.environ.get("TYPST_NVIM_SLOW_COMPILE_MARKER")
    if not marker:
        return
    parent = os.path.dirname(marker)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(marker, "a", encoding="utf-8") as handle:
        handle.write(f"{event}:{os.getpid()}\n")


def stop(_signum, _frame):
    global running
    record("term")
    running = False
    time.sleep(0.4)


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)

args = sys.argv[1:]
if "--version" in args:
    print("typst 0.0.0-test")
    sys.exit(0)

output = args[-1] if args else None

record("start")

if output:
    parent = os.path.dirname(output)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(output, "wb") as handle:
        handle.write(b"%PDF-1.4\n% fake typst.nvim slow-stop compile fixture\n")

while running:
    time.sleep(0.05)

record("exit")
sys.exit(0)
