#include <jni.h>

JNIEXPORT jint JNICALL
Java_com_example_jni_1probe_JniProbe_answer(JNIEnv *env, jclass cls) {
  (void)env;
  (void)cls;
  return 42;
}
