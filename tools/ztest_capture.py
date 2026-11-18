#!/usr/bin/env python3
"""Capture a ztest run until "PROJECT EXECUTION" (or a timeout) and save it.

Usage: ztest_capture.py SECONDS OUTFILE [PORT]   (default port /dev/ttyACM0)
Prints a one-line pass/fail summary and the failing test cases.
"""
import re
import sys
import time

import serial

secs = float(sys.argv[1])
out = sys.argv[2]
port = sys.argv[3] if len(sys.argv) > 3 else "/dev/ttyACM0"

ser = serial.Serial(port, 115200, timeout=0.1)
data = b""
t0 = time.time()
while time.time() - t0 < secs:
    data += ser.read(4096)
    if b"PROJECT EXECUTION" in data:
        time.sleep(0.5)
        data += ser.read(4096)
        break
open(out, "wb").write(data)

text = re.sub(r"\x1b\[[0-9;]*m", "", data.decode(errors="replace"))
# Count only the last boot: the port can also hold lines from the previously flashed image
# (no banner in front of them) or from an extra reset.
boots = text.count("*** Booting Zephyr")
if boots:
    text = text[text.rindex("*** Booting Zephyr"):]
if boots > 1:
    print(f"note: {boots} boots in the capture, counting the last one")
passed = len(re.findall(r"^ - PASS - ", text, re.M))
failed = re.findall(r"^ - FAIL - (\[[^\]]+\])", text, re.M)
result = re.search(r"PROJECT EXECUTION \w+", text)
print(f"{passed} pass, {len(failed)} fail, {result.group(0) if result else 'NO RESULT'}")
for f in failed:
    print("  FAIL", f)
for a in re.findall(r"Assertion failed at .*", text):
    print("  ", a.strip())
