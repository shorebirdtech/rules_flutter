"""Unit tests for the defines the built-in Linux runner compiles with.

The defines reach the runner as C string literals on the compiler's command
line, so a value with a quote or backslash must be escaped, not spliced in raw.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:flutter_linux_application.bzl", "linux_runner_defines")

def _define(defines, name):
    """The value `name` is defined as in a `NAME=value` list, or None."""
    for d in defines:
        if d.startswith(name + "="):
            return d[len(name) + 1:]
    return None

def _plain_title_test_impl(ctx):
    env = unittest.begin(ctx)
    defines = linux_runner_defines("com.example.notes", "Example Notes")
    asserts.equals(env, "\"com.example.notes\"", _define(defines, "GTK_APP_ID"))
    asserts.equals(env, "\"Example Notes\"", _define(defines, "WINDOW_TITLE"))
    return unittest.end(env)

def _escapes_quotes_and_backslashes_test_impl(ctx):
    env = unittest.begin(ctx)
    defines = linux_runner_defines("com.example.x", "Say \"hi\" \\ bye\nnow")
    asserts.equals(env, "\"Say \\\"hi\\\" \\\\ bye\\nnow\"", _define(defines, "WINDOW_TITLE"))
    return unittest.end(env)

def _each_define_is_defined_once_test_impl(ctx):
    env = unittest.begin(ctx)
    for gtk_app_id, title in [
        ("com.example.flutter", "Flutter"),
        ("org.example.my_app", ""),
        ("com.example.a-b_c", "Ünïcode ✓"),
    ]:
        names = [d.split("=")[0] for d in linux_runner_defines(gtk_app_id, title)]
        asserts.equals(env, len(names), len(depset(names).to_list()))
    return unittest.end(env)

_plain_title_test = unittest.make(_plain_title_test_impl)
_escapes_quotes_and_backslashes_test = unittest.make(_escapes_quotes_and_backslashes_test_impl)
_each_define_is_defined_once_test = unittest.make(_each_define_is_defined_once_test_impl)

def linux_runner_defines_test_suite(name):
    unittest.suite(
        name,
        _plain_title_test,
        _escapes_quotes_and_backslashes_test,
        _each_define_is_defined_once_test,
    )
