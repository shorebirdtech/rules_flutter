"""A program is compiled with the defines `flutter_tools` adds: its version and the SDK's.

`appBuildName`, `appBuildNumber` and `FlutterVersion` read them as
`String.fromEnvironment`, and read null without. They are in every compile, in
the dev config's `dartDefines` that the dev tool replays on every reload and
restart, and not in the `build_info` the app reports, whose `dartDefines` the
dev tool passes back as flags to a build of the same target. A `defines` entry
that sets one is refused, as `flutter_tools` refuses it.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("@flutter_version_pin//:version.bzl", "FLUTTER_VERSION")
load("//flutter:defs.bzl", "flutter_application")
load("//flutter/private:flutter_kernel_target.bzl", "flutter_kernel_target")
load("//flutter/private:flutter_test.bzl", "flutter_test")
load("//flutter/private:sdk_defines.bzl", "VERSION_DEFINE_KEYS", "sdk_dart_defines", "version_dart_defines")
load("//flutter/private:validation.bzl", "is_valid_dart_define")
load("//flutter/private:versions.bzl", "FLUTTER_VERSIONS")
load(":action_content.bzl", "written_json")

_DBG = {"//command_line_option:compilation_mode": "dbg"}
_BUILD_INFO = "-Drules_flutter.build_info="

def pinned_version_defines(build_name = "1.0.0", build_number = "1"):
    """The defines the pinned release's programs get, written out from its versions.bzl entry.

    Args:
        build_name: The program's version name.
        build_number: The program's build number.

    Returns:
        The `KEY=VALUE` defines, in the order `flutter_tools` adds them.
    """
    meta = FLUTTER_VERSIONS[FLUTTER_VERSION]
    return [
        "FLUTTER_BUILD_NAME=" + build_name,
        "FLUTTER_BUILD_NUMBER=" + build_number,
        "FLUTTER_VERSION=" + FLUTTER_VERSION,
        "FLUTTER_CHANNEL=stable",
        "FLUTTER_GIT_URL=https://github.com/flutter/flutter.git",
        "FLUTTER_FRAMEWORK_REVISION=" + meta.framework_revision[:10],
        "FLUTTER_ENGINE_REVISION=" + meta.engine_revision[:10],
        "FLUTTER_DART_VERSION=" + meta.dart_version,
    ]

def _is_version_define(arg):
    key = arg.removeprefix("-D").removeprefix("--define").strip().partition("=")[0]
    return key in VERSION_DEFINE_KEYS

def _sdk_defines_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, [
        "FLUTTER_VERSION=3.47.9",
        "FLUTTER_CHANNEL=stable",
        "FLUTTER_GIT_URL=https://github.com/flutter/flutter.git",
        "FLUTTER_FRAMEWORK_REVISION=c197ca5199",
        "FLUTTER_ENGINE_REVISION=89c39edfdf",
        "FLUTTER_DART_VERSION=3.13.7",
    ], sdk_dart_defines("3.47.9"))
    asserts.equals(env, [
        "FLUTTER_BUILD_NAME=1.0.0",
        "FLUTTER_BUILD_NUMBER=1",
    ], version_dart_defines("3.47.9", "", "")[:2], "unset is flutter create's 1.0.0+1")
    asserts.equals(env, [
        "FLUTTER_BUILD_NAME=2.1",
        "FLUTTER_BUILD_NUMBER=42",
    ], version_dart_defines("3.47.9", "2.1", "42")[:2], "as given, not padded to three numbers")
    return unittest.end(env)

_sdk_defines_test = unittest.make(_sdk_defines_test_impl)

def _every_release_describes_itself_test_impl(ctx):
    env = unittest.begin(ctx)
    for version, meta in FLUTTER_VERSIONS.items():
        asserts.equals(env, 40, len(meta.framework_revision), "framework_revision of %s is a 40-char hash" % version)
        asserts.true(env, meta.dart_version[0].isdigit(), "dart_version of %s is a version" % version)
        asserts.equals(env, 6, len(sdk_dart_defines(version)))
    return unittest.end(env)

_every_release_describes_itself_test = unittest.make(_every_release_describes_itself_test_impl)

def _reserved_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, 8, len(VERSION_DEFINE_KEYS))
    for key in VERSION_DEFINE_KEYS:
        asserts.false(env, is_valid_dart_define(key + "=x"), "%s is reserved" % key)
        asserts.false(env, is_valid_dart_define(key), "bare %s is reserved" % key)
    asserts.true(env, is_valid_dart_define("FLUTTER_BUILD_NAMES=x"), "only the keys themselves")
    return unittest.end(env)

_reserved_test = unittest.make(_reserved_test_impl)

def _kernel(env):
    kernels = [a for a in analysistest.target_actions(env) if a.mnemonic == "DartKernel"]
    asserts.equals(env, 1, len(kernels), "expected one DartKernel")
    return kernels[0] if kernels else None

def _compile_impl(ctx):
    env = analysistest.begin(ctx)
    kernel = _kernel(env)
    if kernel != None:
        got = [a.removeprefix("-D") for a in kernel.argv if _is_version_define(a)]
        asserts.equals(env, pinned_version_defines(ctx.attr.build_name, ctx.attr.build_number), got, "version defines in the compile: %s" % kernel.argv)
    return analysistest.end(env)

_compile_test = analysistest.make(
    _compile_impl,
    attrs = {"build_name": attr.string(default = "1.0.0"), "build_number": attr.string(default = "1")},
)

def _dev_loop_impl(ctx):
    env = analysistest.begin(ctx)
    kernel = _kernel(env)
    if kernel == None:
        return analysistest.end(env)
    info = [a for a in kernel.argv if a.startswith(_BUILD_INFO)]
    asserts.equals(env, 1, len(info), "expected the build_info define: %s" % kernel.argv)
    if info:
        replayed = json.decode(info[0][len(_BUILD_INFO):])["dartDefines"]
        asserts.equals(env, ["USER=1"], replayed, "the app's report leaves the version to the target")
    config = written_json(env, "_dev_config.json")
    if config != None:
        asserts.equals(
            env,
            ["USER=1"] + pinned_version_defines("2.3.4", "7"),
            config["dartDefines"],
            "the dev tool replays the version on every reload and restart",
        )
    return analysistest.end(env)

_dev_loop_test = analysistest.make(_dev_loop_impl, config_settings = _DBG)

def _test_compile_impl(ctx):
    env = analysistest.begin(ctx)
    compiles = [a for a in analysistest.target_actions(env) if a.mnemonic == ctx.attr.mnemonic]
    asserts.equals(env, 1, len(compiles), "expected one %s" % ctx.attr.mnemonic)
    for action in compiles:
        # `-D<define>` to frontend_server, `--define <define>` to the kernel tool.
        got = [a.removeprefix("-D") for a in action.argv if _is_version_define(a)]
        asserts.equals(env, pinned_version_defines("1.0.0", "1"), got, "version defines of %s: %s" % (ctx.attr.mnemonic, action.argv))
    return analysistest.end(env)

_test_compile_attrs = {"mnemonic": attr.string(mandatory = True)}
_modular_test = analysistest.make(_test_compile_impl, attrs = _test_compile_attrs)
_whole_program_test = analysistest.make(
    _test_compile_impl,
    attrs = _test_compile_attrs,
    config_settings = {str(Label("@rules_dart//dart:modular_kernel")): False},
)

def version_defines_test_suite(name):
    """Fixtures and tests for the version defines of an application, a kernel target and a test.

    Args:
        name: The test suite name.
    """
    flutter_application(
        name = "_version_app",
        package_name = "flavor_fixture",
        main = "web_fixture_main.dart",
        tags = ["manual"],
    )
    flutter_application(
        name = "_versioned_app",
        package_name = "flavor_fixture",
        build_name = "2.3.4",
        build_number = "7",
        defines = ["USER=1"],
        main = "web_fixture_main.dart",
        tags = ["manual"],
    )
    flutter_kernel_target(
        name = "_version_kernel",
        package_name = "flavor_fixture",
        main = "web_fixture_main.dart",
        tags = ["manual"],
    )
    flutter_test(
        name = "_version_test",
        package_name = "flavor_test_fixture",
        main = "lib/language_version_main.dart",
        tags = ["manual"],
        deps = ["//flutter/tests/flutter_test_analyze_fixture/fake_test_api"],
    )
    _compile_test(name = name + "_app", target_under_test = ":_version_app")
    _compile_test(
        name = name + "_app_versioned",
        target_under_test = ":_versioned_app",
        build_name = "2.3.4",
        build_number = "7",
    )
    _compile_test(name = name + "_kernel_target", target_under_test = ":_version_kernel")
    _dev_loop_test(name = name + "_dev_loop", target_under_test = ":_versioned_app")
    _modular_test(name = name + "_test_modular", target_under_test = ":_version_test", mnemonic = "DartEntryKernel")
    _whole_program_test(name = name + "_test_whole_program", target_under_test = ":_version_test", mnemonic = "DartKernel")
    _sdk_defines_test(name = name + "_sdk_defines")
    _every_release_describes_itself_test(name = name + "_every_release")
    _reserved_test(name = name + "_reserved")
    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_app",
            ":" + name + "_app_versioned",
            ":" + name + "_kernel_target",
            ":" + name + "_dev_loop",
            ":" + name + "_test_modular",
            ":" + name + "_test_whole_program",
            ":" + name + "_sdk_defines",
            ":" + name + "_every_release",
            ":" + name + "_reserved",
        ],
    )
