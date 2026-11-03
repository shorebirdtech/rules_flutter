"""Analysis tests of how the Apple app macros and their wrappers sit in a build.

Both are about `bazel build //...` and `bazel test //...` with flags or a
target platform the iOS rules must still cope with.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _analyses_impl(ctx):
    env = analysistest.begin(ctx)
    files = analysistest.target_under_test(env)[DefaultInfo].files.to_list()
    asserts.true(env, len(files) > 0, "the target analyses and forwards files")
    return analysistest.end(env)

def _skipped_impl(ctx):
    env = analysistest.begin(ctx)

    # Bazel does not analyse a target that is incompatible with the platform,
    # nor a test of it: it reports the test SKIPPED. Getting here means the
    # target was analysed for a platform it declares it is not for.
    asserts.true(
        env,
        False,
        ("%s was analysed, so Bazel found it compatible with the platform; it " +
         "should be skipped.") % analysistest.target_under_test(env).label,
    )
    return analysistest.end(env)

# The `-c` and `--@rules_flutter//flutter:profile` pairs a command line can
# carry. The simulator wrappers build debug mode whatever the pair, so each one
# must analyse; the app they wrap refuses profile outside `-c opt` and
# refuses release mode for the simulator, which is what they exist to avoid.
def _analyses_under(mode, profile):
    return analysistest.make(
        _analyses_impl,
        config_settings = {
            "//command_line_option:compilation_mode": mode,
            str(Label("//flutter:profile")): profile,
        },
    )

# Rules are exported by a global name each.
_dbg_test = _analyses_under("dbg", False)
_dbg_profile_test = _analyses_under("dbg", True)
_fastbuild_test = _analyses_under("fastbuild", False)
_fastbuild_profile_test = _analyses_under("fastbuild", True)
_opt_test = _analyses_under("opt", False)
_opt_profile_test = _analyses_under("opt", True)

_COMMAND_LINES = {
    "dbg": _dbg_test,
    "dbg_profile": _dbg_profile_test,
    "fastbuild": _fastbuild_test,
    "fastbuild_profile": _fastbuild_profile_test,
    "opt": _opt_test,
    "opt_profile": _opt_profile_test,
}

# `dbg` because the iOS simulator refuses every other mode, and that refusal
# would fail analysis before compatibility was in question.
_analyses_dbg_test = analysistest.make(
    _analyses_impl,
    config_settings = {"//command_line_option:compilation_mode": "dbg"},
)
_skipped_dbg_test = analysistest.make(
    _skipped_impl,
    config_settings = {"//command_line_option:compilation_mode": "dbg"},
)

_skipped_linux_test = analysistest.make(
    _skipped_impl,
    config_settings = {
        "//command_line_option:compilation_mode": "dbg",
        "//command_line_option:platforms": [str(Label("//tools/e2e_testing:linux_arm64"))],
    },
)

def command_line_tests(name, target, profile):
    """Analysis tests of `target` under each `-c`, with the profile flag on or off.

    Args:
        name: Prefix of the tests' names.
        target: A label that must analyse under each of them.
        profile: Whether the command line carries the profile flag.

    Returns:
        The tests' labels.
    """
    tests = []
    for suffix, rule in _COMMAND_LINES.items():
        if suffix.endswith("_profile") != profile:
            continue
        rule(name = "%s_%s_test" % (name, suffix), target_under_test = target)
        tests.append(":%s_%s_test" % (name, suffix))
    return tests

def analyses_test(name, target):
    """A test that `target` analyses in `-c dbg`: the control of `skipped_test`.

    Args:
        name: The test's name.
        target: The target that must be compatible.
    """
    _analyses_dbg_test(name = name, target_under_test = target)

def skipped_test(name, target, on_linux = False):
    """A test that passes only by being skipped: `target` is incompatible.

    Bazel skips a target incompatible with the platform and every test of it,
    and a skipped test passes. If `target` is analysed instead, the test body
    runs and fails.

    Args:
        name: The test's name.
        target: The target that must be incompatible.
        on_linux: Build for `//tools/e2e_testing:linux_arm64`, not the default platform.
    """
    rule = _skipped_linux_test if on_linux else _skipped_dbg_test
    rule(name = name, target_under_test = target)
