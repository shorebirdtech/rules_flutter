"""A debug or profile app records where each widget was created, as `flutter run` does.

The widget inspector shows a widget's creation location only when the kernel
was compiled with `--track-widget-creation`. A `flutter_application` passes it
by default in every mode but release, the condition of flutter_tools' assemble
target (`trackWidgetCreation && buildMode != BuildMode.release`). Hot reload
recompiles with the dev tool's own frontend server, which must pass the same
flag, so a debug app also reports whether it was compiled with it in the
`rules_flutter.build_info` record. A profile build has no dev loop and no record.

A `flutter_test` always tracks, as `flutter test` does: it sets
`--@rules_dart//dart:track_creation_locations` for itself and its `deps`, which
puts the transform in its entry compile (and in every module of `deps`, which
the runtime test in `e2e/hello_world`, `:widget_creation_builds`, shows) or,
compiled as one program, in its whole-program compile.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//flutter/private:flutter_application.bzl", "flutter_application")
load("//flutter/private:flutter_test.bzl", "flutter_test")

_PACKAGE = "tracking_fixture"
_MAIN = "lib/language_version_main.dart"
_FLAG = "--track-creation-locations"
_DBG = {"//command_line_option:compilation_mode": "dbg"}
_RELEASE = {"//command_line_option:compilation_mode": "opt"}
_PROFILE = {
    "//command_line_option:compilation_mode": "opt",
    str(Label("//flutter:profile")): True,
}

def _kernel_argv(env):
    kernels = [a for a in analysistest.target_actions(env) if a.mnemonic == "DartKernel"]
    asserts.equals(env, 1, len(kernels), "expected one DartKernel")
    return kernels[0].argv if kernels else []

def _recorded(argv):
    """The `trackWidgetCreation` of the build-info define, or None without one."""
    for arg in argv:
        if arg.startswith("-Drules_flutter.build_info="):
            return json.decode(arg[len("-Drules_flutter.build_info="):]).get("trackWidgetCreation")
    return None

def _tracked_impl(ctx):
    env = analysistest.begin(ctx)
    argv = _kernel_argv(env)
    asserts.true(env, _FLAG in argv, "compiled without %s: %s" % (_FLAG, argv))
    if ctx.attr.debug:
        asserts.equals(env, True, _recorded(argv), "the app's build-info record says it tracks")
    return analysistest.end(env)

def _untracked_impl(ctx):
    env = analysistest.begin(ctx)
    argv = _kernel_argv(env)
    asserts.false(env, _FLAG in argv, "compiled with %s: %s" % (_FLAG, argv))
    if ctx.attr.debug:
        asserts.equals(env, False, _recorded(argv), "the app's build-info record says it does not track")
    return analysistest.end(env)

_tracked_debug_test = analysistest.make(
    _tracked_impl,
    attrs = {"debug": attr.bool(default = True)},
    config_settings = _DBG,
)
_tracked_profile_test = analysistest.make(
    _tracked_impl,
    attrs = {"debug": attr.bool(default = False)},
    config_settings = _PROFILE,
)
_untracked_debug_test = analysistest.make(
    _untracked_impl,
    attrs = {"debug": attr.bool(default = True)},
    config_settings = _DBG,
)
_untracked_release_test = analysistest.make(
    _untracked_impl,
    attrs = {"debug": attr.bool(default = False)},
    config_settings = _RELEASE,
)
_untracked_profile_test = analysistest.make(
    _untracked_impl,
    attrs = {"debug": attr.bool(default = False)},
    config_settings = _PROFILE,
)

def _test_tracks_impl(ctx):
    env = analysistest.begin(ctx)
    compiles = [a for a in analysistest.target_actions(env) if a.mnemonic == ctx.attr.mnemonic]
    asserts.equals(env, 1, len(compiles), "expected one %s" % ctx.attr.mnemonic)
    for action in compiles:
        argv = action.argv
        asserts.true(env, ctx.attr.flag in argv, "compiled without %s: %s" % (ctx.attr.flag, argv))
    return analysistest.end(env)

_test_tracks_modular_test = analysistest.make(
    _test_tracks_impl,
    attrs = {
        "flag": attr.string(default = "--track-creation-locations"),
        "mnemonic": attr.string(default = "DartEntryKernel"),
    },
)
_test_tracks_whole_program_test = analysistest.make(
    _test_tracks_impl,
    attrs = {
        "flag": attr.string(default = _FLAG),
        "mnemonic": attr.string(default = "DartKernel"),
    },
    config_settings = {str(Label("@rules_dart//dart:modular_kernel")): False},
)

def widget_creation_flag_test_suite(name):
    """Fixtures and tests for widget creation tracking in `flutter_application` and `flutter_test`.

    Args:
        name: The test_suite name.
    """
    flutter_application(
        name = "_tracking_default_app",
        package_name = _PACKAGE,
        main = _MAIN,
        tags = ["manual"],
    )
    flutter_application(
        name = "_tracking_off_app",
        package_name = _PACKAGE,
        main = _MAIN,
        track_widget_creation = False,
        tags = ["manual"],
    )
    flutter_test(
        name = "_tracking_flutter_test",
        package_name = _PACKAGE,
        main = _MAIN,
        tags = ["manual"],
        deps = ["//flutter/tests/flutter_test_analyze_fixture/fake_test_api"],
    )
    cases = {
        "debug_default_tracks": (_tracked_debug_test, "_tracking_default_app"),
        "debug_opted_out_does_not": (_untracked_debug_test, "_tracking_off_app"),
        "release_default_does_not": (_untracked_release_test, "_tracking_default_app"),
        "profile_default_tracks": (_tracked_profile_test, "_tracking_default_app"),
        "profile_opted_out_does_not": (_untracked_profile_test, "_tracking_off_app"),
        "flutter_test_modular_tracks": (_test_tracks_modular_test, "_tracking_flutter_test"),
        "flutter_test_whole_program_tracks": (_test_tracks_whole_program_test, "_tracking_flutter_test"),
    }
    tests = []
    for case, (rule, target) in cases.items():
        test = "%s_%s" % (name, case)
        rule(name = test, target_under_test = ":" + target)
        tests.append(":" + test)
    native.test_suite(name = name, tests = tests)
