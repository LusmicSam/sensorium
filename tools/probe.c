// Throwaway probe: can we read per-finger trackpad data (incl. pressure)
// from the private MultitouchSupport.framework on this Mac?
// Usage: ./probe <seconds>   (0 = just check the API and devices)
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint pos, vel; } MTVector;
// Layout per OpenMultitouchSupport (reverse-engineered, unverified here).
typedef struct {
    int frame;
    double timestamp;
    int identifier, state, fingerID, handID;
    MTVector normalized;
    float total, pressure, angle, majorAxis, minorAxis;
    MTVector absolute;
    int reserved[2]; // Keep these 8 bytes so density stays at the right offset.
    float density;
} MTTouch;

typedef void *MTDeviceRef;
typedef int (*MTCallback)(MTDeviceRef, MTTouch *, int, double, int);

static CFMutableArrayRef (*MTDeviceCreateList)(void);
static void (*MTRegisterContactFrameCallback)(MTDeviceRef, MTCallback);
static void (*MTUnregisterContactFrameCallback)(MTDeviceRef, MTCallback);
static void (*MTDeviceStart)(MTDeviceRef, int);
static void (*MTDeviceStop)(MTDeviceRef);
static int (*MTDeviceGetFamilyID)(MTDeviceRef, int *);
static int (*MTDeviceIsBuiltIn)(MTDeviceRef);

static long frames = 0, touchFrames = 0;
static float maxPressure = 0, maxTotal = 0, maxDensity = 0;
static double lastPrint = 0;

static int onFrame(MTDeviceRef dev, MTTouch *t, int n, double ts, int frame) {
    (void)dev; (void)frame;
    frames++;
    if (n > 0) touchFrames++;
    for (int i = 0; i < n; i++) {
        if (t[i].pressure > maxPressure) maxPressure = t[i].pressure;
        if (t[i].total > maxTotal) maxTotal = t[i].total;
        if (t[i].density > maxDensity) maxDensity = t[i].density;
    }
    if (n > 0 && ts - lastPrint >= 0.1) {  // at most 10 lines/sec
        lastPrint = ts;
        for (int i = 0; i < n; i++)
            printf("t=%.2f finger=%d state=%d x=%.3f y=%.3f total=%.3f pressure=%.3f "
                   "density=%.3f major=%.2f minor=%.2f angle=%.2f\n",
                   ts, t[i].identifier, t[i].state, t[i].normalized.pos.x,
                   t[i].normalized.pos.y, t[i].total, t[i].pressure, t[i].density,
                   t[i].majorAxis, t[i].minorAxis, t[i].angle);
        fflush(stdout);
    }
    return 0;
}

#define LOAD(sym) do { *(void **)&sym = dlsym(h, #sym); \
    printf("  %-34s %s\n", #sym, sym ? "found" : "MISSING"); } while (0)

int main(int argc, char **argv) {
    int seconds = argc > 1 ? atoi(argv[1]) : 0;
    void *h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/"
                     "MultitouchSupport", RTLD_NOW);
    if (!h) { printf("dlopen failed: %s\n", dlerror()); return 1; }
    printf("MultitouchSupport loaded. sizeof(MTTouch)=%zu\nSymbols:\n", sizeof(MTTouch));
    LOAD(MTDeviceCreateList); LOAD(MTRegisterContactFrameCallback);
    LOAD(MTUnregisterContactFrameCallback); LOAD(MTDeviceStart); LOAD(MTDeviceStop);
    LOAD(MTDeviceGetFamilyID); LOAD(MTDeviceIsBuiltIn);
    if (!MTDeviceCreateList || !MTRegisterContactFrameCallback || !MTDeviceStart) return 1;

    CFMutableArrayRef list = MTDeviceCreateList();
    CFIndex count = list ? CFArrayGetCount(list) : 0;
    printf("Devices: %ld\n", (long)count);
    for (CFIndex i = 0; i < count; i++) {
        MTDeviceRef d = (MTDeviceRef)CFArrayGetValueAtIndex(list, i);
        int fam = -1;
        if (MTDeviceGetFamilyID) MTDeviceGetFamilyID(d, &fam);
        printf("  [%ld] familyID=%d builtIn=%d\n", (long)i, fam,
               MTDeviceIsBuiltIn ? MTDeviceIsBuiltIn(d) : -1);
        MTRegisterContactFrameCallback(d, onFrame);
        MTDeviceStart(d, 0);
    }
    if (seconds > 0) {
        printf("Listening %d s — rest a finger, then press lightly, then hard...\n", seconds);
        fflush(stdout);
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, false);
    }
    for (CFIndex i = 0; i < count; i++) {
        MTDeviceRef d = (MTDeviceRef)CFArrayGetValueAtIndex(list, i);
        if (MTUnregisterContactFrameCallback) MTUnregisterContactFrameCallback(d, onFrame);
        if (MTDeviceStop) MTDeviceStop(d);
    }
    printf("Summary: frames=%ld withTouch=%ld maxPressure=%.3f maxTotal=%.3f maxDensity=%.3f\n",
           frames, touchFrames, maxPressure, maxTotal, maxDensity);
    return 0;
}
