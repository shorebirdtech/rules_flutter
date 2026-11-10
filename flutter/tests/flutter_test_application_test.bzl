"""`flutter_test`'s `application`: the test is compiled in the application's package.

As `flutter test` compiles a test in the package it is in, a `flutter_test`
naming an `application` takes the application's package name, language
version and sources, so `package:<app>/…` in the test (or its
`flutter_test_config.dart`) resolves against the application's `lib/`.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_dart//dart:providers.bzl", "DartAnalyzableInfo")
load("//flutter/private:flutter_application.bzl", "flutter_application")
load("//flutter/private:flutter_test.bzl", "flutter_test")
load(":action_content.bzl", "package_entry", "written_json")
load(":tests_package.bzl", "TESTS_LANGUAGE_VERSION", "TESTS_PACKAGE")

_PACKAGE = TESTS_PACKAGE
_LANGUAGE_VERSION = TESTS_LANGUAGE_VERSION
_APP_MAIN = "lib/language_version_main.dart"
_TEST_MAIN = "lib/web_fixture_main.dart"
_FAKE_TEST_API = "//flutter/tests/flutter_test_analyze_fixture/fake_test_api"

def _compiled_in_application_impl(ctx):
    env = analysistest.begin(ctx)

    entry = package_entry(written_json(env, ".package_config.json"), _PACKAGE)
    asserts.true(env, entry != None, "the test's package config has the application's package")
    if entry != None:
        asserts.equals(env, _LANGUAGE_VERSION, entry.get("languageVersion", "<absent>"), "in the application's language version")

    records = [
        p
        for p in analysistest.target_under_test(env)[DartAnalyzableInfo].dart_info.transitive_packages.to_list()
        if p.package_name == _PACKAGE
    ]
    asserts.equals(env, 1, len(records), "the analyzer sees the test in the application's package")

    # The application's own sources are the test's, compiled with its own
    # files into their modules, as its `main` is here.
    compiled = [
        f.short_path
        for a in analysistest.target_actions(env)
        if a.mnemonic == "DartModule"
        for f in a.inputs.to_list()
    ]
    asserts.true(env, "flutter/tests/" + _APP_MAIN in compiled, "the application's sources are compiled with the test: %s" % compiled)
    return analysistest.end(env)

_compiled_in_application_test = analysistest.make(_compiled_in_application_impl)

def _refused_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.message)
    return analysistest.end(env)

_refused_test = analysistest.make(
    _refused_impl,
    expect_failure = True,
    attrs = {"message": attr.string()},
)

def flutter_test_application_test_suite(name):
    """The fixtures and the analysis tests over them.

    The fixtures are `manual` and never built: they have no `package:flutter`.
    The tests read declared actions and providers.

    Args:
        name: Prefix for the generated test targets and the suite itself.
    """
    flutter_application(
        name = "_fta_application",
        package = ":pubspec-metadata",
        main = _APP_MAIN,
        tags = ["manual"],
    )
    flutter_test(
        name = "_fta_test",
        application = ":_fta_application",
        main = _TEST_MAIN,
        tags = ["manual"],
        deps = [_FAKE_TEST_API],
    )
    flutter_test(
        name = "_fta_other_package",
        application = ":_fta_application",
        package = "//flutter/tests/another_package:pubspec-metadata",
        main = _TEST_MAIN,
        tags = ["manual"],
        deps = [_FAKE_TEST_API],
    )
    flutter_test(
        name = "_fta_no_package",
        main = _TEST_MAIN,
        tags = ["manual"],
        deps = [_FAKE_TEST_API],
    )

    _compiled_in_application_test(
        name = name + "_compiled_in_application",
        target_under_test = ":_fta_test.program",
    )
    _refused_test(
        name = name + "_other_package",
        target_under_test = ":_fta_other_package.program",
        message = "Drop `package`, or name the same declaration.",
    )
    _refused_test(
        name = name + "_no_package",
        target_under_test = ":_fta_no_package.program",
        message = "`package` is required",
    )
    native.test_suite(
        name = name,
        tests = [
            name + "_compiled_in_application",
            name + "_other_package",
            name + "_no_package",
        ],
    )
