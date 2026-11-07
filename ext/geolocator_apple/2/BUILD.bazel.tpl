# Bazel-native overlay for `package:geolocator_apple` 2.x.
#
# geolocator_apple's Package.swift sets one define from the environment of the
# build: BYPASS_PERMISSION_LOCATION_ALWAYS is 1 when the variable of that name
# is 1, and 0 otherwise. A Bazel build does not pass the environment to the
# manifest, and rules_flutter does not evaluate it, so a plugin whose manifest
# sets defines fails the app rather than build without them. This overlay
# builds the plugin as `flutter build` does with the variable unset: the
# define is 0, which is also the sources' own default, and the plugin asks
# for "always" location access when the app does. An app that wants the
# bypass supplies its own overlay for geolocator_apple
# (flutter_pub.plugin_overlays), adding
# `copts = ["-DBYPASS_PERMISSION_LOCATION_ALWAYS=1"]` to both libraries;
# a user's overlay replaces this one.
#
# Everything else is what rules_flutter generates for the package.
#
# Placeholders (PKG, LANGUAGE_VERSION, DEPS, LICENSE — written in braces
# below, and deliberately not in this comment, because substitution rewrites
# comment text too) are injected by `flutter_pub_package`'s
# `_resolve_overlay_template`. The overlay sits under `2/`, so any 2.x
# geolocator_apple version routes here.

load("@rules_flutter//flutter:defs.bzl", "flutter_plugin")
load("@rules_flutter//flutter:macos.bzl", "flutter_apple_plugin_library")

_SRC = "darwin/{PKG}/Sources/{PKG}"

flutter_plugin(
    name = "{PKG}",
    srcs = glob(
        ["lib/**/*.dart"],
        allow_empty = True,
    ),
    apple_libs = select({
        "@platforms//os:macos": [":{PKG}_apple_macos"],
        "@platforms//os:ios": [":{PKG}_apple_ios"],
        "//conditions:default": [],
    }),
    apple_privacy_files = select({
        "@platforms//os:macos": [_SRC + "/PrivacyInfo.xcprivacy"],
        "@platforms//os:ios": [_SRC + "/PrivacyInfo.xcprivacy"],
        "//conditions:default": [],
    }),
    language_version = "{LANGUAGE_VERSION}",
    package_name = "{PKG}",
    {LICENSE}
    plugin_platforms_json = "{\"ios\":{\"dartPluginClass\":\"GeolocatorApple\",\"pluginClass\":\"GeolocatorPlugin\",\"sharedDarwinSource\":true},\"macos\":{\"dartPluginClass\":\"GeolocatorApple\",\"pluginClass\":\"GeolocatorPlugin\",\"sharedDarwinSource\":true}}",
    visibility = ["//visibility:public"],
    deps = [
        {DEPS}
    ],
)

[
    flutter_apple_plugin_library(
        name = "{PKG}_apple_" + platform,
        srcs = glob([
            _SRC + "/**/*.m",
            _SRC + "/**/*.h",
        ]),
        includes = [
            _SRC + "/include",
            _SRC + "/include/{PKG}",
        ],
        module_name = "{PKG}",
        platform = platform,
        sdk_frameworks = ["CoreLocation"],
        visibility = ["//visibility:public"],
    )
    for platform in ["macos", "ios"]
]
