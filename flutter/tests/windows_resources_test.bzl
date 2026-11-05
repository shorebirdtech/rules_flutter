"""Tests of how a Windows runner's resource script is compiled.

`flutter create`'s `Runner.rc` takes the app's version from `FLUTTER_VERSION*`
defines, which `flutter build windows` derives from `--build-name` and
`--build-number`; `flutter_windows_app`'s rules derive them from `build_name`
and `build_number`, checked by `app_version.bzl`. With no resource compiler
registered, the build fails rather than linking an executable without its icon
and version information.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//flutter/private:app_version.bzl", "windows_version")

# -- The version, from a build name and number -------------------------------

def _numbers(v):
    return [v.version, v.major, v.minor, v.patch, v.build]

def _version_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, ["1.0.0+1", 1, 0, 0, 1], _numbers(windows_version("", "")))
    asserts.equals(env, ["12.34.56+789", 12, 34, 56, 789], _numbers(windows_version("12.34.56", "789")))

    # The string keeps the prerelease; the numbers are the version's core.
    asserts.equals(env, ["2.0.0-beta.1+3", 2, 0, 0, 3], _numbers(windows_version("2.0.0-beta.1", "3")))
    asserts.equals(env, ["65535.0.0+65535", 65535, 0, 0, 65535], _numbers(windows_version("65535.0.0", "65535")))
    return unittest.end(env)

def _rejects_impl(ctx):
    # What `flutter build windows` would replace with 1.0.0, or a build of 0,
    # or what the resource compiler would truncate, is an error.
    env = unittest.begin(ctx)
    for name, number, want in [
        ("1.0", "", "build_name = \"1.0\" is not a valid Windows version"),
        ("1.0.0.0", "", "build_name = \"1.0.0.0\""),
        ("v1.0.0", "", "build_name = \"v1.0.0\""),
        ("1.0.0-", "", "build_name = \"1.0.0-\""),
        ("1.0.0-be_ta", "", "build_name = \"1.0.0-be_ta\""),
        ("1.0.0+2", "", "build_name = \"1.0.0+2\""),
        ("", "1.2", "build_number = \"1.2\" is not a valid Windows build number"),
        ("", "abc", "build_number = \"abc\""),
        ("65536.0.0", "", "build_name = \"65536.0.0\" is too large"),
        ("", "70000", "build_number = \"70000\" is too large"),
    ]:
        error = windows_version(name, number).error
        asserts.true(env, error and want in error, "%r+%r: %r" % (name, number, error))
    return unittest.end(env)

_version_test = unittest.make(_version_impl)
_rejects_test = unittest.make(_rejects_impl)

def windows_version_test_suite(name):
    unittest.suite(name, _version_test, _rejects_test)

# -- What `flutter_windows_app` compiles -------------------------------------

def _platform(label):
    return {"//command_line_option:platforms": str(Label(label))}

_WITH_RC = _platform("//flutter/platforms:windows_x64") | {
    "//command_line_option:extra_toolchains": [str(Label("//flutter/tests/windows_resources_fixture:fake_rc"))],
}

def _compiles_impl(ctx):
    env = analysistest.begin(ctx)
    actions = [a for a in analysistest.target_actions(env) if a.mnemonic == "WindowsRc"]
    asserts.equals(env, 1, len(actions), "expected one WindowsRc action")
    if not actions:
        return analysistest.end(env)
    action = actions[0]
    argv = action.argv
    for define in ctx.attr.defines:
        asserts.true(env, "/d" + define in argv, "missing /d%s in %s" % (define, argv))
    asserts.true(env, argv[-1].endswith(ctx.attr.rc), "compiles %s, not %s" % (argv[-1], ctx.attr.rc))
    inputs = [f.short_path for f in action.inputs.to_list()]
    for src in ctx.attr.inputs:
        asserts.true(env, src in inputs, "%s is not an input of %s" % (src, inputs))
    return analysistest.end(env)

_compiles_test = analysistest.make(
    _compiles_impl,
    attrs = {
        "defines": attr.string_list(),
        "inputs": attr.string_list(),
        "rc": attr.string(),
    },
    config_settings = _WITH_RC,
)

def _no_compiler_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "no Windows resource compiler is registered for this build")
    asserts.expect_failure(env, "@bazel_tools//tools/res:toolchain_type")
    return analysistest.end(env)

# Linux is a target no host registers a resource compiler for, so only Bazel's
# empty one resolves, on a Windows host too.
_no_compiler_test = analysistest.make(
    _no_compiler_impl,
    expect_failure = True,
    config_settings = _platform("//flutter/platforms:linux_x64"),
)

def windows_resources_test_suite(name, target, rc, defines, inputs):
    """Declares the tests of one `flutter_windows_app`'s resources.

    Args:
        name: The test_suite name.
        target: The app's resources target.
        rc: The resource script it must compile, as a workspace path.
        defines: Defines its compile must pass.
        inputs: Files (short paths) the compile must have as inputs.
    """
    _compiles_test(
        name = name + "_compiles",
        target_under_test = target,
        rc = rc,
        defines = defines,
        inputs = inputs,
    )
    _no_compiler_test(
        name = name + "_no_compiler",
        target_under_test = target,
    )
    native.test_suite(
        name = name,
        tests = [name + "_compiles", name + "_no_compiler"],
    )
