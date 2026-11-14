"""An app's `manifest_values` version is its application's, or analysis fails.

`android_binary` writes a `versionCode` of `manifest_values` over the
manifest's, so `flutter_android_app` holds it to the application's version as
it does `build_number`: the APK would otherwise report one version and the
program, as `appBuildNumber`, another.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _refused_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "`versionCode` in `manifest_values` = \"7\"")
    asserts.expect_failure(env, "app_flutter it is built over has build_number = \"42\"")
    return analysistest.end(env)

manifest_values_version_refused_test = analysistest.make(
    _refused_impl,
    expect_failure = True,
)
