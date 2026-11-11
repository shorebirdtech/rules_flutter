"""Tests that applications bundle the data assets packages declare.

A package names its `dart_data_asset`s in its `dart_package_metadata`, and every
application reaching it bundles each at `packages/<package>/<name>`, the key
`rootBundle` loads it by: in a debug build, in a release build with no link
hook to run, and in a web build; and an application of the package itself,
which no library in its `deps` names. What a link hook does with them is
`e2e/_overlay_tests/link_hooks`' to show.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//flutter:defs.bzl", "flutter_application")
load("//flutter:web.bzl", "flutter_web_bundle")
load(":action_content.bzl", "action_config")

def _bundled_impl(ctx):
    env = analysistest.begin(ctx)
    config = action_config(env, "FlutterAssetBundle")
    if config == None:
        return analysistest.end(env)

    # The bundling tool places each data asset the program ships at
    # `packages/<package>/<name>`; the program's assets reach it as
    # rules_dart's program-assets lines.
    bundle = [a for a in analysistest.target_actions(env) if a.mnemonic == "FlutterAssetBundle"][0]
    argv = bundle.argv
    asserts.true(
        env,
        "--data-asset" in argv and "package:data_asset_fixture/greeting.txt" in argv,
        "the asset bundle is not given the program's data asset: %s" % argv,
    )
    asserts.true(
        env,
        "flutter/tests/dart_asset_fixture/data_asset/greeting.txt" in [f.short_path for f in bundle.inputs.to_list()],
        "the declared file is not an input of the asset bundle",
    )
    return analysistest.end(env)

_bundled_dbg_test = analysistest.make(
    _bundled_impl,
    config_settings = {"//command_line_option:compilation_mode": "dbg"},
)

_bundled_opt_test = analysistest.make(
    _bundled_impl,
    config_settings = {"//command_line_option:compilation_mode": "opt"},
)

def data_asset_test_suite(name):
    """Declares the fixtures and tests.

    Args:
      name: The test_suite name.
    """
    flutter_application(
        name = "_data_asset_app",
        main = "lib/web_fixture_main.dart",
        package = ":pubspec-metadata",
        tags = ["manual"],
        deps = ["//flutter/tests/dart_asset_fixture/data_asset"],
    )
    flutter_web_bundle(
        name = "_data_asset_web",
        application = ":_data_asset_app",
        tags = ["manual"],
    )
    _bundled_dbg_test(
        name = name + "_debug",
        target_under_test = ":_data_asset_app",
    )
    _bundled_opt_test(
        name = name + "_release",
        target_under_test = ":_data_asset_app",
    )
    _bundled_opt_test(
        name = name + "_web",
        target_under_test = ":_data_asset_web",
    )
    _bundled_dbg_test(
        name = name + "_own_package",
        target_under_test = "//flutter/tests/dart_asset_fixture/data_asset:own_app",
    )
    native.test_suite(
        name = name,
        tests = [name + "_debug", name + "_release", name + "_web", name + "_own_package"],
    )
