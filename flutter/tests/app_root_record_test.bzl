"""An app's package record keeps what the library at its root states.

An app, widget test or web bundle whose sources are `lib/` of a directory is
that directory's Dart package, and a `flutter_library` rooted at the same
directory is the same package. `synthesize_app_package` puts one record in
place of theirs. That record has to carry the library's code assets and licence:
a record built only from the app's name, root and language version drops them,
and the app then neither bundles the library's native code nor lists its
licence.

The probe calls `synthesize_app_package` on the records of its `deps`, as
`flutter_application`, `flutter_test` and `flutter_web_bundle` do, and returns
the app's own record.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_dart//dart:providers.bzl", "DartInfo")
load("@rules_dart//dart:utils.bzl", "collect_packages", "derive_package_root")
load("//flutter/private:app_entrypoint.bzl", "synthesize_app_package")

AppRecordInfo = provider(
    doc = "The app's own package record, as `synthesize_app_package` returns it.",
    fields = {"record": "DartPackageInfo: the last of the synthesized packages."},
)

def _app_record_probe_impl(ctx):
    packages = synthesize_app_package(
        ctx.label,
        collect_packages(ctx.attr.deps),
        ctx.attr.package_name,
        derive_package_root(ctx.label.workspace_root, ctx.label.package),
        ctx.attr.language_version,
    )
    return [AppRecordInfo(record = packages[-1])]

app_record_probe = rule(
    implementation = _app_record_probe_impl,
    attrs = {
        "deps": attr.label_list(providers = [DartInfo]),
        "language_version": attr.string(),
        "package_name": attr.string(mandatory = True),
    },
)

def _keeps_root_library_facts_impl(ctx):
    env = analysistest.begin(ctx)
    record = analysistest.target_under_test(env)[AppRecordInfo].record
    asserts.equals(env, "app_root_record", record.package_name)
    asserts.equals(env, "flutter/tests/app_root_record_fixture", record.package_root)
    asserts.equals(
        env,
        ["package:app_root_record/system"],
        [asset.asset_id for asset in record.code_assets],
        "the library's code asset is in the app's record",
    )
    asserts.true(env, record.license_file != None, "the library's licence is in the app's record")
    asserts.equals(env, "LICENSE", record.license_file.basename)

    # The app states no version, so it takes the library's.
    asserts.equals(env, "3.5", record.language_version)
    return analysistest.end(env)

_keeps_root_library_facts_test = analysistest.make(_keeps_root_library_facts_impl)

def _agreeing_version_impl(ctx):
    env = analysistest.begin(ctx)
    record = analysistest.target_under_test(env)[AppRecordInfo].record
    asserts.equals(env, "3.5", record.language_version)
    return analysistest.end(env)

_agreeing_version_test = analysistest.make(_agreeing_version_impl)

def _conflicting_version_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "3.6")
    asserts.expect_failure(env, "3.5")
    return analysistest.end(env)

_conflicting_version_test = analysistest.make(_conflicting_version_impl, expect_failure = True)

def app_root_record_test_suite(name):
    """The analysis tests over `//flutter/tests/app_root_record_fixture`.

    Args:
        name: Prefix for the generated test targets and the suite itself.
    """
    fixture = "//flutter/tests/app_root_record_fixture"
    _keeps_root_library_facts_test(
        name = name + "_keeps_root_library_facts",
        target_under_test = fixture + ":app",
    )
    _agreeing_version_test(
        name = name + "_agreeing_version",
        target_under_test = fixture + ":app_same_version",
    )
    _conflicting_version_test(
        name = name + "_conflicting_version",
        target_under_test = fixture + ":app_other_version",
    )
    native.test_suite(
        name = name,
        tests = [
            name + "_keeps_root_library_facts",
            name + "_agreeing_version",
            name + "_conflicting_version",
        ],
    )
