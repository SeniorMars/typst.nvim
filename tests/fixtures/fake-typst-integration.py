#!/usr/bin/env python3
import json
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

mode = args[0] if args else ""
main = args[-2] if len(args) >= 2 else "main.typ"
output = args[-1] if len(args) >= 1 else "main.pdf"
fixture_mode = os.environ.get("TYPST_NVIM_FAKE_TYPST_MODE", "")


def option_value(name):
    if name not in args:
        return None
    index = args.index(name)
    if index + 1 >= len(args):
        return None
    return args[index + 1]


def emit(text):
    sys.stderr.write(text)
    sys.stderr.flush()


def write_output():
    parent = os.path.dirname(output)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(output, "wb") as handle:
        handle.write(b"%PDF-1.4\n% fake typst.nvim integration fixture\n")


def write_deps():
    deps_path = option_value("--deps")
    if not deps_path:
        return
    parent = os.path.dirname(deps_path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    payload = {
        "inputs": [
            main,
            "chapter.typ",
            "assets/image.svg",
            "bib/references.bib",
        ]
    }
    with open(deps_path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle)


if mode == "watch":
    emit(f"watching {main}\nwriting to {output}\n\n[12:00:00] compiling ...\n")
    if fixture_mode == "flood-output":
        for _ in range(1024):
            emit("x" * 1024)
        while running:
            time.sleep(0.05)
        sys.exit(0)

    emit("[12:00:00] compiled successfully in 1.00 ms\n")
    delay_ms = int(os.environ.get("TYPST_NVIM_FAKE_TYPST_DELAY_OUTPUT_MS", "0"))
    if delay_ms > 0:
        time.sleep(delay_ms / 1000.0)
    write_output()
    write_deps()
    while running:
        time.sleep(0.05)
    sys.exit(0)

write_output()
write_deps()
sys.exit(0)
