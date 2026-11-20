# Probe tools

Small standalone programs used to discover what the hardware exposes. Build any of them with:

```bash
clang -O1 -o /tmp/<name> tools/<name>.c -framework CoreFoundation -framework IOKit
```

| Tool | What it does |
|---|---|
| `probe.c` | Trackpad touch frames via MultitouchSupport: `probe <seconds>` |
| `keyprobe.c` | Keyboard: Input Monitoring status, HID elements, key down/up with hold times |
| `sensorprobe.c` | Event-system temps/rails/light, every SPU stream for 1.5 s, `--haptic` fires the motor |
| `spudump.c` | Raw capture of all SPU reports + Touch ID/button events: `spudump 5 --guided > guided.log` |
| `analyze.py` | Per-byte statistics and field guesses for a spudump log: `python3 -I analyze.py guided.log FF00/05` |
| `hid_decode.py` | Decodes a HID report descriptor (hex) into fields |
| `guided.c` | Records every stream (SPU reports, devmotion6/cma events, Touch ID/button events) through 7 prompted 6-second steps. Build line is in the file header. |
| `analyze_guided.py` | Per-step summary of a guided capture: light, lid, motion spread, integrated gyro vs devmotion6 yaw, cma record types, Touch ID events |
| `make_icon.swift` | Draws the app icon and writes `Resources/AppIcon.icns` |
