"""Every gen_snapshot option a target declares reaches gen_snapshot.

`obfuscate`, `split_debug_info` and `extra_gen_snapshot_options` are attributes
of both `flutter_application` and `flutter_aot_target`. A user who sets one has
asked for something specific of the snapshot; an attribute a rule declares and
does not act on gives the user a build that is not the one they asked for, with
no error. These tests read the gen_snapshot action each rule declares, for each
attribute, in each `-c` that builds Flutter's release mode.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//flutter:providers.bzl", "FlutterApplicationInfo")
load("//flutter/private:flutter_aot_target.bzl", "flutter_aot_target")
load("//flutter/private:flutter_application.bzl", "flutter_application")

_PACKAGE = "aot_options_fixture"
_MAIN = "lib/language_version_main.dart"

# A flag gen_snapshot never defined: analysis does not run it, and the test
# only asks that it is passed on.
_EXTRA_FLAG = "--rules_flutter_option_probe"

# gen_snapshot flags that write the file their value names.
_FILE_WRITING_FLAGS = [
    "--save-obfuscation-map",
    "--write-v8-snapshot-profile-to",
]

def _gen_snapshot(env):
    actions = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic in ("FlutterAotMacho", "FlutterAotElf")
    ]
    asserts.equals(env, 1, len(actions), "expected exactly one gen_snapshot action")
    return actions[0] if actions else None

def _impl(ctx):
    env = analysistest.begin(ctx)
    action = _gen_snapshot(env)
    if action == None:
        return analysistest.end(env)
    argv = action.argv
    what = ctx.attr.option
    if what == "obfuscate":
        asserts.true(
            env,
            "--obfuscate" in argv,
            "obfuscate = True should run gen_snapshot with --obfuscate: %s" % argv,
        )
    elif what == "split_debug_info":
        saved = [a for a in argv if a.startswith("--save-debugging-info=")]
        asserts.equals(
            env,
            1,
            len(saved),
            "split_debug_info = True should save the debugging info: %s" % argv,
        )
        outputs = [o.basename for o in action.outputs.to_list()]
        asserts.true(
            env,
            len([o for o in outputs if o.endswith(".symbols")]) == 1,
            "the saved debugging info should be a declared output: %s" % outputs,
        )
    elif what == "extra_gen_snapshot_options":
        asserts.true(
            env,
            _EXTRA_FLAG in argv,
            "extra_gen_snapshot_options should reach gen_snapshot: %s" % argv,
        )
    elif what == "no_strip":
        # flutter_tools reads `--no-strip` itself: it decides whether the
        # snapshot is stripped and does not hand the flag to gen_snapshot.
        # Here a rule that was told not to strip must not ask gen_snapshot to
        # (`--strip`, which `opt` otherwise adds for an ELF snapshot), and
        # says so in its provider so a later strip step can follow.
        asserts.false(
            env,
            "--strip" in argv,
            "--no-strip should leave gen_snapshot unasked to strip: %s" % argv,
        )
        asserts.false(
            env,
            "--no-strip" in argv,
            "--no-strip is the rule's to read, not gen_snapshot's: %s" % argv,
        )
        target = analysistest.target_under_test(env)
        if FlutterApplicationInfo in target:
            asserts.false(
                env,
                target[FlutterApplicationInfo].strip_aot,
                "FlutterApplicationInfo.strip_aot should be False after --no-strip",
            )
    elif what == "file_writing_flags":
        # A flag that makes gen_snapshot write a file names a path. The action
        # keeps only its declared outputs, so a path that is not one is a file
        # the user asked for and never gets.
        declared = [o.basename for o in action.outputs.to_list()]
        for flag in _FILE_WRITING_FLAGS:
            for arg in [a for a in argv if a.startswith(flag + "=")]:
                path = arg[len(flag) + 1:]
                asserts.true(
                    env,
                    path.split("/")[-1] in declared,
                    "%s writes %s, which is not an output the rule declares (%s)" % (flag, path, declared),
                )
    else:
        fail("unknown option " + what)
    return analysistest.end(env)

_OPTION = {"option": attr.string(mandatory = True)}

_fastbuild_test = analysistest.make(
    _impl,
    attrs = _OPTION,
    config_settings = {"//command_line_option:compilation_mode": "fastbuild"},
)
_opt_test = analysistest.make(
    _impl,
    attrs = _OPTION,
    config_settings = {"//command_line_option:compilation_mode": "opt"},
)

_OPTIONS = {
    "extra_gen_snapshot_options": [_EXTRA_FLAG],
    "obfuscate": True,
    "split_debug_info": True,
}

_RULES = {
    "aot_target": flutter_aot_target,
    "application": flutter_application,
}

def _instantiate(name, rules, fixtures, option):
    tests = []
    for rule_name in rules:
        for suffix, attrs in fixtures.items():
            fixture = "_%s_%s" % (rule_name, suffix)
            _RULES[rule_name](
                name = fixture,
                package_name = _PACKAGE,
                main = _MAIN,
                tags = ["manual"],
                **attrs
            )
            for mode, test in [("fastbuild", _fastbuild_test), ("opt", _opt_test)]:
                test_name = "%s%s_%s_test" % (name, fixture, mode)
                test(name = test_name, target_under_test = ":" + fixture, option = option or suffix)
                tests.append(":" + test_name)
    native.test_suite(name = name, tests = tests)

def aot_options_test_suite(name, rules):
    """A fixture per rule and option, and a test per `-c` that builds release.

    Args:
        name: The test_suite name.
        rules: Which of "application" and "aot_target" to test.
    """
    _instantiate(
        name,
        rules,
        {option: {option: value} for option, value in _OPTIONS.items()},
        None,
    )

def aot_no_strip_test_suite(name, rules):
    """A fixture per rule with `--no-strip`, and a test per `-c`.

    Args:
        name: The test_suite name.
        rules: Which of "application" and "aot_target" to test.
    """
    _instantiate(
        name,
        rules,
        {"no_strip": {"extra_gen_snapshot_options": ["--no-strip"]}},
        "no_strip",
    )

def aot_file_flags_test_suite(name, rules):
    """A fixture per rule and file-writing flag, and a test per `-c`.

    Args:
        name: The test_suite name.
        rules: Which of "application" and "aot_target" to test.
    """
    _instantiate(
        name,
        rules,
        {
            flag.lstrip("-").replace("-", "_"): {"extra_gen_snapshot_options": ["%s=out.json" % flag]}
            for flag in _FILE_WRITING_FLAGS
        },
        "file_writing_flags",
    )

def _resolve_dwarf_paths_refused_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "cannot hold `--resolve-dwarf-paths`")
    return analysistest.end(env)

_resolve_dwarf_paths_refused_test = analysistest.make(
    _resolve_dwarf_paths_refused_impl,
    expect_failure = True,
    config_settings = {"//command_line_option:compilation_mode": "opt"},
)

def aot_resolve_dwarf_paths_test_suite(name, rules):
    """A fixture per rule and spelling of `--resolve-dwarf-paths`, each refused.

    gen_snapshot converts only `file:` URIs into DWARF paths, and the kernel
    names its sources by workspace-relative URIs, so the flag would abort the
    snapshot; the rule says why at analysis instead.

    Args:
        name: The test_suite name.
        rules: Which of "application" and "aot_target" to test.
    """
    tests = []
    for rule_name in rules:
        for suffix, flag in [("dashes", "--resolve-dwarf-paths"), ("underscores", "--resolve_dwarf_paths")]:
            fixture = "_%s_resolve_dwarf_paths_%s" % (rule_name, suffix)
            _RULES[rule_name](
                name = fixture,
                package_name = _PACKAGE,
                main = _MAIN,
                extra_gen_snapshot_options = [flag],
                tags = ["manual"],
            )
            test_name = "%s%s_test" % (name, fixture)
            _resolve_dwarf_paths_refused_test(name = test_name, target_under_test = ":" + fixture)
            tests.append(":" + test_name)
    native.test_suite(name = name, tests = tests)
