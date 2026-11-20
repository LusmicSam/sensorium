// CSensors: thin C layer over the macOS hardware interfaces Sensorium reads.
// Several of these are PRIVATE Apple interfaces (no header, may change in any
// macOS update): MultitouchSupport, IOHIDEventSystemClient, the SPU sensor
// reports. Every function fails soft (returns 0 / -1) instead of crashing.
#pragma once
#include <stdbool.h>
#include <stdint.h>

// ---------- Trackpad touches (MultitouchSupport, private) ----------
typedef struct {
    int32_t id;          // finger identifier, stable while the finger stays down
    int32_t state;       // 1 start, 2 hover, 3 touch down, 4 touching, 5 lifting, 7 gone
    float x, y;          // position, 0..1 across the pad
    float vx, vy;        // velocity, pad-widths per second
    float pressure;      // force sensors under the glass, raw units (0 .. ~2000+)
    float total;         // capacitive contact strength (saturates near 1)
    float density;
    float majorAxis, minorAxis, angle;  // contact ellipse (mm-ish), angle in radians
} SNTouch;

typedef void (*SNTouchCallback)(const SNTouch *touches, int32_t count, double timestamp, void *ctx);
int32_t sn_touch_start(SNTouchCallback cb, void *ctx);  // returns device count, <0 on error
void sn_touch_stop(void);

// ---------- Trackpad haptic motor (MultitouchSupport, private) ----------
int32_t sn_haptic_fire(int32_t actuationID, float arg1, float arg2);  // IOReturn, 0 = ok
void sn_haptic_close(void);

// ---------- Event-system sensors: temperatures, rail currents/voltages, light ----------
typedef struct {
    char name[64];
    double value;
} SNReading;
int32_t sn_read_sensors(int32_t page, int32_t usage, int64_t eventType, SNReading *out, int32_t max);

// ---------- SPU sensor reports (accelerometer, gyro, lid, light, unknown) ----------
typedef void (*SNReportCallback)(int32_t page, int32_t usage, const uint8_t *report, int32_t length,
                                 double timestamp, void *ctx);
int32_t sn_spu_start(SNReportCallback cb, void *ctx);  // own thread; returns devices opened
void sn_spu_stop(void);

// ---------- Hidden motion-coprocessor events (vendor-defined) ----------
// devmotion6 (0xFF0C/0x05): 52-byte payload, 100/s: fused orientation quaternion x,y,z,w (f32 @12),
// rotation rate rad/s (f32 @28), probably user acceleration g (f32 @40).
// cma (0xFF0C/0x01): several record types (first byte), a few per second.
int32_t sn_vendor_start(SNReportCallback cb, void *ctx);  // own thread; 0 = ok
void sn_vendor_stop(void);

// Ambient light, the system's decoded fields (see sensors.c for the order). Returns fields read.
int32_t sn_read_als(double *out, int32_t n);

// ---------- HID event services: Touch ID sensor ("Mesa"), buttons ----------
typedef void (*SNEventCallback)(const char *serviceClass, uint32_t eventType, const uint8_t *data,
                                int32_t length, double timestamp, void *ctx);
int32_t sn_events_start(SNEventCallback cb, void *ctx);  // returns services matched
void sn_events_stop(void);

// ---------- Battery ----------
typedef struct {
    bool valid, charging, external;
    int32_t percent, voltage_mV, amperage_mA, cycles, rawMax_mAh, rawCurrent_mAh, design_mAh;
    double temperature_C;
} SNBattery;
SNBattery sn_battery(void);

// ---------- Keyboard, system-wide (needs Input Monitoring) ----------
int32_t sn_input_monitoring_status(void);  // 0 granted, 1 denied, 2 not asked yet
bool sn_input_monitoring_request(void);
typedef void (*SNKeyCallback)(uint32_t usagePage, uint32_t usage, int32_t down, double timestamp, void *ctx);
int32_t sn_keys_start(SNKeyCallback cb, void *ctx);  // IOReturn, 0 = listening
void sn_keys_stop(void);

// ---------- System controls (gestures / tasks) ----------
double sn_brightness_get(void);           // 0..1, -1 if unavailable
int32_t sn_brightness_set(double value);  // 0 = ok
double sn_volume_get(void);               // default output, 0..1, -1 if unavailable
int32_t sn_volume_set(double value);
int32_t sn_mute_get(void);                // 1 muted, 0 not, -1 unavailable
int32_t sn_mute_set(bool on);
bool sn_accessibility_trusted(bool prompt);              // needed only for keyboard-shortcut actions
int32_t sn_post_shortcut(uint16_t keyCode, uint64_t flags);  // -1 = no Accessibility permission

// Seconds on the same clock as the HID timestamps.
double sn_now(void);
