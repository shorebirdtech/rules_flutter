"""Analysis tests for what a `flutter_test`'s runfiles hold.

A test's runfiles are staged for every run, remote ones included, so they have
to be what the run opens and no more. The runner is a compiled executable that
starts `flutter_tester` on a kernel; nothing in a run reads the Dart SDK or the
patched SDK, which are the compile's tools. They are about a thousand files and
700 MB.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//flutter:providers.bzl", "FlutterTestProgramInfo")

_WHOLE_PROGRAM = {str(Label("@rules_dart//dart:modular_kernel")): False}
_KERNEL_LISTS_OFF = {str(Label("@rules_dart//dart:kernel_lists")): False}
_KERNEL_LISTS_ON = {str(Label("@rules_dart//dart:kernel_lists")): True}

# Directories of the SDK repository whose files only a compile opens.
_COMPILE_ONLY = ["/dart-sdk/", "/patched-sdk/"]

def _runfile_paths(target):
    return sorted([f.short_path for f in target[DefaultInfo].default_runfiles.files.to_list()])

def _holds_only_what_a_run_opens_impl(ctx):
    env = analysistest.begin(ctx)
    paths = _runfile_paths(analysistest.target_under_test(env))

    # The runfiles are the test's own, not an empty set that trivially passes.
    asserts.true(env, any([p.endswith(".dill") for p in paths]), "no kernel in the runfiles: %s" % paths[:5])
    asserts.true(env, any([p.rsplit("/", 1)[-1].startswith("flutter_tester") for p in paths]), "no flutter_tester in the runfiles")

    compile_only = [p for p in paths if any([d in "/" + p for d in _COMPILE_ONLY])]
    asserts.equals(
        env,
        [],
        compile_only[:5],
        "%d runfiles belong to the SDK a compile uses and a run never opens; first five" % len(compile_only),
    )
    return analysistest.end(env)

_holds_only_what_a_run_opens_test = analysistest.make(_holds_only_what_a_run_opens_impl)
_holds_only_what_a_run_opens_whole_program_test = analysistest.make(
    _holds_only_what_a_run_opens_impl,
    config_settings = _WHOLE_PROGRAM,
)

def _dills(target):
    return [p for p in _runfile_paths(target) if p.endswith(".dill")]

def _link_args(env):
    links = [a for a in analysistest.target_actions(env) if a.mnemonic == "DartLinkKernel"]
    return links[0].argv if links else []

def _runs_a_kernel_list_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    argv = _link_args(env)

    # The link writes a list; it joins nothing.
    asserts.true(env, "--list-short-path" in argv, "the link action does not write a kernel list: %s" % argv)
    asserts.false(env, "--entry" in argv, "the link action joins the kernels")

    # The list is in the runfiles with the kernels it names, the test's entry
    # among them.
    dills = _dills(target)
    asserts.true(env, any([p.endswith(".entry.dill") for p in dills]), "no entry kernel in the runfiles: %s" % dills)
    asserts.true(env, target[FlutterTestProgramInfo].kernel_list, "the program is not described as a list")
    return analysistest.end(env)

def _runs_a_joined_kernel_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    argv = _link_args(env)
    asserts.true(env, "--entry" in argv, "the link action does not join the kernels: %s" % argv)
    asserts.false(env, "--list-short-path" in argv, "the link action writes a kernel list")
    asserts.equals(env, 1, len(_dills(target)), "the runfiles hold more than the joined kernel: %s" % _dills(target))
    asserts.false(env, target[FlutterTestProgramInfo].kernel_list, "the program is described as a list")
    return analysistest.end(env)

_runs_a_kernel_list_test = analysistest.make(
    _runs_a_kernel_list_impl,
    config_settings = _KERNEL_LISTS_ON,
)
_runs_a_joined_kernel_test = analysistest.make(
    _runs_a_joined_kernel_impl,
    config_settings = _KERNEL_LISTS_OFF,
)

def flutter_test_runfiles_test_suite(name):
    """Declares the runfiles tests of `flutter_test` and `flutter_tester_binary`.

    Args:
        name: The name of the suite.
    """
    targets = {
        "flutter_test": "//flutter/tests/code_asset_fixture/test:wrapped_code_asset_test",
        "tester_binary": "//flutter/tests/tester_binary_fixture:tester_binary",
    }
    tests = []
    for kind, target in targets.items():
        for mode, rule in [
            ("modular", _holds_only_what_a_run_opens_test),
            ("whole_program", _holds_only_what_a_run_opens_whole_program_test),
        ]:
            test = "%s_%s_runfiles_hold_only_what_a_run_opens" % (kind, mode)
            rule(
                name = test,
                target_under_test = target,
                target_compatible_with = ["@platforms//os:macos"],
            )
            tests.append(test)
        for mode, rule in [
            ("kernel_list", _runs_a_kernel_list_test),
            ("joined_kernel", _runs_a_joined_kernel_test),
        ]:
            test = "%s_%s" % (kind, mode)
            rule(
                name = test,
                # The link is the program's.
                target_under_test = target + ".program" if kind == "flutter_test" else target,
                target_compatible_with = ["@platforms//os:macos"],
            )
            tests.append(test)
    native.test_suite(name = name, tests = tests)
