"""A key two different files claim fails the build, naming the key."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "fonts/MaterialIcons-Regular.otf")
    return analysistest.end(env)

two_files_one_key_test = analysistest.make(_impl, expect_failure = True)
