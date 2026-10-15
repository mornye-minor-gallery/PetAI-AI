#ifndef PETAI_ANDROID_PLATFORM_JNI_H
#define PETAI_ANDROID_PLATFORM_JNI_H
typedef void (*PetAIPlatformReply)(const char *json);
void petai_platform_set_reply(PetAIPlatformReply callback);
int petai_platform_submit(const char *json);
int petai_platform_set_time_zone_environment(const char *identifier);
#endif
