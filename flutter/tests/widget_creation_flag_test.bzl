"""A debug or profile app records where each widget was created, as `flutter run` does.

The widget inspector shows a widget's creation location only when the kernel
was compiled with `--track-widget-creation`. A `flutter_application` passes it
by default in every mode but release, the condition of flutter_tools' assemble
target (`trackWidgetCreation && buildMode != BuildMode.release`). Hot reload
recompiles with the dev tool's own frontend server, which must pass the same
flag, so a debug app also reports whether it was compiled with it in the
`rules_flutter.build_info` record. A profile build has no dev loop and no record.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//flutter/private:flutter_application.bzl", "flutter_application")

_PACKAGE = "tracking_fixture"
_MAIN = "lib/language_version_main.dart"
_FLAG = "--track-widget-creation"
_DBG = {"//command_line_option:compilation_mode": "dbg"}
_RELEASE = {"//command_line_option:compilation_mode": "opt"}
_PROFILE = {
    "//command_line_option:compilation_mode": "opt",
    str(Label("//flutter:profile")): True,
}

def _kernel_argv(env):
    kernels = [a for a in analysistest.target_actions(env) if a.mnemonic == "FlutterKernelCompile"]
    asserts.equals(env, 1, len(kernels), "expected one FlutterKernelCompile")
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

def widget_creation_flag_test_suite(name):
    """Fixtures and tests for widget creation tracking in `flutter_application`.

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
    cases = {
        "debug_default_tracks": (_tracked_debug_test, "_tracking_default_app"),
        "debug_opted_out_does_not": (_untracked_debug_test, "_tracking_off_app"),
        "release_default_does_not": (_untracked_release_test, "_tracking_default_app"),
        "profile_default_tracks": (_tracked_profile_test, "_tracking_default_app"),
        "profile_opted_out_does_not": (_untracked_profile_test, "_tracking_off_app"),
    }
    tests = []
    for case, (rule, target) in cases.items():
        test = "%s_%s" % (name, case)
        rule(name = test, target_under_test = ":" + target)
        tests.append(":" + test)
    native.test_suite(name = name, tests = tests)
