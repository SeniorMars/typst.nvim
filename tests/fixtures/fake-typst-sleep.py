#!/usr/bin/env python3
import signal
import sys
import time


def stop(_signum, _frame):
    sys.exit(143)


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)

time.sleep(60)
