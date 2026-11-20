// Event-system sensors (private IOHIDEventSystemClient), SPU report streams,
// HID event services (Touch ID "Mesa", buttons) and the battery.
#include "csensors.h"
#include "internal.h"
#include <IOKit/IOKitLib.h>
#include <IOKit/hid/IOHIDManager.h>
#include <stdlib.h>
#include <string.h>

// ---- IOHIDEventSystemClient: two functions are public (IOHIDEventSystemClient.h,
// IOHIDServiceClient.h); the rest are exported by IOKit without a header. ----
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>
typedef IOHIDEventSystemClientRef HIDClient;
typedef IOHIDServiceClientRef HIDService;
typedef void *HIDEvent;
extern HIDClient IOHIDEventSystemClientCreate(CFAllocatorRef);
extern int IOHIDEventSystemClientSetMatching(HIDClient, CFDictionaryRef);
extern int IOHIDEventSystemClientSetMatchingMultiple(HIDClient, CFArrayRef);
extern void IOHIDEventSystemClientScheduleWithRunLoop(HIDClient, CFRunLoopRef, CFStringRef);
extern void IOHIDEventSystemClientUnscheduleWithRunLoop(HIDClient, CFRunLoopRef, CFStringRef);
extern void IOHIDEventSystemClientRegisterEventCallback(HIDClient, void *cb, void *target, void *refcon);
extern HIDEvent IOHIDServiceClientCopyEvent(HIDService, int64_t, int32_t, int64_t);
extern double IOHIDEventGetFloatValue(HIDEvent, int32_t);
extern uint32_t IOHIDEventGetType(HIDEvent);
extern uint64_t IOHIDEventGetTimeStamp(HIDEvent);
extern CFDataRef IOHIDEventCreateData(CFAllocatorRef, HIDEvent);
extern int64_t IOHIDEventGetIntegerValue(HIDEvent, int32_t);
extern uint8_t *IOHIDEventGetDataValue(HIDEvent, int32_t);

typedef struct { int32_t page, usage; HIDClient client; CFArrayRef services; } SensorSet;
static SensorSet gSets[8];
static int gSetCount;
static pthread_mutex_t gSetLock = PTHREAD_MUTEX_INITIALIZER;

static CFArrayRef servicesFor(int32_t page, int32_t usage) {
    for (int i = 0; i < gSetCount; i++)
        if (gSets[i].page == page && gSets[i].usage == usage) return gSets[i].services;
    if (gSetCount >= 8) return NULL;
    HIDClient c = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!c) return NULL;
    CFDictionaryRef m = sn_usage_match(page, usage);
    IOHIDEventSystemClientSetMatching(c, m);
    CFRelease(m);
    gSets[gSetCount] = (SensorSet){page, usage, c, IOHIDEventSystemClientCopyServices(c)};
    return gSets[gSetCount++].services;
}

static void copyName(HIDService s, char *out, size_t size, CFIndex fallback) {
    CFTypeRef nm = IOHIDServiceClientCopyProperty(s, CFSTR("Product"));
    if (nm && CFGetTypeID(nm) == CFStringGetTypeID() &&
        CFStringGetCString(nm, out, (CFIndex)size, kCFStringEncodingUTF8)) {
        CFRelease(nm);
        return;
    }
    if (nm) CFRelease(nm);
    snprintf(out, size, "sensor %ld", (long)fallback);
}

int32_t sn_read_sensors(int32_t page, int32_t usage, int64_t type, SNReading *out, int32_t max) {
    pthread_mutex_lock(&gSetLock);
    CFArrayRef svcs = servicesFor(page, usage);
    int32_t k = 0;
    for (CFIndex i = 0; svcs && i < CFArrayGetCount(svcs) && k < max; i++) {
        HIDService s = (HIDService)CFArrayGetValueAtIndex(svcs, i);
        HIDEvent e = IOHIDServiceClientCopyEvent(s, type, 0, 0);
        if (!e) continue;
        out[k].value = IOHIDEventGetFloatValue(e, (int32_t)(type << 16));
        CFRelease(e);
        copyName(s, out[k].name, sizeof out[k].name, i);
        k++;
    }
    pthread_mutex_unlock(&gSetLock);
    return k;
}

// ---- SPU report streams ----
typedef struct { int32_t page, usage; uint8_t buf[512]; } SpuCtx;
static SNReportCallback gSpuCb;
static void *gSpuCtx;
static CFSetRef gSpuDevices;
static SpuCtx *gSpuCtxs[64];
static int gSpuN;

static void onSpuReport(void *ctx, IOReturn r, void *sender, IOHIDReportType type, uint32_t id,
                        uint8_t *report, CFIndex length, uint64_t ts) {
    (void)r; (void)sender; (void)type; (void)id;
    SpuCtx *c = ctx;
    if (gSpuCb) gSpuCb(c->page, c->usage, report, (int32_t)length, sn_mach_to_sec(ts), gSpuCtx);
}

static int32_t spuSetup(CFRunLoopRef loop) {
    IOHIDManagerRef m = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    const void *k[] = {CFSTR(kIOHIDTransportKey)}, *v[] = {CFSTR("SPU")};
    CFDictionaryRef match = CFDictionaryCreate(NULL, k, v, 1, &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    IOHIDManagerSetDeviceMatching(m, match);
    CFRelease(match);
    gSpuDevices = IOHIDManagerCopyDevices(m);
    CFRelease(m);
    if (!gSpuDevices) return 0;
    CFIndex n = CFSetGetCount(gSpuDevices);
    IOHIDDeviceRef devs[64];
    if (n > 64) n = 64;
    CFSetGetValues(gSpuDevices, (const void **)devs);
    gSpuN = 0;
    for (CFIndex i = 0; i < n; i++) {
        if (IOHIDDeviceOpen(devs[i], kIOHIDOptionsTypeNone) != kIOReturnSuccess) continue;
        SpuCtx *c = calloc(1, sizeof *c);
        CFNumberRef p = IOHIDDeviceGetProperty(devs[i], CFSTR(kIOHIDPrimaryUsagePageKey));
        CFNumberRef u = IOHIDDeviceGetProperty(devs[i], CFSTR(kIOHIDPrimaryUsageKey));
        if (p) CFNumberGetValue(p, kCFNumberSInt32Type, &c->page);
        if (u) CFNumberGetValue(u, kCFNumberSInt32Type, &c->usage);
        IOHIDDeviceRegisterInputReportWithTimeStampCallback(devs[i], c->buf, sizeof c->buf, onSpuReport, c);
        IOHIDDeviceScheduleWithRunLoop(devs[i], loop, kCFRunLoopDefaultMode);
        gSpuCtxs[gSpuN++] = c;
    }
    return gSpuN;
}

static void spuTeardown(CFRunLoopRef loop) {
    if (gSpuDevices) {
        CFIndex n = CFSetGetCount(gSpuDevices);
        IOHIDDeviceRef devs[64];
        if (n > 64) n = 64;
        CFSetGetValues(gSpuDevices, (const void **)devs);
        for (CFIndex i = 0; i < n; i++) {
            IOHIDDeviceUnscheduleFromRunLoop(devs[i], loop, kCFRunLoopDefaultMode);
            IOHIDDeviceClose(devs[i], kIOHIDOptionsTypeNone);
        }
        CFRelease(gSpuDevices);
        gSpuDevices = NULL;
    }
    for (int i = 0; i < gSpuN; i++) free(gSpuCtxs[i]);
    gSpuN = 0;
}

static SNLoopThread gSpuThread = {.setup = spuSetup, .teardown = spuTeardown};

int32_t sn_spu_start(SNReportCallback cb, void *ctx) {
    gSpuCb = cb;
    gSpuCtx = ctx;
    return sn_loop_start(&gSpuThread);
}
void sn_spu_stop(void) { sn_loop_stop(&gSpuThread); }

// ---- HID event services: Touch ID sensor (Mesa, 0xFF00/0x0B) and buttons (0x0C/0x01) ----
static SNEventCallback gEvCb;
static void *gEvCtx;
static HIDClient gEvClient;

// The event system calls this with sender == NULL for some events (seen in two crash
// reports: IOHIDServiceClientCopyProperty(NULL) -> SIGSEGV at 0x58). Never touch a NULL sender.
static void onHIDEvent(void *target, void *refcon, HIDService svc, HIDEvent ev) {
    (void)target; (void)refcon;
    if (!ev) return;
    char cls[64] = "(no sender)";
    if (svc) {
        CFTypeRef c = IOHIDServiceClientCopyProperty(svc, CFSTR("IOClass"));
        if (c && CFGetTypeID(c) == CFStringGetTypeID()) CFStringGetCString(c, cls, sizeof cls, kCFStringEncodingUTF8);
        if (c) CFRelease(c);
    }
    CFDataRef d = IOHIDEventCreateData(kCFAllocatorDefault, ev);
    if (gEvCb)
        gEvCb(cls, IOHIDEventGetType(ev), d ? CFDataGetBytePtr(d) : NULL, d ? (int32_t)CFDataGetLength(d) : 0,
              sn_mach_to_sec(IOHIDEventGetTimeStamp(ev)), gEvCtx);
    if (d) CFRelease(d);
}

static int32_t evSetup(CFRunLoopRef loop) {
    gEvClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!gEvClient) return -1;
    const void *ms[] = {sn_usage_match(0xFF00, 0x0B), sn_usage_match(0x0C, 0x01)};
    CFArrayRef multi = CFArrayCreate(NULL, ms, 2, &kCFTypeArrayCallBacks);
    CFRelease(ms[0]);
    CFRelease(ms[1]);
    IOHIDEventSystemClientSetMatchingMultiple(gEvClient, multi);
    CFRelease(multi);
    CFArrayRef svcs = IOHIDEventSystemClientCopyServices(gEvClient);
    int32_t n = svcs ? (int32_t)CFArrayGetCount(svcs) : 0;
    if (svcs) CFRelease(svcs);
    IOHIDEventSystemClientRegisterEventCallback(gEvClient, (void *)onHIDEvent, NULL, NULL);
    IOHIDEventSystemClientScheduleWithRunLoop(gEvClient, loop, kCFRunLoopDefaultMode);
    return n;
}

static void evTeardown(CFRunLoopRef loop) {
    if (gEvClient) IOHIDEventSystemClientUnscheduleWithRunLoop(gEvClient, loop, kCFRunLoopDefaultMode);
}

static SNLoopThread gEvThread = {.setup = evSetup, .teardown = evTeardown};

int32_t sn_events_start(SNEventCallback cb, void *ctx) {
    gEvCb = cb;
    gEvCtx = ctx;
    return sn_loop_start(&gEvThread);
}
void sn_events_stop(void) { sn_loop_stop(&gEvThread); }

// ---- battery (AppleSmartBattery registry properties) ----
static int64_t regInt(io_service_t s, const char *key, bool *found) {
    CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    CFTypeRef v = IORegistryEntryCreateCFProperty(s, k, kCFAllocatorDefault, 0);
    CFRelease(k);
    int64_t out = 0;
    if (v && CFGetTypeID(v) == CFNumberGetTypeID()) {
        CFNumberGetValue(v, kCFNumberSInt64Type, &out);
        if (found) *found = true;
    } else if (v && CFGetTypeID(v) == CFBooleanGetTypeID()) {
        out = CFBooleanGetValue(v);
        if (found) *found = true;
    }
    if (v) CFRelease(v);
    return out;
}

SNBattery sn_battery(void) {
    SNBattery b = {0};
    io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"));
    if (!s) return b;
    bool found = false;
    b.percent = (int32_t)regInt(s, "CurrentCapacity", &found);
    b.voltage_mV = (int32_t)regInt(s, "Voltage", NULL);
    b.amperage_mA = (int32_t)regInt(s, "Amperage", NULL);  // signed: negative = discharging
    b.temperature_C = regInt(s, "Temperature", NULL) / 100.0;
    b.cycles = (int32_t)regInt(s, "CycleCount", NULL);
    b.rawMax_mAh = (int32_t)regInt(s, "AppleRawMaxCapacity", NULL);
    b.rawCurrent_mAh = (int32_t)regInt(s, "AppleRawCurrentCapacity", NULL);
    b.design_mAh = (int32_t)regInt(s, "DesignCapacity", NULL);
    b.charging = regInt(s, "IsCharging", NULL) != 0;
    b.external = regInt(s, "ExternalConnected", NULL) != 0;
    b.valid = found;
    IOObjectRelease(s);
    return b;
}

// ---- ambient light: the system's own decoded fields ----
// Field order verified on this Mac against the raw SPU report: 0 level, 1-4 raw channels,
// 5 brightness-changed, 6 colour space, 7-9 colour X/Y/Z, 10 colour temperature K, 11 illuminance lux.
int32_t sn_read_als(double *out, int32_t n) {
    pthread_mutex_lock(&gSetLock);
    CFArrayRef s = servicesFor(0xFF00, 0x04);
    HIDEvent e = (s && CFArrayGetCount(s)) ? IOHIDServiceClientCopyEvent((HIDService)CFArrayGetValueAtIndex(s, 0), 12, 0, 0) : NULL;
    pthread_mutex_unlock(&gSetLock);
    if (!e) return 0;
    for (int32_t i = 0; i < n; i++) out[i] = IOHIDEventGetFloatValue(e, (12 << 16) + i);
    CFRelease(e);
    return n;
}

// ---- vendor events: devmotion6 (fused orientation, 100/s) and cma (records) ----
static SNReportCallback gVCb;
static void *gVCtx;
static HIDClient gVClient;

static void onVendor(void *target, void *refcon, HIDService svc, HIDEvent ev) {
    (void)target; (void)refcon; (void)svc;
    if (!ev || !gVCb || IOHIDEventGetType(ev) != 1) return;   // 1 = vendor-defined
    int64_t page = IOHIDEventGetIntegerValue(ev, (1 << 16) + 0);
    int64_t usage = IOHIDEventGetIntegerValue(ev, (1 << 16) + 1);
    int64_t len = IOHIDEventGetIntegerValue(ev, (1 << 16) + 3);
    uint8_t *d = IOHIDEventGetDataValue(ev, (1 << 16) + 4);
    if (!d || len <= 0 || len > 4096) return;
    gVCb((int32_t)page, (int32_t)usage, d, (int32_t)len, sn_mach_to_sec(IOHIDEventGetTimeStamp(ev)), gVCtx);
}

static int32_t vSetup(CFRunLoopRef loop) {
    gVClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!gVClient) return -1;
    const void *ms[] = {sn_usage_match(0xFF0C, 0x01), sn_usage_match(0xFF0C, 0x05)};
    CFArrayRef multi = CFArrayCreate(NULL, ms, 2, &kCFTypeArrayCallBacks);
    CFRelease(ms[0]);
    CFRelease(ms[1]);
    IOHIDEventSystemClientSetMatchingMultiple(gVClient, multi);
    CFRelease(multi);
    IOHIDEventSystemClientRegisterEventCallback(gVClient, (void *)onVendor, NULL, NULL);
    IOHIDEventSystemClientScheduleWithRunLoop(gVClient, loop, kCFRunLoopDefaultMode);
    return 0;
}

static void vTeardown(CFRunLoopRef loop) {
    if (!gVClient) return;
    IOHIDEventSystemClientUnscheduleWithRunLoop(gVClient, loop, kCFRunLoopDefaultMode);
    CFRelease(gVClient);
    gVClient = NULL;
}

static SNLoopThread gVThread = {.setup = vSetup, .teardown = vTeardown};

int32_t sn_vendor_start(SNReportCallback cb, void *ctx) {
    gVCb = cb;
    gVCtx = ctx;
    return sn_loop_start(&gVThread);
}
void sn_vendor_stop(void) { sn_loop_stop(&gVThread); }
