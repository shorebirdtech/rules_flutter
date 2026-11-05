"""Tests for the integration test rules: the bootstrap, the test rule and the variant's package check.

Over `//flutter/tests/integration_fixture`.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//flutter:providers.bzl", "FlutterIntegrationRunnerInfo")
load("//flutter/private:flutter_integration_bootstrap.bzl", "make_integration_bootstrap_content")
load(":action_content.bzl", "written_json", "written_text")

_FIXTURE = "//flutter/tests/integration_fixture:"

# -- The bootstrap -----------------------------------------------------------

def _content_impl(ctx):
    """The bootstrap imports the test and runs it as a suite."""
    env = unittest.begin(ctx)
    plain = make_integration_bootstrap_content("org-dartlang-app:///t/a_test.dart", "b_support/integration_suite.dart")
    asserts.true(env, "import 'org-dartlang-app:///t/a_test.dart' as test;" in plain)
    asserts.true(env, "import 'b_support/integration_suite.dart';" in plain)
    asserts.true(env, "Future<void> main() => runIntegrationSuite(test.main);" in plain)
    asserts.false(env, "test_config" in plain, "no config imported when there is none")

    configured = make_integration_bootstrap_content(
        "org-dartlang-app:///t/a_test.dart",
        "b_support/integration_suite.dart",
        test_config_import = "org-dartlang-app:///t/flutter_test_config.dart",
    )
    asserts.true(env, "import 'org-dartlang-app:///t/flutter_test_config.dart' as test_config;" in configured)
    asserts.true(
        env,
        "runIntegrationSuite(test.main, testExecutable: test_config.testExecutable);" in configured,
        "the config's testExecutable runs the test's main",
    )
    return unittest.end(env)

_content_test = unittest.make(_content_impl)

def _bootstrap_impl(ctx):
    """The rule writes the bootstrap, importing the test by its workspace path, and stages the support library."""
    env = analysistest.begin(ctx)
    text = written_text(env, ".dart")
    if text == None:
        return analysistest.end(env)
    asserts.true(
        env,
        "import 'org-dartlang-app:///flutter/tests/integration_fixture/test/a_test.dart' as test;" in text,
        "the test is imported by its workspace path: %s" % text,
    )
    asserts.equals(env, ctx.attr.configured, "test_config" in text)
    asserts.true(env, "import '%s_support/integration_suite.dart';" % ctx.attr.name_of_target in text)

    staged = sorted([
        f.path.split(ctx.attr.name_of_target + "_support/")[-1]
        for a in analysistest.target_actions(env)
        if a.mnemonic == "Symlink"
        for f in a.outputs.to_list()
    ])
    asserts.equals(
        env,
        ["_channel.dart", "_channel_io.dart", "_channel_web.dart", "integration_suite.dart"],
        staged,
        "the support library staged beside the bootstrap, both platforms' channel: the import that picks one is the compiler's",
    )
    return analysistest.end(env)

_bootstrap_test = analysistest.make(
    _bootstrap_impl,
    attrs = {
        "configured": attr.bool(),
        "name_of_target": attr.string(mandatory = True),
    },
)

def _relative_impl(ctx):
    """A bootstrap for a web program imports the test by a path from itself, since the web compilers mount no file-system root."""
    env = analysistest.begin(ctx)
    text = written_text(env, ".dart")
    if text == None:
        return analysistest.end(env)
    bootstrap = [f for f in analysistest.target_under_test(env)[DefaultInfo].files.to_list() if f.basename == "bootstrap_relative.dart"][0]
    depth = len(bootstrap.dirname.split("/"))
    asserts.true(
        env,
        "import '%sflutter/tests/integration_fixture/test/a_test.dart' as test;" % ("../" * depth) in text,
        "the test is imported from the exec root, %d levels above the bootstrap: %s" % (depth, text),
    )
    asserts.true(
        env,
        "import '%sflutter/tests/integration_fixture/test/flutter_test_config.dart' as test_config;" % ("../" * depth) in text,
        "and so is its config: %s" % text,
    )
    asserts.false(env, "org-dartlang-app" in text, "no URI a web compile cannot resolve: %s" % text)
    return analysistest.end(env)

_relative_test = analysistest.make(_relative_impl)

def _bootstrap_missing_package_impl(ctx):
    """A web bootstrap whose deps lack a package its program needs fails analysis, naming the package and the hub target to add."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "the program needs `package:integration_test`, which no dependency of it brings; add `@<hub>//:integration_test`")
    return analysistest.end(env)

_bootstrap_missing_package_test = analysistest.make(_bootstrap_missing_package_impl, expect_failure = True)

# -- The test rule -----------------------------------------------------------

def _test_rule_impl(ctx):
    """The test rule tells the runner what to launch, and places the test where its app can run."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    config = written_json(env, ".integration_config.json")
    if config == None:
        return analysistest.end(env)

    asserts.equals(env, "desktop", config["family"])
    asserts.equals(env, {"FIXTURE_KEY": "fixture value"}, config["env"])
    asserts.equals(env, "@@//flutter/tests/integration_fixture:desktop_test", config["testDisplayName"])
    asserts.true(env, len(config["appArtifacts"]) > 0, "the app's files are the runner's to choose from")
    asserts.true(
        env,
        all([a.startswith("_main/flutter/tests/variant_fixture/app/") or a.startswith("_main/bazel-out") or "/flutter/tests/variant_fixture/app" in a for a in config["appArtifacts"]]),
        "app artifacts are runfiles paths: %s" % config["appArtifacts"],
    )

    environment = target[RunEnvironmentInfo].environment
    asserts.equals(env, "fixture value", environment["FIXTURE_KEY"], "the test's env reaches the runner")
    asserts.true(
        env,
        environment["FLUTTER_INTEGRATION_TEST_CONFIG"].endswith("desktop_test.integration_config.json"),
        "the runner is told where its config is: %s" % environment,
    )
    requirements = target[testing.ExecutionInfo].requirements
    asserts.equals(env, "1", requirements.get("no-remote"), "the app runs on this machine")
    asserts.equals(env, "1", requirements.get("no-sandbox"), "and in this machine's session")
    return analysistest.end(env)

_test_rule_test = analysistest.make(_test_rule_impl)

def _web_rule_impl(ctx):
    """The web test rule tells the runner which browser, and hands it the bundle to serve."""
    env = analysistest.begin(ctx)
    config = written_json(env, ".integration_config.json")
    if config == None:
        return analysistest.end(env)
    asserts.equals(env, "web", config["family"])
    asserts.equals(
        env,
        {"chrome": "_main/flutter/tests/integration_fixture/fake_chrome/chrome-headless-shell"},
        config["launcher"],
        "the browser is the runner's, by runfiles path",
    )
    bundles = [a for a in config["appArtifacts"] if a.endswith("_web")]
    asserts.equals(env, 1, len(bundles), "the bundle directory is among the app's files: %s" % config["appArtifacts"])
    target = analysistest.target_under_test(env)
    requirements = target[testing.ExecutionInfo].requirements
    asserts.equals(env, "1", requirements.get("no-remote"))
    asserts.equals(env, "1", requirements.get("no-sandbox"))
    return analysistest.end(env)

_web_rule_test = analysistest.make(_web_rule_impl)

def _web_unchecked_impl(ctx):
    """A web bundle checks the imports of the user's sources against its deps, and not of the files a rule wrote for it."""
    env = analysistest.begin(ctx)
    checks = [a for a in analysistest.target_actions(env) if a.mnemonic == "DartImportCheck"]
    asserts.equals(env, 1, len(checks), "one import check")
    if checks:
        checked = " ".join(checks[0].argv)
        asserts.true(env, "b_test.dart" in checked, "the user's source is checked: %s" % checked)
        asserts.false(env, "flutter_test_config.dart" in checked, "the rule's own file is not: %s" % checked)
    return analysistest.end(env)

_web_unchecked_test = analysistest.make(_web_unchecked_impl)

def _wrong_family_impl(ctx):
    """A test rule takes only a runner of its own family."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "is for web devices, and this rule runs the app on a desktop one")
    return analysistest.end(env)

_wrong_family_test = analysistest.make(_wrong_family_impl, expect_failure = True)

def _stub_runner_impl(ctx):
    return [FlutterIntegrationRunnerInfo(
        family = ctx.attr.family,
        launcher_config = struct(),
        runfiles = depset(),
        execution_requirements = {},
        target_compatible_with = [],
    )]

stub_runner = rule(
    implementation = _stub_runner_impl,
    attrs = {"family": attr.string(mandatory = True)},
    doc = "A runner of a family, for a test of what a test rule does with one.",
)

# -- The Chrome runner -------------------------------------------------------

def _chrome_runner_impl(ctx):
    """The Chrome runner names its browser by runfiles path and brings everything the browser needs."""
    env = analysistest.begin(ctx)
    runner = analysistest.target_under_test(env)[FlutterIntegrationRunnerInfo]
    asserts.equals(env, "web", runner.family)
    asserts.equals(
        env,
        "_main/flutter/tests/integration_fixture/fake_chrome/chrome-headless-shell",
        runner.launcher_config.chrome,
        "the runner reads the browser from the runfiles",
    )
    brought = sorted([f.basename for f in runner.runfiles.to_list()])
    asserts.equals(env, ["chrome-headless-shell", "resources.pak"], brought, "the executable and the files beside it that it needs")
    asserts.equals(env, "1", runner.execution_requirements.get("no-remote"))
    asserts.equals(env, "1", runner.execution_requirements.get("no-sandbox"))
    return analysistest.end(env)

_chrome_runner_test = analysistest.make(_chrome_runner_impl)

# -- The variant's package check ---------------------------------------------

def _missing_package_impl(ctx):
    """A program missing a package it needs fails analysis, naming the package and the hub target to add."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "the program needs `package:integration_test`, which no dependency of it brings; add `@<hub>//:integration_test`")
    return analysistest.end(env)

_missing_package_test = analysistest.make(_missing_package_impl, expect_failure = True)

def _has_package_impl(ctx):
    """A program whose dependencies bring what it needs analyses."""
    env = analysistest.begin(ctx)
    return analysistest.end(env)

_has_package_test = analysistest.make(_has_package_impl)

def flutter_integration_test_test_suite(name):
    """Tests of the integration test rules over `//flutter/tests/integration_fixture`.

    Args:
        name: The test suite name.
    """
    _content_test(name = name + "_content")
    _bootstrap_test(
        name = name + "_bootstrap",
        target_under_test = _FIXTURE + "bootstrap",
        name_of_target = "bootstrap",
    )
    _bootstrap_test(
        name = name + "_bootstrap_with_config",
        target_under_test = _FIXTURE + "bootstrap_with_config",
        name_of_target = "bootstrap_with_config",
        configured = True,
    )
    _chrome_runner_test(name = name + "_chrome_runner", target_under_test = _FIXTURE + "chrome_runner")
    _relative_test(name = name + "_relative", target_under_test = _FIXTURE + "bootstrap_relative")
    _bootstrap_missing_package_test(name = name + "_bootstrap_missing_package", target_under_test = _FIXTURE + "bootstrap_missing_a_package")
    _web_unchecked_test(name = name + "_web_unchecked", target_under_test = _FIXTURE + "web_unchecked")
    _web_rule_test(name = name + "_web_rule", target_under_test = _FIXTURE + "web_test")
    _test_rule_test(name = name + "_test_rule", target_under_test = _FIXTURE + "desktop_test")
    _wrong_family_test(name = name + "_wrong_family", target_under_test = _FIXTURE + "desktop_test_on_a_web_runner")
    _missing_package_test(name = name + "_missing_package", target_under_test = _FIXTURE + "program_missing_a_package")
    _has_package_test(name = name + "_has_package", target_under_test = _FIXTURE + "program_with_its_packages")
    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_content",
            ":" + name + "_bootstrap",
            ":" + name + "_bootstrap_with_config",
            ":" + name + "_chrome_runner",
            ":" + name + "_relative",
            ":" + name + "_bootstrap_missing_package",
            ":" + name + "_web_rule",
            ":" + name + "_web_unchecked",
            ":" + name + "_test_rule",
            ":" + name + "_wrong_family",
            ":" + name + "_missing_package",
            ":" + name + "_has_package",
        ],
    )
