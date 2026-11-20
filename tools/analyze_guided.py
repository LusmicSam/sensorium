"""Summarise a guided capture (tools/guided.c) step by step.

    python3 -I tools/analyze_guided.py /tmp/guided.log

For each step prints what changed: light, lid, accel/gyro activity, integrated yaw from
devmotion6 and from the raw gyro (settles °/s vs rad/s), cma record types, and any
Touch ID / button events.
"""
import math
import struct
import sys
from collections import Counter, defaultdict

steps, rows = [], []
for line in open(sys.argv[1]):
    p = line.split()
    if not p:
        continue
    if p[0] == "P":
        steps.append((float(p[1]), " ".join(p[3:])))
    else:
        rows.append(p)

def step_of(t):
    k = -1
    for i, (ts, _) in enumerate(steps):
        if t >= ts:
            k = i
    return k

fx = lambda b, o: struct.unpack_from("<i", b, o)[0] / 65536
f32 = lambda b, o: struct.unpack_from("<f", b, o)[0]
per = defaultdict(lambda: defaultdict(list))
def unhex(x):
    try:
        return bytes.fromhex(x)
    except ValueError:
        return b""   # a damaged line (e.g. the capture was stopped mid-write)

for p in rows:
    if len(p) < 2:
        continue
    try:
        kind, t = p[0], float(p[1])
    except ValueError:
        continue
    k = step_of(t)
    if kind == "R":
        page, usage, data = p[2], p[3], unhex(p[5]) if len(p) > 5 else b""
        if (page, usage) == ("FF00", "03") and len(data) >= 18:
            per[k]["accel"].append((t, fx(data, 6), fx(data, 10), fx(data, 14)))
        elif (page, usage) == ("FF00", "09") and len(data) >= 18:
            per[k]["gyro"].append((t, fx(data, 6), fx(data, 10), fx(data, 14)))
        elif (page, usage) == ("0020", "8A") and len(data) >= 3:
            per[k]["lid"].append(data[1] | data[2] << 8)
        elif (page, usage) == ("FF00", "04") and len(data) >= 73:
            per[k]["lux"].append(f32(data, 40))
    elif kind == "V":
        usage, data = p[3], unhex(p[5]) if len(p) > 5 else b""
        if usage == "05" and len(data) >= 52:
            x, y, z, w = struct.unpack_from("<4f", data, 12)
            yaw = math.degrees(math.atan2(2 * (w * z + x * y), 1 - 2 * (y * y + z * z)))
            per[k]["yaw"].append((t, yaw))
        elif usage == "01" and data:
            per[k]["cma"].append(data[0])
    elif kind == "E":
        per[k]["events"].append(f"{p[2]} type {p[3]}")

for i, (_, name) in enumerate(steps):
    d = per[i]
    print(f"\n=== step {i + 1}: {name}")
    if d["lux"]:
        print(f"  light: {min(d['lux']):.1f} .. {max(d['lux']):.1f} lux")
    if d["lid"]:
        print(f"  lid: {min(d['lid'])}° .. {max(d['lid'])}°")
    if d["accel"]:
        mags = [math.sqrt(a * a + b * b + c * c) for _, a, b, c in d["accel"]]
        print(f"  accel |a|: {min(mags):.3f} .. {max(mags):.3f} g  (spread {max(mags) - min(mags):.3f})")
    if len(d["gyro"]) > 1:
        g = d["gyro"]
        integral = [0.0, 0.0, 0.0]
        for (t0, *a), (t1, *_) in zip(g, g[1:]):
            for j in range(3):
                integral[j] += a[j] * (t1 - t0)
        print(f"  gyro integrated over the step (if °/s → degrees): x {integral[0]:+.1f} y {integral[1]:+.1f} z {integral[2]:+.1f}")
    if d["yaw"]:
        ys = [y for _, y in d["yaw"]]
        print(f"  devmotion6 yaw: {ys[0]:+.1f}° → {ys[-1]:+.1f}°  (range {min(ys):+.1f}..{max(ys):+.1f})")
    if d["cma"]:
        print(f"  cma record types: {dict(Counter(f'0x{c:02x}' for c in d['cma']))}")
    if d["events"]:
        print(f"  Touch ID / button events: {dict(Counter(d['events']))}")
    else:
        print("  Touch ID / button events: none")
