#pragma once
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <dispatch/dispatch.h>

static inline double sn_mach_to_sec(uint64_t t) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)t * tb.numer / tb.denom / 1e9;
}

// A background thread that owns a CFRunLoop. setup() runs on the thread before
// the loop starts and returns a status; teardown() runs after the loop stops.
typedef struct {
    pthread_t thread;
    CFRunLoopRef loop;
    dispatch_semaphore_t ready;
    int32_t status;
    bool running;
    int32_t (*setup)(CFRunLoopRef loop);
    void (*teardown)(CFRunLoopRef loop);
} SNLoopThread;

int32_t sn_loop_start(SNLoopThread *t);  // returns setup()'s status
void sn_loop_stop(SNLoopThread *t);
CFDictionaryRef sn_usage_match(int page, int usage);
