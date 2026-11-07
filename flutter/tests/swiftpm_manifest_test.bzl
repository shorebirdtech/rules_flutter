"""Unit tests for swiftpm_manifest.bzl."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//flutter/private:swiftpm_manifest.bzl",
    "build_settings_message",
    "find_manifest_computations",
    "find_swiftpm_build_settings",
    "find_unsupported_swiftpm_dependencies",
    "shell_quote_copt",
    "swift_package_message",
    "swift_package_targets",
)

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
        ["import Foundation"],
    )
    for fragment in [
        "package:permission_handler_apple 9.6.5 sets build settings in ios/permission_handler_apple/Package.swift",
        "\n    define PERMISSION_CAMERA = enabled(\"PERMISSION_CAMERA\")\n    define PERMISSION_PHOTOS = x\n",
        "from what surrounds the build (import Foundation)",
        "the iOS build stops here",
        "flutter_pub.plugin_overlays",
        "`-D<NAME>`",
    ]:
        asserts.true(env, fragment in message, fragment + " not in " + message)
    return unittest.end(env)

build_settings_message_test = unittest.make(_build_settings_message_test_impl)

def _computations_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, [], find_manifest_computations("""
// swift-tools-version: 5.9
// import Foundation, in a comment
import PackageDescription
let package = Package(name: "foo", targets: [.target(name: "foo", cSettings: [.define("A")])])
"""))
    asserts.equals(env, ["import Foundation", "import Darwin"], find_manifest_computations("""
import PackageDescription
@preconcurrency import Foundation
import struct Darwin.size_t
let v = ProcessInfo.processInfo.environment["X"] ?? "0"
"""))
    asserts.equals(env, ["Context"], find_manifest_computations("""
import PackageDescription
let dir = Context.packageDirectory
"""))

    # A string that says `import` is not an import.
    asserts.equals(env, [], find_manifest_computations("""
import PackageDescription
let note = "do not import Foundation here"
"""))
    return unittest.end(env)

computations_test = unittest.make(_computations_test_impl)

def _shell_quote_copt_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "-DA=1", shell_quote_copt("-DA=1"))
    asserts.equals(env, "'-DV=\"x y\"'", shell_quote_copt("-DV=\"x y\""))
    asserts.equals(env, "'-DQ='\\''q'\\'''", shell_quote_copt("-DQ='q'"))
    asserts.equals(env, "'-DP=$$HOME'", shell_quote_copt("-DP=$HOME"))
    return unittest.end(env)

shell_quote_copt_test = unittest.make(_shell_quote_copt_test_impl)

def _dump(targets, products = None, **kwargs):
    """A `dump-package` result: the plugin `foo` with `targets`."""
    result = {
        "name": "foo",
        "products": products if products != None else [
            {"name": "foo", "targets": ["foo"], "type": {"library": ["automatic"]}},
        ],
        "targets": targets,

        # The Flutter framework's package, which every plugin's target names.
        "dependencies": [{"fileSystem": [{
            "identity": "flutterframework",
            "nameForTargetDependencyResolutionOnly": "FlutterFramework",
            "path": "/x/ios/FlutterFramework",
        }]}],
    }
    result.update(kwargs)
    return result

def _target(**kwargs):
    t = {
        "dependencies": [{"product": ["FlutterFramework", "FlutterFramework", None, None]}],
        "exclude": [],
        "name": "foo",
        "path": None,
        "publicHeadersPath": None,
        "resources": [],
        "settings": [],
        "sources": None,
        "type": "regular",
    }
    t.update(kwargs)
    return t

def _swift_package_target_test_impl(ctx):
    env = unittest.begin(ctx)

    # What `swift package dump-package` prints for flutter_qjs_next's shape:
    # defines in both C and C++ settings, one of them for Debug only, header
    # search paths, a linked library and the package's C++ standard; plus
    # settings for the other platform and the other configuration.
    built = swift_package_targets(_dump([_target(
        exclude = ["quickjs/VERSION.txt"],
        path = "Sources/foo",
        publicHeadersPath = "include",
        settings = [
            {"kind": {"headerSearchPath": {"_0": "."}}, "tool": "c"},
            {"kind": {"headerSearchPath": {"_0": "quickjs"}}, "tool": "c"},
            {"kind": {"define": {"_0": "CONFIG_VERSION=\"2026-06-04\""}}, "tool": "c"},
            {"condition": {"config": "debug", "platformNames": []}, "kind": {"define": {"_0": "DUMP_LEAKS=1"}}, "tool": "c"},
            {"kind": {"define": {"_0": "CONFIG_VERSION=\"2026-06-04\""}}, "tool": "cxx"},
            {"condition": {"platformNames": ["macos"]}, "kind": {"define": {"_0": "MAC_ONLY"}}, "tool": "c"},
            {"condition": {"platformNames": ["ios"]}, "kind": {"define": {"_0": "IOS_ONLY"}}, "tool": "c"},
            {"condition": {"config": "release", "platformNames": []}, "kind": {"unsafeFlags": {"_0": ["-O3"]}}, "tool": "cxx"},
            {"kind": {"define": {"_0": "SWIFT_FLAG"}}, "tool": "swift"},
            {"kind": {"enableUpcomingFeature": {"_0": "ExistentialAny"}}, "tool": "swift"},
            {"kind": {"linkedLibrary": {"_0": "c++"}}, "tool": "linker"},
            {"kind": {"linkedFramework": {"_0": "Photos"}}, "tool": "linker"},
            {"kind": {"unsafeFlags": {"_0": ["-weak_framework", "XCTest"]}}, "tool": "linker"},
        ],
    )], cxxLanguageStandard = "c++17", cLanguageStandard = None), "foo", "ios", "ios/foo")
    asserts.equals(env, [], built.problems)
    asserts.equals(env, "foo", built.main)
    asserts.equals(env, 1, len(built.targets))
    target = built.targets[0]
    asserts.equals(env, [], target.deps)
    asserts.equals(env, "ios/foo/Sources/foo", target.dir)
    asserts.equals(env, ["ios/foo/Sources/foo"], target.sources)
    asserts.equals(env, ["ios/foo/Sources/foo/quickjs/VERSION.txt"], target.exclude)
    asserts.equals(env, "ios/foo/Sources/foo/include", target.public_headers)
    asserts.equals(env, [
        "ios/foo/Sources/foo/include",
        "ios/foo/Sources/foo",
        "ios/foo/Sources/foo/quickjs",
    ], target.includes)
    asserts.equals(env, {
        "": ["-DCONFIG_VERSION=\"2026-06-04\"", "-DIOS_ONLY"],
        "debug": ["-DDUMP_LEAKS=1"],
        "release": [],
    }, target.clang_copts)
    asserts.equals(env, {"": ["-std=c++17"], "debug": [], "release": ["-O3"]}, target.cxxopts)
    asserts.equals(env, {"": [], "debug": [], "release": []}, target.conlyopts)
    asserts.equals(env, ["-DSWIFT_FLAG", "-enable-upcoming-feature", "ExistentialAny"], target.swift_copts[""])
    asserts.equals(env, ["c++"], target.sdk_dylibs[""])
    asserts.equals(env, ["Photos"], target.sdk_frameworks[""])
    asserts.equals(env, ["-weak_framework", "XCTest"], target.linkopts[""])

    # Named sources, and a target at the package's root.
    built = swift_package_targets(_dump([_target(
        path = ".",
        sources = ["Sources/foo/Plugin.mm", "Sources/foo/cpp"],
        publicHeadersPath = "Sources/foo",
    )]), "foo", "macos", "darwin/foo")
    asserts.equals(env, [], built.problems)
    target = built.targets[0]
    asserts.equals(env, "darwin/foo", target.dir)
    asserts.equals(env, ["darwin/foo/Sources/foo/Plugin.mm", "darwin/foo/Sources/foo/cpp"], target.sources)
    asserts.equals(env, "darwin/foo/Sources/foo", target.public_headers)
    return unittest.end(env)

swift_package_target_test = unittest.make(_swift_package_target_test_impl)

def _swift_package_targets_test_impl(ctx):
    env = unittest.begin(ctx)

    def shape(dump, platform = "ios"):
        built = swift_package_targets(dump, "foo", platform, "ios/foo")
        asserts.equals(env, [], built.problems)
        return built.main, [(t.name, t.deps) for t in built.targets]

    # firebase_core's shape: the product is the plugin's module and another
    # target, which the plugin's module links with it.
    asserts.equals(env, ("foo", [("foo_objc", []), ("foo", ["foo_objc"])]), shape(_dump(
        [_target(), _target(name = "foo_objc")],
        products = [{"name": "foo", "targets": ["foo", "foo_objc"], "type": {"library": ["automatic"]}}],
    )))

    # video_player_avfoundation's: the plugin's module depends on a target,
    # which depends on one target per platform; each is built after what it
    # depends on, and only for its platform.
    dump = _dump([
        _target(dependencies = [
            {"byName": ["foo_objc", None]},
            {"product": ["FlutterFramework", "FlutterFramework", None, None]},
        ]),
        _target(name = "foo_objc", dependencies = [
            {"target": ["foo_ios", {"platformNames": ["ios"]}]},
            {"target": ["foo_macos", {"platformNames": ["macos"]}]},
        ]),
        _target(name = "foo_ios"),
        _target(name = "foo_macos"),
        _target(name = "unused"),
    ])
    asserts.equals(env, ("foo", [
        ("foo_ios", []),
        ("foo_objc", ["foo_ios"]),
        ("foo", ["foo_objc"]),
    ]), shape(dump))
    asserts.equals(env, ("foo", [
        ("foo_macos", []),
        ("foo_objc", ["foo_macos"]),
        ("foo", ["foo_objc"]),
    ]), shape(dump, "macos"))

    # Two targets that depend on one target: it is built once.
    asserts.equals(env, ("foo", [
        ("shared", []),
        ("a", ["shared"]),
        ("foo", ["a", "shared"]),
    ]), shape(_dump([
        _target(dependencies = [{"byName": ["a", None]}, {"byName": ["shared", None]}]),
        _target(name = "a", dependencies = [{"byName": ["shared", None]}]),
        _target(name = "shared"),
    ])))
    return unittest.end(env)

swift_package_targets_test = unittest.make(_swift_package_targets_test_impl)

def _remote_products_test_impl(ctx):
    env = unittest.begin(ctx)

    # firebase_core's dependencies, as dump-package prints them: a remote
    # package, the Flutter framework by path, and a sibling plugin by path.
    dependencies = [
        {"sourceControl": [{
            "identity": "firebase-ios-sdk",
            "location": {"remote": [{"urlString": "https://github.com/firebase/firebase-ios-sdk"}]},
        }]},
        {"fileSystem": [{"identity": "flutterframework", "nameForTargetDependencyResolutionOnly": "FlutterFramework", "path": "/x/ios/FlutterFramework"}]},
        {"registry": [{"identity": "scope.pkg"}]},
    ]
    built = swift_package_targets(_dump(
        [_target(dependencies = [
            {"product": ["FirebaseCore", "firebase-ios-sdk", None, None]},
            {"product": ["FirebaseInstallations", "firebase-ios-sdk", None, None]},
            {"product": ["FirebaseCore", "firebase-ios-sdk", None, None]},
            {"product": ["MacOnly", "firebase-ios-sdk", None, {"platformNames": ["macos"]}]},
            {"product": ["FlutterFramework", "FlutterFramework", None, None]},
        ])],
        dependencies = dependencies,
    ), "foo", "ios", "ios/foo")
    asserts.equals(env, [], built.problems)
    asserts.equals(env, [
        ("firebase-ios-sdk", "FirebaseCore"),
        ("firebase-ios-sdk", "FirebaseInstallations"),
    ], built.targets[0].remote_products)

    # A registry package, and a package the manifest does not declare.
    asserts.equals(env, [
        "its target `foo` depends on `P` of the registry package `scope.pkg`, and rules_flutter builds only packages from source repositories (`.package(url:)`)",
        "its target `foo` depends on `Q` of the package `nowhere`, which it does not declare",
    ], swift_package_targets(_dump(
        [_target(dependencies = [
            {"product": ["P", "scope.pkg", None, None]},
            {"product": ["Q", "nowhere", None, None]},
        ])],
        dependencies = dependencies,
    ), "foo", "ios", "ios/foo").problems)
    return unittest.end(env)

remote_products_test = unittest.make(_remote_products_test_impl)

def _swift_package_target_problems_test_impl(ctx):
    env = unittest.begin(ctx)

    def problems(dump, platform = "ios"):
        return swift_package_targets(dump, "foo", platform, "ios/foo").problems

    # Flutter links the product named after the plugin.
    asserts.equals(env, [
        "it has no library product named `foo`, which Flutter links a plugin's package by",
    ], problems(_dump([_target()], products = [{"name": "Foo", "targets": ["foo"], "type": {"library": ["automatic"]}}])))

    # A product of several targets, none of them the module Flutter imports.
    asserts.equals(env, [
        "its `foo` product is the targets `a`, `b`, none of them the module `foo` Flutter imports",
    ], problems(_dump(
        [_target(name = "a"), _target(name = "b")],
        products = [{"name": "foo", "targets": ["a", "b"], "type": {"library": ["automatic"]}}],
    )))

    # A binary target the plugin's module depends on.
    asserts.equals(env, [
        "its target `sdk` is a binary target, which rules_flutter does not build",
    ], problems(_dump([
        _target(dependencies = [{"byName": ["sdk", None]}]),
        _target(name = "sdk", type = "binary"),
    ])))

    # A path that leaves the package, and a setting kind with no mapping.
    asserts.equals(env, [
        "its target `foo` names the header search path `../../../x`, outside the package",
        "its target `foo` has a swift setting rules_flutter does not apply: {\"strictMemorySafety\":{}}",
    ], problems(_dump([_target(settings = [
        {"kind": {"headerSearchPath": {"_0": "../../../x"}}, "tool": "c"},
        {"kind": {"strictMemorySafety": {}}, "tool": "swift"},
    ])])))

    message = swift_package_message("foo", "1.0.0", "macos", "darwin/foo/Package.swift", ["a", "b"])
    for fragment in [
        "package:foo 1.0.0 cannot be built for macOS as its darwin/foo/Package.swift says:\n    a\n    b\n",
        "flutter_pub.plugin_overlays",
    ]:
        asserts.true(env, fragment in message, fragment + " not in " + message)
    return unittest.end(env)

swift_package_target_problems_test = unittest.make(_swift_package_target_problems_test_impl)

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
        computations_test,
        shell_quote_copt_test,
        swift_package_target_test,
        swift_package_targets_test,
        remote_products_test,
        swift_package_target_problems_test,
    )
