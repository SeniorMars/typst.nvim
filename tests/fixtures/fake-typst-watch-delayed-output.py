#!/usr/bin/env python3
import os
import signal
import sys
import time

running = True


def stop(_signum, _frame):
    global running
    running = False


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)

args = sys.argv[1:]
if "--version" in args:
    print("typst 0.0.0-test")
    sys.exit(0)

main = args[-2] if len(args) >= 2 else "main.typ"
output = args[-1] if len(args) >= 1 else "main.pdf"
release = output + ".release"
wrote_output = False


def emit(text):
    sys.stderr.write(text)
    sys.stderr.flush()


emit(f"watching {main}\nwriting to {output}\n\n[12:00:00] compiling ...\n")
emit("[12:00:00] compiled successfully in 1.00 ms\n")

while running:
    if not wrote_output and os.path.exists(release):
        output_dir = os.path.dirname(output)
        if output_dir:
            os.makedirs(output_dir, exist_ok=True)
        with open(output, "w", encoding="utf-8") as handle:
            handle.write("delayed output\n")
        wrote_output = True
    time.sleep(0.005)

sys.exit(0)
