#!/usr/bin/env python3
"""Capture the check app output until its final line (or a timeout).

Usage: run.py [seconds] [port]   (defaults: 50, /dev/ttyACM0)
"""
import sys
import time

import serial

secs = float(sys.argv[1]) if len(sys.argv) > 1 else 50
port = sys.argv[2] if len(sys.argv) > 2 else "/dev/ttyACM0"

ser = serial.Serial(port, 115200, timeout=0.1)
data = b""
t0 = time.time()
while time.time() - t0 < secs:
    data += ser.read(4096)
    if b"=== uart dma check:" in data and data.count(b"===") >= 4:
        break
print(data.decode(errors="replace"))
