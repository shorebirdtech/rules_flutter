"""`outline_cutoff_modules`: Flutter's kernel modules of a library and its dependent, built from each edit of the library, for `outline_cutoff_test`.

The modules compile against Flutter's SDK (`flutter_module_aspect`), whose
`DartKernelSdkInfo` carries the outline tool, so a library's dependents compile
against its outline, not its full kernel. The plan names the library's module,
its outline and its dependent's module for the `base` sources and for each
edit.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@bazel_skylib//rules:copy_file.bzl", "copy_file")
load("@rules_dart//dart:providers.bzl", "DartModuleInfo")
load("//flutter/private:flutter_module.bzl", "flutter_module_aspect")

_VARIANT = str(Label("//flutter/tests/outline_fixture:variant"))
_EDITS = ["body", "signature"]

VARIANTS = ["base"] + _EDITS

def variant_source(name, out):
    """`out`, copied from `variants/<stem>.<variant>.dart` for the `:variant` flag's value.

    Args:
      name: The target name.
      out: The library file to write, e.g. `a_lib/lib/a.dart`.
    """
    stem = out.rsplit("/", 1)[-1].removesuffix(".dart")
    copy_file(
        name = name,
        src = select({
            "//flutter/tests/outline_fixture:%s" % v: "variants/%s.%s.dart" % (stem, v)
            for v in VARIANTS
        }),
        out = out,
    )

def _variants_impl(_settings, _attr):
    return {v: {_VARIANT: v} for v in VARIANTS}

_variants = transition(
    implementation = _variants_impl,
    inputs = [],
    outputs = [_VARIANT],
)

def _own(target):
    # The target's own directories: the last of each postorder depset.
    info = target[DartModuleInfo]
    return struct(modules = info.modules.to_list()[-1], outlines = info.outlines.to_list()[-1])

def _impl(ctx):
    placed = {}

    # Every variant's copy of a directory has the same runfiles path, so each
    # is linked under a path of its own, by which the plan names it.
    def place(variant, tree):
        key = (variant, tree.path)
        if key not in placed:
            link = ctx.actions.declare_directory("%s/%s/%s" % (ctx.label.name, variant, tree.short_path))
            ctx.actions.symlink(output = link, target_file = tree)
            placed[key] = link
        return ctx.workspace_name + "/" + placed[key].short_path

    def describe(variant):
        dependency = _own(ctx.split_attr.dependency[variant])
        dependent = _own(ctx.split_attr.dependent[variant])
        return {
            "dependency": place(variant, dependency.modules),
            "dependency_outlines": place(variant, dependency.outlines),
            "dependent": place(variant, dependent.modules),
        }

    plan = ctx.actions.declare_file(ctx.label.name + ".json")
    ctx.actions.write(plan, json.encode_indent({
        "base": describe("base"),
        "edits": {edit: describe(edit) for edit in _EDITS},
    }))
    return [DefaultInfo(files = depset([plan]), runfiles = ctx.runfiles(files = [plan] + placed.values()))]

def _reads_outline_impl(ctx):
    env = analysistest.begin(ctx)

    # The dependent's compile takes its dependencies' `outlines` as inputs, and
    # `DartModuleInfo.outlines` is that depset plus the module's own.
    outlines = analysistest.target_under_test(env)[DartModuleInfo].outlines.to_list()
    inputs = [f.basename for f in outlines[:-1]]
    asserts.true(
        env,
        "a.flutter.modules.outlines" in inputs,
        "the dependent's compile does not read its dependency's outline: %s" % inputs,
    )
    asserts.false(
        env,
        "a.flutter.modules" in inputs,
        "the dependent's compile reads its dependency's full kernel: %s" % inputs,
    )
    return analysistest.end(env)

# What a dependent's module compile is given of its dependency: the outline and
# not the full kernel. A compile given the full kernel runs again on every
# edit, though its output does not change.
reads_outline_test = analysistest.make(
    _reads_outline_impl,
    extra_target_under_test_aspects = [flutter_module_aspect],
)

outline_cutoff_modules = rule(
    implementation = _impl,
    attrs = {
        "dependency": attr.label(cfg = _variants, aspects = [flutter_module_aspect], doc = "The library that is edited."),
        "dependent": attr.label(cfg = _variants, aspects = [flutter_module_aspect], doc = "A library depending on `dependency`."),
    },
)
