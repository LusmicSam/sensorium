// Capture tool for deciphering sensors.
// Prints every SPU HID report as:  R <t> <page> <usage> <len> <hex>
// and every HID *event* from the Touch ID (Mesa) / button services as:
//                                  E <t> <service> <eventType> <hex of event data>
// Usage: ./spudump <seconds> [--guided]
//   --guided: prints a prompt every 5 s on stderr (phases also marked in stdout as "P <t> <n> <name>")
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hid/IOHIDManager.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef void *HIDClient, *HIDService, *HIDEvent;
extern HIDClient IOHIDEventSystemClientCreate(CFAllocatorRef);
extern int IOHIDEventSystemClientSetMatching(HIDClient, CFDictionaryRef);
extern int IOHIDEventSystemClientSetMatchingMultiple(HIDClient, CFArrayRef);
extern void IOHIDEventSystemClientScheduleWithRunLoop(HIDClient, CFRunLoopRef, CFStringRef);
extern void IOHIDEventSystemClientRegisterEventCallback(HIDClient, void *cb, void *target, void *refcon);
extern CFArrayRef IOHIDEventSystemClientCopyServices(HIDClient);
extern CFTypeRef IOHIDServiceClientCopyProperty(HIDService, CFStringRef);
extern uint32_t IOHIDEventGetType(HIDEvent);
extern CFDataRef IOHIDEventCreateData(CFAllocatorRef, HIDEvent);

static double t0;
static double now(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e9 - t0;
}

typedef struct { int page, usage; uint8_t buf[512]; } Ctx;
static void onReport(void *ctx, IOReturn r, void *s, IOHIDReportType ty, uint32_t id, uint8_t *rep, CFIndex len) {
    (void)r; (void)s; (void)ty; (void)id;
    Ctx *c = ctx;
    printf("R %.4f %04X %02X %ld ", now(), c->page, c->usage, (long)len);
    for (CFIndex i = 0; i < len; i++) printf("%02x", rep[i]);
    printf("\n");
}

static void onEvent(void *target, void *refcon, HIDService svc, HIDEvent ev) {
    (void)target; (void)refcon;
    char name[64] = "?";
    CFTypeRef cls = IOHIDServiceClientCopyProperty(svc, CFSTR("IOClass"));
    if (cls && CFGetTypeID(cls) == CFStringGetTypeID())
        CFStringGetCString(cls, name, sizeof name, kCFStringEncodingUTF8);
    if (cls) CFRelease(cls);
    printf("E %.4f %s type=%u ", now(), name, IOHIDEventGetType(ev));
    CFDataRef d = IOHIDEventCreateData(kCFAllocatorDefault, ev);
    if (d) {
        const uint8_t *b = CFDataGetBytePtr(d);
        for (CFIndex i = 0; i < CFDataGetLength(d) && i < 96; i++) printf("%02x", b[i]);
        CFRelease(d);
    }
    printf("\n");
    fflush(stdout);
}

static CFDictionaryRef usageDict(int page, int usage) {
    CFNumberRef p = CFNumberCreate(NULL, kCFNumberIntType, &page), u = CFNumberCreate(NULL, kCFNumberIntType, &usage);
    const void *k[] = {CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage")}, *v[] = {p, u};
    CFDictionaryRef d = CFDictionaryCreate(NULL, k, v, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(p); CFRelease(u);
    return d;
}

static const char *phases[] = {
    "do nothing, hands off",
    "cover the area next to the camera (light sensor) with your hand",
    "slowly close the lid halfway and open it again",
    "rest a finger on Touch ID (do NOT press it)",
    "tap the palm rest a few times",
    "lift the front of the laptop / tilt it left and right",
};

int main(int argc, char **argv) {
    int seconds = argc > 1 ? atoi(argv[1]) : 5;
    int guided = argc > 2 && !strcmp(argv[2], "--guided");
    t0 = 0; t0 = now();
    setvbuf(stdout, NULL, _IOFBF, 1 << 16);

    // SPU devices: raw reports
    IOHIDManagerRef m = IOHIDManagerCreate(kCFAllocatorDefault, 0);
    IOHIDManagerSetDeviceMatching(m, NULL);
    CFSetRef all = IOHIDManagerCopyDevices(m);
    CFIndex n = all ? CFSetGetCount(all) : 0;
    IOHIDDeviceRef *devs = calloc(n ? n : 1, sizeof *devs);
    if (all) CFSetGetValues(all, (const void **)devs);
    int opened = 0;
    for (CFIndex i = 0; i < n; i++) {
        CFStringRef tr = IOHIDDeviceGetProperty(devs[i], CFSTR(kIOHIDTransportKey));
        if (!tr || CFStringCompare(tr, CFSTR("SPU"), 0)) continue;
        Ctx *c = calloc(1, sizeof *c);
        CFNumberRef p = IOHIDDeviceGetProperty(devs[i], CFSTR(kIOHIDPrimaryUsagePageKey));
        CFNumberRef u = IOHIDDeviceGetProperty(devs[i], CFSTR(kIOHIDPrimaryUsageKey));
        if (p) CFNumberGetValue(p, kCFNumberIntType, &c->page);
        if (u) CFNumberGetValue(u, kCFNumberIntType, &c->usage);
        if (IOHIDDeviceOpen(devs[i], 0)) continue;
        IOHIDDeviceRegisterInputReportCallback(devs[i], c->buf, sizeof c->buf, onReport, c);
        IOHIDDeviceScheduleWithRunLoop(devs[i], CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        opened++;
    }

    // Touch ID (Mesa, 0xFF00/0x0B), buttons (0x0C/0x01): HID events via the event system
    HIDClient ec = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    const void *ms[] = {usageDict(0xFF00, 0x0B), usageDict(0x0C, 0x01)};
    CFArrayRef multi = CFArrayCreate(NULL, ms, 2, &kCFTypeArrayCallBacks);
    IOHIDEventSystemClientSetMatchingMultiple(ec, multi);
    CFArrayRef svcs = IOHIDEventSystemClientCopyServices(ec);
    fprintf(stderr, "SPU devices opened: %d, event services matched (Touch ID / buttons): %ld\n",
            opened, svcs ? (long)CFArrayGetCount(svcs) : 0L);
    for (CFIndex i = 0; svcs && i < CFArrayGetCount(svcs); i++) {
        char name[64] = "?";
        CFTypeRef cls = IOHIDServiceClientCopyProperty((HIDService)CFArrayGetValueAtIndex(svcs, i), CFSTR("IOClass"));
        if (cls && CFGetTypeID(cls) == CFStringGetTypeID()) CFStringGetCString(cls, name, sizeof name, kCFStringEncodingUTF8);
        fprintf(stderr, "  event service: %s\n", name);
        if (cls) CFRelease(cls);
    }
    IOHIDEventSystemClientRegisterEventCallback(ec, (void *)onEvent, NULL, NULL);
    IOHIDEventSystemClientScheduleWithRunLoop(ec, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);

    if (!guided) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, false);
    } else {
        int np = sizeof phases / sizeof *phases;
        for (int i = 0; i < np; i++) {
            fprintf(stderr, "\n>>> [%d/%d] %d s: %s\n", i + 1, np, seconds, phases[i]);
            printf("P %.4f %d %s\n", now(), i, phases[i]);
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, false);
        }
        fprintf(stderr, "\n>>> done\n");
    }
    fflush(stdout);
    return 0;
}
