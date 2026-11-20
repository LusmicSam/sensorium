# Minimal HID report-descriptor decoder: prints each input field with its
# usage page, usage range, logical min/max, bit size and count.
import sys
raw = bytes.fromhex(open(sys.argv[1]).read().strip())
TAGS = {(0,0x8):"Input",(0,0x9):"Output",(0,0xB):"Feature",(0,0xA):"Collection",(0,0xC):"EndCollection",
        (1,0x0):"UsagePage",(1,0x1):"LogicalMin",(1,0x2):"LogicalMax",(1,0x7):"ReportSize",
        (1,0x8):"ReportID",(1,0x9):"ReportCount",(2,0x0):"Usage",(2,0x1):"UsageMin",(2,0x2):"UsageMax"}
g = {}; local = {}; i = 0
while i < len(raw):
    b = raw[i]; size = [0,1,2,4][b & 3]; typ = (b >> 2) & 3; tag = b >> 4
    data = int.from_bytes(raw[i+1:i+1+size], "little"); i += 1 + size
    name = TAGS.get((typ, tag), f"t{typ}/{tag:x}")
    if name in ("UsagePage","LogicalMin","LogicalMax","ReportSize","ReportID","ReportCount"): g[name] = data
    elif name in ("Usage","UsageMin","UsageMax"): local.setdefault(name, []).append(data)
    elif name in ("Input","Feature","Output"):
        kind = "array" if not (data & 2) else "variable"
        const = " (padding)" if data & 1 else ""
        u = local.get("Usage") or (local.get("UsageMin", [None])[:1] + local.get("UsageMax", [None])[:1])
        print(f"{name:7} id={g.get('ReportID','-')} page=0x{g.get('UsagePage',0):X} usages={[hex(x) if x is not None else None for x in u]} "
              f"logical={g.get('LogicalMin')}..{g.get('LogicalMax')} bits={g.get('ReportSize')} x{g.get('ReportCount')} {kind}{const}")
        local = {}
    elif name in ("Collection","EndCollection"): local = {}
