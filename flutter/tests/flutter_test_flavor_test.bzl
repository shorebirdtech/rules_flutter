"""A `flutter_test` with a `flavor` is that flavor, as `flutter test --flavor` makes it.

Its `deps`' modules and its entry (or its whole program) compile with
`FLUTTER_APP_FLAVOR`, which `appFlavor` reads, and its asset bundle holds the
pub assets whose `flavors:` name the flavor. `flutter test` matches the flavor
for the `tester` target too, so a flavored asset is in no test without one.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//flutter/private:flutter_test.bzl", "flutter_test")
load(":action_content.bzl", "action_config")

_PACKAGE = "flavor_test_fixture"
_MAIN = "lib/language_version_main.dart"
_DEFINE = "FLUTTER_APP_FLAVOR=paid"

def _compile_impl(ctx):
    env = analysistest.begin(ctx)
    compiles = [a for a in analysistest.target_actions(env) if a.mnemonic == ctx.attr.mnemonic]
    asserts.equals(env, 1, len(compiles), "expected one %s" % ctx.attr.mnemonic)
    for action in compiles:
        # `-D<define>` to frontend_server, `--define <define>` to the kernel tool.
        flavored = [a.removeprefix("-D") for a in action.argv if "FLUTTER_APP_FLAVOR" in a]
        asserts.equals(env, ctx.attr.expected, flavored, "flavor defines of %s: %s" % (ctx.attr.mnemonic, action.argv))
    return analysistest.end(env)

_compile_attrs = {
    "expected": attr.string_list(),
    "mnemonic": attr.string(mandatory = True),
}
_modular_compile_test = analysistest.make(_compile_impl, attrs = _compile_attrs)
_whole_program_compile_test = analysistest.make(
    _compile_impl,
    attrs = _compile_attrs,
    config_settings = {str(Label("@rules_dart//dart:modular_kernel")): False},
)

def _assets_impl(ctx):
    env = analysistest.begin(ctx)
    config = action_config(env, "FlutterAssetBundle")
    if config != None:
        copies = config["copies"].keys()
        asserts.equals(
            env,
            ctx.attr.expected,
            sorted([c for c in copies if c.startswith("packages/flavor_test_lib/")]),
        )
    return analysistest.end(env)

_assets_test = analysistest.make(_assets_impl, attrs = {"expected": attr.string_list()})

def flutter_test_flavor_test_suite(name):
    """Fixtures and tests for `flavor` on `flutter_test`.

    Args:
        name: The test suite name.
    """
    for flavor in ["paid", ""]:
        suffix = "paid" if flavor else "none"
        flutter_test(
            name = "_flavor_test_" + suffix,
            package_name = _PACKAGE,
            flavor = flavor,
            main = _MAIN,
            tags = ["manual"],
            deps = [
                "//flutter/tests/flavor_fixture:flavor_lib",
                "//flutter/tests/flutter_test_analyze_fixture/fake_test_api",
            ],
        )
    _modular_compile_test(
        name = name + "_modular",
        target_under_test = ":_flavor_test_paid",
        mnemonic = "DartEntryKernel",
        expected = [_DEFINE],
    )
    _whole_program_compile_test(
        name = name + "_whole_program",
        target_under_test = ":_flavor_test_paid",
        mnemonic = "DartKernel",
        expected = [_DEFINE],
    )
    _modular_compile_test(
        name = name + "_none",
        target_under_test = ":_flavor_test_none",
        mnemonic = "DartEntryKernel",
    )
    _assets_test(
        name = name + "_assets_paid",
        target_under_test = ":_flavor_test_paid",
        expected = ["packages/flavor_test_lib/assets/all.txt", "packages/flavor_test_lib/assets/paid.txt"],
    )
    _assets_test(
        name = name + "_assets_none",
        target_under_test = ":_flavor_test_none",
        expected = ["packages/flavor_test_lib/assets/all.txt"],
    )
    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_modular",
            ":" + name + "_whole_program",
            ":" + name + "_none",
            ":" + name + "_assets_paid",
            ":" + name + "_assets_none",
        ],
    )
