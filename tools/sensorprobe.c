// Throwaway probe: which hidden sensors can a normal (non-root) process read?
// 1) Temperatures / currents / voltages via the private IOHIDEventSystemClient.
// 2) Every SPU (sensor processor) HID device: try to switch reporting on, then
//    listen 1.5 s and count reports.
// 3) Lid angle via a feature report.
// 4) --haptic: fire the trackpad's actuator once via MultitouchSupport.
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hid/IOHIDManager.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

// ---- private IOHIDEventSystemClient bits (exported by IOKit, no header) ----
typedef void *HIDClient, *HIDService, *HIDEvent;
extern HIDClient IOHIDEventSystemClientCreate(CFAllocatorRef);
extern int IOHIDEventSystemClientSetMatching(HIDClient, CFDictionaryRef);
extern CFArrayRef IOHIDEventSystemClientCopyServices(HIDClient);
extern HIDEvent IOHIDServiceClientCopyEvent(HIDService, int64_t, int32_t, int64_t);
extern CFTypeRef IOHIDServiceClientCopyProperty(HIDService, CFStringRef);
extern double IOHIDEventGetFloatValue(HIDEvent, int32_t);

static CFDictionaryRef usageMatch(int page, int usage) {
    CFNumberRef p = CFNumberCreate(NULL, kCFNumberIntType, &page);
    CFNumberRef u = CFNumberCreate(NULL, kCFNumberIntType, &usage);
    const void *k[] = {CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage")}, *v[] = {p, u};
    CFDictionaryRef d = CFDictionaryCreate(NULL, k, v, 2, &kCFTypeDictionaryKeyCallBacks,
                                           &kCFTypeDictionaryValueCallBacks);
    CFRelease(p); CFRelease(u);
    return d;
}

static void readEventSensors(const char *label, int page, int usage, int64_t type, double scale) {
    HIDClient c = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    CFDictionaryRef m = usageMatch(page, usage);
    IOHIDEventSystemClientSetMatching(c, m);
    CFArrayRef svcs = IOHIDEventSystemClientCopyServices(c);
    CFIndex n = svcs ? CFArrayGetCount(svcs) : 0, ok = 0;
    double lo = 1e9, hi = -1e9; char loName[64] = "", hiName[64] = "";
    for (CFIndex i = 0; i < n; i++) {
        HIDService s = (HIDService)CFArrayGetValueAtIndex(svcs, i);
        HIDEvent e = IOHIDServiceClientCopyEvent(s, type, 0, 0);
        if (!e) continue;
        double v = IOHIDEventGetFloatValue(e, (int32_t)(type << 16)) * scale;
        CFRelease(e);
        char name[64] = "?";
        CFStringRef nm = IOHIDServiceClientCopyProperty(s, CFSTR("Product"));
        if (nm) { CFStringGetCString(nm, name, sizeof name, kCFStringEncodingUTF8); CFRelease(nm); }
        ok++;
        if (v < lo) { lo = v; strcpy(loName, name); }
        if (v > hi) { hi = v; strcpy(hiName, name); }
    }
    printf("%-12s sensors=%ld readable=%ld", label, (long)n, (long)ok);
    if (ok) printf("  min=%.2f (%s)  max=%.2f (%s)", lo, loName, hi, hiName);
    printf("\n");
    if (svcs) CFRelease(svcs);
    CFRelease(m); CFRelease(c);
}

// ---- SPU HID devices ----
typedef struct { int page, usage; long reports; CFIndex len; uint8_t sample[32]; } Tap;
static void onReport(void *ctx, IOReturn r, void *sender, IOHIDReportType t, uint32_t id,
                     uint8_t *rep, CFIndex len) {
    (void)r; (void)sender; (void)t; (void)id;
    Tap *tap = ctx;
    tap->reports++;
    tap->len = len;
    memcpy(tap->sample, rep, len < 32 ? len : 32);
}

static void enableSPUReporting(void) {
    io_iterator_t it;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDriver"), &it))
        return;
    io_service_t s; int one = 1, interval = 10000;  // 10 ms
    CFNumberRef on = CFNumberCreate(NULL, kCFNumberIntType, &one);
    CFNumberRef iv = CFNumberCreate(NULL, kCFNumberIntType, &interval);
    while ((s = IOIteratorNext(it))) {
        kern_return_t a = IORegistryEntrySetCFProperty(s, CFSTR("SensorPropertyReportingState"), on);
        kern_return_t b = IORegistryEntrySetCFProperty(s, CFSTR("SensorPropertyPowerState"), on);
        kern_return_t c = IORegistryEntrySetCFProperty(s, CFSTR("ReportInterval"), iv);
        printf("  enable on SPU driver: reporting=0x%X power=0x%X interval=0x%X\n", a, b, c);
        IOObjectRelease(s);
    }
    IOObjectRelease(it);
    CFRelease(on); CFRelease(iv);
}

static int noEnable = 0;
static void probeSPU(void) {
    printf("SPU devices (sensor processor):\n");
    if (!noEnable) enableSPUReporting(); else printf("  (not touching driver properties)\n");
    IOHIDManagerRef m = IOHIDManagerCreate(kCFAllocatorDefault, 0);
    IOHIDManagerSetDeviceMatching(m, NULL);
    CFSetRef all = IOHIDManagerCopyDevices(m);
    CFIndex n = all ? CFSetGetCount(all) : 0;
    IOHIDDeviceRef devs[256]; Tap taps[64]; int nt = 0;
    if (n > 256) n = 256;
    if (all) CFSetGetValues(all, (const void **)devs);
    for (CFIndex i = 0; i < n && nt < 64; i++) {
        CFStringRef tr = IOHIDDeviceGetProperty(devs[i], CFSTR(kIOHIDTransportKey));
        if (!tr || CFStringCompare(tr, CFSTR("SPU"), 0) != kCFCompareEqualTo) continue;
        int page = 0, usage = 0;
        CFNumberRef p = IOHIDDeviceGetProperty(devs[i], CFSTR(kIOHIDPrimaryUsagePageKey));
        CFNumberRef u = IOHIDDeviceGetProperty(devs[i], CFSTR(kIOHIDPrimaryUsageKey));
        if (p) CFNumberGetValue(p, kCFNumberIntType, &page);
        if (u) CFNumberGetValue(u, kCFNumberIntType, &usage);
        Tap *t = &taps[nt++]; memset(t, 0, sizeof *t); t->page = page; t->usage = usage;
        IOReturn r = IOHIDDeviceOpen(devs[i], kIOHIDOptionsTypeNone);
        if (r) { printf("  0x%04X/0x%02X open failed 0x%X\n", page, usage, r); t->reports = -1; continue; }
        static uint8_t bufs[64][256];
        IOHIDDeviceRegisterInputReportCallback(devs[i], bufs[nt - 1], sizeof bufs[0], onReport, t);
        IOHIDDeviceScheduleWithRunLoop(devs[i], CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        if (page == 0x20 && usage == 0x8A) {  // lid angle: feature report 1
            uint8_t f[8] = {0}; CFIndex fl = sizeof f;
            IOReturn gr = IOHIDDeviceGetReport(devs[i], kIOHIDReportTypeFeature, 1, f, &fl);
            printf("  lid feature report: ret=0x%X len=%ld bytes=", gr, (long)fl);
            for (CFIndex k = 0; k < fl; k++) printf("%02x ", f[k]);
            if (!gr && fl >= 3) printf(" -> angle=%u deg", f[1] | (f[2] << 8));
            printf("\n");
        }
    }
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.5, false);
    for (int i = 0; i < nt; i++) {
        if (taps[i].reports < 0) continue;
        printf("  0x%04X/0x%02X reports in 1.5s=%ld len=%ld first bytes=", taps[i].page,
               taps[i].usage, taps[i].reports, (long)taps[i].len);
        for (int k = 0; k < (taps[i].len < 24 ? taps[i].len : 24); k++) printf("%02x ", taps[i].sample[k]);
        printf("\n");
    }
    if (all) CFRelease(all);
}

static void haptic(void) {
    void *h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW);
    CFMutableArrayRef (*list)(void) = dlsym(h, "MTDeviceCreateList");
    int (*getID)(void *, uint64_t *) = dlsym(h, "MTDeviceGetDeviceID");
    void *(*create)(uint64_t) = dlsym(h, "MTActuatorCreateFromDeviceID");
    int (*open)(void *) = dlsym(h, "MTActuatorOpen");
    int (*act)(void *, int32_t, uint32_t, float, float) = dlsym(h, "MTActuatorActuate");
    int (*close)(void *) = dlsym(h, "MTActuatorClose");
    printf("haptic symbols: list=%d getID=%d create=%d open=%d actuate=%d close=%d\n",
           !!list, !!getID, !!create, !!open, !!act, !!close);
    if (!list || !getID || !create || !open || !act) return;
    CFMutableArrayRef l = list(); uint64_t id = 0;
    if (!l || !CFArrayGetCount(l)) return;
    getID((void *)CFArrayGetValueAtIndex(l, 0), &id);
    void *a = create(id);
    int o = a ? open(a) : -1;
    int r = (a && o == 0) ? act(a, 6, 0, 0.0f, 0.0f) : -1;
    printf("haptic: deviceID=%llu actuator=%s open=0x%X actuate(6)=0x%X\n",
           (unsigned long long)id, a ? "ok" : "NULL", o, r);
    if (a && close) close(a);
}

int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) if (!strcmp(argv[i], "--no-enable")) noEnable = 1;
    printf("== Event-system sensors ==\n");
    readEventSensors("temperature", 0xFF00, 5, 15, 1.0);   // degC
    readEventSensors("current", 0xFF08, 2, 25, 1.0);       // raw units
    readEventSensors("voltage", 0xFF08, 3, 25, 1.0);       // raw units
    readEventSensors("ambient", 0xFF00, 4, 12, 1.0);       // ALS event (type 12)
    printf("== SPU ==\n");
    probeSPU();
    if (argc > 1 && !strcmp(argv[argc-1], "--haptic")) { printf("== Haptic ==\n"); haptic(); }
    return 0;
}
