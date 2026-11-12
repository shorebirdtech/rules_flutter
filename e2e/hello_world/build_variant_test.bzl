"""Runs a `flutter_test` under every combination of compilation mode and kernel mode."""

_COMPILATION_MODE = "//command_line_option:compilation_mode"
_MODULAR_KERNEL = "@rules_dart//dart:modular_kernel"

def _variant_transition_impl(_settings, attr):
    return {
        _COMPILATION_MODE: attr.compilation_mode,
        _MODULAR_KERNEL: attr.modular,
    }

_variant_transition = transition(
    implementation = _variant_transition_impl,
    inputs = [],
    outputs = [_COMPILATION_MODE, _MODULAR_KERNEL],
)

def _build_variant_test_impl(ctx):
    test = ctx.attr.test[0]
    target = test[DefaultInfo].files_to_run.executable

    # The target's extension too: Windows starts only a `.exe` (or `.bat`).
    executable = ctx.actions.declare_file(ctx.label.name + ("." + target.extension if target.extension else ""))
    ctx.actions.symlink(
        output = executable,
        target_file = target,
        is_executable = True,
    )
    return [
        DefaultInfo(
            executable = executable,
            runfiles = ctx.runfiles(files = [executable]).merge(test[DefaultInfo].default_runfiles),
        ),
        test[RunEnvironmentInfo],
    ]

build_variant_test = rule(
    implementation = _build_variant_test_impl,
    test = True,
    doc = "Runs `test` built with the given compilation mode and kernel mode.",
    attrs = {
        "compilation_mode": attr.string(
            mandatory = True,
            values = ["fastbuild", "dbg", "opt"],
            doc = "The `-c` mode to build `test` in.",
        ),
        "modular": attr.bool(
            mandatory = True,
            doc = "`--@rules_dart//dart:modular_kernel`: per-library kernel modules (True) or one whole-program compile (False).",
        ),
        "test": attr.label(
            cfg = _variant_transition,
            executable = True,
            mandatory = True,
            doc = "The `flutter_test` to run.",
        ),
    },
)

def build_variant_tests(name, test):
    """Declares the builds of `test` that it has to behave the same in, and a suite over all four.

    `test` is a `flutter_test` in the default configuration (per-library
    kernel modules, fastbuild). Beside it this declares `<test>_dbg`,
    `<test>_whole_program` and `<test>_dbg_whole_program`, named after `test`'s
    own target.

    Args:
        name: The name of a `test_suite` over `test` and its variants.
        test: Label of the `flutter_test`, in this package.
    """
    test_name = test.removeprefix(":")
    tests = [test]
    for suffix, mode, modular in [
        ("_dbg", "dbg", True),
        ("_whole_program", "fastbuild", False),
        ("_dbg_whole_program", "dbg", False),
    ]:
        build_variant_test(
            name = test_name + suffix,
            compilation_mode = mode,
            modular = modular,
            test = test,
        )
        tests.append(":" + test_name + suffix)
    native.test_suite(name = name, tests = tests)
