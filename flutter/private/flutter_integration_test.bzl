"""The integration test rules and the runner rules that say where they run.

One test rule per family of device, sharing one implementation: the build
flags that put the app on a device (an Android ABI, a simulator CPU) must come
from the test rule itself, and a transition reads attributes but not providers,
so they cannot come from the runner. The runner rule of a family says which
device of the family, and the test rule refuses a runner of another.
"""

load("@rules_dart//dart:utils.bzl", "runfiles_path")
load("//flutter:providers.bzl", "FlutterIntegrationRunnerInfo")
load("//flutter/private:dbg_transition.bzl", "DBG_SETTINGS", "dbg_transition")

_ANDROID_PLATFORMS = str(Label("@rules_android//flags:android_platforms"))

def _android_dbg_transition_impl(_settings, attr):
    # Debug mode as everywhere, and the one ABI the device runs: the engine,
    # `libapp.so` and the native libraries are the ones the device loads, which
    # `AndroidDevice.buildArgs` sets the same flag for.
    return DBG_SETTINGS | {
        _ANDROID_PLATFORMS: [str(Label("@rules_android//:" + attr.abi))],
    }

# Exported for the test of what it does to a target built under it.
android_dbg_transition = transition(
    implementation = _android_dbg_transition_impl,
    inputs = [],
    outputs = DBG_SETTINGS.keys() + [_ANDROID_PLATFORMS],
)

_IOS_MULTI_CPUS = "//command_line_option:ios_multi_cpus"

def ios_simulator_dbg_settings(sim_cpu):
    """The configuration an iOS simulator test's app is built in.

    Debug mode, and the simulator CPU of this host: the simulator runs the
    architecture of the Mac it is on, which the dev tool's own build says the
    same way (`--ios_multi_cpus=sim_arm64`).

    Args:
        sim_cpu: `sim_arm64` or `x86_64`.

    Returns:
        The settings the transition sets.
    """
    return DBG_SETTINGS | {_IOS_MULTI_CPUS: [sim_cpu]}

def _ios_simulator_dbg_transition_impl(_settings, attr):
    return ios_simulator_dbg_settings(attr.sim_cpu)

ios_simulator_dbg_transition = transition(
    implementation = _ios_simulator_dbg_transition_impl,
    inputs = [],
    outputs = DBG_SETTINGS.keys() + [_IOS_MULTI_CPUS],
)

ANDROID = "android"
DESKTOP = "desktop"
IOS_SIMULATOR = "ios_simulator"
WEB = "web"

# What a runner of every family asks of the test's placement: the app runs on
# this machine, in this machine's session, so neither a remote executor nor
# Bazel's sandbox can host the test.
_EXECUTION_REQUIREMENTS = {
    "no-remote": "1",
    "no-sandbox": "1",
}

def _flutter_desktop_runner_impl(_ctx):
    return [FlutterIntegrationRunnerInfo(
        family = DESKTOP,
        launcher_config = struct(),
        runfiles = depset(),
        execution_requirements = dict(_EXECUTION_REQUIREMENTS),
        target_compatible_with = [],
    )]

flutter_desktop_runner = rule(
    implementation = _flutter_desktop_runner_impl,
    doc = """Runs a desktop integration test on the host's own desktop.

The test needs a desktop session. On macOS that is an unlocked screen and an
awake display; the runner checks both before it launches the app and fails,
saying which, when either is not so. It holds the display awake for the run
and takes a lock on the screen (`macos-gui`), because a window that is covered
stops producing frames, so two tests share the screen one after the other.""",
)

def _flutter_chrome_runner_impl(ctx):
    chrome = ctx.file.chrome
    return [DefaultInfo(files = depset([chrome])), FlutterIntegrationRunnerInfo(
        family = WEB,
        launcher_config = struct(chrome = runfiles_path(chrome, ctx.workspace_name)),
        # The browser and what it needs beside itself: `chrome` is the file to
        # run and its `data` the libraries and resources it loads.
        runfiles = depset([chrome], transitive = [ctx.attr.chrome[DefaultInfo].default_runfiles.files]),
        execution_requirements = dict(_EXECUTION_REQUIREMENTS),
        target_compatible_with = [],
    )]

flutter_chrome_runner = rule(
    implementation = _flutter_chrome_runner_impl,
    attrs = {
        "chrome": attr.label(
            doc = "The browser: a target whose one file is the executable, carrying the rest of the browser as `data` (the Chrome for Testing repositories' `chrome`).",
            mandatory = True,
            allow_single_file = True,
        ),
    },
    doc = """Runs a web integration test in a headless Chrome of the runner's own.

`chrome` is the executable the test launches, on a profile of its own that is
deleted when the test ends; the browser is the one the runner names rather than
one found on the host, so the page is drawn by the same browser everywhere the
test runs. The default runner, `@rules_flutter//flutter/integration_test:chrome`,
is a pinned Chrome for Testing headless shell for the host.""",
)

# The families whose app cannot be handed an environment, and what to call
# their devices.
_FAMILIES_WITHOUT_ENVIRONMENT = {
    ANDROID: "an Android device",
    IOS_SIMULATOR: "an iOS simulator",
}

def _flutter_android_device_runner_impl(ctx):
    adb = ctx.file.adb
    return [FlutterIntegrationRunnerInfo(
        family = ANDROID,
        launcher_config = struct(adb = runfiles_path(adb, ctx.workspace_name)),
        # `adb` is a link to the Android SDK's own, and the host tools beside it
        # that the test reads the APK with are found from where it leads.
        runfiles = depset([adb]),
        execution_requirements = dict(_EXECUTION_REQUIREMENTS),
        target_compatible_with = [],
    )]

flutter_android_device_runner = rule(
    implementation = _flutter_android_device_runner_impl,
    attrs = {
        "adb": attr.label(
            doc = "The `adb` of the Android SDK the app is built against, such as `@androidsdk//:adb`, the one rules_android resolves from `ANDROID_HOME`.",
            mandatory = True,
            allow_single_file = True,
        ),
    },
    doc = """Runs an Android integration test on an attached phone or a running emulator.

The device is the one `ANDROID_SERIAL` names (`--test_env=ANDROID_SERIAL=<serial>`),
else the only one attached; none, or several with none named, fails the test,
naming `adb devices`. The app is installed over `adb` from the SDK `adb` names,
started, and driven through the VM service forwarded from the device. It stays
installed afterwards, as `flutter test` leaves it. The test takes a lock on the
device (`android-<serial>`), so two tests on one device run one after the other
instead of installing over each other.

`adb` is the SDK's own, never one found on `PATH`.""",
)

def _flutter_ios_simulator_runner_impl(ctx):
    return [FlutterIntegrationRunnerInfo(
        family = IOS_SIMULATOR,
        launcher_config = struct(
            deviceType = ctx.attr.device_type,
            runtime = ctx.attr.runtime,
        ),
        runfiles = depset(),
        # What a simulator takes of the machine, so that Bazel schedules the test
        # with it. Measured: the processes under a booted simulator's launchd
        # used 15 CPU-seconds in the 20 seconds a test took, 0.75 of a core on
        # average; the services the simulator talks to on the host are not in
        # that, hence two.
        execution_requirements = dict(_EXECUTION_REQUIREMENTS) | {"cpu:%d" % ctx.attr.cpus: ""},
        target_compatible_with = [],
    )]

flutter_ios_simulator_runner = rule(
    implementation = _flutter_ios_simulator_runner_impl,
    attrs = {
        "device_type": attr.string(
            doc = "The simulator's device type, as `xcrun simctl list devicetypes` names it.",
            default = "iPhone 16",
        ),
        "runtime": attr.string(
            doc = "The simulator's runtime: an identifier or name `xcrun simctl list runtimes` lists. Empty is the newest installed runtime that suits the device type.",
        ),
        "cpus": attr.int(
            doc = "The cores a test on this runner is scheduled with.",
            default = 2,
        ),
    },
    doc = """Runs an iOS integration test on a simulator the test makes for itself.

Each test makes a simulator (`rules_flutter-<test>-<pid>`) of `device_type`,
boots it, installs the app, drives the suite through the app's VM service, and
shuts the simulator down and deletes it however the test ends, a Bazel timeout
included. A fresh simulator shares no state with another test or with the
simulators of the person running it, so tests need no lock. No runtime installed
fails the test, saying `xcodebuild -downloadPlatform iOS`.""",
)

def integration_test_impl(ctx, family, inherited_environment = []):
    """The implementation every integration test rule shares.

    Args:
        ctx: The rule context: `app`, `runner`, `env`, `data` and `_runner`.
        family: The family of device this rule runs the app on.
        inherited_environment: What the test takes from the invoking shell.

    Returns:
        The rule's providers.
    """
    if family in _FAMILIES_WITHOUT_ENVIRONMENT and ctx.attr.env:
        fail((
            "%s: `env` is %s, but an app on %s cannot receive an environment: " +
            "the app starts as the device starts apps. Pass what the app " +
            "should see as `defines` of the program (`flutter_application_variant`) instead."
        ) % (ctx.label, ctx.attr.env, _FAMILIES_WITHOUT_ENVIRONMENT[family]))

    runner = ctx.attr.runner[FlutterIntegrationRunnerInfo]
    if runner.family != family:
        fail((
            "%s: `runner` %s is for %s devices, and this rule runs the app on a " +
            "%s one. Use a runner of the family the rule is for."
        ) % (ctx.label, ctx.attr.runner.label, runner.family, family))

    # A list: the attribute has a transition, which makes its value one.
    app = ctx.attr.app[0]
    app_files = app[DefaultInfo].files.to_list()
    if not app_files:
        fail("%s: `app` %s builds no files, so there is nothing to launch." % (ctx.label, app.label))

    workspace = ctx.workspace_name
    config = ctx.actions.declare_file(ctx.label.name + ".integration_config.json")
    ctx.actions.write(config, json.encode({
        "family": family,
        "appArtifacts": [runfiles_path(f, workspace) for f in app_files],
        "launcher": runner.launcher_config,
        "testDisplayName": str(ctx.label),
        "env": ctx.attr.env,
    }))

    tool = ctx.attr._runner
    executable = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.symlink(
        output = executable,
        target_file = tool[DefaultInfo].files_to_run.executable,
        is_executable = True,
    )

    runfiles = ctx.runfiles(
        files = [config] + app_files + ctx.files.data,
        transitive_files = runner.runfiles,
    ).merge(tool[DefaultInfo].default_runfiles).merge(app[DefaultInfo].default_runfiles)
    for data in ctx.attr.data:
        runfiles = runfiles.merge(data[DefaultInfo].default_runfiles)

    return [
        DefaultInfo(executable = executable, runfiles = runfiles),
        RunEnvironmentInfo(
            environment = ctx.attr.env | {
                "FLUTTER_INTEGRATION_TEST_CONFIG": runfiles_path(config, workspace),
            },
            inherited_environment = inherited_environment,
        ),
        testing.ExecutionInfo(runner.execution_requirements),
    ]

# The attributes every integration test rule has, whatever its family.
#
# `default_runner` is the runner a test is given when it names none, and None
# for a family that has no runner of its own to default to. `cfg` is the
# transition the app is built under.
def _test_attrs(default_runner, cfg = dbg_transition):
    return {
        "app": attr.label(
            doc = "The app the test runs, built in debug mode whatever the command line says: the suite is driven through the VM service a debug build serves, as `flutter test` forces debug for an integration test.",
            mandatory = True,
            cfg = cfg,
        ),
        "runner": attr.label(
            doc = "Where the app runs.",
            default = Label(default_runner) if default_runner else None,
            mandatory = not default_runner,
            providers = [FlutterIntegrationRunnerInfo],
        ),
        "env": attr.string_dict(
            doc = "Environment variables for the host runner and, on desktop, for the app's process.",
        ),
        "data": attr.label_list(
            doc = "Files the test reads at run time.",
            allow_files = True,
        ),
        "_runner": attr.label(
            default = Label("//tools/dev_tool:integration_test_runner"),
            executable = True,
            cfg = "target",
        ),
    }

def _flutter_desktop_integration_test_impl(ctx):
    return integration_test_impl(ctx, DESKTOP)

flutter_desktop_integration_test = rule(
    implementation = _flutter_desktop_integration_test_impl,
    attrs = _test_attrs("//flutter/integration_test:desktop"),
    test = True,
    doc = """Runs the desktop app `app` (`flutter_macos_app`) on the host and reports the integration test suite it runs.

The app's program is an integration test (see `flutter_integration_bootstrap`),
so each `testWidgets` is a test case: `--test_filter` and `shard_count` select
among them, each is reported as it finishes, and the JUnit file names each. A
suite that registers no test fails, as does an app that exits during a test, with
the reason the device gives for its exit.

The test is built in debug mode, runs outside Bazel's sandbox and never remotely.
A macOS app needs an unlocked, awake desktop session.""",
)

def _flutter_web_bundle_integration_test_impl(ctx):
    return integration_test_impl(ctx, WEB)

flutter_web_bundle_integration_test = rule(
    implementation = _flutter_web_bundle_integration_test_impl,
    attrs = _test_attrs("//flutter/integration_test:chrome"),
    test = True,
    doc = """Runs the web bundle `app` (`flutter_web_app` or `flutter_web_bundle`) in the runner's headless Chrome and reports the integration test suite it runs.

The bundle's program is an integration test (see `flutter_integration_bootstrap`),
so each `testWidgets` is a test case: `--test_filter` and `shard_count` select
among them, each is reported as it finishes, and the JUnit file names each. The
suite is driven over the browser's DevTools protocol, which is what a web bundle
has in place of a VM service. A suite that registers no test fails, as does a
page that is lost during a test, with the reason the browser gives.

The test is built in debug mode, runs outside Bazel's sandbox and never remotely.
The bundle is served from a directory of its own on the loopback, and the
browser's profile is deleted when the test ends.""",
)

def _flutter_android_app_integration_test_impl(ctx):
    return integration_test_impl(ctx, ANDROID, inherited_environment = ["ANDROID_SERIAL"])

flutter_android_app_integration_test = rule(
    implementation = _flutter_android_app_integration_test_impl,
    attrs = _test_attrs(None, cfg = android_dbg_transition) | {
        "abi": attr.string(
            doc = "The ABI the app is built for, which the device must run: the platform of `--@rules_android//flags:android_platforms` the app is built under, whatever the command line says.",
            default = "arm64-v8a",
            values = ["arm64-v8a", "x86_64"],
        ),
    },
    test = True,
    doc = """Runs the Android app `app` (`flutter_android_app`) on a device and reports the integration test suite it runs.

The app's program is an integration test (see `flutter_integration_bootstrap`),
so each `testWidgets` is a test case: `--test_filter` and `shard_count` select
among them, each is reported as it finishes, and the JUnit file names each. A
suite that registers no test fails, as does an app that exits during a test, with
the reason the device gives for its exit.

The app is built in debug mode for `abi`, whatever the command line says, and the
test runs outside Bazel's sandbox and never remotely. An app on a device cannot be
handed an environment, so a non-empty `env` fails analysis; its `defines` are the
program's.

An integration test's app links `integration_test`'s Android library, which needs
`androidx.test:runner`, `androidx.test:rules`, `androidx.test.espresso:espresso-core`
and `com.google.guava:guava` in the workspace's `@rules_android_maven` install:
analysis says which are missing.""",
)

def _flutter_ios_app_integration_test_impl(ctx):
    return integration_test_impl(ctx, IOS_SIMULATOR, inherited_environment = ["DEVELOPER_DIR"])

flutter_ios_app_integration_test = rule(
    implementation = _flutter_ios_app_integration_test_impl,
    attrs = _test_attrs("//flutter/integration_test:ios_simulator", cfg = ios_simulator_dbg_transition) | {
        "sim_cpu": attr.string(
            doc = "The CPU the app is built for, which the simulator runs: `sim_arm64` on an Apple-silicon Mac, `x86_64` on an Intel one.",
            default = "sim_arm64",
            values = ["sim_arm64", "x86_64"],
        ),
    },
    test = True,
    doc = """Runs the iOS app `app` (`flutter_ios_app`) on a simulator made for the test and reports the integration test suite it runs.

The app's program is an integration test (see `flutter_integration_bootstrap`),
so each `testWidgets` is a test case: `--test_filter` and `shard_count` select
among them, each is reported as it finishes, and the JUnit file names each. A
suite that registers no test fails, as does an app that exits during a test, with
the reason the device gives for its exit.

The app is built in debug mode for `sim_cpu`, whatever the command line says, and
the test runs outside Bazel's sandbox and never remotely. An app on a simulator
cannot be handed an environment, so a non-empty `env` fails analysis; its
`defines` are the program's.""",
)
