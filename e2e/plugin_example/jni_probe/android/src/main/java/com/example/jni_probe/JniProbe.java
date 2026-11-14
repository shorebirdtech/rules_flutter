package com.example.jni_probe;

/** Calls into libjni_probe.so, which the plugin builds from source. */
public final class JniProbe {
  static {
    System.loadLibrary("jni_probe");
  }

  private JniProbe() {}

  /** 42, from native code. */
  public static native int answer();
}
