# package:jni 1.x Android sub-package overlay.
#
# Mirrors what `make_android_subpackage_build_content` would auto-generate,
# plus the two things Gradle wires up that autogen cannot see:
#
#   * `//:jni_java_support_srcs` — the shared JNI support classes from
#     `java/src/main/java` (PortContinuation, PortProxyBuilder, PortCleaner,
#     JniUtils), folded in by the plugin's `sourceSets` srcDirs declaration.
#     dartjni.c resolves them via JNI at runtime, so they must be in the dex.
#   * kotlinx-coroutines-core — PortContinuation implements
#     `kotlin.coroutines.Continuation` and returns `Dispatchers.getIO()`.
#
# Placeholder substitution is performed by `_resolve_overlay_template`;
# this comment names none of them, because it rewrites comment text too.

load("@rules_flutter//flutter:android.bzl", "flutter_android_engine")
load("@rules_flutter//flutter/private:android_build_config.bzl", "android_build_config")
load("@rules_kotlin//kotlin:android.bzl", "kt_android_library")

# Private engine target — gives the plugin's Java the FlutterPlugin SPI
# on the compile classpath. Always arm64; Java bytecode is
# ABI-independent. neverlink, so the APK carries only the app's engine, of
# each ABI of --@rules_android//flags:android_platforms.
flutter_android_engine(
    name = "_engine",
    neverlink = True,
    visibility = ["//visibility:private"],
)

# BuildConfig for the plugin's namespace, which Gradle generates and
# rules_android does not. DEBUG and BUILD_TYPE follow the build mode.
android_build_config(
    name = "_build_config",
    package = "com.github.dart_lang.jni",
)

kt_android_library(
    name = "lib",
    srcs = glob(
        [
            "src/main/**/*.kt",
            "src/main/**/*.java",
        ],
        allow_empty = True,
    ) + ["//:jni_java_support_srcs"],
    custom_package = "com.github.dart_lang.jni",
    exports_manifest = 1,
    manifest = "src/main/AndroidManifest.xml",
    proguard_specs = ["consumer-rules.pro"],
    visibility = ["//visibility:public"],
    deps = [
        ":_build_config",
        ":_engine",
        "@rules_android_maven//:androidx_annotation_annotation",
        "@rules_android_maven//:androidx_lifecycle_lifecycle_common",
        "@rules_android_maven//:org_jetbrains_kotlin_kotlin_stdlib",
        "@rules_android_maven//:org_jetbrains_kotlinx_kotlinx_coroutines_core",
    ],
)
