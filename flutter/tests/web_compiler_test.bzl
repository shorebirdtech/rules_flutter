"""What a web bundle's compilers share, and what each gets its own of.

A web bundle builds its program once per compiler, as `@rules_dart//dart:web_compiler`
`wasm` and `js`. A configured target carries the setting, so a target reached under
both is analysed twice and builds its outputs twice, unless its rule resets the
setting on the way in. These tests look at where a generated file lands, which is
the configuration it was built in: the same root as a build with no web compiler
means built once, and a different one means built per compiler.

Shared, built once with no web compiler:

  * a `flutter_native_library`, the same library whichever compiler an app that
    bundles it is built for;
  * what a `flutter_gen_l10n` generates;
  * a `flutter_library` or `flutter_plugin` that says `web_compiler_independent`,
    as every package pub provides does, and what it depends on.

Built per compiler, which makes the check above mean something:

  * a `flutter_library` or `flutter_plugin` that does not say so, since it may
    `select()` a dependency by compiler.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_dart//dart:providers.bzl", "DartInfo")
load("//flutter/private:flutter_web_branch.bzl", "WEB_COMPILER_SETTING")

_RootsInfo = provider(
    doc = "Generated file short path to output root, per compiler (`none` for a plain build).",
    fields = ["by_compiler"],
)

def _both_compilers_impl(_settings, _attr):
    return {
        "js": {WEB_COMPILER_SETTING: "js"},
        "wasm": {WEB_COMPILER_SETTING: "wasm"},
    }

_both_compilers = transition(
    implementation = _both_compilers_impl,
    inputs = [],
    outputs = [WEB_COMPILER_SETTING],
)

def _roots(target):
    roots = {}
    for f in target[DefaultInfo].files.to_list():
        if not f.is_source:
            roots[f.short_path] = f.root.path
    if DartInfo in target:
        for f in target[DartInfo].transitive_srcs.to_list():
            if not f.is_source:
                roots[f.short_path] = f.root.path
    return roots

def _compiler_roots_impl(ctx):
    by_compiler = {"none": _roots(ctx.attr.plain)}
    for compiler, target in ctx.split_attr.lib.items():
        by_compiler[compiler] = _roots(target)
    return [_RootsInfo(by_compiler = by_compiler)]

# Reaches one target under each compiler and in a plain build.
_compiler_roots = rule(
    implementation = _compiler_roots_impl,
    attrs = {
        "lib": attr.label(cfg = _both_compilers, mandatory = True),
        "plain": attr.label(mandatory = True),
    },
)

def _shared_test_impl(ctx):
    env = analysistest.begin(ctx)
    by_compiler = analysistest.target_under_test(env)[_RootsInfo].by_compiler
    plain = by_compiler["none"]
    asserts.true(env, plain, "the target generates nothing, so the test proves nothing")

    # A split whose branches reach one configured target keeps one of them, so
    # only the compilers still present are compared.
    for path, baseline in plain.items():
        for compiler in ["js", "wasm"]:
            if compiler not in by_compiler:
                continue
            asserts.equals(
                env,
                baseline,
                by_compiler[compiler].get(path),
                "%s should be built once, with no web compiler, but %s builds it elsewhere" % (path, compiler),
            )
    return analysistest.end(env)

# Everything the target generates is built in the plain build's configuration
# under every compiler.
_shared_test = analysistest.make(_shared_test_impl)

def _forked_test_impl(ctx):
    env = analysistest.begin(ctx)
    by_compiler = analysistest.target_under_test(env)[_RootsInfo].by_compiler
    plain = by_compiler["none"]
    asserts.true(env, plain, "the target generates nothing, so the test proves nothing")
    asserts.true(env, "js" in by_compiler and "wasm" in by_compiler, "the compilers share one configuration of the target: %s" % by_compiler.keys())
    for path, baseline in plain.items():
        roots = [by_compiler[c].get(path) for c in ["js", "wasm"]]
        asserts.true(env, baseline not in roots, "%s is built with no web compiler, but should be built per compiler" % path)
        asserts.true(env, roots[0] != roots[1], "%s is built once for js and wasm, but should be built for each" % path)
    return analysistest.end(env)

# The control: a target that is not reset is built once per compiler.
_forked_test = analysistest.make(_forked_test_impl)

def web_compiler_test_suite(name):
    """Instantiate the web compiler tests.

    Args:
        name: Prefix of the test targets, and of the suite.
    """
    shared = {
        "native_library": "//flutter/tests/web_compiler_fixture:native_library",
        "gen_l10n": "//flutter/tests/gen_l10n_fixture:l10n",
        "independent_library": "//flutter/tests/web_compiler_fixture:independent_library",
        "independent_plugin": "//flutter/tests/web_compiler_fixture:independent_plugin",
    }
    forked = {
        "library": "//flutter/tests/web_compiler_fixture:library",
        "plugin": "//flutter/tests/web_compiler_fixture:plugin",
    }
    tests = []
    for case, label in dict(shared, **forked).items():
        _compiler_roots(
            name = "%s_%s_roots" % (name, case),
            lib = label,
            plain = label,
            tags = ["manual"],
        )
        test = "%s_%s" % (name, case)
        (_shared_test if case in shared else _forked_test)(
            name = test,
            target_under_test = ":%s_%s_roots" % (name, case),
        )
        tests.append(":" + test)
    native.test_suite(name = name, tests = tests)
