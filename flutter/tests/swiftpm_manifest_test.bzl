"""Unit tests for swiftpm_manifest.bzl."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:swiftpm_manifest.bzl", "build_settings_message", "find_swiftpm_build_settings", "find_unsupported_swiftpm_dependencies")

def _plain_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, [], find_unsupported_swiftpm_dependencies("""
// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "foo",
    platforms: [.iOS("13.0")],
    products: [.library(name: "foo", targets: ["foo"])],
    dependencies: [],
    targets: [.target(name: "foo", linkerSettings: [.linkedFramework("AVFoundation")])]
)
""", "ios/foo"))
    return unittest.end(env)

plain_test = unittest.make(_plain_test_impl)

def _remote_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, [
        "https://github.com/apple/swift-log",
        "https://example.com/b.git",
        "registry package scope.name",
    ], find_unsupported_swiftpm_dependencies("""
let package = Package(
    dependencies: [
        .package(url: "https://github.com/apple/swift-log", from: "1.0.0"),
        .package(name: "b", url: "https://example.com/b.git", .upToNextMajor(from: "2.0.0")),
        .package(id: "scope.name", from: "1.0.0"),
        // .package(url: "https://example.com/commented", from: "1.0.0"),
    ],
    targets: [.target(name: "foo", dependencies: [.product(name: "Logging", package: "swift-log")])]
)
""", "darwin/foo"))
    return unittest.end(env)

remote_test = unittest.make(_remote_test_impl)

def _local_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, [], find_unsupported_swiftpm_dependencies("""
    dependencies: [.package(path: "../foo_shared"), .package(name: "x", path: "Sub"), .package(path: ".")],
""", "ios/foo"))
    asserts.equals(env, ["path ../../../other", "path /abs/dir"], find_unsupported_swiftpm_dependencies("""
    dependencies: [.package(path: "../../../other"), .package(name: "x", path: "/abs/dir")],
""", "ios/foo"))
    asserts.equals(env, ["path ../../../other"], find_unsupported_swiftpm_dependencies("""
    dependencies: [.package(path: "../../../other")],
""", "ios/foo"))
    return unittest.end(env)

local_test = unittest.make(_local_test_impl)

def _no_settings_test_impl(ctx):
    env = unittest.begin(ctx)

    # Header search paths and linker settings are not build settings of this
    # kind: a missing one fails the compile or the link by itself.
    asserts.equals(env, [], find_swiftpm_build_settings("""
let package = Package(
    targets: [
        .target(
            name: "foo",
            cSettings: [.headerSearchPath("include/foo")],
            linkerSettings: [.linkedFramework("AVFoundation")]
        ),
    ]
)
"""))
    return unittest.end(env)

no_settings_test = unittest.make(_no_settings_test_impl)

def _computed_defines_test_impl(ctx):
    env = unittest.begin(ctx)

    # permission_handler_apple's shape: the defines are built into a list
    # before the package, from what the manifest reads, and the list is
    # concatenated into cSettings.
    asserts.equals(env, [
        "define PERMISSION_CAMERA = enabled(\"PERMISSION_CAMERA\", plistKeys: \"NSCameraUsageDescription\")",
        "define PERMISSION_NOTIFICATIONS = enabled(\"PERMISSION_NOTIFICATIONS\", defaultValue: \"1\")",
    ], find_swiftpm_build_settings("""
let permissionDefines: [CSetting] = [
    // dart: PermissionGroup.camera
    .define("PERMISSION_CAMERA",
            to: enabled("PERMISSION_CAMERA",
                        plistKeys: "NSCameraUsageDescription")),
    .define("PERMISSION_NOTIFICATIONS",
            to: enabled("PERMISSION_NOTIFICATIONS", defaultValue: "1")),
    // .define("PERMISSION_COMMENTED", to: "1"),
]
let package = Package(
    targets: [
        .target(
            name: "permission_handler_apple",
            cSettings: [
                .headerSearchPath("."),
            ] + permissionDefines
        ),
    ]
)
"""))

    # geolocator_apple's: a define from an environment variable.
    asserts.equals(env, [
        "define BYPASS_PERMISSION_LOCATION_ALWAYS = bypassLocationAlways",
    ], find_swiftpm_build_settings("""
let bypassLocationAlways = ProcessInfo.processInfo.environment["BYPASS_PERMISSION_LOCATION_ALWAYS"] == "1" ? "1" : "0"
let package = Package(
    targets: [
        .target(
            name: "geolocator_apple",
            cSettings: [
                .headerSearchPath("include/geolocator_apple"),
                .define("BYPASS_PERMISSION_LOCATION_ALWAYS", to: bypassLocationAlways)
            ]
        ),
    ]
)
"""))
    return unittest.end(env)

computed_defines_test = unittest.make(_computed_defines_test_impl)

def _literal_settings_test_impl(ctx):
    env = unittest.begin(ctx)

    # Literal defines, one with a value built by interpolation, a Swift
    # condition and unsafe flags, each listed as the manifest writes it.
    asserts.equals(env, [
        "define LIBRARY_VERSION = \"v\\(libraryVersion)\"",
        "define LIBRARY_NAME = \"flutter-fire-fcm\"",
        "define FLT_FIREBASE_SDK_13",
        "define DEBUG_ONLY, .when(configuration: .debug)",
        "unsafeFlags([\"-fno-objc-arc\"])",
    ], find_swiftpm_build_settings("""
let package = Package(
    targets: [
        .target(
            name: "foo",
            cSettings: [
                .define("LIBRARY_VERSION", to: "v\\(libraryVersion)"),
                .define("LIBRARY_NAME", to: "flutter-fire-fcm"),
                .define("FLT_FIREBASE_SDK_13"),
            ],
            swiftSettings: [.define("DEBUG_ONLY", .when(configuration: .debug))],
            linkerSettings: [.unsafeFlags(["-fno-objc-arc"])]
        ),
    ]
)
"""))
    return unittest.end(env)

literal_settings_test = unittest.make(_literal_settings_test_impl)

def _build_settings_message_test_impl(ctx):
    env = unittest.begin(ctx)
    message = build_settings_message(
        "permission_handler_apple",
        "9.6.5",
        "ios",
        "ios/permission_handler_apple/Package.swift",
        ["define PERMISSION_CAMERA = enabled(\"PERMISSION_CAMERA\")", "define PERMISSION_PHOTOS = x"],
    )
    for fragment in [
        "package:permission_handler_apple 9.6.5 sets build settings in ios/permission_handler_apple/Package.swift",
        "\n    define PERMISSION_CAMERA = enabled(\"PERMISSION_CAMERA\")\n    define PERMISSION_PHOTOS = x\n",
        "the iOS build stops here",
        "flutter_pub.plugin_overlays",
        "`-D<NAME>`",
    ]:
        asserts.true(env, fragment in message, fragment + " not in " + message)
    return unittest.end(env)

build_settings_message_test = unittest.make(_build_settings_message_test_impl)

def swiftpm_manifest_test_suite(name):
    unittest.suite(
        name,
        plain_test,
        remote_test,
        local_test,
        no_settings_test,
        computed_defines_test,
        literal_settings_test,
        build_settings_message_test,
    )
