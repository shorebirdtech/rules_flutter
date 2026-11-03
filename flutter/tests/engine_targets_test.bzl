"""The engine targets of the engine repos follow the build mode, or say their mode.

A target named plainly `engine_library` is the engine of the build mode; a
target for one mode says which in its name. No release-only target may carry
the plain name: a rule linking it under `-c dbg` bundles the wrong engine.

The generated BUILD text is checked for every host OS, since a Linux or Windows
host is not one the tests run on. The toolchain's engine is resolved for the
host and, from a macOS host, for the Linux and Windows cross toolchains, whose
engines come from repos of their own per mode.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//flutter/private:engine_helpers.bzl", "desktop_cross_engine_attr", "engine_filegroup_for_os", "engine_target_name", "host_engine_targets")
load("//flutter/private:flutter_android_engine_repo.bzl", "android_engine_build_file")
load(":engine_mode.bzl", "engine_modes")

_TOOLCHAIN_TYPE = "@rules_flutter//flutter:toolchain_type"

def _names(build_text):
    return sorted([
        line.split("\"")[1]
        for line in build_text.splitlines()
        if line.strip().startswith("name = ")
    ])

def _filegroup_names_test_impl(ctx):
    env = unittest.begin(ctx)
    for os_name in ["macos", "linux", "windows"]:
        for mode in ["release", "debug", "profile"]:
            asserts.equals(
                env,
                ["engine_%s_library" % mode],
                _names(engine_filegroup_for_os(os_name, mode)),
                "%s %s" % (os_name, mode),
            )
        asserts.false(env, "engine_library" in _names(engine_filegroup_for_os(os_name, "release")))
    return unittest.end(env)

def _strict_globs_test_impl(ctx):
    # A glob that may match nothing builds a repo that lacks a download, and
    # the rules using it fail later with no word of what is missing. Each
    # pattern of a strict glob has to match, so Bazel stops the package load
    # naming the pattern.
    env = unittest.begin(ctx)
    for os_name in ["macos", "linux", "windows"]:
        for mode in ["release", "debug", "profile"]:
            asserts.false(env, "allow_empty" in engine_filegroup_for_os(os_name, mode), "%s %s" % (os_name, mode))
        asserts.false(
            env,
            "allow_empty" in host_engine_targets(os_name, has_debug = True, profile_repo = "sdk_profile"),
            os_name,
        )

    # The Windows engine's files are named one by one, the wrapper's by
    # directory, and the wrapper is not in the engine archive.
    text = engine_filegroup_for_os("windows", "release")
    asserts.true(env, "\"engine/flutter_windows.dll\"" in text)
    asserts.true(env, "cpp-client-wrapper/cpp_client_wrapper/include/flutter/*.h" in text)
    return unittest.end(env)

def _filegroup_dirs_test_impl(ctx):
    env = unittest.begin(ctx)
    for os_name in ["macos", "linux", "windows"]:
        text = engine_filegroup_for_os(os_name, "debug", dir = "engine-debug")
        asserts.true(env, "\"engine-debug/" in text, os_name)
        asserts.false(env, "\"engine/" in text, os_name)
        text = engine_filegroup_for_os(os_name, "release")
        asserts.true(env, "\"engine/" in text, os_name)
        asserts.false(env, "engine-debug" in text, os_name)
    return unittest.end(env)

def _host_targets_test_impl(ctx):
    env = unittest.begin(ctx)
    for os_name in ["macos", "linux", "windows"]:
        text = host_engine_targets(os_name, has_debug = True, profile_repo = "sdk_profile")
        asserts.equals(
            env,
            ["engine_debug_library", "engine_library", "engine_profile_library", "engine_release_library"],
            _names(text),
            os_name,
        )

        # `engine_library` is the select over the three engines, never a
        # filegroup of one mode's files.
        asserts.true(env, "alias(\n    name = \"engine_library\"" in text, os_name)
        asserts.true(env, "\"@rules_flutter//flutter/private:dbg\": \":engine_debug_library\"" in text, os_name)
        asserts.true(env, "\"@rules_flutter//flutter/private:profile\": \":engine_profile_library\"" in text, os_name)
        asserts.true(env, "\"//conditions:default\": \":engine_release_library\"" in text, os_name)
        asserts.true(env, "actual = \"@sdk_profile//:engine_profile_library\"" in text, os_name)

        # The profile repo names its engine for its mode.
        asserts.equals(env, ["engine_profile_library"], _names(engine_filegroup_for_os(os_name, "profile")))
    return unittest.end(env)

def _host_targets_without_optional_modes_test_impl(ctx):
    env = unittest.begin(ctx)
    text = host_engine_targets("linux", has_debug = False, profile_repo = "")
    asserts.equals(env, ["engine_library", "engine_release_library"], _names(text))
    asserts.false(env, "flutter/private:dbg" in text)
    asserts.false(env, "flutter/private:profile" in text)
    return unittest.end(env)

def _target_name_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "engine_debug_library", engine_target_name("debug"))
    asserts.equals(env, "engine_profile_library", engine_target_name("profile"))
    asserts.equals(env, "engine_release_library", engine_target_name("release"))
    return unittest.end(env)

def _cross_engine_attr_test_impl(ctx):
    env = unittest.begin(ctx)
    text = desktop_cross_engine_attr({
        "debug": "sdk_engine_linux-x64_debug",
        "profile": "sdk_engine_linux-x64_profile",
        "release": "sdk_engine_linux-x64_release",
    })
    asserts.true(env, "\"@rules_flutter//flutter/private:dbg\": \"@sdk_engine_linux-x64_debug//:engine_debug_library\"" in text)
    asserts.true(env, "\"@rules_flutter//flutter/private:profile\": \"@sdk_engine_linux-x64_profile//:engine_profile_library\"" in text)
    asserts.true(env, "\"//conditions:default\": \"@sdk_engine_linux-x64_release//:engine_release_library\"" in text)
    return unittest.end(env)

def _android_engine_targets_test_impl(ctx):
    env = unittest.begin(ctx)
    text = android_engine_build_file("arm64-v8a", "sdk_android_profile")
    asserts.equals(
        env,
        ["debug_stripped", "profile_stripped", "release_stripped", "stripped"],
        _names(text),
    )

    # `stripped` is the select over the three jars, never one mode's jar.
    asserts.true(env, "alias(\n    name = \"stripped\"" in text)
    asserts.true(env, "\"@rules_flutter//flutter/private:dbg\": \":debug_stripped\"" in text)
    asserts.true(env, "\"@rules_flutter//flutter/private:profile\": \":profile_stripped\"" in text)
    asserts.true(env, "\"//conditions:default\": \":release_stripped\"" in text)
    asserts.true(env, "actual = \"@sdk_android_profile//:profile_stripped\"" in text)
    asserts.true(env, "name = \"release_stripped\",\n    jar = \"flutter.jar\"" in text)
    asserts.true(env, "name = \"debug_stripped\",\n    jar = \"debug/flutter.jar\"" in text)
    return unittest.end(env)

_filegroup_names_test = unittest.make(_filegroup_names_test_impl)
_strict_globs_test = unittest.make(_strict_globs_test_impl)
_filegroup_dirs_test = unittest.make(_filegroup_dirs_test_impl)
_host_targets_test = unittest.make(_host_targets_test_impl)
_host_targets_without_optional_modes_test = unittest.make(_host_targets_without_optional_modes_test_impl)
_target_name_test = unittest.make(_target_name_test_impl)
_cross_engine_attr_test = unittest.make(_cross_engine_attr_test_impl)
_android_engine_targets_test = unittest.make(_android_engine_targets_test_impl)

def _mode_transition_impl(settings, attr):
    out = {
        "//command_line_option:compilation_mode": "dbg" if attr.mode == "debug" else "opt",
        str(Label("//flutter:profile")): attr.mode == "profile",
        "//command_line_option:platforms": settings["//command_line_option:platforms"],
    }
    if attr.platform:
        out["//command_line_option:platforms"] = [attr.platform]
    return out

_mode_transition = transition(
    implementation = _mode_transition_impl,
    inputs = ["//command_line_option:platforms"],
    outputs = [
        "//command_line_option:compilation_mode",
        str(Label("//flutter:profile")),
        "//command_line_option:platforms",
    ],
)

def _toolchain_engine_impl(ctx):
    sdk = ctx.toolchains[_TOOLCHAIN_TYPE].flutter_sdk_info
    return [DefaultInfo(files = sdk.engine_library.files)]

# The engine the Flutter toolchain resolved for a build mode and target
# platform (the host's, when `platform` is empty).
_toolchain_engine = rule(
    implementation = _toolchain_engine_impl,
    attrs = {
        "mode": attr.string(values = ["debug", "profile", "release"]),
        "platform": attr.string(),
    },
    cfg = _mode_transition,
    toolchains = [_TOOLCHAIN_TYPE],
)

def _toolchain_engine_modes_impl(ctx):
    env = analysistest.begin(ctx)
    files = analysistest.target_under_test(env)[DefaultInfo].files.to_list()
    asserts.equals(env, [ctx.attr.expected], engine_modes(files, ctx.attr.marker))
    return analysistest.end(env)

_toolchain_engine_modes_test = analysistest.make(
    _toolchain_engine_modes_impl,
    attrs = {"expected": attr.string(), "marker": attr.string()},
)

# The engine's own file, which tells the engine's repo from any other file the
# target carries.
_ENGINE_MARKER = {
    "linux": "libflutter_linux_gtk.so",
    "macos": "/FlutterMacOS.framework/",
    "windows": "flutter_windows.dll",
}

def engine_targets_test_suite(name):
    """The engine targets of the SDK repos say or follow their build mode.

    Args:
        name: Suite name.
    """
    tests = []
    for case, test in {
        "filegroup_names": _filegroup_names_test,
        "filegroup_dirs": _filegroup_dirs_test,
        "strict_globs": _strict_globs_test,
        "host_targets": _host_targets_test,
        "host_targets_without_optional_modes": _host_targets_without_optional_modes_test,
        "target_name": _target_name_test,
        "cross_engine_attr": _cross_engine_attr_test,
        "android_engine_targets": _android_engine_targets_test,
    }.items():
        test(name = "%s_%s" % (name, case))
        tests.append("%s_%s" % (name, case))

    # The host's own toolchain: an engine of each mode.
    host_marker = select({
        "@platforms//os:linux": _ENGINE_MARKER["linux"],
        "@platforms//os:macos": _ENGINE_MARKER["macos"],
        "@platforms//os:windows": _ENGINE_MARKER["windows"],
    })
    for mode in ["debug", "profile", "release"]:
        engine = "%s_host_%s_engine" % (name, mode)
        _toolchain_engine(name = engine, mode = mode, tags = ["manual"])
        _toolchain_engine_modes_test(
            name = "%s_host_%s" % (name, mode),
            target_under_test = ":" + engine,
            expected = mode,
            marker = host_marker,
        )
        tests.append("%s_host_%s" % (name, mode))

    # The cross toolchains' engines come from a repo per mode.
    for target in ["linux", "windows"]:
        for mode in ["debug", "profile", "release"]:
            engine = "%s_cross_%s_%s_engine" % (name, target, mode)
            _toolchain_engine(
                name = engine,
                mode = mode,
                platform = str(Label("//flutter/platforms:%s_x64" % target)),
                tags = ["manual"],
            )
            _toolchain_engine_modes_test(
                name = "%s_cross_%s_%s" % (name, target, mode),
                target_under_test = ":" + engine,
                expected = mode,
                marker = _ENGINE_MARKER[target],
                target_compatible_with = ["@platforms//os:macos"],
            )
            tests.append("%s_cross_%s_%s" % (name, target, mode))
    native.test_suite(name = name, tests = tests)
