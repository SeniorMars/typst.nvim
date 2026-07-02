#!/usr/bin/env python3
import json
import os
import signal
import sys


def stop(_signum, _frame):
    sys.exit(143)


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)

args = sys.argv[1:]
if "--version" in args:
    print("typst 0.0.0-test")
    sys.exit(0)

main = args[-2] if len(args) >= 2 else "main.typ"
output = args[-1] if len(args) >= 1 else "main.pdf"
schema = os.environ.get("TYPST_NVIM_FAKE_DEPS_SCHEMA", "valid")


def option_value(name):
    if name not in args:
        return None
    index = args.index(name)
    if index + 1 >= len(args):
        return None
    return args[index + 1]


def write_output():
    parent = os.path.dirname(output)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(output, "wb") as handle:
        handle.write(b"%PDF-1.4\n% fake typst.nvim deps schema fixture\n")


def write_deps():
    deps_path = option_value("--deps")
    if not deps_path:
        return
    parent = os.path.dirname(deps_path)
    if parent:
        os.makedirs(parent, exist_ok=True)

    if schema == "malformed":
        with open(deps_path, "w", encoding="utf-8") as handle:
            handle.write('{"inputs": [')
        return

    if schema == "missing-inputs":
        payload = {
            "outputs": ["ignored-output.pdf"],
            "future": {"inputs": ["ignored.typ"]},
        }
    elif schema == "invalid-inputs":
        payload = {"inputs": "chapter.typ"}
    else:
        payload = {
            "inputs": [
                main,
                "chapter.typ",
                "assets/image.svg",
                "chapter.typ",
            ],
            "outputs": ["ignored-output.pdf"],
            "future": {"path": "ignored.typ"},
        }

    with open(deps_path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle)


write_output()
write_deps()
sys.exit(0)
