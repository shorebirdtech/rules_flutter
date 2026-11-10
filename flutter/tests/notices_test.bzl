"""A program's `NOTICES` merges the licence of every package in its closure.

The `FlutterNotices` action's inputs are the licence files of the packages the
program depends on, pure Dart ones included, the program's own and the
engine's; its config
names them by package, sorted, the program's own last. A package with no
licence file contributes nothing.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//flutter:defs.bzl", "flutter_application")
load(":action_content.bzl", "action_config")

# The engine's licences, `sky_engine`'s `LICENSE`, which every program reads.
_ENGINE = "LICENSE"

def _packages_impl(ctx):
    env = analysistest.begin(ctx)
    config = action_config(env, "FlutterNotices")
    if config != None:
        listed = ["%s=%s" % (p["name"], p["file"].rsplit("/", 1)[-1]) for p in config["packages"]]
        asserts.equals(env, ctx.attr.expected, listed, "the packages in the notices config")
    return analysistest.end(env)

_packages_test = analysistest.make(
    _packages_impl,
    attrs = {"expected": attr.string_list()},
)

def _inputs_impl(ctx):
    env = analysistest.begin(ctx)
    actions = [a for a in analysistest.target_actions(env) if a.mnemonic == "FlutterNotices"]
    asserts.equals(env, 1, len(actions), "expected one FlutterNotices action")
    if actions:
        names = sorted([f.basename for f in actions[0].inputs.to_list() if f.basename.endswith("LICENSE")])
        asserts.equals(env, ctx.attr.expected, names, "the licence files the action reads")
    return analysistest.end(env)

_inputs_test = analysistest.make(
    _inputs_impl,
    attrs = {"expected": attr.string_list()},
)

def notices_test_suite(name):
    """Fixtures and tests for the packages a program's `NOTICES` lists.

    Args:
        name: The test suite name.
    """

    # The app with no licence of its own is in this directory's package,
    # which names none.
    flutter_application(
        name = "_plain_app",
        package = ":pubspec-metadata",
        main = "web_fixture_main.dart",
        tags = ["manual"],
        deps = ["//flutter/tests/notices_fixture/bare:notices_bare"],
    )
    _packages_test(
        name = name + "_packages",
        target_under_test = "//flutter/tests/notices_fixture:notices_app",
        expected = [
            "notices_dart=DART_LICENSE",
            "notices_flutter=FLUTTER_LICENSE",
            "notices_app=APP_LICENSE",
        ],
    )
    _inputs_test(
        name = name + "_inputs",
        target_under_test = "//flutter/tests/notices_fixture:notices_app",
        expected = ["APP_LICENSE", "DART_LICENSE", "FLUTTER_LICENSE", _ENGINE],
    )
    _inputs_test(
        name = name + "_none",
        target_under_test = ":_plain_app",
        expected = [_ENGINE],
    )
    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_packages",
            ":" + name + "_inputs",
            ":" + name + "_none",
        ],
    )
