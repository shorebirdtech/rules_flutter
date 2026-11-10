"""Tests for `flutter_android_class_check`'s inputs.

The check's tool fails when one Maven library reaches the app from two
repositories (tools/test/check_android_classes_test.dart); these check that
the rule names each linked jar's Maven coordinates and target to it, and
leaves out a library the app compiles against only.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_dart//dart:defs.bzl", "dart_library")
load("@rules_java//java:java_library.bzl", "java_library")
load("//flutter/private:flutter_android_classes.bzl", "flutter_android_class_check")
load("//flutter/private:resolved_package.bzl", "resolved_package")
load(":tests_package.bzl", "TESTS_PACKAGE")

def _maven_pairs(argv):
    return [
        (argv[i + 1], argv[i + 2])
        for i in range(len(argv))
        if argv[i] == "--maven"
    ]

def _names_linked_libraries_impl(ctx):
    env = analysistest.begin(ctx)
    actions = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "FlutterCheckAndroidClasses"
    ]
    asserts.equals(env, 1, len(actions))
    pairs = _maven_pairs(actions[0].argv)
    label = str(Label("//flutter/tests:" + ctx.attr.linked))
    asserts.equals(env, [(label, "g:linked:1.0")], pairs, actions[0].argv)
    return analysistest.end(env)

_names_linked_libraries_test = analysistest.make(
    _names_linked_libraries_impl,
    attrs = {"linked": attr.string()},
)

def _jar_args(argv):
    return [argv[i + 1] for i in range(len(argv)) if argv[i] == "--jar"]

def _compares_classes_impl(ctx):
    env = analysistest.begin(ctx)
    actions = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "FlutterCheckAndroidClasses"
    ]
    asserts.equals(env, 1, len(actions))
    argv = actions[0].argv
    asserts.true(env, len(_jar_args(argv)) > 0, "the jars are compared: %s" % argv)
    return analysistest.end(env)

_compares_classes_test = analysistest.make(_compares_classes_impl)

def _allows_duplicate_classes_impl(ctx):
    env = analysistest.begin(ctx)
    actions = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "FlutterCheckAndroidClasses"
    ]
    asserts.equals(env, 1, len(actions))
    argv = actions[0].argv
    asserts.equals(env, [], _jar_args(argv), "no jar is compared")
    asserts.false(
        env,
        [f for f in actions[0].inputs.to_list() if f.extension == "jar"],
        "no jar is read",
    )

    # The switch allows duplicate classes, not one library from two
    # repositories: that check still runs.
    asserts.equals(env, 1, len(_maven_pairs(argv)), argv)
    return analysistest.end(env)

def _follows_resolved_package_impl(ctx):
    env = analysistest.begin(ctx)
    actions = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "FlutterCheckAndroidClasses"
    ]
    asserts.equals(env, 1, len(actions))
    return analysistest.end(env)

# A resolve-mapped pub package reaches the app as `resolved_package`, whose
# `deps` is one label, not a list; the coordinates aspect walks through it.
_follows_resolved_package_test = analysistest.make(_follows_resolved_package_impl)

_allows_duplicate_classes_test = analysistest.make(
    _allows_duplicate_classes_impl,
    config_settings = {
        str(Label("//flutter:allow_duplicate_classes")): True,
    },
)

def android_class_check_test_suite(name):
    """Declares the tests.

    Args:
        name: The test_suite name.
    """

    # Libraries as rules_jvm_external imports them: tagged with their
    # coordinates, and the owners of their jars. Analysis only, so nothing
    # is compiled.
    for lib in ["linked", "compile_only"]:
        native.genrule(
            name = "%s_%s_src" % (name, lib),
            outs = ["%s_%s/A.java" % (name, lib)],
            cmd = "false",
            tags = ["manual"],
        )
        java_library(
            name = "%s_%s" % (name, lib),
            srcs = [":%s_%s_src" % (name, lib)],
            neverlink = lib == "compile_only",
            tags = ["manual", "maven_coordinates=g:%s:1.0" % lib],
        )
    java_library(
        name = name + "_library",
        exports = [":%s_linked" % name, ":%s_compile_only" % name],
        tags = ["manual"],
    )
    flutter_android_class_check(
        name = name + "_subject",
        app = "//:app",
        libraries = [":%s_library" % name],
        report = "//:app_maven_artifacts",
        tags = ["manual"],
    )
    _names_linked_libraries_test(
        name = name + "_names_linked_libraries",
        linked = name + "_linked",
        target_under_test = ":%s_subject" % name,
    )
    _compares_classes_test(
        name = name + "_compares_classes",
        target_under_test = ":%s_subject" % name,
    )
    _allows_duplicate_classes_test(
        name = name + "_allows_duplicate_classes",
        target_under_test = ":%s_subject" % name,
    )
    dart_library(
        name = name + "_mapped_library",
        package = ":pubspec-metadata",
        tags = ["manual"],
    )
    resolved_package(
        name = name + "_mapped",
        deps = ":%s_mapped_library" % name,
        package_name = TESTS_PACKAGE,
        tags = ["manual"],
    )
    flutter_android_class_check(
        name = name + "_resolved_subject",
        app = "//:app",
        libraries = [":%s_library" % name, ":%s_mapped" % name],
        report = "//:app_maven_artifacts",
        tags = ["manual"],
    )
    _follows_resolved_package_test(
        name = name + "_follows_resolved_package",
        target_under_test = ":%s_resolved_subject" % name,
    )
    native.test_suite(
        name = name,
        tests = [
            name + "_follows_resolved_package",
            name + "_names_linked_libraries",
            name + "_compares_classes",
            name + "_allows_duplicate_classes",
        ],
    )
