"""Analysis tests for `flutter_program_test` running a program it did not compile.

A third-party rule that compiles a test provides `FlutterTestProgramInfo`, and
`flutter_program_test` runs it with the runner's whole contract: the paths it
reads from the environment, `@Tags` selection, the kernel list, and the
coverage and source variables.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//flutter:defs.bzl", "flutter_program_test")
load("//flutter:providers.bzl", "FlutterTestProgramInfo")

def _fake_program_impl(ctx):
    files = ctx.files.srcs
    kernel = ctx.actions.declare_file(ctx.label.name + ".dill")
    ctx.actions.write(kernel, "")
    assets = ctx.actions.declare_directory(ctx.label.name + "_assets")
    ctx.actions.run_shell(outputs = [assets], command = "true")
    tester = ctx.actions.declare_file(ctx.label.name + "_tester")
    ctx.actions.write(tester, "")
    icu = ctx.actions.declare_file(ctx.label.name + "_icu")
    ctx.actions.write(icu, "")
    source = files[0]
    return [
        DefaultInfo(files = depset([kernel])),
        FlutterTestProgramInfo(
            kernel = kernel,
            kernel_list = ctx.attr.kernel_list,
            kernels = depset(),
            assets = assets,
            tester = tester,
            icu_data = icu,
            display_path = "pkg/fake_suite.dart",
            source = source,
            coverage_libraries = ["package:fake/", "org-dartlang-root:///pkg/fake_suite.dart"],
            native_assets_manifest = None,
            native_files = ctx.attr.native_files,
            enable_impeller = ctx.attr.impeller,
            target_os = "linux",
            runfiles = ctx.runfiles(files = [kernel, assets, tester, icu, source]),
        ),
    ]

_fake_program = rule(
    implementation = _fake_program_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = True),
        "kernel_list": attr.bool(),
        "impeller": attr.bool(),
        "native_files": attr.string_list(),
    },
)

def _environment(env):
    return analysistest.target_under_test(env)[RunEnvironmentInfo].environment

def _runs_the_program_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    environment = _environment(env)
    for key, suffix in [
        ("FLUTTER_TEST_DILL", "/_fake_program.dill"),
        ("FLUTTER_TEST_ASSETS", "/_fake_program_assets"),
        ("FLUTTER_TEST_TESTER", "/_fake_program_tester"),
        ("FLUTTER_TEST_ICU", "/_fake_program_icu"),
        ("FLUTTER_TEST_SOURCE", "/flutter/tests/fake_suite.dart"),
    ]:
        asserts.true(env, environment.get(key, "").endswith(suffix), "%s is %s" % (key, environment.get(key)))
    asserts.equals(env, "pkg/fake_suite.dart", environment["FLUTTER_TEST_PATH"])
    asserts.equals(env, "", environment["FLUTTER_TEST_IMPELLER"])
    asserts.equals(env, "package:fake/\norg-dartlang-root:///pkg/fake_suite.dart", environment["FLUTTER_TEST_COVERAGE_LIBRARIES"])
    asserts.equals(env, "wip", environment["FLUTTER_TEST_EXCLUDE_TAGS"])
    asserts.equals(env, "from_target", environment["EXTRA"])
    asserts.false(env, "FLUTTER_TEST_KERNEL_LIST" in environment)
    asserts.false(env, "FLUTTER_TEST_NATIVE_FILES" in environment)

    # The program's files travel with the test.
    paths = [f.short_path for f in target[DefaultInfo].default_runfiles.files.to_list()]
    asserts.true(env, any([p.endswith("_fake_program.dill") for p in paths]), "no kernel in runfiles: %s" % paths)
    asserts.true(env, any([p.endswith("flutter_test_runner") or "flutter_test_runner" in p for p in paths]), "no runner in runfiles")
    return analysistest.end(env)

_runs_the_program_test = analysistest.make(_runs_the_program_impl)

def _describes_a_list_impl(ctx):
    env = analysistest.begin(ctx)
    environment = _environment(env)
    asserts.equals(env, "1", environment["FLUTTER_TEST_KERNEL_LIST"])
    asserts.equals(env, "1", environment["FLUTTER_TEST_IMPELLER"])
    asserts.equals(env, "pkg/a.so\npkg/b.so", environment["FLUTTER_TEST_NATIVE_FILES"])
    return analysistest.end(env)

_describes_a_list_test = analysistest.make(_describes_a_list_impl)

def _refuses_its_own_keys_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "env key FLUTTER_TEST_PATH is set by the rule itself")
    return analysistest.end(env)

_refuses_its_own_keys_test = analysistest.make(_refuses_its_own_keys_impl, expect_failure = True)

def flutter_program_test_test_suite(name):
    """Declares the tests of `flutter_program_test` over a program of another rule.

    Args:
        name: The name of the suite.
    """
    _fake_program(
        name = "_fake_program",
        srcs = ["fake_suite.dart"],
        tags = ["manual"],
        testonly = True,
    )
    _fake_program(
        name = "_fake_list_program",
        srcs = ["fake_suite.dart"],
        impeller = True,
        kernel_list = True,
        native_files = ["pkg/a.so", "pkg/b.so"],
        tags = ["manual"],
        testonly = True,
    )
    flutter_program_test(
        name = "_runs_fake",
        env = {"EXTRA": "from_target"},
        exclude_tags = ["wip"],
        program = ":_fake_program",
        tags = ["manual"],
    )
    flutter_program_test(
        name = "_runs_fake_list",
        program = ":_fake_list_program",
        tags = ["manual"],
    )
    flutter_program_test(
        name = "_overrides_key",
        env = {"FLUTTER_TEST_PATH": "x"},
        program = ":_fake_program",
        tags = ["manual"],
    )
    _runs_the_program_test(name = name + "_runs_the_program", target_under_test = ":_runs_fake")
    _describes_a_list_test(name = name + "_describes_a_list", target_under_test = ":_runs_fake_list")
    _refuses_its_own_keys_test(name = name + "_refuses_its_own_keys", target_under_test = ":_overrides_key")
    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_runs_the_program",
            ":" + name + "_describes_a_list",
            ":" + name + "_refuses_its_own_keys",
        ],
    )
