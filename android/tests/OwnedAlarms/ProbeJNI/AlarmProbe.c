#include "AlarmProbe.h"
#include <jni.h>
#include <stdlib.h>
#include <string.h>
extern void petai_alarm_probe_submit(const char *json);
static JavaVM *probe_vm;
static jclass probe_class;
static jmethodID probe_result;

JNIEXPORT void JNICALL Java_com_byeolmuri_petai_platform_PetAIAlarmAgent_nativeSubmit(JNIEnv *env, jclass type, jbyteArray bytes) {
    if (!probe_vm) {
        (*env)->GetJavaVM(env, &probe_vm);
        probe_class = (*env)->NewGlobalRef(env, type);
        probe_result = (*env)->GetStaticMethodID(env, type, "onResult", "([B)V");
    }
    jsize count = (*env)->GetArrayLength(env, bytes);
    char *copy = malloc((size_t)count + 1);
    (*env)->GetByteArrayRegion(env, bytes, 0, count, (jbyte *)copy); copy[count] = 0;
    petai_alarm_probe_submit(copy); free(copy);
}

void petai_alarm_probe_reply(const char *json) {
    JNIEnv *env = NULL;
    int attached = (*probe_vm)->GetEnv(probe_vm, (void **)&env, JNI_VERSION_1_6) == JNI_EDETACHED;
    if (attached && (*probe_vm)->AttachCurrentThread(probe_vm, &env, NULL) != JNI_OK) return;
    jsize count = (jsize)strlen(json);
    jbyteArray bytes = (*env)->NewByteArray(env, count);
    (*env)->SetByteArrayRegion(env, bytes, 0, count, (const jbyte *)json);
    (*env)->CallStaticVoidMethod(env, probe_class, probe_result, bytes);
    (*env)->DeleteLocalRef(env, bytes);
    if (attached) (*probe_vm)->DetachCurrentThread(probe_vm);
}
