import json
import os
import pathlib
import sys
import time


def main():
    mode = sys.argv[1]
    main_path = sys.argv[2]
    output_path = sys.argv[3]
    root = sys.argv[4]
    profile = sys.argv[5] if len(sys.argv) > 5 else ""
    provider = sys.argv[6] if len(sys.argv) > 7 and sys.argv[6] in {"generic", "task"} else ""
    marker = sys.argv[-1] if len(sys.argv) > 6 else ""
    stdin_text = sys.stdin.read() if main_path == "-" else ""

    output = pathlib.Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(f"{mode}:{pathlib.Path(main_path).name}:{profile}\n", encoding="utf-8")

    if marker:
        pathlib.Path(marker).write_text(
            json.dumps(
                {
                    "argv": sys.argv[1:],
                    "cwd": os.getcwd(),
                    "root": root,
                    "output": output_path,
                    "provider": provider,
                    "stdin": stdin_text,
                },
                ensure_ascii=False,
            ),
            encoding="utf-8",
        )

    if mode == "watch":
        time.sleep(60)


if __name__ == "__main__":
    main()
