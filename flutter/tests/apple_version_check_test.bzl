"""Analysis tests for flutter_apple_version_check.

The check is a validation action: it is registered over the plist it is given,
with the name and app the failure message uses, and its stamp is in the
`_validation` output group, so building the app runs it. What the tool says
about a plist is covered by its unit test; what makes a build fail is that the
stamp is required, which is asserted here.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//flutter/private:apple_version_check.bzl", "flutter_apple_version_check")

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
    asserts.true(env, argv[argv.index("--app") + 1].endswith(":app"), argv)

    asserts.equals(
        env,
        sorted([f.basename for f in actions[0].inputs.to_list() if f.basename.endswith(".dart")]),
        ["check_apple_version_keys.dart", "merge_plists.dart"],
        "the tool and the parser it imports",
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

def apple_version_check_test_suite(name):
    """Defines the tests.

    Args:
        name: The test_suite target name.
    """
    tests = []
    for fixture in ["FlutterCreate", "Literal"]:
        flutter_apple_version_check(
            name = "_version_check_" + fixture,
            plist = "apple_version_check/%s.plist" % fixture,
            plist_name = "macos/Runner/Info.plist",
            app_label = "//flutter/tests:app",
            rule_name = "flutter_macos_app",
            tags = ["manual"],
        )
        _check_test(
            name = "%s_%s" % (name, fixture),
            target_under_test = ":_version_check_" + fixture,
            plist = "apple_version_check/%s.plist" % fixture,
        )
        tests.append(":%s_%s" % (name, fixture))

    native.test_suite(name = name, tests = tests)
