"""`outcome_test`: a test that must fail, or run only some of its cases, as a passing target."""

load("@rules_dart//dart:utils.bzl", "runfiles_path")

def _test_outcome_impl(ctx):
    wrapped = ctx.attr.test
    wrapped_exe = wrapped[DefaultInfo].files_to_run.executable
    workspace = ctx.workspace_name

    config = ctx.actions.declare_file(ctx.label.name + ".outcome.json")
    ctx.actions.write(config, json.encode({
        "executable": runfiles_path(wrapped_exe, workspace),
        "env": wrapped[RunEnvironmentInfo].environment,
        "expect": ctx.attr.expect,
        "testFilter": ctx.attr.test_filter if ctx.attr.test_filter else None,
        "cases": ctx.attr.cases if ctx.attr.cases else None,
        "failingCases": ctx.attr.failing_cases if ctx.attr.failing_cases_given else None,
        "outputContains": ctx.attr.output_contains,
    }))

    executable = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.symlink(
        output = executable,
        target_file = ctx.executable._outcome_runner,
        is_executable = True,
    )
    runfiles = ctx.runfiles(files = [config]).merge(
        ctx.attr._outcome_runner[DefaultInfo].default_runfiles,
    ).merge(wrapped[DefaultInfo].default_runfiles)
    return [
        DefaultInfo(executable = executable, runfiles = runfiles),
        RunEnvironmentInfo(
            environment = {"TEST_OUTCOME_CONFIG": runfiles_path(config, workspace)},
            inherited_environment = wrapped[RunEnvironmentInfo].inherited_environment,
        ),
        # The wrapped test's own placement: it runs here, in this machine's session.
        testing.ExecutionInfo(wrapped[testing.ExecutionInfo].requirements),
    ]

outcome_test = rule(
    implementation = _test_outcome_impl,
    attrs = {
        "test": attr.label(
            doc = "The test to run. It is `manual`, since it is not meant to pass on its own.",
            mandatory = True,
            providers = [RunEnvironmentInfo],
        ),
        "expect": attr.string(
            doc = "How the test must end: `pass` or `fail`.",
            mandatory = True,
            values = ["pass", "fail"],
        ),
        "test_filter": attr.string(
            doc = "A `--test_filter` to run the test with.",
        ),
        "cases": attr.string_list(
            doc = "The names of the cases its report must hold, in order. Unchecked when empty.",
        ),
        "failing_cases": attr.string_list(
            doc = "The names of the cases of its report that must have failed. Checked only with `failing_cases_given`.",
        ),
        "failing_cases_given": attr.bool(
            doc = "Whether `failing_cases` is checked, so that an empty list can say that no case may fail.",
        ),
        "output_contains": attr.string_list(
            doc = "Text its output must contain.",
        ),
        "_outcome_runner": attr.label(
            default = Label("//:test_outcome_runner"),
            executable = True,
            cfg = "target",
        ),
    },
    test = True,
    doc = """Runs `test` with its own environment and passes when it ends as `expect` says.

A test that must fail (a red twin of a passing test) is the case for it: the
wrapped test is `manual` only because it is meant to fail, the wrapper is the
target that runs, and it passes exactly when the failure happens and is the
failure that was expected: the failing case is named in the JUnit report with
a `<failure>`, and the output says why. A target that passed whatever the test
did would be hiding a gap, so each check is stated by the target.""",
)
