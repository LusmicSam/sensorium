#include "internal.h"

static void keepAlive(CFRunLoopTimerRef timer, void *info) { (void)timer; (void)info; }

static void *loopMain(void *arg) {
    SNLoopThread *t = arg;
    t->loop = CFRunLoopGetCurrent();
    CFRetain(t->loop);
    t->status = t->setup(t->loop);
    dispatch_semaphore_signal(t->ready);
    if (t->status >= 0) {
        // A far-future timer keeps the loop alive even if setup scheduled nothing.
        CFRunLoopTimerRef keep = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + 1e9, 1e9, 0, 0, keepAlive, NULL);
        CFRunLoopAddTimer(t->loop, keep, kCFRunLoopDefaultMode);
        CFRunLoopRun();
        CFRunLoopRemoveTimer(t->loop, keep, kCFRunLoopDefaultMode);
        CFRelease(keep);
    }
    if (t->teardown) t->teardown(t->loop);
    return NULL;
}

int32_t sn_loop_start(SNLoopThread *t) {
    if (t->running) return t->status;
    t->ready = dispatch_semaphore_create(0);
    pthread_create(&t->thread, NULL, loopMain, t);
    dispatch_semaphore_wait(t->ready, DISPATCH_TIME_FOREVER);
    if (t->status < 0) {
        pthread_join(t->thread, NULL);
        CFRelease(t->loop);
        t->loop = NULL;
        return t->status;
    }
    t->running = true;
    return t->status;
}

void sn_loop_stop(SNLoopThread *t) {
    if (!t->running) return;
    // Queue the stop as a block so it works even if the loop has not started running yet.
    CFRunLoopRef loop = t->loop;
    CFRunLoopPerformBlock(loop, kCFRunLoopDefaultMode, ^{ CFRunLoopStop(loop); });
    CFRunLoopWakeUp(loop);
    pthread_join(t->thread, NULL);
    CFRelease(t->loop);
    t->loop = NULL;
    t->running = false;
}

CFDictionaryRef sn_usage_match(int page, int usage) {
    CFNumberRef p = CFNumberCreate(NULL, kCFNumberIntType, &page);
    CFNumberRef u = CFNumberCreate(NULL, kCFNumberIntType, &usage);
    const void *k[] = {CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage")}, *v[] = {p, u};
    CFDictionaryRef d = CFDictionaryCreate(NULL, k, v, 2, &kCFTypeDictionaryKeyCallBacks,
                                           &kCFTypeDictionaryValueCallBacks);
    CFRelease(p);
    CFRelease(u);
    return d;
}

double sn_now(void) { return sn_mach_to_sec(mach_absolute_time()); }
