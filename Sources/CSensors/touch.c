// Trackpad touches + haptic motor through the private MultitouchSupport framework.
// Record layout is from community reverse-engineering (OpenMultitouchSupport);
// checked on this Mac: 96-byte records, x/y in 0..1, pressure tracks force.
#include "csensors.h"
#include "internal.h"
#include <dlfcn.h>

typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint pos, vel; } MTVector;
typedef struct {
    int frame;
    double timestamp;
    int identifier, state, fingerID, handID;
    MTVector normalized;
    float total, pressure, angle, majorAxis, minorAxis;
    MTVector absolute;
    int unknown3, unknown4;
    float density;
} MTTouch;
_Static_assert(sizeof(MTTouch) == 96, "MTTouch must be 96 bytes");

typedef void *MTDeviceRef;
typedef int (*MTContactCallback)(MTDeviceRef, MTTouch *, int, double, int);

static struct {
    void *lib;
    CFMutableArrayRef (*createList)(void);
    void (*registerCb)(MTDeviceRef, MTContactCallback);
    void (*unregisterCb)(MTDeviceRef, MTContactCallback);
    void (*start)(MTDeviceRef, int);
    void (*stop)(MTDeviceRef);
    int (*getDeviceID)(MTDeviceRef, uint64_t *);
    int (*isBuiltIn)(MTDeviceRef);
    void *(*actCreate)(uint64_t);
    int (*actOpen)(void *);
    int (*actClose)(void *);
    int (*actActuate)(void *, int32_t, uint32_t, float, float);
} mt;

static bool mtLoad(void) {
    if (mt.lib) return mt.createList != NULL;
    mt.lib = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW);
    if (!mt.lib) return false;
    mt.createList = dlsym(mt.lib, "MTDeviceCreateList");
    mt.registerCb = dlsym(mt.lib, "MTRegisterContactFrameCallback");
    mt.unregisterCb = dlsym(mt.lib, "MTUnregisterContactFrameCallback");
    mt.start = dlsym(mt.lib, "MTDeviceStart");
    mt.stop = dlsym(mt.lib, "MTDeviceStop");
    mt.getDeviceID = dlsym(mt.lib, "MTDeviceGetDeviceID");
    mt.isBuiltIn = dlsym(mt.lib, "MTDeviceIsBuiltIn");
    mt.actCreate = dlsym(mt.lib, "MTActuatorCreateFromDeviceID");
    mt.actOpen = dlsym(mt.lib, "MTActuatorOpen");
    mt.actClose = dlsym(mt.lib, "MTActuatorClose");
    mt.actActuate = dlsym(mt.lib, "MTActuatorActuate");
    return mt.createList && mt.registerCb && mt.start;
}

static SNTouchCallback gTouchCb;
static void *gTouchCtx;
static CFMutableArrayRef gDevices;

static int onFrame(MTDeviceRef dev, MTTouch *t, int n, double ts, int frame) {
    (void)dev; (void)frame;
    SNTouch out[32];
    int m = n < 32 ? n : 32;
    for (int i = 0; i < m; i++) {
        out[i] = (SNTouch){
            .id = t[i].identifier, .state = t[i].state,
            .x = t[i].normalized.pos.x, .y = t[i].normalized.pos.y,
            .vx = t[i].normalized.vel.x, .vy = t[i].normalized.vel.y,
            .pressure = t[i].pressure, .total = t[i].total, .density = t[i].density,
            .majorAxis = t[i].majorAxis, .minorAxis = t[i].minorAxis, .angle = t[i].angle,
        };
    }
    if (gTouchCb) gTouchCb(out, m, ts, gTouchCtx);
    return 0;
}

int32_t sn_touch_start(SNTouchCallback cb, void *ctx) {
    if (!mtLoad()) return -1;
    if (gDevices) return (int32_t)CFArrayGetCount(gDevices);
    gTouchCb = cb;
    gTouchCtx = ctx;
    gDevices = mt.createList();
    if (!gDevices) return -2;
    CFIndex n = CFArrayGetCount(gDevices);
    for (CFIndex i = 0; i < n; i++) {
        MTDeviceRef d = (MTDeviceRef)CFArrayGetValueAtIndex(gDevices, i);
        mt.registerCb(d, onFrame);
        mt.start(d, 0);
    }
    return (int32_t)n;
}

void sn_touch_stop(void) {
    if (!gDevices) return;
    for (CFIndex i = 0; i < CFArrayGetCount(gDevices); i++) {
        MTDeviceRef d = (MTDeviceRef)CFArrayGetValueAtIndex(gDevices, i);
        if (mt.unregisterCb) mt.unregisterCb(d, onFrame);
        if (mt.stop) mt.stop(d);
    }
    CFRelease(gDevices);
    gDevices = NULL;
}

// ---- haptics ----
static void *gActuator;
static pthread_mutex_t gHapticLock = PTHREAD_MUTEX_INITIALIZER;

static int32_t hapticOpenLocked(void) {
    if (gActuator) return 0;
    if (!mtLoad() || !mt.actCreate || !mt.actOpen || !mt.actActuate || !mt.getDeviceID) return -1;
    CFMutableArrayRef list = mt.createList();
    if (!list) return -2;
    uint64_t id = 0;
    for (CFIndex i = 0; i < CFArrayGetCount(list) && !id; i++) {
        MTDeviceRef d = (MTDeviceRef)CFArrayGetValueAtIndex(list, i);
        if (!mt.isBuiltIn || mt.isBuiltIn(d)) mt.getDeviceID(d, &id);
    }
    CFRelease(list);
    if (!id) return -3;
    void *a = mt.actCreate(id);
    if (!a) return -4;
    int r = mt.actOpen(a);
    if (r) return r;
    gActuator = a;
    return 0;
}

int32_t sn_haptic_fire(int32_t actuationID, float arg1, float arg2) {
    pthread_mutex_lock(&gHapticLock);
    int32_t r = hapticOpenLocked();
    if (r == 0) r = mt.actActuate(gActuator, actuationID, 0, arg1, arg2);
    pthread_mutex_unlock(&gHapticLock);
    return r;
}

void sn_haptic_close(void) {
    pthread_mutex_lock(&gHapticLock);
    if (gActuator && mt.actClose) mt.actClose(gActuator);
    gActuator = NULL;
    pthread_mutex_unlock(&gHapticLock);
}
