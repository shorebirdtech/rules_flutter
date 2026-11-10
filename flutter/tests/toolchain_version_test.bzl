"""Tests for which Flutter version a toolchain name resolves to."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:toolchain_version.bzl", "select_flutter_version")

def _root_pin_is_exact_test_impl(ctx):
    env = unittest.begin(ctx)
    sel = select_flutter_version("flutter", "3.47.9", [("app", "3.47.9"), ("rules_flutter", "3.47.8")])
    asserts.equals(env, "3.47.9", sel.version)
    asserts.equals(env, None, sel.error)
    return unittest.end(env)

def _dependency_asking_newer_fails_test_impl(ctx):
    env = unittest.begin(ctx)
    sel = select_flutter_version("flutter", "3.47.8", [("app", "3.47.8"), ("rules_flutter", "3.47.9"), ("lib", "3.47.10")])
    asserts.equals(env, None, sel.version)
    asserts.true(env, "rules_flutter (3.47.9), lib (3.47.10)" in sel.error, sel.error)
    asserts.true(env, "raise the root's flutter_version to 3.47.10 or newer" in sel.error, sel.error)
    return unittest.end(env)

def _without_root_the_highest_wins_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "3.47.9", select_flutter_version("flutter", None, [("a", "3.47.2"), ("b", "3.47.9"), ("c", "3.47.8")]).version)
    asserts.equals(env, "3.47.10", select_flutter_version("flutter", None, [("a", "3.47.9"), ("b", "3.47.10")]).version)
    return unittest.end(env)

_root_pin_is_exact_test = unittest.make(_root_pin_is_exact_test_impl)
_dependency_asking_newer_fails_test = unittest.make(_dependency_asking_newer_fails_test_impl)
_without_root_the_highest_wins_test = unittest.make(_without_root_the_highest_wins_test_impl)

def toolchain_version_test_suite(name):
    unittest.suite(
        name,
        _root_pin_is_exact_test,
        _dependency_asking_newer_fails_test,
        _without_root_the_highest_wins_test,
    )
