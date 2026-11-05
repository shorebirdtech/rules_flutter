"""Tests for the integration test rules: the bootstrap, the test rule and the variant's package check.

Over `//flutter/tests/integration_fixture`.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//flutter:providers.bzl", "FlutterIntegrationRunnerInfo")
load("//flutter/private:flutter_integration_bootstrap.bzl", "make_integration_bootstrap_content")
load("//flutter/private:flutter_integration_test.bzl", "android_dbg_transition", "ios_simulator_dbg_settings")
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
        ["_channel.dart", "_channel_io.dart", "_channel_web.dart", "_golden.dart", "integration_suite.dart"],
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
    asserts.equals(env, None, config["goldens"], "a test given no golden comparator has none")
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

# -- Goldens -------------------------------------------------------------------

def _stub_golden_service_impl(ctx):
    executable = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.write(executable, "", is_executable = True)
    return [
        DefaultInfo(executable = executable, runfiles = ctx.runfiles(files = [executable])),
        RunEnvironmentInfo(environment = {"FLUTTER_TEST_DILL": "_main/stub.dill"}),
    ]

stub_golden_service = rule(
    implementation = _stub_golden_service_impl,
    executable = True,
    doc = "An executable with an environment, shaped as the `flutter_test` that compares goldens, for a test of what a test rule does with one.",
)

def _goldens_rule_impl(ctx):
    """A test with a golden service tells the runner how to start it and which test's goldens it compares."""
    env = analysistest.begin(ctx)
    config = written_json(env, ".integration_config.json")
    if config == None:
        return analysistest.end(env)

    goldens = config["goldens"]
    asserts.equals(env, "_main/flutter/tests/integration_fixture/golden_service", goldens["executable"], "the service is started from the runfiles")
    asserts.equals(env, {"FLUTTER_TEST_DILL": "_main/stub.dill"}, goldens["environment"], "with the environment its rule gave it")
    asserts.equals(env, "flutter/tests/integration_fixture/test/a_test.dart", goldens["testSource"], "goldens are relative to the directory of the test's source")
    return analysistest.end(env)

_goldens_rule_test = analysistest.make(_goldens_rule_impl)

def _goldens_without_source_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "`src` (the test's source, which goldens are relative to) and `golden_service`")
    return analysistest.end(env)

_goldens_without_source_test = analysistest.make(_goldens_without_source_impl, expect_failure = True)

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

# -- Android -----------------------------------------------------------------

def _android_runner_impl(ctx):
    """The Android runner names the SDK's `adb` by runfiles path and brings it."""
    env = analysistest.begin(ctx)
    runner = analysistest.target_under_test(env)[FlutterIntegrationRunnerInfo]
    asserts.equals(env, "android", runner.family)
    asserts.equals(
        env,
        "_main/flutter/tests/integration_fixture/fake_sdk/platform-tools/adb",
        runner.launcher_config.adb,
        "the runner reads the adb from the runfiles",
    )
    asserts.equals(env, ["adb"], [f.basename for f in runner.runfiles.to_list()], "the adb is brought")
    asserts.equals(env, "1", runner.execution_requirements.get("no-remote"))
    asserts.equals(env, "1", runner.execution_requirements.get("no-sandbox"))
    return analysistest.end(env)

_android_runner_test = analysistest.make(_android_runner_impl)

def _android_rule_impl(ctx):
    """The Android test rule tells the runner which adb, takes the device from the invoking shell, and places the test where its device is."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    config = written_json(env, ".integration_config.json")
    if config == None:
        return analysistest.end(env)
    asserts.equals(env, "android", config["family"])
    asserts.equals(
        env,
        {"adb": "_main/flutter/tests/integration_fixture/fake_sdk/platform-tools/adb"},
        config["launcher"],
    )
    asserts.equals(env, {}, config["env"])
    asserts.true(env, len(config["appArtifacts"]) > 0, "the app's files are the runner's to choose from")

    environment = target[RunEnvironmentInfo]
    asserts.equals(
        env,
        ["ANDROID_SERIAL"],
        environment.inherited_environment,
        "the device the invoking shell names reaches the runner",
    )
    asserts.true(env, environment.environment["FLUTTER_INTEGRATION_TEST_CONFIG"].endswith("android_test.integration_config.json"))
    requirements = target[testing.ExecutionInfo].requirements
    asserts.equals(env, "1", requirements.get("no-remote"), "the device is attached to this machine")
    asserts.equals(env, "1", requirements.get("no-sandbox"), "and reached from outside Bazel's sandbox")
    return analysistest.end(env)

_android_rule_test = analysistest.make(_android_rule_impl)

def _android_env_impl(ctx):
    """An Android test given an `env` fails analysis, saying an app on a device takes none and where its defines go."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "an app on an Android device cannot receive an environment")
    return analysistest.end(env)

_android_env_test = analysistest.make(_android_env_impl, expect_failure = True)

def _android_wrong_family_impl(ctx):
    """An Android test takes only an Android runner."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "is for desktop devices, and this rule runs the app on a android one")
    return analysistest.end(env)

_android_wrong_family_test = analysistest.make(_android_wrong_family_impl, expect_failure = True)

BuiltAsInfo = provider(
    doc = "How a probe was built.",
    fields = ["mode", "profile", "platforms"],
)

def _probe_impl(ctx):
    return [BuiltAsInfo(
        mode = ctx.var["COMPILATION_MODE"],
        profile = ctx.attr._profile[BuildSettingInfo].value,
        platforms = ctx.attr._platforms[BuildSettingInfo].value,
    )]

_probe = rule(
    implementation = _probe_impl,
    attrs = {
        "_platforms": attr.label(default = Label("@rules_android//flags:android_platforms")),
        "_profile": attr.label(default = Label("//flutter:profile")),
    },
    doc = "Records the configuration it is built in.",
)

def _built_under_impl(ctx):
    return [ctx.attr.target[0][BuiltAsInfo]]

_built_under_android_transition = rule(
    implementation = _built_under_impl,
    attrs = {
        "abi": attr.string(mandatory = True),
        "target": attr.label(cfg = android_dbg_transition, mandatory = True),
    },
    doc = "Builds `target` as an Android integration test builds its app, for `abi`.",
)

def _android_transition_impl(ctx):
    """An Android test's app is built in debug mode, for the ABI the test names, whatever the command line says."""
    env = analysistest.begin(ctx)
    built = analysistest.target_under_test(env)[BuiltAsInfo]
    asserts.equals(env, "dbg", built.mode, "debug, the mode a VM service is served in")
    asserts.equals(env, False, built.profile)
    asserts.equals(env, [str(Label("@rules_android//:" + ctx.attr.abi))], built.platforms, "the platform of the device's ABI")
    return analysistest.end(env)

_android_transition_test = analysistest.make(
    _android_transition_impl,
    attrs = {"abi": attr.string(mandatory = True)},
    # What the command line says, which the transition overrides.
    config_settings = {
        "//command_line_option:compilation_mode": "opt",
        str(Label("//flutter:profile")): True,
        str(Label("@rules_android//flags:android_platforms")): [str(Label("@rules_android//:x86_64"))],
    },
)

def android_probe_targets(name, abi):
    """A probe built as an Android test builds its app, for the test of what that does.

    Args:
        name: The name of the target that has the probe's configuration.
        abi: The ABI the transition is told.
    """
    _probe(name = name + "_probe", tags = ["manual"])
    _built_under_android_transition(
        name = name,
        abi = abi,
        target = ":" + name + "_probe",
        tags = ["manual"],
    )

# -- iOS simulator -------------------------------------------------------------

def _ios_runner_impl(ctx):
    """The iOS runner tells the host runner which simulator to make, and asks for the cores one takes."""
    env = analysistest.begin(ctx)
    runner = analysistest.target_under_test(env)[FlutterIntegrationRunnerInfo]
    asserts.equals(env, "ios_simulator", runner.family)
    asserts.equals(env, {"deviceType": "iPhone 16", "runtime": ""}, {"deviceType": runner.launcher_config.deviceType, "runtime": runner.launcher_config.runtime})
    asserts.equals(env, "1", runner.execution_requirements.get("no-remote"))
    asserts.equals(env, "1", runner.execution_requirements.get("no-sandbox"))
    asserts.true(env, "cpu:2" in runner.execution_requirements, "a booting simulator is scheduled with its cores: %s" % runner.execution_requirements)
    return analysistest.end(env)

_ios_runner_test = analysistest.make(_ios_runner_impl)

def _ios_named_runner_impl(ctx):
    """An iOS runner passes on the device type and runtime it is given."""
    env = analysistest.begin(ctx)
    runner = analysistest.target_under_test(env)[FlutterIntegrationRunnerInfo]
    asserts.equals(env, "iPad (10th generation)", runner.launcher_config.deviceType)
    asserts.equals(env, "com.apple.CoreSimulator.SimRuntime.iOS-18-0", runner.launcher_config.runtime)
    asserts.true(env, "cpu:3" in runner.execution_requirements)
    return analysistest.end(env)

_ios_named_runner_test = analysistest.make(_ios_named_runner_impl)

def _ios_rule_impl(ctx):
    """The iOS test rule tells the runner which simulator, takes DEVELOPER_DIR from the invoking shell, and places the test on this Mac."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    config = written_json(env, ".integration_config.json")
    if config == None:
        return analysistest.end(env)
    asserts.equals(env, "ios_simulator", config["family"])
    asserts.equals(env, {"deviceType": "iPhone 16", "runtime": ""}, config["launcher"])
    asserts.equals(env, {}, config["env"])
    asserts.true(env, len(config["appArtifacts"]) > 0)
    environment = target[RunEnvironmentInfo]
    asserts.equals(env, ["DEVELOPER_DIR"], environment.inherited_environment, "the Xcode the invoking shell selected reaches `xcrun`")
    requirements = target[testing.ExecutionInfo].requirements
    asserts.equals(env, "1", requirements.get("no-remote"))
    asserts.equals(env, "1", requirements.get("no-sandbox"))
    asserts.true(env, "cpu:2" in requirements, "the runner's cores reach the test: %s" % requirements)
    return analysistest.end(env)

_ios_rule_test = analysistest.make(_ios_rule_impl)

def _ios_env_impl(ctx):
    """An iOS test given an `env` fails analysis, saying an app on a simulator takes none."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "an app on an iOS simulator cannot receive an environment")
    return analysistest.end(env)

_ios_env_test = analysistest.make(_ios_env_impl, expect_failure = True)

def _ios_wrong_family_impl(ctx):
    """An iOS test takes only a simulator runner."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "is for desktop devices, and this rule runs the app on a ios_simulator one")
    return analysistest.end(env)

_ios_wrong_family_test = analysistest.make(_ios_wrong_family_impl, expect_failure = True)

def _ios_settings_impl(ctx):
    """An iOS test's app is built in debug mode, for the simulator CPU the test names, whatever the command line says."""
    env = unittest.begin(ctx)
    for cpu in ["sim_arm64", "x86_64"]:
        settings = ios_simulator_dbg_settings(cpu)
        asserts.equals(env, "dbg", settings["//command_line_option:compilation_mode"])
        asserts.equals(env, False, settings[str(Label("//flutter:profile"))])
        asserts.equals(env, [cpu], settings["//command_line_option:ios_multi_cpus"])
    return unittest.end(env)

_ios_settings_test = unittest.make(_ios_settings_impl)

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
    _android_runner_test(name = name + "_android_runner", target_under_test = _FIXTURE + "android_runner")
    _android_rule_test(name = name + "_android_rule", target_under_test = _FIXTURE + "android_test")
    _android_env_test(name = name + "_android_env", target_under_test = _FIXTURE + "android_test_with_env")
    _android_wrong_family_test(name = name + "_android_wrong_family", target_under_test = _FIXTURE + "android_test_on_a_desktop_runner")
    for abi in ["arm64-v8a", "x86_64"]:
        _android_transition_test(
            name = name + "_android_transition_" + abi.replace("-", "_"),
            target_under_test = _FIXTURE + "built_for_" + abi.replace("-", "_"),
            abi = abi,
        )
    _ios_runner_test(name = name + "_ios_runner", target_under_test = _FIXTURE + "ios_runner")
    _ios_named_runner_test(name = name + "_ios_named_runner", target_under_test = _FIXTURE + "ios_named_runner")
    _ios_rule_test(name = name + "_ios_rule", target_under_test = _FIXTURE + "ios_test")
    _ios_env_test(name = name + "_ios_env", target_under_test = _FIXTURE + "ios_test_with_env")
    _ios_wrong_family_test(name = name + "_ios_wrong_family", target_under_test = _FIXTURE + "ios_test_on_a_desktop_runner")
    _ios_settings_test(name = name + "_ios_settings")
    _relative_test(name = name + "_relative", target_under_test = _FIXTURE + "bootstrap_relative")
    _bootstrap_missing_package_test(name = name + "_bootstrap_missing_package", target_under_test = _FIXTURE + "bootstrap_missing_a_package")
    _web_unchecked_test(name = name + "_web_unchecked", target_under_test = _FIXTURE + "web_unchecked")
    _web_rule_test(name = name + "_web_rule", target_under_test = _FIXTURE + "web_test")
    _test_rule_test(name = name + "_test_rule", target_under_test = _FIXTURE + "desktop_test")
    _wrong_family_test(name = name + "_wrong_family", target_under_test = _FIXTURE + "desktop_test_on_a_web_runner")
    _goldens_rule_test(name = name + "_goldens_rule", target_under_test = _FIXTURE + "desktop_test_with_goldens")
    _goldens_without_source_test(name = name + "_goldens_without_source", target_under_test = _FIXTURE + "desktop_test_with_goldens_and_no_source")
    _missing_package_test(name = name + "_missing_package", target_under_test = _FIXTURE + "program_missing_a_package")
    _has_package_test(name = name + "_has_package", target_under_test = _FIXTURE + "program_with_its_packages")
    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_content",
            ":" + name + "_bootstrap",
            ":" + name + "_bootstrap_with_config",
            ":" + name + "_chrome_runner",
            ":" + name + "_android_runner",
            ":" + name + "_android_rule",
            ":" + name + "_android_env",
            ":" + name + "_android_wrong_family",
            ":" + name + "_android_transition_arm64_v8a",
            ":" + name + "_android_transition_x86_64",
            ":" + name + "_ios_runner",
            ":" + name + "_ios_named_runner",
            ":" + name + "_ios_rule",
            ":" + name + "_ios_env",
            ":" + name + "_ios_wrong_family",
            ":" + name + "_ios_settings",
            ":" + name + "_relative",
            ":" + name + "_bootstrap_missing_package",
            ":" + name + "_web_rule",
            ":" + name + "_web_unchecked",
            ":" + name + "_test_rule",
            ":" + name + "_wrong_family",
            ":" + name + "_goldens_rule",
            ":" + name + "_goldens_without_source",
            ":" + name + "_missing_package",
            ":" + name + "_has_package",
        ],
    )
