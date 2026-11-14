"""The `BuildConfig` a plugin library gets says what Gradle's would in each mode.

`-c dbg` is debug, `-c opt --@rules_flutter//flutter:profile` is profile, and
any other `-c` (`opt`, and `fastbuild`, the default) is release.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//flutter/private:android_build_config.bzl", "android_build_config")
load(":action_content.bzl", "written_text")
load(":engine_mode.bzl", "MODE_FLAGS")

def _expect(env, debug, build_type):
    content = written_text(env, "BuildConfig.java")
    if content == None:
        return
    for line in [
        "public static final boolean DEBUG = %s;" % debug,
        'public static final String BUILD_TYPE = "%s";' % build_type,
    ]:
        asserts.true(env, line in content, "%s in:\n%s" % (line, content))

def _make(debug, build_type, config_settings):
    def impl(ctx):
        env = analysistest.begin(ctx)
        _expect(env, debug, build_type)
        return analysistest.end(env)

    return analysistest.make(impl, config_settings = config_settings)

_debug_test = _make("true", "debug", MODE_FLAGS["debug"])
_profile_test = _make("true", "profile", MODE_FLAGS["profile"])
_opt_test = _make("false", "release", MODE_FLAGS["release"])
_fastbuild_test = _make("false", "release", {"//command_line_option:compilation_mode": "fastbuild"})

def android_build_config_test_suite(name):
    """Declares the tests.

    Args:
        name: The test_suite name.
    """
    android_build_config(
        name = name + "_src",
        package = "com.example.build_config",
        tags = ["manual"],
    )
    tests = {
        "debug": _debug_test,
        "fastbuild": _fastbuild_test,
        "opt": _opt_test,
        "profile": _profile_test,
    }
    for mode, test in tests.items():
        test(
            name = "%s_%s" % (name, mode),
            target_under_test = ":" + name + "_src",
        )
    native.test_suite(
        name = name,
        tests = ["%s_%s" % (name, mode) for mode in tests],
    )
