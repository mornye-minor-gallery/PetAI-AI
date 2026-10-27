#include "AndroidDispatch.h"
#include <android/looper.h>
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/eventfd.h>
#include <unistd.h>

static int wakeup;
static int callbacks;
static int enqueue_during_callback;

int _dispatch_get_main_queue_port_4CF(void) { return wakeup; }

void _dispatch_main_queue_callback_4CF(void *context) {
    (void)context;
    callbacks++;
    if (enqueue_during_callback) {
        enqueue_during_callback = 0;
        assert(eventfd_write(wakeup, 1) == 0);
    }
}

int main(void) {
    ALooper_prepare(0);
    wakeup = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
    assert(wakeup >= 0);
    assert(petai_main_queue_install_event() == 1);
    assert(eventfd_write(wakeup, 1) == 0);
    assert(ALooper_pollOnce(100, NULL, NULL, NULL) == ALOOPER_POLL_CALLBACK);
    assert(callbacks == 1);
    // A handled notification must not wake an otherwise idle queue again.
    assert(ALooper_pollOnce(20, NULL, NULL, NULL) == ALOOPER_POLL_TIMEOUT);
    assert(callbacks == 1);

    enqueue_during_callback = 1;
    assert(eventfd_write(wakeup, 3) == 0);
    assert(ALooper_pollOnce(100, NULL, NULL, NULL) == ALOOPER_POLL_CALLBACK);
    assert(callbacks == 2);
    // Work arriving during dispatch must retain its wakeup.
    assert(ALooper_pollOnce(100, NULL, NULL, NULL) == ALOOPER_POLL_CALLBACK);
    assert(callbacks == 3);
    assert(ALooper_pollOnce(20, NULL, NULL, NULL) == ALOOPER_POLL_TIMEOUT);
    ALooper_removeFd(ALooper_forThread(), wakeup);
    close(wakeup);
    puts("PASS: idle sleeps, coalesced notification drains, new work wakes again");
}
