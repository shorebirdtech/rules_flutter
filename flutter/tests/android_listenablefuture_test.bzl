"""Tests for `flutter_android_listenablefuture`.

An app links `com.google.guava:listenablefuture` 1.0 at runtime when Gradle
would: when it links no Guava, or one older than 27.0, whose POM does not ask
for the empty `9999.0-empty-to-avoid-conflict-with-guava` placeholder.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_java//java:java_library.bzl", "java_library")
load("@rules_java//java/common:java_info.bzl", "JavaInfo")
load("//flutter/private:flutter_android_classes.bzl", "flutter_android_listenablefuture")

def _links_listenablefuture(target):
    if JavaInfo not in target:
        return False
    return any([
        jar.basename.endswith("listenablefuture-1.0.jar")
        for jar in target[JavaInfo].transitive_runtime_jars.to_list()
    ])

def _links_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.true(
        env,
        _links_listenablefuture(analysistest.target_under_test(env)),
        "the app should link listenablefuture 1.0",
    )
    return analysistest.end(env)

_links_test = analysistest.make(_links_impl)

def _drops_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.false(
        env,
        _links_listenablefuture(analysistest.target_under_test(env)),
        "an app linking Guava 27.0 or later should not link listenablefuture 1.0",
    )
    return analysistest.end(env)

_drops_test = analysistest.make(_drops_impl)

def android_listenablefuture_test_suite(name):
    """Declares the tests.

    Args:
        name: The test_suite name.
    """

    # rules_jvm_external's targets, as the class check's aspect sees them:
    # by the coordinates in their tags.
    for suffix, coordinates in [
        ("guava_jre", "com.google.guava:guava:33.3.1-jre"),
        ("guava_android", "com.google.guava:guava:27.0-android"),
        ("old_guava", "com.google.guava:guava:26.0-android"),
        ("other", "com.google.guava:guava-testlib:33.3.1-jre"),
    ]:
        java_library(
            name = "%s_lib_%s" % (name, suffix),
            tags = ["manual", "maven_coordinates=" + coordinates],
        )

    # Through a library that depends on it, as a plugin's would.
    java_library(
        name = name + "_lib_plugin",
        tags = ["manual"],
        exports = [":%s_lib_guava_android" % name],
    )

    cases = [
        ("no_guava", [], _links_test),
        ("other_artifact", ["other"], _links_test),
        ("guava_before_27", ["old_guava"], _links_test),
        ("guava_jre", ["guava_jre"], _drops_test),
        ("guava_android_through_a_library", ["plugin"], _drops_test),
    ]
    for case, libraries, test in cases:
        flutter_android_listenablefuture(
            name = "%s_%s_subject" % (name, case),
            libraries = [":%s_lib_%s" % (name, lib) for lib in libraries],
            tags = ["manual"],
        )
        test(
            name = "%s_%s" % (name, case),
            target_under_test = ":%s_%s_subject" % (name, case),
        )
    native.test_suite(
        name = name,
        tests = ["%s_%s" % (name, case) for case, _, _ in cases],
    )
