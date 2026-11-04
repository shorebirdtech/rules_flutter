"""Tests for how a runner collects its plugins' link libraries."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//flutter/private:flutter_desktop_plugin_info.bzl", "plugin_link_flags")

def _entry(package, linkopts = [], link_errors = []):
    return struct(package = package, linkopts = linkopts, link_errors = link_errors)

def _flags_test_impl(ctx):
    env = unittest.begin(ctx)

    # In plugin order, once each.
    asserts.equals(env, ["a.lib", "b.lib", "c.lib"], plugin_link_flags([
        _entry("one", ["a.lib", "b.lib"]),
        _entry("two", ["b.lib", "c.lib"]),
        _entry("three"),
    ], "Windows"))
    asserts.equals(env, [], plugin_link_flags([], "Linux"))
    return unittest.end(env)

flags_test = unittest.make(_flags_test_impl)

def _unreadable_subject_impl(_ctx):
    plugin_link_flags([
        _entry("fine", ["a.lib"]),
        _entry("zeta", link_errors = ["windows/CMakeLists.txt:4: `${libs}` is a CMake variable"]),
        _entry("alpha", link_errors = ["windows/CMakeLists.txt:9: `crypto` may be a target"]),
    ], "Windows")
    return []

_unreadable_subject = rule(implementation = _unreadable_subject_impl)

def _unreadable_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "These Windows plugins link libraries rules_flutter cannot translate")
    asserts.expect_failure(env, "    package:alpha\n        windows/CMakeLists.txt:9: `crypto` may be a target\n" +
                                "    package:zeta\n        windows/CMakeLists.txt:4: `${libs}` is a CMake variable")
    asserts.expect_failure(env, "flutter_windows_plugin_library` with the `linkopts`")
    return analysistest.end(env)

unreadable_test = analysistest.make(_unreadable_impl, expect_failure = True)

def desktop_plugin_link_test_suite(name):
    unittest.suite(name, flags_test)
    _unreadable_subject(name = name + "_unreadable_subject", tags = ["manual"])
    unreadable_test(name = name + "_unreadable_test", target_under_test = ":" + name + "_unreadable_subject")
