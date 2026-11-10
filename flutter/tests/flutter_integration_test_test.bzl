"""Tests for the integration test rules: the bootstrap, the test rule and the variant's package check.

Over `//flutter/tests/integration_fixture`.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//flutter:providers.bzl", "FlutterIntegrationRunnerInfo")
load("//flutter/private:flutter_integration_bootstrap.bzl", "make_integration_bootstrap_content")
load("//flutter/private:flutter_integration_test.bzl", "IOS_SIMULATOR_DBG_SETTINGS", "android_dbg_transition")
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
    asserts.equals(env, None, requirements.get("no-remote"), "the browser is the runner's own, so the test can run remotely")
    asserts.equals(env, None, requirements.get("no-sandbox"), "and needs no desktop session, so it can be sandboxed")
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

def _tags_rule_impl(ctx):
    """A test's source and tag selectors reach the runner's config."""
    env = analysistest.begin(ctx)
    config = written_json(env, ".integration_config.json")
    if config == None:
        return analysistest.end(env)

    asserts.equals(env, "_main/flutter/tests/integration_fixture/test/a_test.dart", config["source"], "the runner reads the test's source for its library tags")
    asserts.equals(env, ["a", "b || c"], config["includeTags"])
    asserts.equals(env, ["flaky"], config["excludeTags"])
    runfiles = [f.short_path for f in analysistest.target_under_test(env)[DefaultInfo].default_runfiles.files.to_list()]
    asserts.true(env, "flutter/tests/integration_fixture/test/a_test.dart" in runfiles, "and the source is in the runfiles: %s" % runfiles[:5])
    return analysistest.end(env)

_tags_rule_test = analysistest.make(_tags_rule_impl)

def _no_tags_rule_impl(ctx):
    env = analysistest.begin(ctx)
    config = written_json(env, ".integration_config.json")
    if config == None:
        return analysistest.end(env)

    asserts.equals(env, [], config["includeTags"])
    asserts.equals(env, [], config["excludeTags"])
    return analysistest.end(env)

_no_tags_rule_test = analysistest.make(_no_tags_rule_impl)

def _empty_tag_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "include_tags entry \"\" is empty, spans lines or holds a comma")
    return analysistest.end(env)

_empty_tag_test = analysistest.make(_empty_tag_impl, expect_failure = True)

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
    asserts.equals(env, {}, runner.execution_requirements, "a headless browser of its own needs neither the machine's session nor its filesystem")
    return analysistest.end(env)

_chrome_runner_test = analysistest.make(_chrome_runner_impl)

# -- Android -----------------------------------------------------------------

def _android_runner_impl(ctx):
    """The Android runner names the `adb` its SDK has for the host the test runs on, by runfiles path, and brings it."""
    env = analysistest.begin(ctx)
    runner = analysistest.target_under_test(env)[FlutterIntegrationRunnerInfo]
    asserts.equals(env, "android", runner.family)
    expected = "_main/flutter/tests/integration_fixture/fake_sdk/platform-tools/" + ctx.attr.adb
    asserts.equals(env, expected, runner.launcher_config.adb, "the adb of the %s host, read from the runfiles" % ctx.attr.host)
    asserts.equals(env, [ctx.attr.adb], [f.basename for f in runner.runfiles.to_list()], "that adb is brought")
    asserts.equals(env, "1", runner.execution_requirements.get("no-remote"))
    asserts.equals(env, "1", runner.execution_requirements.get("no-sandbox"))
    return analysistest.end(env)

def _on_host(host):
    """The configuration of a build whose tests run on a host: the platform in `//flutter/platforms`.

    The host is the target platform as well as the first execution platform, as
    in a build on that host. An execution platform alone would leave the test
    built for the machine running the analysis: on Windows, a binary built for
    Windows takes Bazel's launcher, whose maker would then be built from source
    for `host`, with a C++ toolchain no Windows machine has for Linux.
    """
    platform = str(Label("//flutter/platforms:" + host))
    return {
        "//command_line_option:extra_execution_platforms": [platform],
        "//command_line_option:platforms": [platform],
    }

def _android_runner_test(host, adb):
    return analysistest.make(
        _android_runner_impl,
        attrs = {"adb": attr.string(default = adb), "host": attr.string(default = host)},
        config_settings = _on_host(host),
    )

# The `adb` of the SDK on each host the Android rules run on.
_android_runner_linux_test = _android_runner_test("linux_x64", "adb")
_android_runner_macos_test = _android_runner_test("macos_arm64", "adb")
_android_runner_windows_test = _android_runner_test("windows_x64", "adb.exe")
_ANDROID_RUNNER_TESTS = {
    "linux_x64": _android_runner_linux_test,
    "macos_arm64": _android_runner_macos_test,
    "windows_x64": _android_runner_windows_test,
}

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

_android_rule_test = analysistest.make(_android_rule_impl, config_settings = _on_host("linux_x64"))

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

def _emulator_runner_impl(ctx):
    """The emulator runner names the emulator, its image and what the device is, brings them and the SDK's adb, and asks for the cores the emulator takes."""
    env = analysistest.begin(ctx)
    runner = analysistest.target_under_test(env)[FlutterIntegrationRunnerInfo]
    asserts.equals(env, "android", runner.family)
    fixture = "_main/flutter/tests/integration_fixture/"
    asserts.equals(env, fixture + "fake_sdk/platform-tools/adb", runner.launcher_config.adb)
    emulator = runner.launcher_config.emulator
    asserts.equals(env, fixture + "fake_emulator/emulator/emulator", emulator.executable)
    asserts.equals(env, fixture + "fake_image/source.properties", emulator.systemImage)
    asserts.equals(env, "x86_64", emulator.abi)
    asserts.equals(env, 35, emulator.apiLevel)
    asserts.equals(env, "aosp_atd", emulator.tag)
    asserts.equals(env, 2, emulator.cores)
    asserts.equals(env, 2048, emulator.memoryMb)
    asserts.equals(
        env,
        ["adb", "emulator", "qemu-system", "source.properties", "system.img"],
        sorted([f.basename for f in runner.runfiles.to_list()]),
        "the adb, the emulator with what it carries, and the image",
    )
    asserts.equals(env, "1", runner.execution_requirements.get("no-remote"))
    asserts.equals(env, "1", runner.execution_requirements.get("no-sandbox"))
    asserts.true(env, "cpu:3" in runner.execution_requirements, "the device's two cores and one for the emulator's own work")
    return analysistest.end(env)

_emulator_runner_test = analysistest.make(_emulator_runner_impl, config_settings = _on_host("macos_arm64"))

def _android_emulator_rule_impl(ctx):
    """An Android test on an emulator tells the host runner which emulator and image, as the runner says."""
    env = analysistest.begin(ctx)
    config = written_json(env, ".integration_config.json")
    if config == None:
        return analysistest.end(env)
    emulator = config["launcher"]["emulator"]
    asserts.equals(env, "x86_64", emulator["abi"])
    asserts.true(env, emulator["executable"].endswith("fake_emulator/emulator/emulator"))
    asserts.true(env, emulator["systemImage"].endswith("fake_image/source.properties"))
    requirements = analysistest.target_under_test(env)[testing.ExecutionInfo].requirements
    asserts.true(env, "cpu:3" in requirements, "the test is scheduled with the emulator's cores")
    return analysistest.end(env)

_android_emulator_rule_test = analysistest.make(_android_emulator_rule_impl, config_settings = _on_host("macos_arm64"))

def _android_emulator_abi_impl(ctx):
    """An app built for an ABI the emulator's image does not run fails analysis, naming both."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "the app is built for arm64-v8a, and the runner")
    asserts.expect_failure(env, "boots an emulator of x86_64, which cannot install it")
    return analysistest.end(env)

_android_emulator_abi_test = analysistest.make(_android_emulator_abi_impl, expect_failure = True)

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

def _ios_intel_host_impl(ctx):
    """An iOS test on an Intel Mac fails analysis, saying only Apple Silicon hosts are supported."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "rules_flutter supports Apple Silicon hosts only")
    return analysistest.end(env)

_ios_intel_host_test = analysistest.make(
    _ios_intel_host_impl,
    expect_failure = True,
    config_settings = {
        "//command_line_option:platforms": str(Label("//flutter/platforms:macos_x64")),
        "//command_line_option:host_platform": str(Label("//flutter/platforms:macos_x64")),
    },
)

def _ios_settings_impl(ctx):
    """An iOS test's app is built in debug mode, for the arm64 simulator, whatever the command line says."""
    env = unittest.begin(ctx)
    settings = IOS_SIMULATOR_DBG_SETTINGS
    asserts.equals(env, "dbg", settings["//command_line_option:compilation_mode"])
    asserts.equals(env, False, settings[str(Label("//flutter:profile"))])
    asserts.equals(env, ["sim_arm64"], settings["//command_line_option:ios_multi_cpus"])
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
    _android_rule_test(name = name + "_android_rule", target_under_test = _FIXTURE + "android_test")
    _android_env_test(name = name + "_android_env", target_under_test = _FIXTURE + "android_test_with_env")
    _android_wrong_family_test(name = name + "_android_wrong_family", target_under_test = _FIXTURE + "android_test_on_a_desktop_runner")
    for host, host_test in _ANDROID_RUNNER_TESTS.items():
        host_test(
            name = name + "_android_runner_" + host,
            target_under_test = _FIXTURE + "android_runner",
        )
    _emulator_runner_test(name = name + "_emulator_runner", target_under_test = _FIXTURE + "emulator_runner")
    _android_emulator_rule_test(name = name + "_android_emulator_rule", target_under_test = _FIXTURE + "android_emulator_test")
    _android_emulator_abi_test(name = name + "_android_emulator_abi", target_under_test = _FIXTURE + "android_emulator_test_of_another_abi")
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
    _ios_intel_host_test(name = name + "_ios_intel_host", target_under_test = _FIXTURE + "ios_test")
    _relative_test(name = name + "_relative", target_under_test = _FIXTURE + "bootstrap_relative")
    _bootstrap_missing_package_test(name = name + "_bootstrap_missing_package", target_under_test = _FIXTURE + "bootstrap_missing_a_package")
    _web_unchecked_test(name = name + "_web_unchecked", target_under_test = _FIXTURE + "web_unchecked")
    _web_rule_test(name = name + "_web_rule", target_under_test = _FIXTURE + "web_test")
    _test_rule_test(name = name + "_test_rule", target_under_test = _FIXTURE + "desktop_test")
    _wrong_family_test(name = name + "_wrong_family", target_under_test = _FIXTURE + "desktop_test_on_a_web_runner")
    _goldens_rule_test(name = name + "_goldens_rule", target_under_test = _FIXTURE + "desktop_test_with_goldens")
    _tags_rule_test(name = name + "_tags_rule", target_under_test = _FIXTURE + "desktop_test_with_tags")
    _no_tags_rule_test(name = name + "_no_tags_rule", target_under_test = _FIXTURE + "desktop_test")
    _empty_tag_test(name = name + "_empty_tag", target_under_test = _FIXTURE + "desktop_test_with_an_empty_tag")
    _missing_package_test(name = name + "_missing_package", target_under_test = _FIXTURE + "program_missing_a_package")
    _has_package_test(name = name + "_has_package", target_under_test = _FIXTURE + "program_with_its_packages")
    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_content",
            ":" + name + "_bootstrap",
            ":" + name + "_bootstrap_with_config",
            ":" + name + "_chrome_runner",
            ":" + name + "_android_rule",
        ] + [":%s_android_runner_%s" % (name, host) for host in _ANDROID_RUNNER_TESTS] + [
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
            ":" + name + "_ios_intel_host",
            ":" + name + "_relative",
            ":" + name + "_bootstrap_missing_package",
            ":" + name + "_web_rule",
            ":" + name + "_web_unchecked",
            ":" + name + "_test_rule",
            ":" + name + "_wrong_family",
            ":" + name + "_goldens_rule",
            ":" + name + "_tags_rule",
            ":" + name + "_no_tags_rule",
            ":" + name + "_empty_tag",
            ":" + name + "_missing_package",
            ":" + name + "_has_package",
        ],
    )
