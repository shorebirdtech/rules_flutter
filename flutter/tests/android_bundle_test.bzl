"""Tests for the Android bundle, built for each Android platform.

`android_binary` builds its dependencies once for each of `--@rules_android//flags:android_platforms`
and packages what each build brings. The bundle takes its ABI from the
platform it is built for, so an APK for several ABIs carries the `libapp.so`
and native libraries of each, every one the ABI of its own `lib/` directory.
Over `//flutter/tests/shared_code_asset_fixture:app_android_bundle`.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

_BUNDLE = "//flutter/tests/shared_code_asset_fixture:app_android_bundle"

_RELEASE = {"//command_line_option:compilation_mode": "opt"}

def _platform(label):
    return {"//command_line_option:platforms": str(Label(label))}

def _libraries_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)

    # The AOT code is `libapp.so` whatever gen_snapshot called its output, next
    # to the application's native libraries.
    asserts.equals(
        env,
        sorted(ctx.attr.libraries),
        sorted([f.basename for f in target[OutputGroupInfo].native_libs.to_list()]),
    )

    # Every library is checked against the ABI of the platform it was built
    # for: that ABI's name and ELF machine, not another's.
    validations = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "FlutterValidateNativeLibs"
    ]
    asserts.equals(env, 1, len(validations), "one validation of the libraries")
    if validations:
        argv = validations[0].argv
        asserts.true(
            env,
            ctx.attr.abi in argv and str(ctx.attr.elf_machine) in argv,
            "validates for %s (machine %d): %s" % (ctx.attr.abi, ctx.attr.elf_machine, argv),
        )

        # The validation is a requirement of the build, not an output nobody
        # asks for.
        stamps = getattr(target[OutputGroupInfo], "_validation").to_list()
        asserts.true(
            env,
            validations[0].outputs.to_list()[0] in stamps,
            "the validation is a requirement of the target: %s" % stamps,
        )

    # Nothing in the bundle needs a POSIX shell: its actions run on whatever
    # host the exec-tools toolchain resolves, a Windows one included.
    shells = [
        a.mnemonic
        for a in analysistest.target_actions(env)
        if a.argv and a.argv[0].split("/")[-1] in ("bash", "sh", "cmd.exe")
    ]
    asserts.equals(env, [], shells, "actions that run a shell")
    return analysistest.end(env)

_ATTRS = {
    "abi": attr.string(mandatory = True),
    "elf_machine": attr.int(mandatory = True),
    "libraries": attr.string_list(mandatory = True),
}

_arm64_test = analysistest.make(
    _libraries_impl,
    attrs = _ATTRS,
    config_settings = _platform("@rules_android//:arm64-v8a") | _RELEASE,
)

_x86_64_test = analysistest.make(
    _libraries_impl,
    attrs = _ATTRS,
    config_settings = _platform("@rules_android//:x86_64") | _RELEASE,
)

def _not_android_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "which is not Android arm64 or x86_64")
    asserts.expect_failure(env, "--@rules_android//flags:android_platforms")
    return analysistest.end(env)

_not_android_test = analysistest.make(
    _not_android_impl,
    expect_failure = True,
    config_settings = _platform("//flutter/platforms:linux_x64") | {"//command_line_option:compilation_mode": "dbg"},
)

def android_bundle_test_suite(name):
    """Declares the tests.

    Args:
        name: The test_suite name.
    """
    _arm64_test(
        name = name + "_arm64",
        target_under_test = _BUNDLE,
        abi = "arm64-v8a",
        elf_machine = 183,
        libraries = ["libapp.so", "libcombined.so"],
        target_compatible_with = ["@platforms//os:macos"],
    )
    _x86_64_test(
        name = name + "_x86_64",
        target_under_test = _BUNDLE,
        abi = "x86_64",
        elf_machine = 62,
        libraries = ["libapp.so", "libcombined.so"],
        target_compatible_with = ["@platforms//os:macos"],
    )
    _not_android_test(
        name = name + "_not_android",
        target_under_test = _BUNDLE + "_any_platform",
        target_compatible_with = ["@platforms//os:macos"],
    )
    native.test_suite(
        name = name,
        tests = [name + "_arm64", name + "_x86_64", name + "_not_android"],
    )
