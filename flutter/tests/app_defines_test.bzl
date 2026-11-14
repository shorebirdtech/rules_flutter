"""An app's Dart defines reach its kernel compile whole, commas included, and reserved keys do not.

`flutter_test` cannot take a comma in a define's value (its dependencies are
compiled by kernel_worker, which splits every `-D` on commas), so hello_world's
end-to-end define test no longer uses one. Applications are still compiled by
frontend_server, which does not split, and this pins that.

The command-line flag is rules_dart's, which reserves no key. The keys the
Flutter build sets itself are refused where a Flutter target merges its
defines, from the flag and, for a `flutter_test`, from its `defines` too.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//flutter/private:flutter_application.bzl", "flutter_application")
load("//flutter/private:flutter_test.bzl", "flutter_test")

_FLAG = str(Label("@rules_dart//dart:extra_dart_defines"))

def _comma_test_impl(ctx):
    env = analysistest.begin(ctx)
    kernels = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "DartKernel"
    ]
    asserts.equals(env, 1, len(kernels), "expected one DartKernel")
    argv = kernels[0].argv if kernels else []
    asserts.true(env, "-DATTR_COMMA=a,b" in argv, "the attr define reaches the compile whole")
    asserts.true(env, "-DFLAG_COMMA=c,d" in argv, "the flag define reaches the compile whole")
    return analysistest.end(env)

_comma_test = analysistest.make(
    _comma_test_impl,
    config_settings = {
        _FLAG: ["FLAG_COMMA=c,d"],
    },
)

def _refused_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "Invalid Dart define %r in %s" % (ctx.attr.define, ctx.attr.source))
    return analysistest.end(env)

_refused_attrs = {
    "define": attr.string(mandatory = True),
    "source": attr.string(mandatory = True),
}

_refused_from_flag_test = analysistest.make(
    _refused_test_impl,
    attrs = _refused_attrs,
    expect_failure = True,
    config_settings = {_FLAG: ["dart.vm.product=true"]},
)

_refused_test = analysistest.make(
    _refused_test_impl,
    attrs = _refused_attrs,
    expect_failure = True,
)

def app_defines_test_suite(name):
    """Fixtures and tests for comma-valued and reserved defines.

    Args:
        name: The test suite name.
    """
    flutter_application(
        name = "_defines_comma_app",
        package = ":pubspec-metadata",
        defines = ["ATTR_COMMA=a,b"],
        main = "web_fixture_main.dart",
        tags = ["manual"],
    )
    flutter_application(
        name = "_defines_plain_app",
        package = ":pubspec-metadata",
        main = "web_fixture_main.dart",
        tags = ["manual"],
    )
    flutter_test(
        name = "_defines_plain_test",
        package = ":pubspec-metadata",
        main = "lib/language_version_main.dart",
        tags = ["manual"],
        deps = ["//flutter/tests/flutter_test_analyze_fixture/fake_test_api"],
    )
    flutter_test(
        name = "_defines_reserved_test",
        package = ":pubspec-metadata",
        defines = ["FLUTTER_APP_FLAVOR=x"],
        main = "lib/language_version_main.dart",
        tags = ["manual"],
        deps = ["//flutter/tests/flutter_test_analyze_fixture/fake_test_api"],
    )
    _comma_test(
        name = name + "_comma",
        target_under_test = ":_defines_comma_app",
    )
    _refused_from_flag_test(
        name = name + "_flag_reserved_app",
        target_under_test = ":_defines_plain_app",
        define = "dart.vm.product=true",
        source = "`--@rules_dart//dart:extra_dart_defines`",
    )
    _refused_from_flag_test(
        name = name + "_flag_reserved_test",
        target_under_test = ":_defines_plain_test.program",
        define = "dart.vm.product=true",
        source = "`--@rules_dart//dart:extra_dart_defines`",
    )
    _refused_test(
        name = name + "_attr_reserved_test",
        target_under_test = ":_defines_reserved_test.program",
        define = "FLUTTER_APP_FLAVOR=x",
        source = "defines attribute of",
    )
    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_comma",
            ":" + name + "_flag_reserved_app",
            ":" + name + "_flag_reserved_test",
            ":" + name + "_attr_reserved_test",
        ],
    )
