# Sensorium

A native macOS app that shows what the hidden hardware in an Apple-silicon MacBook is doing, and turns
the trackpad into a programmable controller.

- **Trackpad**: every finger's position, contact shape and real force (the Force Touch sensors), 100+ frames/s.
- **Keyboard rhythm**: hold and gap times, typing speed.
- **Motion**: accelerometer, gyroscope, vibration/tap detection, and the fused orientation the motion
  coprocessor computes (a stream normal apps never see).
- **Light**: lux, colour temperature and CIE XYZ colour from the ambient light sensor, plotted on a
  chromaticity diagram; lid angle; 60+ temperature sensors; battery and power rails; Touch ID status.
- **Trackpad gestures** (background service): slide on the left edge for brightness, right edge for volume;
  record your own taps, rhythms, swipes, hard presses, flat-finger touches and drawn letters, and bind them
  to tasks (open apps/files/URLs, run commands, open Terminal in the current Finder folder, …).
- **Menu bar popover**, **desktop widgets**, **No Sleep** (wraps `caffeinate`), haptic motor control.

Built with SwiftUI and a small C layer, using Swift Package Manager and the Command Line Tools (no Xcode).

## Run

```bash
./run.sh
```

Builds the app and its background helper, installs `Sensorium.app` to `~/Applications` and launches it.
The gesture service is started from **Trackpad Gestures → Run in background** (a per-user LaunchAgent;
**Stop & remove** undoes it).

## Notes

- Several data sources are **private Apple interfaces** (MultitouchSupport, IOHIDEventSystemClient,
  DisplayServices, the sensor-processor reports). They work on the Mac this was built on
  (MacBookPro18,3, macOS 26) but can change with any macOS update; every call fails soft.
- No root or kernel extensions. Optional permissions: Input Monitoring (system-wide keys),
  Accessibility (keyboard-shortcut actions), Automation for Finder (the "Terminal here" action).
- `tools/` holds the small probe programs used to discover and decode the sensors.
