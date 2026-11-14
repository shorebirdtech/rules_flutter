"""Tests that flutter_android_build keeps the configuration it is given when the
platforms it asks for are already the ones `--@rules_android//flags:android_platforms` names.

The flag holds strings, so `@rules_android//:arm64-v8a` (as a command line or
.bazelrc spells it) and `@@rules_android+//:arm64-v8a` are two configurations
of one ABI. A target built both through the rule and outside it would be built
twice if the rule rewrote one spelling into the other.

Each test builds one file twice from the incoming configuration: through
`flutter_android_build` and directly. Their output roots are the same exactly
when the rule left the configuration alone.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//flutter/private:flutter_android_build.bzl", "flutter_android_build")

_PLATFORMS_FLAG = str(Label("@rules_android//flags:android_platforms"))

_RootsInfo = provider(
    doc = "The output roots of the file built through the rule and directly.",
    fields = ["through_rule", "direct"],
)

def _probe_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".txt")
    ctx.actions.write(out, "")
    return [DefaultInfo(files = depset([out]))]

_probe = rule(implementation = _probe_impl)

def _roots_impl(ctx):
    def root(target):
        files = target[DefaultInfo].files.to_list()
        if len(files) != 1:
            fail("expected one file from %s, got %s" % (target.label, files))
        return files[0].root.path

    return [_RootsInfo(through_rule = root(ctx.attr.through_rule), direct = root(ctx.attr.direct))]

_roots = rule(
    implementation = _roots_impl,
    attrs = {
        "direct": attr.label(mandatory = True),
        "through_rule": attr.label(mandatory = True),
    },
)

def _same_root_impl(ctx):
    env = analysistest.begin(ctx)
    roots = analysistest.target_under_test(env)[_RootsInfo]
    asserts.equals(
        env,
        roots.direct,
        roots.through_rule,
        "flutter_android_build should keep a configuration that already names its platforms",
    )
    return analysistest.end(env)

def _other_root_impl(ctx):
    env = analysistest.begin(ctx)
    roots = analysistest.target_under_test(env)[_RootsInfo]
    asserts.true(
        env,
        roots.direct != roots.through_rule,
        "flutter_android_build should change a configuration that names other platforms: %s" % roots.direct,
    )
    return analysistest.end(env)

def _incoming(*platforms):
    return {_PLATFORMS_FLAG: list(platforms)}

# A command line's spelling, through the root module's name for rules_android.
_apparent_test = analysistest.make(
    _same_root_impl,
    config_settings = _incoming("@rules_android//:arm64-v8a"),
)

# The canonical spelling, as `str(Label)` writes it.
_canonical_test = analysistest.make(
    _same_root_impl,
    config_settings = _incoming(str(Label("@rules_android//:arm64-v8a"))),
)

_two_platforms_test = analysistest.make(
    _same_root_impl,
    config_settings = _incoming("@rules_android//:arm64-v8a", "@rules_android//:x86_64"),
)

_other_abi_test = analysistest.make(
    _other_root_impl,
    config_settings = _incoming("@rules_android//:x86_64"),
)

def android_build_transition_test_suite(name):
    """Declares the tests.

    Args:
        name: The test_suite name.
    """
    _probe(name = name + "_probe", tags = ["manual"])
    for suffix, platforms in [
        ("arm64", ["@rules_android//:arm64-v8a"]),
        ("two", ["@rules_android//:arm64-v8a", "@rules_android//:x86_64"]),
    ]:
        flutter_android_build(
            name = "%s_%s_build" % (name, suffix),
            android_platforms = platforms,
            targets = [":" + name + "_probe"],
            tags = ["manual"],
        )
        _roots(
            name = "%s_%s_roots" % (name, suffix),
            through_rule = ":%s_%s_build" % (name, suffix),
            direct = ":" + name + "_probe",
            tags = ["manual"],
        )
    tests = {
        "apparent": (_apparent_test, "arm64"),
        "canonical": (_canonical_test, "arm64"),
        "other_abi": (_other_abi_test, "arm64"),
        "two_platforms": (_two_platforms_test, "two"),
    }
    for test_name, (test, suffix) in tests.items():
        test(
            name = "%s_%s" % (name, test_name),
            target_under_test = ":%s_%s_roots" % (name, suffix),
        )
    native.test_suite(
        name = name,
        tests = ["%s_%s" % (name, test_name) for test_name in tests],
    )
