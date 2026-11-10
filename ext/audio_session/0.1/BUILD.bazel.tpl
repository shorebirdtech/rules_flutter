# Bazel-native overlay for `package:audio_session` 0.1.x.
#
# audio_session's iOS / macOS sources `#import <AVFoundation/AVFoundation.h>`
# without the plugin declaring the framework, and this overlay names it in
# `sdk_frameworks`. It sets no `AUDIO_SESSION_MICROPHONE`, which the 0.1.x
# manifests default to 1, so it builds the plugin without its microphone code.
# Later versions are built from their Package.swift for each app, which
# `swift_package_environment` sets the variable for.
#
# Placeholders (PKG, VERSION, LANGUAGE_VERSION, DEPS, LICENSE — written in
# braces below, and deliberately not in this comment, because substitution
# rewrites comment text too) are injected by `flutter_pub_package`'s
# `_resolve_overlay_template`. The overlay sits under `0.1/`, so any 0.1.x
# audio_session version routes here.

load("@rules_dart//dart:defs.bzl", "dart_package_metadata")
load("@rules_flutter//flutter:defs.bzl", "flutter_plugin", "flutter_plugin_platform")
load("@rules_flutter//flutter:macos.bzl", "flutter_apple_plugin_library")

dart_package_metadata(
    name = "pubspec-metadata",
    package_name = "{PKG}",
    language_version = "{LANGUAGE_VERSION}",
    {LICENSE}
    visibility = ["//visibility:public"],
)

flutter_plugin(
    name = "{PKG}",
    srcs = glob(
        ["lib/**/*.dart"],
        allow_empty = True,
    ),
    exports = select({
        "@platforms//os:android": ["//android:lib"],
        "//conditions:default": [],
    }),
    package = ":pubspec-metadata",
    platforms = [
        ":plugin_android",
        ":plugin_ios",
        ":plugin_macos",
        ":plugin_web",
    ],
    visibility = ["//visibility:public"],
    deps = [
        {DEPS}
    ],
)

flutter_plugin_platform(
    name = "plugin_android",
    group = "com.ryanheise.audio_session",
    package = "com.ryanheise.audio_session",
    platform = "android",
    plugin_class = "AudioSessionPlugin",
)

flutter_plugin_platform(
    name = "plugin_ios",
    lib = ":{PKG}_apple_ios",
    platform = "ios",
    plugin_class = "AudioSessionPlugin",
)

flutter_plugin_platform(
    name = "plugin_macos",
    lib = ":{PKG}_apple_macos",
    platform = "macos",
    plugin_class = "AudioSessionPlugin",
)

flutter_plugin_platform(
    name = "plugin_web",
    file_name = "audio_session_web.dart",
    platform = "web",
    plugin_class = "AudioSessionWeb",
)

flutter_apple_plugin_library(
    name = "{PKG}_apple_macos",
    srcs = glob(
        [
            "macos/{PKG}/Sources/{PKG}/**/*.swift",
            "macos/{PKG}/Sources/{PKG}/**/*.m",
            "macos/{PKG}/Sources/{PKG}/**/*.mm",
            "macos/{PKG}/Sources/{PKG}/**/*.h",
        ],
        allow_empty = True,
        exclude = [
            "macos/{PKG}/Sources/{PKG}/test/**",
            "macos/{PKG}/Sources/{PKG}/example/**",
        ],
    ),
    includes = [
        "macos/{PKG}/Sources/{PKG}/include",
        "macos/{PKG}/Sources/{PKG}/include/{PKG}",
    ],
    module_name = "{PKG}",
    platform = "macos",
    sdk_frameworks = ["AVFoundation"],
    visibility = ["//visibility:public"],
)

flutter_apple_plugin_library(
    name = "{PKG}_apple_ios",
    srcs = glob(
        [
            "ios/{PKG}/Sources/{PKG}/**/*.swift",
            "ios/{PKG}/Sources/{PKG}/**/*.m",
            "ios/{PKG}/Sources/{PKG}/**/*.mm",
            "ios/{PKG}/Sources/{PKG}/**/*.h",
        ],
        allow_empty = True,
        exclude = [
            "ios/{PKG}/Sources/{PKG}/test/**",
            "ios/{PKG}/Sources/{PKG}/example/**",
        ],
    ),
    includes = [
        "ios/{PKG}/Sources/{PKG}/include",
        "ios/{PKG}/Sources/{PKG}/include/{PKG}",
    ],
    module_name = "{PKG}",
    platform = "ios",
    sdk_frameworks = ["AVFoundation"],
    visibility = ["//visibility:public"],
)
