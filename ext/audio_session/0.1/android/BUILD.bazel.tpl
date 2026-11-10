# audio_session 0.1.x Android sub-package overlay.
#
# Mirrors what `make_android_subpackage_build_content` would auto-generate
# for a plugin with Android sources, with no audio_session-specific
# additions — but the top-level overlay short-circuits the auto-gen path,
# so we ship the sub-package alongside it. Placeholder substitution is
# performed by `_resolve_overlay_template`; this comment names none of
# them, because it rewrites comment text too.

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
    package = "com.ryanheise.audio_session",
)

kt_android_library(
    name = "lib",
    srcs = glob(
        [
            "src/main/**/*.kt",
            "src/main/**/*.java",
        ],
        allow_empty = True,
    ),
    custom_package = "com.ryanheise.audio_session",
    visibility = ["//visibility:public"],
    deps = [
        ":_engine",
        ":_build_config",
        "@rules_android_maven//:androidx_annotation_annotation",
        "@rules_android_maven//:androidx_lifecycle_lifecycle_common",
        "@rules_android_maven//:androidx_media_media",
    ],
)
