"""Tests of `flutter_android_plugin_libs`: an app links the plugins it uses, and checks those only.

Over `//flutter/tests/android_plugin_libs_fixture`, where three plugins each
have an Android library and `app_uses_<n>` depends on plugin `<n>` alone.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_java//java/common:java_info.bzl", "JavaInfo")

_FIXTURE = "//flutter/tests/android_plugin_libs_fixture:"

def _linked_jars(target):
    return sorted([jar.basename for jar in target[JavaInfo].transitive_runtime_jars.to_list()])

def _links_only_its_plugins_impl(ctx):
    """An app that depends on plugin A links A's library, and not B's or the other's."""
    env = analysistest.begin(ctx)
    asserts.equals(env, ["liblib_a.jar"], _linked_jars(analysistest.target_under_test(env)))
    return analysistest.end(env)

_links_only_its_plugins_test = analysistest.make(_links_only_its_plugins_impl)

def _checks_what_it_links_impl(ctx):
    """An app that links plugin A fails for what A's Gradle build declares, naming it."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, '"g:needed_by_a:2.0",  # declared by package:plugin_a 1.0; missing')
    asserts.expect_failure(env, "bazel run //app:a_maven_artifacts` prints the complete block for the plugins this app links")
    return analysistest.end(env)

_checks_what_it_links_test = analysistest.make(_checks_what_it_links_impl, expect_failure = True)

def _ignores_what_it_does_not_link_impl(ctx):
    """An app builds whatever plugins the lock lists, when the ones it links are satisfied.

    The hub's Maven data says plugins A and B lack artifacts; the app links
    neither, so it neither fails nor links them.
    """
    env = analysistest.begin(ctx)
    asserts.equals(env, ["liblib_ok.jar"], _linked_jars(analysistest.target_under_test(env)))
    return analysistest.end(env)

_ignores_what_it_does_not_link_test = analysistest.make(_ignores_what_it_does_not_link_impl)

def _report_content(env):
    actions = [a for a in analysistest.target_actions(env) if a.mnemonic == "FileWrite"]
    asserts.equals(env, 1, len(actions))
    return actions[0].content

def _report_names_only_its_plugins_impl(ctx):
    """An app that links plugin A reports A's artifact, not B's or the installed one."""
    env = analysistest.begin(ctx)
    content = _report_content(env)
    asserts.true(env, '"g:needed_by_a:2.0",  # declared by package:plugin_a 1.0; missing' in content, content)
    asserts.false(env, "needed_by_b" in content, content)
    asserts.true(env, "Android plugins that //app:a links" in content, content)
    return analysistest.end(env)

_report_names_only_its_plugins_test = analysistest.make(_report_names_only_its_plugins_impl)

def _report_does_not_fail_impl(ctx):
    """An app whose plugins are all satisfied reports so, listing only its own."""
    env = analysistest.begin(ctx)
    content = _report_content(env)
    asserts.true(env, "All 1 are provided" in content, content)
    asserts.true(env, '"g:installed:1.0"' in content, content)
    asserts.false(env, "needed_by" in content, content)
    return analysistest.end(env)

_report_does_not_fail_test = analysistest.make(_report_does_not_fail_impl)

def android_plugin_libs_test_suite(name):
    """Declares the tests.

    Args:
        name: The test_suite name.
    """
    _links_only_its_plugins_test(
        name = name + "_links_only_its_plugins",
        target_under_test = _FIXTURE + "libs_of_a",
    )
    _checks_what_it_links_test(
        name = name + "_checks_what_it_links",
        target_under_test = _FIXTURE + "checked_libs_of_a",
    )
    _ignores_what_it_does_not_link_test(
        name = name + "_ignores_what_it_does_not_link",
        target_under_test = _FIXTURE + "checked_libs_of_ok",
    )
    _report_names_only_its_plugins_test(
        name = name + "_report_names_only_its_plugins",
        target_under_test = _FIXTURE + "report_of_a",
    )
    _report_does_not_fail_test(
        name = name + "_report_does_not_fail",
        target_under_test = _FIXTURE + "report_of_ok",
    )
    native.test_suite(
        name = name,
        tests = [
            name + "_report_names_only_its_plugins",
            name + "_report_does_not_fail",
            name + "_links_only_its_plugins",
            name + "_checks_what_it_links",
            name + "_ignores_what_it_does_not_link",
        ],
    )
