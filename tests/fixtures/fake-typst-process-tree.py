#!/usr/bin/env python3
import json
import os
import signal
import subprocess
import sys
import time


def stop(_signum, _frame):
    sys.exit(143)


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)


def child():
    while True:
        time.sleep(1)


def output_path(argv):
    if len(argv) >= 3:
        return argv[-1]
    return None


def main():
    if "--child" in sys.argv:
        child()
        return

    child_proc = subprocess.Popen([sys.executable, __file__, "--child"])
    marker = os.environ.get("TYPST_NVIM_PROCESS_TREE_MARKER")
    if marker:
        os.makedirs(os.path.dirname(marker), exist_ok=True)
        with open(marker, "w", encoding="utf-8") as handle:
            json.dump({"parent": os.getpid(), "child": child_proc.pid}, handle)

    output = output_path(sys.argv)
    if output:
        os.makedirs(os.path.dirname(output), exist_ok=True)
        with open(output, "w", encoding="utf-8") as handle:
            handle.write("fake output\n")

    print("[00:00:00] compiling ...", flush=True)
    print("[00:00:00] compiled successfully", flush=True)

    while True:
        time.sleep(1)


if __name__ == "__main__":
    main()
