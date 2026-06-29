#!/usr/bin/env python3
import sys


def main():
    args = sys.argv[1:]
    print("fake-crityp " + "|".join(args))
    if "--fail" in args:
        print("benchmark failure", file=sys.stderr)
        return 2
    print("Benchmark Summary 1 benchmark")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
