"""Tests for the 32-bit ARM Android ABI (armeabi-v7a, Flutter's `android-arm`).

`flutter build apk` and `flutter build appbundle` build for android-arm,
android-arm64 and android-x64 by default, so an app built for each ABI needs
the AOT compiler of its own CPU, run with the options flutter_tools gives a
32-bit ARM snapshot.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//flutter/private:common.bzl", "ANDROID_ABIS")
load("//flutter/private:flutter_aot_target.bzl", "flutter_aot_target")

# What flutter_tools gives gen_snapshot for android-arm (`base/build.dart`):
# softfp, because Android armv7 devices have no hard-float ABI, and no integer
# division instruction, which not every 32-bit device has.
_ARM_FLAGS = ["--no-sim-use-hardfp", "--no-use-integer-division"]

_RELEASE = {"//command_line_option:compilation_mode": "opt"}

def _platform(label):
    return {"//command_line_option:platforms": str(Label(label))}

def _gen_snapshot_impl(ctx):
    env = analysistest.begin(ctx)
    actions = [a for a in analysistest.target_actions(env) if a.mnemonic == "FlutterAotElf"]
    asserts.equals(env, 1, len(actions), "expected exactly one gen_snapshot action")
    if not actions:
        return analysistest.end(env)
    argv = actions[0].argv

    # The compiler is the android-arm one, from the repository of that pair
    # (`..._android-arm`), not the arm64 or x64 one.
    asserts.true(
        env,
        argv[0].endswith("_android-%s/gen_snapshot" % ctx.attr.cpu),
        "gen_snapshot should be the android-%s one: %s" % (ctx.attr.cpu, argv[0]),
    )
    for flag in _ARM_FLAGS:
        asserts.equals(
            env,
            ctx.attr.cpu == "arm",
            flag in argv,
            "%s for android-%s: %s" % (flag, ctx.attr.cpu, argv),
        )
    return analysistest.end(env)

_ATTRS = {"cpu": attr.string(mandatory = True)}

_arm_test = analysistest.make(
    _gen_snapshot_impl,
    attrs = _ATTRS,
    config_settings = _platform("@rules_android//:armeabi-v7a") | _RELEASE,
)

_arm64_test = analysistest.make(
    _gen_snapshot_impl,
    attrs = _ATTRS,
    config_settings = _platform("@rules_android//:arm64-v8a") | _RELEASE,
)

_x64_test = analysistest.make(
    _gen_snapshot_impl,
    attrs = _ATTRS,
    config_settings = _platform("@rules_android//:x86_64") | _RELEASE,
)

def _abi_test_impl(ctx):
    env = unittest.begin(ctx)
    abi = ANDROID_ABIS["armeabi-v7a"]
    asserts.equals(env, Label("@rules_android//:armeabi-v7a"), abi.platform)
    asserts.equals(env, 40, abi.elf_machine)  # EM_ARM
    return unittest.end(env)

_abi_test = unittest.make(_abi_test_impl)

def android_arm_test_suite(name):
    """Declares the tests.

    Args:
        name: The test_suite name.
    """
    flutter_aot_target(
        name = name + "_aot_target",
        package_name = "android_arm_fixture",
        main = "lib/language_version_main.dart",
        tags = ["manual"],
    )
    for cpu, test in [("arm", _arm_test), ("arm64", _arm64_test), ("x64", _x64_test)]:
        test(
            name = "%s_gen_snapshot_%s" % (name, cpu),
            target_under_test = ":" + name + "_aot_target",
            cpu = cpu,
            target_compatible_with = ["@platforms//os:macos"],
        )
    _abi_test(name = name + "_abi")
    native.test_suite(
        name = name,
        tests = [
            name + "_gen_snapshot_arm",
            name + "_gen_snapshot_arm64",
            name + "_gen_snapshot_x64",
            name + "_abi",
        ],
    )
