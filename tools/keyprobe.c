// Throwaway probe: what can we read from the built-in keyboard?
// 1) Is input-listening permission granted to this terminal?
// 2) What does the keyboard's HID descriptor say each key can report
//    (on/off only, or a range like pressure)?
// 3) With <seconds> > 0: print key down/up events and how long each was held.
// Usage: ./keyprobe <seconds>   (0 = only steps 1 and 2)
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hid/IOHIDLib.h>
#include <IOKit/hid/IOHIDManager.h>
#include <IOKit/hidsystem/IOHIDLib.h>  // IOHIDCheckAccess (Input Monitoring check)
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>

static const char *keyName(uint32_t u) {
    static char buf[16];
    if (u >= 0x04 && u <= 0x1D) { snprintf(buf, sizeof buf, "%c", 'A' + (u - 0x04)); return buf; }
    if (u >= 0x1E && u <= 0x26) { snprintf(buf, sizeof buf, "%c", '1' + (u - 0x1E)); return buf; }
    switch (u) {
        case 0x27: return "0";      case 0x28: return "Return"; case 0x29: return "Esc";
        case 0x2A: return "Delete"; case 0x2B: return "Tab";    case 0x2C: return "Space";
        case 0x4F: return "Right";  case 0x50: return "Left";   case 0x51: return "Down";
        case 0x52: return "Up";     case 0xE0: return "Ctrl";   case 0xE1: return "Shift";
        case 0xE2: return "Option"; case 0xE3: return "Cmd";    case 0xE5: return "RShift";
        case 0xE6: return "ROption";case 0xE7: return "RCmd";
    }
    snprintf(buf, sizeof buf, "0x%02X", u);
    return buf;
}

static double toSec(uint64_t t) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)t * tb.numer / tb.denom / 1e9;
}

static double downAt[256];
static long events = 0;
static CFIndex maxKeyValue = 0;

static void onValue(void *ctx, IOReturn r, void *sender, IOHIDValueRef v) {
    (void)ctx; (void)r; (void)sender;
    IOHIDElementRef e = IOHIDValueGetElement(v);
    uint32_t page = IOHIDElementGetUsagePage(e), usage = IOHIDElementGetUsage(e);
    CFIndex val = IOHIDValueGetIntegerValue(v);
    double t = toSec(IOHIDValueGetTimeStamp(v));
    if (page == kHIDPage_KeyboardOrKeypad && usage >= 0x04 && usage <= 0xE7) {
        events++;
        if (val > maxKeyValue) maxKeyValue = val;
        if (val) { downAt[usage] = t; printf("t=%.3f %-8s down (value=%ld)\n", t, keyName(usage), (long)val); }
        else printf("t=%.3f %-8s up   held %.0f ms\n", t, keyName(usage),
                    downAt[usage] ? (t - downAt[usage]) * 1000 : -1.0);
        fflush(stdout);
    } else if (page != kHIDPage_KeyboardOrKeypad) {
        printf("t=%.3f other page=0x%X usage=0x%X value=%ld\n", t, page, usage, (long)val);
        fflush(stdout);
    }
}

static void setInt(CFMutableDictionaryRef d, CFStringRef k, int v) {
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &v);
    CFDictionarySetValue(d, k, n);
    CFRelease(n);
}

int main(int argc, char **argv) {
    int seconds = argc > 1 ? atoi(argv[1]) : 0;

    IOHIDAccessType a = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent);
    printf("Input Monitoring for this terminal: %s\n",
           a == kIOHIDAccessTypeGranted ? "GRANTED" :
           a == kIOHIDAccessTypeDenied ? "DENIED" : "NOT ASKED YET");

    IOHIDManagerRef m = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    CFMutableDictionaryRef match = CFDictionaryCreateMutable(NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    setInt(match, CFSTR(kIOHIDDeviceUsagePageKey), kHIDPage_GenericDesktop);
    setInt(match, CFSTR(kIOHIDDeviceUsageKey), kHIDUsage_GD_Keyboard);
    IOHIDManagerSetDeviceMatching(m, match);
    CFRelease(match);

    CFSetRef devs = IOHIDManagerCopyDevices(m);
    CFIndex n = devs ? CFSetGetCount(devs) : 0;
    printf("Keyboard devices: %ld\n", (long)n);
    IOHIDDeviceRef list[32];
    if (n > 32) n = 32;
    if (devs) CFSetGetValues(devs, (const void **)list);
    for (CFIndex i = 0; i < n; i++) {
        char prod[128] = "?", trans[32] = "?";
        CFStringRef p = IOHIDDeviceGetProperty(list[i], CFSTR(kIOHIDProductKey));
        CFStringRef tr = IOHIDDeviceGetProperty(list[i], CFSTR(kIOHIDTransportKey));
        if (p) CFStringGetCString(p, prod, sizeof prod, kCFStringEncodingUTF8);
        if (tr) CFStringGetCString(tr, trans, sizeof trans, kCFStringEncodingUTF8);
        int vars = 0, arrays = 0; CFIndex varMax = 0, arrMax = 0;
        CFArrayRef els = IOHIDDeviceCopyMatchingElements(list[i], NULL, kIOHIDOptionsTypeNone);
        for (CFIndex j = 0; els && j < CFArrayGetCount(els); j++) {
            IOHIDElementRef e = (IOHIDElementRef)CFArrayGetValueAtIndex(els, j);
            if (IOHIDElementGetUsagePage(e) != kHIDPage_KeyboardOrKeypad) continue;
            if (IOHIDElementGetType(e) > kIOHIDElementTypeInput_ScanCodes) continue;  // inputs only
            CFIndex mx = IOHIDElementGetLogicalMax(e);
            if (IOHIDElementIsArray(e)) { arrays++; if (mx > arrMax) arrMax = mx; }
            else { vars++; if (mx > varMax) varMax = mx; }
        }
        printf("  [%ld] %s (%s): key inputs as on/off switches=%d (max value %ld), "
               "key-slot arrays=%d (max key index %ld)\n",
               (long)i, prod, trans, vars, (long)varMax, arrays, (long)arrMax);
        if (els) CFRelease(els);
    }
    if (devs) CFRelease(devs);

    if (seconds > 0) {
        IOHIDManagerRegisterInputValueCallback(m, onValue, NULL);
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        IOReturn r = IOHIDManagerOpen(m, kIOHIDOptionsTypeNone);
        if (r != kIOReturnSuccess) {
            printf("Could not open keyboards (0x%X). Likely missing Input Monitoring:\n"
                   "System Settings > Privacy & Security > Input Monitoring > enable your terminal app,\n"
                   "then quit and reopen the terminal.\n", r);
            return 1;
        }
        printf("Listening %d s — tap a few keys, hold one for a second, press one hard and one soft...\n",
               seconds);
        fflush(stdout);
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, false);
        IOHIDManagerClose(m, kIOHIDOptionsTypeNone);
        printf("Summary: key events=%ld, highest value any key reported=%ld\n",
               events, (long)maxKeyValue);
    }
    CFRelease(m);
    return 0;
}
