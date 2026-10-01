#include "AndroidDispatch.h"
#include <android/looper.h>
#include <unistd.h>

// These are libdispatch's Android main-queue wakeup and drain primitives.
// The process owns this event source for the lifetime of the Swift runtime.
extern int _dispatch_get_main_queue_port_4CF(void);
extern void _dispatch_main_queue_callback_4CF(void *context);

static int on_main_queue_ready(int fd, int events, void *data) {
    (void)fd;
    (void)data;
    if (events & ALOOPER_EVENT_INPUT) _dispatch_main_queue_callback_4CF(NULL);
    return 1;
}

int petai_main_queue_install_event(void) {
    if (!petai_is_android_main_thread()) return -3;
    ALooper *looper = ALooper_forThread();
    if (!looper) return -1;
    int fd = _dispatch_get_main_queue_port_4CF();
    if (fd < 0) return -2;
    return ALooper_addFd(looper, fd, ALOOPER_POLL_CALLBACK,
                         ALOOPER_EVENT_INPUT, on_main_queue_ready, NULL);
}

int petai_is_android_main_thread(void) {
    return gettid() == getpid();
}

void petai_main_queue_drain(void) {
    _dispatch_main_queue_callback_4CF(NULL);
}
