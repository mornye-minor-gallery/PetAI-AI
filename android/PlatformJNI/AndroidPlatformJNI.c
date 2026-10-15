#include "AndroidPlatformJNI.h"
#include <jni.h>
#include <android/log.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static JavaVM *platform_vm;
static jclass platform_class;
static jmethodID platform_submit;
static PetAIPlatformReply platform_reply;
static pthread_mutex_t platform_lock = PTHREAD_MUTEX_INITIALIZER;
extern int petai_android_apply_time_zone(const char *identifier);

JNIEXPORT jboolean JNICALL
Java_com_byeolmuri_petai_platform_PetAIPlatformBridge_nativeSetTimeZone(JNIEnv *env, jclass type, jbyteArray utf8) {
    (void)type;
    jsize size = (*env)->GetArrayLength(env, utf8);
    if (size < 1 || size > 128) return JNI_FALSE;
    char identifier[129];
    (*env)->GetByteArrayRegion(env, utf8, 0, size, (jbyte *)identifier);
    if ((*env)->ExceptionCheck(env)) return JNI_FALSE;
    identifier[size] = 0;
    return petai_android_apply_time_zone(identifier) == 1 ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jboolean JNICALL
Java_com_byeolmuri_petai_platform_PetAIPlatformBridge_nativeInstall(JNIEnv *env, jclass type) {
    if (gettid() != getpid()) return JNI_FALSE;
    pthread_mutex_lock(&platform_lock);
    if (platform_class) {
        jboolean same = (*env)->IsSameObject(env, type, platform_class);
        pthread_mutex_unlock(&platform_lock);
        return same;
    }
    JavaVM *vm = NULL;
    jmethodID method = (*env)->GetStaticMethodID(env, type, "submit", "([B)V");
    jclass retained = method ? (*env)->NewGlobalRef(env, type) : NULL;
    int valid = retained && (*env)->GetJavaVM(env, &vm) == JNI_OK;
    if (valid) { platform_vm = vm; platform_class = retained; platform_submit = method; }
    else if (retained) (*env)->DeleteGlobalRef(env, retained);
    pthread_mutex_unlock(&platform_lock);
    return valid ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT void JNICALL
Java_com_byeolmuri_petai_platform_PetAIPlatformBridge_nativeComplete(JNIEnv *env, jclass type, jbyteArray utf8) {
    (void)type;
    if (!utf8) return;
    jsize size = (*env)->GetArrayLength(env, utf8);
    if (size < 1 || size > 131072) return;
    char *copy = malloc((size_t)size + 1);
    if (!copy) return;
    (*env)->GetByteArrayRegion(env, utf8, 0, size, (jbyte *)copy);
    if ((*env)->ExceptionCheck(env)) { free(copy); return; }
    copy[size] = 0;
    pthread_mutex_lock(&platform_lock);
    PetAIPlatformReply callback = platform_reply;
    pthread_mutex_unlock(&platform_lock);
    if (callback) callback(copy);
    free(copy);
}

void petai_platform_set_reply(PetAIPlatformReply callback) {
    pthread_mutex_lock(&platform_lock); platform_reply = callback; pthread_mutex_unlock(&platform_lock);
}

int petai_platform_submit(const char *json) {
    if (!json) return -1;
    size_t size = strlen(json);
    if (!size || size > 32768) return -1;
    pthread_mutex_lock(&platform_lock);
    JavaVM *vm = platform_vm; jclass type = platform_class; jmethodID method = platform_submit;
    pthread_mutex_unlock(&platform_lock);
    if (!vm || !type || !method) return -2;
    JNIEnv *env = NULL;
    int attached = 0;
    jint status = (*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6);
    if (status == JNI_EDETACHED) {
        if ((*vm)->AttachCurrentThread(vm, &env, NULL) != JNI_OK) return -3;
        attached = 1;
    } else if (status != JNI_OK) return -3;
    // JNI modified UTF-8 changes supplementary Unicode. Transfer real UTF-8 bytes
    // in both directions so Korean text and emoji survive without normalization.
    jbyteArray bytes = (*env)->NewByteArray(env, (jsize)size);
    if (bytes) {
        (*env)->SetByteArrayRegion(env, bytes, 0, (jsize)size, (const jbyte *)json);
        if (!(*env)->ExceptionCheck(env)) (*env)->CallStaticVoidMethod(env, type, method, bytes);
        (*env)->DeleteLocalRef(env, bytes);
    }
    int failed = !bytes || (*env)->ExceptionCheck(env);
    if ((*env)->ExceptionCheck(env)) {
        // Never print Java exception payloads, which can contain user arguments.
        (*env)->ExceptionClear(env);
        __android_log_print(ANDROID_LOG_ERROR, "PetAI.Platform", "JNI submission failed");
    }
    if (attached) (*vm)->DetachCurrentThread(vm);
    return failed ? -4 : 1;
}
