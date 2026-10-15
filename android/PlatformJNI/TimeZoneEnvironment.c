#include "AndroidPlatformJNI.h"
#include <stdlib.h>
#include <time.h>

int petai_platform_set_time_zone_environment(const char *identifier) {
    if (!identifier || setenv("TZ", identifier, 1) != 0) return -1;
    tzset();
    return 0;
}
