# Per-stream byte statistics + candidate field decodes from a spudump log.
import sys, struct, statistics as st
from collections import defaultdict
rows = defaultdict(list)
for line in open(sys.argv[1]):
    p = line.split()
    if p[0] != "R": continue
    rows[(p[2], p[3])].append((float(p[1]), bytes.fromhex(p[5])))
want = sys.argv[2:] or None
for (page, usage), rs in sorted(rows.items()):
    key = f"{page}/{usage}"
    if want and key not in want: continue
    n = len(rs); L = len(rs[0][1]); dur = rs[-1][0] - rs[0][0]
    print(f"\n=== {key}  reports={n}  len={L}  rate={n/dur if dur else 0:.1f}/s")
    for t, b in rs[:3]: print("   ", " ".join(f"{x:02x}" for x in b[:48]))
    varying = []
    for i in range(L):
        vals = [b[i] for _, b in rs if len(b) > i]
        if len(set(vals)) > 1: varying.append(i)
    print("   varying byte offsets:", varying)
    # candidate int32 / int16 / float fields at 2-aligned offsets among varying region
    for off in range(0, L - 1):
        for fmt, size, nm in (("<i", 4, "i32"), ("<h", 2, "i16"), ("<f", 4, "f32")):
            if off + size > L: continue
            vs = [struct.unpack_from(fmt, b, off)[0] for _, b in rs if len(b) >= off + size]
            if len(set(vs)) < 2: continue
            if nm == "f32" and not all(abs(v) < 1e6 and v == v for v in vs): continue
            d = [b - a for a, b in zip(vs, vs[1:])]
            mono = all(x >= 0 for x in d) or all(x <= 0 for x in d)
            if off in varying:
                print(f"    @{off:<3}{nm}: min={min(vs):.4g} max={max(vs):.4g} mean={st.mean(vs):.4g} sd={st.pstdev(vs):.3g}{'  MONOTONIC' if mono else ''}")
