"""Analysis tests for flutter_apple_version_check.

The check is a validation action: it is registered over the plist it is given,
with the name and app the failure message uses, and the version the
application reports, which the bundle's must be. Its stamp is in the
`_validation` output group, so building the app runs it. What the tool says
about a plist and a version is covered by its unit test; what makes a build
fail is that the stamp is required, which is asserted here.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//flutter:defs.bzl", "flutter_application")
load("//flutter/private:apple_version_check.bzl", "flutter_apple_version_check")
load("//flutter/private:flutter_apple_bundle_version.bzl", "flutter_apple_bundle_version")

def _check_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    actions = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "FlutterCheckAppleVersion"
    ]
    asserts.equals(env, 1, len(actions), "expected one check action")
    if len(actions) != 1:
        return analysistest.end(env)
    argv = actions[0].argv

    asserts.true(env, argv[argv.index("--plist") + 1].endswith(ctx.attr.plist), argv)
    asserts.equals(env, "macos/Runner/Info.plist", argv[argv.index("--name") + 1])
    asserts.equals(env, "flutter_macos_app", argv[argv.index("--rule") + 1])

    # The app's version, which an equal literal may match.
    version_file = argv[argv.index("--version-file") + 1]
    asserts.true(env, version_file.endswith("_version_check_version.bundle_version"), argv)
    asserts.true(
        env,
        "_version_check_version.bundle_version" in [f.basename for f in actions[0].inputs.to_list()],
        "the version file is an input",
    )
    asserts.true(env, argv[argv.index("--app") + 1].endswith(":app"), argv)
    asserts.true(env, argv[argv.index("--version-target") + 1].endswith(":_version_check_version"), argv)

    # What the application reports, as the bundle's keys carry it: its
    # `build_name` of 3.1 padded to three numbers.
    asserts.true(env, argv[argv.index("--application") + 1].endswith(":_version_check_application"), argv)
    asserts.equals(env, "3.1.0", argv[argv.index("--short-version-string") + 1])
    asserts.equals(env, "42", argv[argv.index("--build-version") + 1])

    asserts.equals(
        env,
        sorted([f.basename for f in actions[0].inputs.to_list() if f.basename.endswith(".dart")]),
        ["check_apple_version_keys.dart", "merge_plists.dart", "plist_binary.dart"],
        "the tool and the parsers it imports",
    )

    # The build requires the check: the stamp is a validation output.
    stamp = actions[0].outputs.to_list()[0]
    asserts.true(
        env,
        stamp in target[OutputGroupInfo]._validation.to_list(),
        "the check is a requirement of the target",
    )
    return analysistest.end(env)

_check_test = analysistest.make(
    _check_test_impl,
    attrs = {"plist": attr.string(mandatory = True)},
)

def _invalid_application_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "the application ")
    asserts.expect_failure(env, "build_name = \"1.0-beta\" is not a valid CFBundleShortVersionString")
    return analysistest.end(env)

_invalid_application_test = analysistest.make(
    _invalid_application_test_impl,
    expect_failure = True,
)

def _setting_test_impl(ctx):
    env = analysistest.begin(ctx)
    actions = [a for a in analysistest.target_actions(env) if a.mnemonic == "FlutterCheckAppleVersion"]
    asserts.equals(env, 1, len(actions), "expected one check action")
    if len(actions) != 1:
        return analysistest.end(env)
    argv = actions[0].argv

    # The program has the setting's build number, and the check names the
    # setting, so that a version target with its own fails saying so.
    asserts.equals(env, "123", argv[argv.index("--build-version") + 1])
    asserts.equals(env, "--@rules_flutter//flutter:build_number", argv[argv.index("--build-version-setting") + 1])
    asserts.equals(env, "3.1.0", argv[argv.index("--short-version-string") + 1])
    asserts.false(env, "--short-version-string-setting" in argv, argv)
    return analysistest.end(env)

_setting_test = analysistest.make(
    _setting_test_impl,
    config_settings = {str(Label("//flutter:build_number")): "123"},
)

def apple_version_check_test_suite(name):
    """Defines the tests.

    Args:
        name: The test_suite target name.
    """
    flutter_application(
        name = "_version_check_application",
        package = ":pubspec-metadata",
        main = "web_fixture_main.dart",
        build_name = "3.1",
        build_number = "42",
        tags = ["manual"],
    )
    flutter_apple_bundle_version(
        name = "_version_check_version",
        build_name = "3.1.0",
        build_number = "42",
        tags = ["manual"],
    )
    tests = []
    for fixture in ["FlutterCreate", "Literal"]:
        flutter_apple_version_check(
            name = "_version_check_" + fixture,
            plist = "apple_version_check/%s.plist" % fixture,
            plist_name = "macos/Runner/Info.plist",
            app_label = "//flutter/tests:app",
            application = ":_version_check_application",
            version = ":_version_check_version",
            rule_name = "flutter_macos_app",
            tags = ["manual"],
        )
        _check_test(
            name = "%s_%s" % (name, fixture),
            target_under_test = ":_version_check_" + fixture,
            plist = "apple_version_check/%s.plist" % fixture,
        )
        tests.append(":%s_%s" % (name, fixture))

    # An application whose version no Apple bundle can carry fails the app
    # that names it, whatever its `version` says.
    flutter_application(
        name = "_version_check_invalid_application",
        package = ":pubspec-metadata",
        main = "web_fixture_main.dart",
        build_name = "1.0-beta",
        tags = ["manual"],
    )
    flutter_apple_version_check(
        name = "_version_check_invalid",
        plist = "apple_version_check/FlutterCreate.plist",
        app_label = "//flutter/tests:app",
        application = ":_version_check_invalid_application",
        version = ":_version_check_version",
        rule_name = "flutter_macos_app",
        tags = ["manual"],
    )
    _invalid_application_test(
        name = name + "_invalid_application",
        target_under_test = ":_version_check_invalid",
    )
    tests.append(":%s_invalid_application" % name)

    # Built with `--@rules_flutter//flutter:build_number`, the application's
    # version is the setting's.
    _setting_test(
        name = name + "_build_number_setting",
        target_under_test = ":_version_check_FlutterCreate",
    )
    tests.append(":%s_build_number_setting" % name)

    native.test_suite(name = name, tests = tests)
