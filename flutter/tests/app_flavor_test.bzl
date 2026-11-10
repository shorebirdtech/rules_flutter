"""A `flavor` reaches the kernel compile as `FLUTTER_APP_FLAVOR`, and the dev loop's replay.

`appFlavor` (`package:flutter/services.dart`) reads `FLUTTER_APP_FLAVOR` from
the compile's environment. The define must be in the compile, and in the
dev config's `dartDefines` that the dev tool replays on every reload and
restart. It must not be in the `build_info` the app reports, whose
`dartDefines` the dev tool passes back as flags to a build of the same target:
that build takes the flavor from the target.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//flutter:defs.bzl", "flutter_application")
load("//flutter/private:flutter_kernel.bzl", "flutter_kernel")
load(":action_content.bzl", "written_json")
load(":version_defines_test.bzl", "pinned_version_defines")

_DBG = {"//command_line_option:compilation_mode": "dbg"}
_BUILD_INFO = "-Drules_flutter.build_info="

def _kernel(env):
    kernels = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "DartKernel"
    ]
    asserts.equals(env, 1, len(kernels), "expected one DartKernel")
    return kernels[0] if kernels else None

def _flavor_defines(argv):
    return [a for a in argv if a.startswith("-DFLUTTER_APP_FLAVOR")]

def _compile_impl(ctx):
    env = analysistest.begin(ctx)
    kernel = _kernel(env)
    if kernel != None:
        asserts.equals(env, ctx.attr.expected, _flavor_defines(kernel.argv), "the flavor define in the compile: %s" % kernel.argv)
    return analysistest.end(env)

_compile_test = analysistest.make(
    _compile_impl,
    attrs = {"expected": attr.string_list()},
)

def _dev_loop_impl(ctx):
    env = analysistest.begin(ctx)
    kernel = _kernel(env)
    if kernel == None:
        return analysistest.end(env)
    asserts.equals(env, ["-DFLUTTER_APP_FLAVOR=paid"], _flavor_defines(kernel.argv))

    info = [a for a in kernel.argv if a.startswith(_BUILD_INFO)]
    asserts.equals(env, 1, len(info), "expected the build_info define: %s" % kernel.argv)
    if info:
        replayed = json.decode(info[0][len(_BUILD_INFO):])["dartDefines"]
        asserts.equals(env, ["USER=1"], replayed, "the app's report leaves the flavor to the target")

    config = written_json(env, "_dev_config.json")
    if config != None:
        asserts.equals(
            env,
            ["USER=1", "FLUTTER_APP_FLAVOR=paid"] + pinned_version_defines(),
            config["dartDefines"],
            "the dev tool replays the flavor on every reload and restart",
        )
    return analysistest.end(env)

_dev_loop_test = analysistest.make(_dev_loop_impl, config_settings = _DBG)

def app_flavor_test_suite(name):
    """Fixtures and tests for `flavor` on an application and a kernel target.

    Args:
        name: The test suite name.
    """
    flutter_application(
        name = "_flavor_app",
        package = ":pubspec-metadata",
        flavor = "paid",
        defines = ["USER=1"],
        main = "web_fixture_main.dart",
        tags = ["manual"],
    )
    flutter_application(
        name = "_no_flavor_app",
        package = ":pubspec-metadata",
        main = "web_fixture_main.dart",
        tags = ["manual"],
    )
    flutter_kernel(
        name = "_flavor_kernel",
        package = ":pubspec-metadata",
        flavor = "paid",
        main = "web_fixture_main.dart",
        tags = ["manual"],
    )
    _compile_test(
        name = name + "_compile",
        target_under_test = ":_flavor_app",
        expected = ["-DFLUTTER_APP_FLAVOR=paid"],
    )
    _compile_test(
        name = name + "_none",
        target_under_test = ":_no_flavor_app",
        expected = [],
    )
    _compile_test(
        name = name + "_kernel_target",
        target_under_test = ":_flavor_kernel",
        expected = ["-DFLUTTER_APP_FLAVOR=paid"],
    )
    _dev_loop_test(name = name + "_dev_loop", target_under_test = ":_flavor_app")
    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_compile",
            ":" + name + "_none",
            ":" + name + "_kernel_target",
            ":" + name + "_dev_loop",
        ],
    )
