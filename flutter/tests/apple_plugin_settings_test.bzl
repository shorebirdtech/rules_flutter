"""An Apple plugin's build settings, supplied by an overlay, reach its compile.

A plugin's C-family sources are compiled with module autolinking on, as Xcode
compiles them, so the SDK frameworks they import are linked into the app.

`apple_plugin_fixture/` is a plugin in SwiftPM's layout whose behaviour depends
on a define, as `permission_handler_apple`'s does: `FixturePlugin.feature` is
`on` only when `FIXTURE_FEATURE` is set. Its private header uses `NS_ENUM`
without importing Foundation, as `permission_handler_apple`'s
`PermissionHandlerEnums.h` does, and so cannot be part of the plugin's module.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("//flutter/private:flutter_apple_plugin_library.bzl", "flutter_apple_plugin_library")

_SRC = "apple_plugin_fixture/Sources/fixture"

def _define_reaches_the_compile_impl(ctx):
    env = analysistest.begin(ctx)
    compiles = [a for a in analysistest.target_actions(env) if a.mnemonic == "ObjcCompile"]
    asserts.equals(env, 1, len(compiles), [a.mnemonic for a in analysistest.target_actions(env)])
    argv = compiles[0].argv
    asserts.true(env, "-DFIXTURE_FEATURE" in argv, argv)

    # Autolinking is on, as under Xcode: after the toolchain's `-fno-autolink`,
    # which the last of the two overrides.
    autolink = [i for i, a in enumerate(argv) if a in ("-fautolink", "-fno-autolink")]
    asserts.true(env, autolink and argv[autolink[-1]] == "-fautolink", argv)

    # Only the header under `include/` is the module's; the private one is
    # compiled with the sources.
    context = analysistest.target_under_test(env)[CcInfo].compilation_context
    public = [f.basename for f in context.direct_public_headers]
    private = [f.basename for f in context.direct_private_headers]
    asserts.equals(env, ["FixturePlugin.h"], public)
    asserts.equals(env, ["FixtureInternal.h"], private)
    return analysistest.end(env)

_define_reaches_the_compile_test = analysistest.make(_define_reaches_the_compile_impl)

def _swift_version(env):
    compiles = [a for a in analysistest.target_actions(env) if a.mnemonic == "SwiftCompile"]
    asserts.equals(env, 1, len(compiles), [a.mnemonic for a in analysistest.target_actions(env)])
    argv = compiles[0].argv
    versions = [argv[i + 1] for i in range(len(argv) - 1) if argv[i] == "-swift-version"]
    return versions

def _swift_6_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.equals(env, ["6"], _swift_version(env))
    return analysistest.end(env)

_swift_6_test = analysistest.make(_swift_6_impl)

def _swift_5_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.equals(env, ["5"], _swift_version(env))
    return analysistest.end(env)

_swift_5_test = analysistest.make(_swift_5_impl)

def apple_plugin_settings_test_suite(name):
    """The tests, and the fixture targets they analyse.

    Args:
        name: Suite name.
    """
    macos = ["@platforms//os:macos"]
    flutter_apple_plugin_library(
        name = name + "_fixture_apple_macos",
        srcs = native.glob([_SRC + "/**/*.m", _SRC + "/**/*.h"]),
        copts = ["-DFIXTURE_FEATURE"],
        includes = [_SRC, _SRC + "/include/fixture"],
        module_name = "fixture",
        platform = "macos",
    )
    _define_reaches_the_compile_test(
        name = name + "_define_reaches_the_compile",
        target_under_test = ":_%s_fixture_apple_macos__objc" % name,
        target_compatible_with = macos,
    )

    # A Swift package target in Swift 6 mode (`swift-tools-version: 6.0`) is
    # compiled so; the default is Swift 5.
    for mode in ("5", "6"):
        flutter_apple_plugin_library(
            name = "{}_swift_{}_apple_macos".format(name, mode),
            srcs = ["apple_plugin_fixture/Sources/fixture_swift/FixtureSwift.swift"],
            module_name = "fixture_swift_" + mode,
            platform = "macos",
            swift_language_mode = mode if mode == "6" else None,
        )
    _swift_5_test(
        name = name + "_swift_5",
        target_under_test = ":{}_swift_5_apple_macos".format(name),
        target_compatible_with = macos,
    )
    _swift_6_test(
        name = name + "_swift_6",
        target_under_test = ":{}_swift_6_apple_macos".format(name),
        target_compatible_with = macos,
    )

    native.test_suite(
        name = name,
        tests = [
            name + "_define_reaches_the_compile",
            name + "_swift_5",
            name + "_swift_6",
        ],
    )
