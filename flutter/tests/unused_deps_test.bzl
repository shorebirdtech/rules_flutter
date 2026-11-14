"""Tests of rules_dart's unused-dependency check on Flutter's library rules.

A `flutter_library` or `flutter_plugin` checks its own imports, as a
`dart_library` does, so each of its `deps` must be imported or exported by one
of its files. A plugin is registered by native code, and a package's fonts,
assets and shaders are loaded by key, so neither need be: the rules that
declare one return `DartUsedWithoutImportInfo`, which the check reads.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_dart//dart:providers.bzl", "DartUsedWithoutImportInfo")

_FIXTURE = "//flutter/tests/unused_deps_fixture"

def _check_argv(env):
    checks = [a for a in analysistest.target_actions(env) if a.mnemonic == "DartImportCheck"]
    asserts.equals(env, 1, len(checks), "the library has no import check of its own")
    return " ".join(checks[0].argv) if checks else ""

def _unused_dep_judged_test_impl(ctx):
    # Its check judges the dependency by its files, none of which the
    # library imports: building it fails.
    env = analysistest.begin(ctx)
    argv = _check_argv(env)
    asserts.true(env, "--check-unused" in argv, "the unused check is off: %s" % argv)
    asserts.true(env, "unused_deps_fixture/base:base\tfile\t" in argv, "the dependency is not judged: %s" % argv)
    return analysistest.end(env)

_unused_dep_judged_test = analysistest.make(_unused_dep_judged_test_impl)

def _plugin_dep_exempt_test_impl(ctx):
    # A plugin among `deps` is marked exempt: the check never calls it unused,
    # and credits it for its own files only.
    env = analysistest.begin(ctx)
    argv = _check_argv(env)
    asserts.true(env, "--check-unused" in argv, "the unused check is off: %s" % argv)
    asserts.true(env, ctx.attr.dep + "\texempt" in argv, "the plugin dependency is not exempt: %s" % argv)
    return analysistest.end(env)

_plugin_dep_exempt_test = analysistest.make(
    _plugin_dep_exempt_test_impl,
    attrs = {"dep": attr.string(mandatory = True)},
)

def _used_without_import_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.equals(
        env,
        ctx.attr.expected,
        DartUsedWithoutImportInfo in target,
        "%s: DartUsedWithoutImportInfo" % target.label,
    )
    return analysistest.end(env)

_used_without_import_test = analysistest.make(
    _used_without_import_test_impl,
    attrs = {"expected": attr.bool(mandatory = True)},
)

def unused_deps_test_suite(name):
    """The tests of the unused-dependency check on Flutter's library rules.

    Args:
      name: The test suite's name.
    """
    _unused_dep_judged_test(
        name = "unused_dep_judged_test",
        target_under_test = _FIXTURE + ":unused",
    )
    _plugin_dep_exempt_test(
        name = "plugin_dep_exempt_test",
        target_under_test = _FIXTURE + ":with_plugin",
        dep = "unused_deps_fixture/plugin:plugin",
    )
    _plugin_dep_exempt_test(
        name = "pub_plugin_dep_exempt_test",
        target_under_test = _FIXTURE + ":with_pub_plugin",
        dep = "unused_deps_fixture/pub_plugin:pub_plugin",
    )
    _used_without_import_test(
        name = "bundled_used_without_import_test",
        target_under_test = _FIXTURE + "/bundled",
        expected = True,
    )
    _used_without_import_test(
        name = "library_used_with_import_test",
        target_under_test = _FIXTURE + "/base",
        expected = False,
    )
    _used_without_import_test(
        name = "plugin_used_without_import_test",
        target_under_test = _FIXTURE + "/plugin",
        expected = True,
    )
    _used_without_import_test(
        name = "pub_plugin_member_used_without_import_test",
        target_under_test = _FIXTURE + "/pub_plugin:member",
        expected = True,
    )
    _used_without_import_test(
        name = "pub_plugin_library_used_without_import_test",
        target_under_test = _FIXTURE + "/pub_plugin",
        expected = True,
    )
    _used_without_import_test(
        name = "pub_plain_library_test",
        target_under_test = _FIXTURE + "/pub_plugin:plain",
        expected = False,
    )
    native.test_suite(name = name, tests = [
        ":unused_dep_judged_test",
        ":plugin_dep_exempt_test",
        ":pub_plugin_dep_exempt_test",
        ":bundled_used_without_import_test",
        ":library_used_with_import_test",
        ":plugin_used_without_import_test",
        ":pub_plugin_member_used_without_import_test",
        ":pub_plugin_library_used_without_import_test",
        ":pub_plain_library_test",
    ])
