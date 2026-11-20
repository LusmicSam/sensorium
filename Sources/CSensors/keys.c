// System-wide keyboard listening through IOHIDManager. macOS only delivers
// these values if the app has Input Monitoring permission.
#include "csensors.h"
#include "internal.h"
#include <IOKit/hid/IOHIDManager.h>
#include <IOKit/hidsystem/IOHIDLib.h>  // IOHIDCheckAccess / IOHIDRequestAccess

int32_t sn_input_monitoring_status(void) {
    IOHIDAccessType a = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent);
    return a == kIOHIDAccessTypeGranted ? 0 : a == kIOHIDAccessTypeDenied ? 1 : 2;
}

bool sn_input_monitoring_request(void) { return IOHIDRequestAccess(kIOHIDRequestTypeListenEvent); }

static SNKeyCallback gKeyCb;
static void *gKeyCtx;
static IOHIDManagerRef gKeyMgr;

static void onValue(void *ctx, IOReturn r, void *sender, IOHIDValueRef v) {
    (void)ctx; (void)r; (void)sender;
    IOHIDElementRef e = IOHIDValueGetElement(v);
    uint32_t page = IOHIDElementGetUsagePage(e), usage = IOHIDElementGetUsage(e);
    // Keyboard page keys + Apple's vendor "Fn" bit (page 0xFF, usage 0x03).
    bool isKey = (page == 0x07 && usage >= 0x04 && usage <= 0xE7) || (page == 0xFF && usage == 0x03);
    if (!isKey || !gKeyCb) return;
    gKeyCb(page, usage, IOHIDValueGetIntegerValue(v) != 0, sn_mach_to_sec(IOHIDValueGetTimeStamp(v)), gKeyCtx);
}

static int32_t keySetup(CFRunLoopRef loop) {
    gKeyMgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    // Generic Desktop / Keyboard. IOHIDManager matches on DeviceUsagePage/DeviceUsage keys.
    int page = 0x01, usage = 0x06;
    CFNumberRef p = CFNumberCreate(NULL, kCFNumberIntType, &page), u = CFNumberCreate(NULL, kCFNumberIntType, &usage);
    const void *k[] = {CFSTR(kIOHIDDeviceUsagePageKey), CFSTR(kIOHIDDeviceUsageKey)}, *v[] = {p, u};
    CFDictionaryRef dm = CFDictionaryCreate(NULL, k, v, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    IOHIDManagerSetDeviceMatching(gKeyMgr, dm);
    CFRelease(dm); CFRelease(p); CFRelease(u);
    IOHIDManagerRegisterInputValueCallback(gKeyMgr, onValue, NULL);
    IOHIDManagerScheduleWithRunLoop(gKeyMgr, loop, kCFRunLoopDefaultMode);
    IOReturn r = IOHIDManagerOpen(gKeyMgr, kIOHIDOptionsTypeNone);
    if (r != kIOReturnSuccess) {
        IOHIDManagerUnscheduleFromRunLoop(gKeyMgr, loop, kCFRunLoopDefaultMode);
        CFRelease(gKeyMgr);
        gKeyMgr = NULL;
        return (int32_t)r < 0 ? (int32_t)r : -1;  // IOReturn errors are negative as int32
    }
    return 0;
}

static void keyTeardown(CFRunLoopRef loop) {
    if (!gKeyMgr) return;
    IOHIDManagerUnscheduleFromRunLoop(gKeyMgr, loop, kCFRunLoopDefaultMode);
    IOHIDManagerClose(gKeyMgr, kIOHIDOptionsTypeNone);
    CFRelease(gKeyMgr);
    gKeyMgr = NULL;
}

static SNLoopThread gKeyThread = {.setup = keySetup, .teardown = keyTeardown};

int32_t sn_keys_start(SNKeyCallback cb, void *ctx) {
    gKeyCb = cb;
    gKeyCtx = ctx;
    int32_t r = sn_loop_start(&gKeyThread);
    return r < 0 ? r : 0;
}
void sn_keys_stop(void) { sn_loop_stop(&gKeyThread); }
