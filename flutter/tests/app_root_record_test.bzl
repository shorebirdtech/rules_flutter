"""An app's package record keeps what the library at its root states.

An app, widget test or web bundle whose sources are `lib/` of a directory is
that directory's Dart package, and a `flutter_library` rooted at the same
directory is the same package, naming the same `dart_package_metadata`.
`synthesize_app_package` puts one record in place of theirs. That record has to
carry the package's code assets and licence, or the app neither bundles the
library's native code nor lists its licence; and an app over a library of its
package that names no declaration fails, naming both.

The probe calls `synthesize_app_package` on the records of its `deps`, as
`flutter_application`, `flutter_test` and `flutter_web_bundle` do, and returns
the app's own record.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_dart//dart:providers.bzl", "DartInfo", "DartPackageMetadataInfo")
load("@rules_dart//dart:utils.bzl", "collect_packages")
load("//flutter/private:app_entrypoint.bzl", "synthesize_app_package")

AppRecordInfo = provider(
    doc = "The app's own package record, as `synthesize_app_package` returns it.",
    fields = {"record": "DartPackageInfo: the last of the synthesized packages."},
)

def _app_record_probe_impl(ctx):
    metadata = ctx.attr.package[DartPackageMetadataInfo]
    packages = synthesize_app_package(
        ctx.label,
        collect_packages(ctx.attr.deps),
        metadata.package_name,
        metadata.package_root,
        metadata,
    )
    return [AppRecordInfo(record = packages[-1])]

app_record_probe = rule(
    implementation = _app_record_probe_impl,
    attrs = {
        "deps": attr.label_list(providers = [DartInfo]),
        "package": attr.label(providers = [DartPackageMetadataInfo], mandatory = True),
    },
)

def _keeps_root_library_facts_impl(ctx):
    env = analysistest.begin(ctx)
    record = analysistest.target_under_test(env)[AppRecordInfo].record
    asserts.equals(env, "app_root_record_fixture", record.package_name)
    asserts.equals(env, "flutter/tests/app_root_record_fixture", record.package_root)
    asserts.equals(
        env,
        ["package:app_root_record_fixture/system"],
        [asset.asset_id for asset in record.code_assets],
        "the library's code asset is in the app's record",
    )
    asserts.true(env, record.license_file != None, "the library's licence is in the app's record")
    asserts.equals(env, "LICENSE", record.license_file.basename)

    asserts.equals(env, "3.5", record.language_version)
    return analysistest.end(env)

_keeps_root_library_facts_test = analysistest.make(_keeps_root_library_facts_impl)

def _undeclared_library_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "different `dart_package_metadata`")
    asserts.expect_failure(env, "app_root_record_fixture:pubspec-metadata")
    asserts.expect_failure(env, "none, named by @@//flutter/tests/app_root_record_fixture:undeclared_library")
    return analysistest.end(env)

_undeclared_library_test = analysistest.make(_undeclared_library_impl, expect_failure = True)

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
    _undeclared_library_test(
        name = name + "_undeclared_library",
        target_under_test = fixture + ":app_over_undeclared_library",
    )
    native.test_suite(
        name = name,
        tests = [
            name + "_keeps_root_library_facts",
            name + "_undeclared_library",
        ],
    )
