#!/usr/bin/env python3
import os
import sys


def main():
    args = sys.argv[1:]
    print("fake-tinymist " + "|".join(args))
    if "--coverage" in args:
        coverage_path = os.environ.get("TINYMIST_COVERAGE_PATH")
        if not coverage_path:
            cache_home = os.environ.get("XDG_CACHE_HOME", os.getcwd())
            coverage_path = os.path.join(
                cache_home,
                "typst.nvim",
                "coverage",
                "fake",
                "coverage.json",
            )
        os.makedirs(os.path.dirname(coverage_path), exist_ok=True)
        with open(coverage_path, "w", encoding="utf-8") as handle:
            handle.write("{}\n")
        print(f"Info Written coverage to {coverage_path} ...")
        print("Cov Coverage Summary 1/1 (100.00%)")
    if "--fail" in args:
        print("requested failure", file=sys.stderr)
        return 2
    print("Info All test cases passed...")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
