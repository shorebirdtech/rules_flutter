"""A macOS plugin compiles against the engine of the build mode.

The application bundles that mode's FlutterMacOS.framework; a plugin
importing another mode's copy puts two frameworks of one name into the
bundle, which rules_apple cannot assemble.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_apple//apple:providers.bzl", "AppleFrameworkImportInfo")
load("//flutter/private:flutter_apple_plugin_library.bzl", "flutter_apple_plugin_library")

def _engine_dirs(target):
    dirs = {}
    for f in target[AppleFrameworkImportInfo].framework_imports.to_list():
        i = f.path.find("/FlutterMacOS.framework/")
        if i >= 0:
            dirs[f.path[:i].rpartition("/")[2]] = True
    return sorted(dirs.keys())

def _imports_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.equals(env, [ctx.attr.engine_dir], _engine_dirs(analysistest.target_under_test(env)))
    return analysistest.end(env)

def _imports_test(config_settings):
    return analysistest.make(
        _imports_impl,
        attrs = {"engine_dir": attr.string()},
        config_settings = config_settings,
    )

_imports_debug_test = _imports_test({"//command_line_option:compilation_mode": "dbg"})
_imports_release_test = _imports_test({"//command_line_option:compilation_mode": "opt"})

def apple_plugin_engine_test_suite(name):
    """The macOS plugin's engine import follows the build mode.

    Args:
        name: Suite name.
    """
    flutter_apple_plugin_library(
        name = name + "_plugin",
        srcs = ["apple_plugin_engine_probe.swift"],
        platform = "macos",
    )
    framework = ":_%s_plugin__flutter_framework" % name
    _imports_debug_test(
        name = name + "_debug",
        target_under_test = framework,
        engine_dir = "engine-debug",
        target_compatible_with = ["@platforms//os:macos"],
    )
    _imports_release_test(
        name = name + "_release",
        target_under_test = framework,
        engine_dir = "engine",
        target_compatible_with = ["@platforms//os:macos"],
    )
    native.test_suite(name = name, tests = [name + "_debug", name + "_release"])
