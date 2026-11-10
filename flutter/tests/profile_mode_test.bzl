"""Profile mode compiles with the profile toolchain, and only with `-c opt`.

The engine checks the snapshot it is handed against its own mode: a release
snapshot on the profile engine dies at startup with "VM snapshot invalid", and
so does the reverse. So profile is three things that must agree — the
`dart.vm.profile` define, the non-product platform kernel, and the profile
gen_snapshot — and these tests pin each, in profile and in release, from the
actions the rule declares.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//flutter/private:flutter_aot_snapshot.bzl", "flutter_aot_snapshot")
load("//flutter/private:flutter_application.bzl", "flutter_application")
load("//flutter/private:flutter_profile_build.bzl", "flutter_profile_build")

_MAIN = "lib/language_version_main.dart"

_PROFILE = {
    "//command_line_option:compilation_mode": "opt",
    str(Label("//flutter:profile")): True,
}

_RELEASE = {
    "//command_line_option:compilation_mode": "opt",
}

def _action(env, mnemonics):
    actions = [a for a in analysistest.target_actions(env) if a.mnemonic in mnemonics]
    asserts.equals(env, 1, len(actions), "expected exactly one of %s" % (mnemonics,))
    return actions[0] if actions else None

def _assert_mode(env, profile, os):
    kernel = _action(env, ["DartKernel"])
    aot = _action(env, ["FlutterAotMacho", "FlutterAotElf"])
    if kernel == None or aot == None:
        return
    argv = " ".join(kernel.argv)

    # Profile keeps the VM service and the profiling hooks, which the product
    # platform has compiled out.
    asserts.equals(env, profile, "/flutter_patched_sdk/" in argv, "non-product platform kernel")
    asserts.equals(env, not profile, "/flutter_patched_sdk_product/" in argv, "product platform kernel")
    asserts.equals(env, profile, "dart.vm.profile=true" in argv, "dart.vm.profile define")
    asserts.equals(env, not profile, "dart.vm.product=true" in argv, "dart.vm.product define")

    # Both optimized modes drop the framework's `toString` bodies, as
    # `flutter build` does.
    for uri in ["dart:ui", "package:flutter"]:
        asserts.true(env, "--delete-tostring-package-uri=" + uri in kernel.argv, "toString of %s deleted" % uri)

    # The kernel is compiled for the OS the artifact runs on, as `flutter
    # build` does.
    asserts.true(env, "--target-os " + os in argv, "compiled for the target OS: " + argv)

    # The profile gen_snapshot lives in a repo of its own, fetched only for a
    # profile build.
    asserts.equals(
        env,
        profile,
        "_profile/" in aot.argv[0],
        "gen_snapshot %s should %sbe the profile one" % (aot.argv[0], "" if profile else "not "),
    )

def _target_os(ctx):
    """The OS the fixtures are built for: the one the test runs on."""
    for os in ["macos", "linux", "windows"]:
        if ctx.target_platform_has_constraint(getattr(ctx.attr, "_" + os)[platform_common.ConstraintValueInfo]):
            return os
    fail("the target platform is none of macos, linux, windows")

def _profile_test_impl(ctx):
    env = analysistest.begin(ctx)
    _assert_mode(env, profile = True, os = _target_os(ctx))
    return analysistest.end(env)

def _release_test_impl(ctx):
    env = analysistest.begin(ctx)
    _assert_mode(env, profile = False, os = _target_os(ctx))
    return analysistest.end(env)

def _refused_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "needs -c opt")
    return analysistest.end(env)

_FIXTURE = {
    "_linux": attr.label(default = "@platforms//os:linux"),
    "_macos": attr.label(default = "@platforms//os:macos"),
    "_windows": attr.label(default = "@platforms//os:windows"),
}

_profile_test = analysistest.make(_profile_test_impl, attrs = _FIXTURE, config_settings = _PROFILE)
_release_test = analysistest.make(_release_test_impl, attrs = _FIXTURE, config_settings = _RELEASE)

def _debug_test_impl(ctx):
    """A debug kernel keeps every `toString`, and is not compiled for an OS."""
    env = analysistest.begin(ctx)
    kernel = _action(env, ["DartKernel"])
    if kernel != None:
        argv = " ".join(kernel.argv)
        asserts.false(env, "--delete-tostring-package-uri" in argv, "debug keeps toString: " + argv)
        asserts.false(env, "--target-os" in argv, "a JIT kernel names no OS: " + argv)
    return analysistest.end(env)

_debug_test = analysistest.make(
    _debug_test_impl,
    attrs = _FIXTURE,
    config_settings = {"//command_line_option:compilation_mode": "dbg"},
)
_refused_dbg_test = analysistest.make(
    _refused_test_impl,
    expect_failure = True,
    config_settings = {
        "//command_line_option:compilation_mode": "dbg",
        str(Label("//flutter:profile")): True,
    },
)
_refused_fastbuild_test = analysistest.make(
    _refused_test_impl,
    expect_failure = True,
    config_settings = {
        "//command_line_option:compilation_mode": "fastbuild",
        str(Label("//flutter:profile")): True,
    },
)

def _wrapper_test_impl(ctx):
    env = analysistest.begin(ctx)

    # Under -c dbg the wrapped application would be refused with the profile
    # flag; it analyses only because the transition also sets -c opt, and its
    # files land in the opt configuration's output tree.
    files = analysistest.target_under_test(env)[DefaultInfo].files.to_list()
    asserts.true(env, len(files) > 0, "the wrapper forwards the application's files")
    for f in files:
        asserts.true(env, "-opt" in f.path, "%s is built in the opt configuration" % f.path)
    return analysistest.end(env)

# One test per command line the wrapper must override: it builds in profile mode
# whatever the invocation asked for.
_wrapper_dbg_test = analysistest.make(
    _wrapper_test_impl,
    config_settings = {"//command_line_option:compilation_mode": "dbg"},
)
_wrapper_fastbuild_test = analysistest.make(
    _wrapper_test_impl,
    config_settings = {"//command_line_option:compilation_mode": "fastbuild"},
)

def profile_mode_test_suite(name):
    """Instantiate the fixtures and the analysis tests over them.

    The fixtures are `manual` and never built: with no `deps` there is no
    `package:flutter`, so they would not compile. The tests read the actions
    analysis declares.

    Args:
      name: The test_suite name.
    """
    flutter_application(
        name = "_profile_application",
        package = ":pubspec-metadata",
        main = _MAIN,
        tags = ["manual"],
    )
    flutter_aot_snapshot(
        name = "_profile_aot",
        package = ":pubspec-metadata",
        main = _MAIN,
        tags = ["manual"],
    )

    tests = []
    for fixture in ["_profile_application", "_profile_aot"]:
        for suffix, rule in [
            ("profile", _profile_test),
            ("release", _release_test),
            ("debug", _debug_test),
            ("refused_dbg", _refused_dbg_test),
            ("refused_fastbuild", _refused_fastbuild_test),
        ]:
            test_name = "%s%s_%s_test" % (name, fixture, suffix)
            rule(name = test_name, target_under_test = ":" + fixture)
            tests.append(":" + test_name)

    flutter_profile_build(
        name = "_profile_wrapper",
        targets = [":_profile_application"],
        tags = ["manual"],
    )
    for suffix, rule in [("dbg", _wrapper_dbg_test), ("fastbuild", _wrapper_fastbuild_test)]:
        test_name = "%s_profile_build_%s_test" % (name, suffix)
        rule(name = test_name, target_under_test = ":_profile_wrapper")
        tests.append(":" + test_name)

    native.test_suite(name = name, tests = tests)
