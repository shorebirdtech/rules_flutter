"""Analysis tests for how `flutter_test` hands the runner its test source and tag selection."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

_TAG_KEYS = ["FLUTTER_TEST_INCLUDE_TAGS", "FLUTTER_TEST_EXCLUDE_TAGS"]

def _environment(env):
    return analysistest.target_under_test(env)[RunEnvironmentInfo].environment

def _source_is_in_the_runfiles_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    source = _environment(env)["FLUTTER_TEST_SOURCE"]
    asserts.true(env, source.endswith("/flutter/tests/test_tags_fixture/main.dart"), "FLUTTER_TEST_SOURCE is " + source)
    short_paths = [f.short_path for f in target[DefaultInfo].default_runfiles.files.to_list()]
    asserts.true(
        env,
        any([source.endswith("/" + p) for p in short_paths if p.endswith("test_tags_fixture/main.dart")]),
        "main.dart is not in the runfiles: %s" % short_paths[:5],
    )
    return analysistest.end(env)

_source_is_in_the_runfiles_test = analysistest.make(_source_is_in_the_runfiles_impl)

def _selectors_are_newline_joined_impl(ctx):
    env = analysistest.begin(ctx)
    environment = _environment(env)
    asserts.equals(env, "a\nb || c", environment["FLUTTER_TEST_INCLUDE_TAGS"])
    asserts.equals(env, "flaky", environment["FLUTTER_TEST_EXCLUDE_TAGS"])
    return analysistest.end(env)

_selectors_are_newline_joined_test = analysistest.make(_selectors_are_newline_joined_impl)

def _no_attributes_no_keys_impl(ctx):
    env = analysistest.begin(ctx)
    environment = _environment(env)
    asserts.equals(env, [], [k for k in _TAG_KEYS if k in environment])
    return analysistest.end(env)

_no_attributes_no_keys_test = analysistest.make(_no_attributes_no_keys_impl)

def _empty_entry_fails_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "include_tags entry \"\" is empty, spans lines or holds a comma")
    return analysistest.end(env)

_empty_entry_fails_test = analysistest.make(_empty_entry_fails_impl, expect_failure = True)

def _comma_entry_fails_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "include_tags entry \"a,b\" is empty, spans lines or holds a comma")
    return analysistest.end(env)

_comma_entry_fails_test = analysistest.make(_comma_entry_fails_impl, expect_failure = True)

def _binary_has_no_tag_keys_impl(ctx):
    env = analysistest.begin(ctx)
    launch = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "FileWrite" and a.outputs.to_list()[0].basename.endswith(".launch.json")
    ]
    asserts.equals(env, 1, len(launch))
    content = launch[0].content
    asserts.equals(env, [], [k for k in _TAG_KEYS + ["FLUTTER_TEST_SOURCE"] if k in content])
    return analysistest.end(env)

_binary_has_no_tag_keys_test = analysistest.make(_binary_has_no_tag_keys_impl)

def flutter_test_tags_test_suite(name):
    """Declares the tests of `flutter_test`'s source and tag-selection environment.

    Args:
        name: The name of the suite.
    """
    macos = ["@platforms//os:macos"]
    _source_is_in_the_runfiles_test(
        name = name + "_source_is_in_the_runfiles",
        target_under_test = "//flutter/tests/test_tags_fixture:plain",
        target_compatible_with = macos,
    )
    _selectors_are_newline_joined_test(
        name = name + "_selectors_are_newline_joined",
        target_under_test = "//flutter/tests/test_tags_fixture:tagged",
        target_compatible_with = macos,
    )
    _no_attributes_no_keys_test(
        name = name + "_no_attributes_no_keys",
        target_under_test = "//flutter/tests/test_tags_fixture:plain",
        target_compatible_with = macos,
    )
    _empty_entry_fails_test(
        name = name + "_empty_entry_fails",
        target_under_test = "//flutter/tests/test_tags_fixture:empty_entry",
        target_compatible_with = macos,
    )
    _comma_entry_fails_test(
        name = name + "_comma_entry_fails",
        target_under_test = "//flutter/tests/test_tags_fixture:comma_entry",
        target_compatible_with = macos,
    )
    _binary_has_no_tag_keys_test(
        name = name + "_binary_has_no_tag_keys",
        target_under_test = "//flutter/tests/tester_binary_fixture:tester_binary",
        target_compatible_with = macos,
    )
    native.test_suite(name = name, tests = [
        name + "_source_is_in_the_runfiles",
        name + "_selectors_are_newline_joined",
        name + "_no_attributes_no_keys",
        name + "_empty_entry_fails",
        name + "_comma_entry_fails",
        name + "_binary_has_no_tag_keys",
    ])
