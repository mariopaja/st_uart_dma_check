#!/usr/bin/env python3
"""Capture samples/drivers/uart/async_api built with CONFIG_LOG=n and check its packets.

Usage: sample_capture.py SECONDS OUTFILE [PORT]   (default port /dev/ttyACM0)
With logging off, every console line must be "Loop N: Packet: M" and each loop's packets
must be numbered 0..n-1 without gaps.
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
text = data.decode(errors="replace")
open(out, "w").write(text)

# The board may be reset more than once while the port is open (flash, then a capture reset):
# check only the output of the last boot.
boots = text.count("*** Booting Zephyr")
if boots > 1:
    text = text[text.rindex("*** Booting Zephyr"):]
    print(f"note: {boots} boots in the capture, checking the last one")

good = re.findall(r"^Loop (\d+): Packet: (\d+)\r?$", text, re.M)
lines = [l for l in text.splitlines() if l.strip() and "Booting" not in l]
bad = [l for l in lines if not re.match(r"^Loop \d+: Packet: \d+\r?$", l)]
loops = {}
for l, p in good:
    loops.setdefault(int(l), []).append(int(p))
gaps = {l: v for l, v in loops.items() if v != list(range(len(v)))}
print(f"good={len(good)} bad_lines={len(bad)} loops={len(loops)} loops_with_gaps={len(gaps)}")
for b in bad[:6]:
    print("  bad:", repr(b))
for l, v in list(gaps.items())[:6]:
    print("  gap: loop", l, v)
