#include "AndroidDispatch.h"
#include <android/looper.h>
#include <android/log.h>
#include <errno.h>
#include <stdint.h>
#include <unistd.h>

// These are libdispatch's Android main-queue wakeup and drain primitives.
// The process owns this event source for the lifetime of the Swift runtime.
extern int _dispatch_get_main_queue_port_4CF(void);
extern void _dispatch_main_queue_callback_4CF(void *context);

static int on_main_queue_ready(int fd, int events, void *data) {
    (void)data;
    if (events & (ALOOPER_EVENT_ERROR | ALOOPER_EVENT_HANGUP | ALOOPER_EVENT_INVALID)) {
        __android_log_print(ANDROID_LOG_ERROR, "PetAI.MainQueue",
                            "Main queue wakeup failed: events=%d", events);
        return 0;
    }
    if (events & ALOOPER_EVENT_INPUT) {
        // libdispatch drains queued work, not the Linux eventfd notification.
        // Consume it BEFORE dispatch: work enqueued during dispatch must retain
        // its new wakeup, otherwise it can remain stranded until another event.
        uint64_t count;
        ssize_t size;
        do { size = read(fd, &count, sizeof(count)); } while (size < 0 && errno == EINTR);
        if (size < 0 && errno == EAGAIN) return 1;
        if (size != sizeof(count)) {
            __android_log_print(ANDROID_LOG_ERROR, "PetAI.MainQueue",
                                "Main queue wakeup read failed: size=%zd errno=%d", size, errno);
            return 0;
        }
        _dispatch_main_queue_callback_4CF(NULL);
    }
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
