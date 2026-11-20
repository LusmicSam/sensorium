// System controls used by trackpad gestures and tasks.
// Brightness: private DisplayServices (built-in display), checked on this Mac: get/set rc=0, no permission.
// Volume / mute: public CoreAudio on the default output device.
// Keyboard shortcuts: CGEvent posting, which macOS only allows with Accessibility permission.
#include "csensors.h"
#include <ApplicationServices/ApplicationServices.h>
#include <AudioToolbox/AudioServices.h>
#include <CoreAudio/CoreAudio.h>
#include <dlfcn.h>

static int (*dsGet)(CGDirectDisplayID, float *);
static int (*dsSet)(CGDirectDisplayID, float);

static bool loadDS(void) {
    static bool tried = false;
    if (!tried) {
        tried = true;
        void *h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW);
        if (h) {
            dsGet = dlsym(h, "DisplayServicesGetBrightness");
            dsSet = dlsym(h, "DisplayServicesSetBrightness");
        }
    }
    return dsGet && dsSet;
}

double sn_brightness_get(void) {
    float b = -1;
    if (!loadDS() || dsGet(CGMainDisplayID(), &b) != 0) return -1;
    return b;
}

int32_t sn_brightness_set(double value) {
    if (!loadDS()) return -1;
    float v = (float)(value < 0 ? 0 : value > 1 ? 1 : value);
    return dsSet(CGMainDisplayID(), v);
}

static AudioObjectID defaultOutput(void) {
    AudioObjectID dev = 0;
    UInt32 size = sizeof dev;
    AudioObjectPropertyAddress a = {kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, &dev) != noErr) return 0;
    return dev;
}

double sn_volume_get(void) {
    AudioObjectID dev = defaultOutput();
    Float32 v = -1;
    UInt32 size = sizeof v;
    AudioObjectPropertyAddress a = {kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput,
                                    kAudioObjectPropertyElementMain};
    if (!dev || AudioObjectGetPropertyData(dev, &a, 0, NULL, &size, &v) != noErr) return -1;
    return v;
}

int32_t sn_volume_set(double value) {
    AudioObjectID dev = defaultOutput();
    if (!dev) return -1;
    Float32 v = (Float32)(value < 0 ? 0 : value > 1 ? 1 : value);
    AudioObjectPropertyAddress a = {kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput,
                                    kAudioObjectPropertyElementMain};
    return AudioObjectSetPropertyData(dev, &a, 0, NULL, sizeof v, &v);
}

int32_t sn_mute_get(void) {
    AudioObjectID dev = defaultOutput();
    UInt32 m = 0, size = sizeof m;
    AudioObjectPropertyAddress a = {kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain};
    if (!dev || AudioObjectGetPropertyData(dev, &a, 0, NULL, &size, &m) != noErr) return -1;
    return (int32_t)m;
}

int32_t sn_mute_set(bool on) {
    AudioObjectID dev = defaultOutput();
    if (!dev) return -1;
    UInt32 m = on ? 1 : 0;
    AudioObjectPropertyAddress a = {kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain};
    return AudioObjectSetPropertyData(dev, &a, 0, NULL, sizeof m, &m);
}

bool sn_accessibility_trusted(bool prompt) {
    const void *k[] = {kAXTrustedCheckOptionPrompt}, *v[] = {prompt ? kCFBooleanTrue : kCFBooleanFalse};
    CFDictionaryRef opts = CFDictionaryCreate(NULL, k, v, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    bool ok = AXIsProcessTrustedWithOptions(opts);
    CFRelease(opts);
    return ok;
}

int32_t sn_post_shortcut(uint16_t keyCode, uint64_t flags) {
    if (!AXIsProcessTrusted()) return -1;
    CGEventRef down = CGEventCreateKeyboardEvent(NULL, keyCode, true);
    CGEventRef up = CGEventCreateKeyboardEvent(NULL, keyCode, false);
    if (!down || !up) return -2;
    CGEventSetFlags(down, (CGEventFlags)flags);
    CGEventSetFlags(up, (CGEventFlags)flags);
    CGEventPost(kCGHIDEventTap, down);
    CGEventPost(kCGHIDEventTap, up);
    CFRelease(down);
    CFRelease(up);
    return 0;
}
