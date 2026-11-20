// Guided capture: records every sensor stream while you do a few short actions,
// so the remaining unknowns (cma records, Touch ID chip events, gyro/yaw scale) can be
// matched to what you did.
//
// Build:  clang -O1 -w -I Sources/CSensors/include -I Sources/CSensors -o /tmp/guided tools/guided.c \
//           Sources/CSensors/loop.c -framework CoreFoundation -framework IOKit
// Run:    /tmp/guided /tmp/guided.log        (in a normal terminal so the prompts show live)
#include "sensors.c"
#include <stdio.h>

static FILE *out;
static double t0;

// Three sensor threads write here, so each line is built in a buffer and written with one call.
static void emit(const char *head, const uint8_t *b, int32_t n) {
    char line[512];
    int k = snprintf(line, sizeof line, "%s", head);
    for (int32_t i = 0; i < n && i < 160 && k < (int)sizeof line - 4; i++) k += snprintf(line + k, sizeof line - k, "%02x", b[i]);
    line[k++] = '\n';
    fwrite(line, 1, k, out);
}

static void onReport(int32_t page, int32_t usage, const uint8_t *r, int32_t len, double ts, void *ctx) {
    (void)ctx;
    char head[64]; snprintf(head, sizeof head, "R %.4f %04X %02X %d ", ts - t0, page, usage, len); emit(head, r, len);
}
static void onVendorEv(int32_t page, int32_t usage, const uint8_t *d, int32_t len, double ts, void *ctx) {
    (void)ctx;
    char head[64]; snprintf(head, sizeof head, "V %.4f %04X %02X %d ", ts - t0, page, usage, len); emit(head, d, len);
}
static void onHidEv(const char *cls, uint32_t type, const uint8_t *d, int32_t len, double ts, void *ctx) {
    (void)ctx;
    char head[128]; snprintf(head, sizeof head, "E %.4f %s %u %d ", ts - t0, cls, type, len); emit(head, d, len);
}

static const char *steps[] = {
    "Hands off: don't touch anything",
    "Cover the area next to the camera with your hand",
    "Slowly close the lid halfway, then open it again",
    "REST a finger on the Touch ID key (top right). Do NOT press it",
    "Tap the palm rest 3-4 times",
    "Turn the Mac flat on the desk by about 90 degrees, then back",
    "Pick the Mac up, hold it and sway gently, then put it down",
};

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "/tmp/guided.log";
    out = fopen(path, "w");
    if (!out) { perror("open log"); return 1; }
    t0 = sn_now();
    printf("Recording to %s\nspu streams: %d   motion events: %s   touch-id/button services: %d\n\n", path,
           sn_spu_start(onReport, NULL), sn_vendor_start(onVendorEv, NULL) == 0 ? "on" : "off",
           sn_events_start(onHidEv, NULL));
    int n = sizeof steps / sizeof *steps;
    for (int i = 0; i < n; i++) {
        printf(">>> step %d/%d (6 s): %s\n", i + 1, n, steps[i]);
        fflush(stdout);
        fprintf(out, "P %.4f %d %s\n", sn_now() - t0, i, steps[i]);
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 6, false);
    }
    sn_spu_stop();
    sn_vendor_stop();
    sn_events_stop();
    fclose(out);
    printf("\nDone. Tell Claude it's finished.\n");
    return 0;
}
