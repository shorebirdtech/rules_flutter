"""A test that a target fails analysis with a given message.

A package `flutter_pub.from_lock(ignored = ...)` names fails what depends on
it, at analysis, giving the reason the module wrote.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _ignored_package_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.message)
    return analysistest.end(env)

ignored_package_test = analysistest.make(
    _ignored_package_test_impl,
    expect_failure = True,
    attrs = {
        "message": attr.string(
            doc = "Text the analysis failure must contain.",
            mandatory = True,
        ),
    },
)
