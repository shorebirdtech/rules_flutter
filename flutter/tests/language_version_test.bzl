"""`language_version` reaches the app's own `package_config.json` entry.

The attribute exists because an absent `languageVersion` is not a neutral
default: `package_config.json` reads it as the *current* SDK's, so an app
whose pubspec pins an older version is compiled under newer syntax and
semantics than `flutter build` would allow. Declaring the attr is therefore
only half the job — a rule that accepts it and drops it diverges exactly as
far as one that never offered it, and does so silently.

That is what these tests pin, and why they read the emitted config rather
than the helper that builds it. `synthesize_app_package` was already covered
by a unit test asserting it carries the value it is handed; every rule but
`flutter_application` still failed to hand it over, and the suite stayed
green. The assertion has to start at the rule's attr and end at the bytes.

Both failure modes are covered by the same assertion:

  * `flutter_kernel` and `flutter_aot_snapshot` never declared the attr
    while `flutter_compile_kernel` read it off their `ctx`, so they failed at
    analysis — `//:hello_world` and `//:hello_world_aot` in `e2e/hello_world`
    could not be built at all;
  * `flutter_test` and `flutter_web_bundle` declared it, then called
    `synthesize_app_package` without it, so widget tests and web builds
    quietly compiled under the SDK's version.

The two analyzer-side rules get a second assertion. They also publish a
package record through `dart_analyzable_info`, and that call
drops the value independently of the compile path's — `flutter_test` dropped
it in both places, and fixing only the one the config test catches would
leave `dart analyze` running against a different language version than the
compiler.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_dart//dart:providers.bzl", "DartAnalyzableInfo")
load("//flutter:web.bzl", "flutter_web_bundle")
load("//flutter/private:flutter_aot_snapshot.bzl", "flutter_aot_snapshot")
load("//flutter/private:flutter_application.bzl", "flutter_application")
load("//flutter/private:flutter_kernel.bzl", "flutter_kernel")
load("//flutter/private:flutter_test.bzl", "flutter_test")
load("//flutter/private:flutter_web_branch.bzl", "web_branches_target")
load(":action_content.bzl", "package_entry", "written_json")
load(":tests_package.bzl", "TESTS_LANGUAGE_VERSION", "TESTS_PACKAGE")

# The version the fixtures' package states, deliberately not the SDK's own.
_LANGUAGE_VERSION = TESTS_LANGUAGE_VERSION
_PACKAGE = TESTS_PACKAGE
_MAIN = "lib/language_version_main.dart"

def _assert_config_states_version(env):
    """The app's own `package_config.json` entry carries the stated version."""
    entry = package_entry(written_json(env, ".package_config.json"), _PACKAGE)
    asserts.true(
        env,
        entry != None,
        "no `%s` entry in the emitted package_config" % _PACKAGE,
    )
    if entry != None:
        asserts.equals(
            env,
            _LANGUAGE_VERSION,
            # `.get`, because the drop shows up as a *missing* key rather than
            # an empty one — `generate_package_config` omits `languageVersion`
            # entirely when the record's is blank.
            entry.get("languageVersion", "<absent>"),
            "the app's package_config entry must state the attr's version",
        )

def _assert_provider_states_version(env):
    """The published package record carries it too, for `dart analyze`."""
    dart_info = analysistest.target_under_test(env)[DartAnalyzableInfo].dart_info
    records = [
        p
        for p in dart_info.transitive_packages.to_list()
        if p.package_name == _PACKAGE
    ]
    asserts.equals(env, 1, len(records), "expected one `%s` package record" % _PACKAGE)
    if records:
        asserts.equals(
            env,
            _LANGUAGE_VERSION,
            records[0].language_version,
            "the analyzable package record must state the attr's version",
        )

def _application_test_impl(ctx):
    env = analysistest.begin(ctx)
    _assert_config_states_version(env)
    return analysistest.end(env)

def _flutter_test_test_impl(ctx):
    env = analysistest.begin(ctx)
    _assert_config_states_version(env)
    _assert_provider_states_version(env)
    return analysistest.end(env)

def _web_test_impl(ctx):
    env = analysistest.begin(ctx)
    _assert_provider_states_version(env)
    return analysistest.end(env)

def _web_branch_test_impl(ctx):
    # The bundle's package config is written by its branch target, one per
    # compiler, so that is where the version has to arrive.
    env = analysistest.begin(ctx)
    _assert_config_states_version(env)
    return analysistest.end(env)

def _kernel_test_impl(ctx):
    env = analysistest.begin(ctx)
    _assert_config_states_version(env)
    return analysistest.end(env)

def _aot_test_impl(ctx):
    env = analysistest.begin(ctx)
    _assert_config_states_version(env)
    return analysistest.end(env)

_application_test = analysistest.make(_application_test_impl)
_flutter_test_test = analysistest.make(_flutter_test_test_impl)
_web_test = analysistest.make(_web_test_impl)
_web_branch_test = analysistest.make(_web_branch_test_impl)
_kernel_test = analysistest.make(_kernel_test_impl)
_aot_test = analysistest.make(_aot_test_impl)

def _setup_fixtures():
    """One fixture per rule that synthesizes an app package.

    `manual`, and never built: with no `deps` there is no `package:flutter`,
    so none of these would compile. The tests read declared actions and
    providers, which analysis alone produces.
    """
    flutter_application(
        name = "_lv_application",
        package = ":pubspec-metadata",
        main = _MAIN,
        tags = ["manual"],
    )

    # The only fixture needing a dep: `flutter_test` refuses a closure
    # exposing neither `package:flutter_test` nor `package:test_api`, so the
    # generated bootstrap it would emit has something to import.
    flutter_test(
        name = "_lv_flutter_test",
        package = ":pubspec-metadata",
        main = _MAIN,
        tags = ["manual"],
        deps = ["//flutter/tests/flutter_test_analyze_fixture/fake_test_api"],
    )

    flutter_web_bundle(
        name = "_lv_web",
        package = ":pubspec-metadata",
        main = _MAIN,
        tags = ["manual"],
    )

    # The two low-level rules. Both build a narrowed attr surface of their own,
    # and both failed at analysis rather than silently — declaring the fixture
    # is most of the test.
    flutter_kernel(
        name = "_lv_kernel",
        package = ":pubspec-metadata",
        main = _MAIN,
        tags = ["manual"],
    )

    flutter_aot_snapshot(
        name = "_lv_aot",
        package = ":pubspec-metadata",
        main = _MAIN,
        tags = ["manual"],
    )

def language_version_test_suite(name):
    """Instantiate the fixtures and the analysis tests over them.

    Args:
        name: Prefix for the generated test targets and the suite itself.
    """
    _setup_fixtures()

    _application_test(
        name = name + "_application",
        target_under_test = ":_lv_application",
    )
    _flutter_test_test(
        name = name + "_flutter_test",
        target_under_test = ":_lv_flutter_test.program",
    )
    _web_test(
        name = name + "_web",
        target_under_test = ":_lv_web",
    )
    _web_branch_test(
        name = name + "_web_branch",
        target_under_test = ":" + web_branches_target("_lv_web"),
    )
    _kernel_test(
        name = name + "_kernel",
        target_under_test = ":_lv_kernel",
    )
    _aot_test(
        name = name + "_aot",
        target_under_test = ":_lv_aot",
    )

    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_application",
            ":" + name + "_flutter_test",
            ":" + name + "_web",
            ":" + name + "_web_branch",
            ":" + name + "_kernel",
            ":" + name + "_aot",
        ],
    )
