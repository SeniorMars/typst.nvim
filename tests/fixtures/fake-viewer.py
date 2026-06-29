#!/usr/bin/env python3
import json
import os
import sys


log_path = os.environ.get("TYPST_NVIM_FAKE_VIEWER_LOG")
if log_path:
    parent = os.path.dirname(log_path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(log_path, "w", encoding="utf-8") as handle:
        json.dump(
            {
                "args": sys.argv[1:],
                "cwd": os.getcwd(),
            },
            handle,
        )
