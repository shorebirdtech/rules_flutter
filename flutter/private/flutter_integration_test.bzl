"""The integration test rules and the runner rules that say where they run.

One test rule per family of device, sharing one implementation: the build
flags that put the app on a device (an Android ABI, a simulator CPU) must come
from the test rule itself, and a transition reads attributes but not providers,
so they cannot come from the runner. The runner rule of a family says which
device of the family, and the test rule refuses a runner of another.
"""

load("@rules_dart//dart:utils.bzl", "runfiles_path")
load("//flutter:providers.bzl", "FlutterIntegrationRunnerInfo")
load("//flutter/private:dbg_transition.bzl", "dbg_transition")

DESKTOP = "desktop"

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

def integration_test_impl(ctx, family, inherited_environment = []):
    """The implementation every integration test rule shares.

    Args:
        ctx: The rule context: `app`, `runner`, `env`, `data` and `_runner`.
        family: The family of device this rule runs the app on.
        inherited_environment: What the test takes from the invoking shell.

    Returns:
        The rule's providers.
    """
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
def _test_attrs(default_runner):
    return {
        "app": attr.label(
            doc = "The app the test runs, built in debug mode whatever the command line says: the suite is driven through the VM service a debug build serves, as `flutter test` forces debug for an integration test.",
            mandatory = True,
            cfg = dbg_transition,
        ),
        "runner": attr.label(
            doc = "Where the app runs.",
            default = Label(default_runner),
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
