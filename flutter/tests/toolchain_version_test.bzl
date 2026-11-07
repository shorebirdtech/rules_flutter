"""Tests for which Flutter version a toolchain name resolves to."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:toolchain_version.bzl", "select_flutter_version")

def _root_wins_test_impl(ctx):
    env = unittest.begin(ctx)

    # A consumer pinning an older release than rules_flutter's own tag gets it.
    asserts.equals(env, "3.47.8", select_flutter_version("3.47.8", ["3.47.8", "3.47.9"]))
    asserts.equals(env, "3.47.9", select_flutter_version("3.47.9", ["3.41.2", "3.47.9"]))
    return unittest.end(env)

def _without_root_the_highest_wins_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "3.47.9", select_flutter_version(None, ["3.41.2", "3.47.9", "3.47.8"]))
    asserts.equals(env, "3.47.10", select_flutter_version(None, ["3.47.9", "3.47.10"]))
    return unittest.end(env)

_root_wins_test = unittest.make(_root_wins_test_impl)
_without_root_the_highest_wins_test = unittest.make(_without_root_the_highest_wins_test_impl)

def toolchain_version_test_suite(name):
    unittest.suite(
        name,
        _root_wins_test,
        _without_root_the_highest_wins_test,
    )
