"""The compilers a web bundle's Dart goes through, and what each one reads.

A web bundle compiles one program with up to three compilers, and the program
may differ between them: a library's `deps` can `select()` on
`@rules_dart//dart:web_compiler`, so a dependency that holds an `Int64List`
for dart2wasm can be a `List<int>` for dart2js. The bundle therefore reads
each compiler's inputs from a *branch* of its dependencies, built with that
compiler's value of the setting:

    branch     compiles                              web_compiler
    dart2wasm  the WebAssembly build                 wasm
    dart2js    the JavaScript fallback               js
    ddc        the dev loop (`flutter_bazel run`)    js

Two branches share a setting value, so a debug bundle has at most two
configurations of its program: DDC compiles what dart2js does.

Each branch is its own configured target of `flutter_web_branch`, because the
staging a compile needs (the package config and the co-located sources of a
package whose files are split between the source tree and `bazel-out`) declares
files named after its target, and two of them in one target collide. The
bundle macro (`flutter_web_bundle`) declares that target beside the bundle.
"""

load("@rules_dart//dart:providers.bzl", "DartInfo")
load(
    "@rules_dart//dart:utils.bzl",
    "COPY_TO_DIRECTORY_TOOLCHAINS",
    "collect_packages",
    "collect_transitive_srcs",
    "derive_lib_root",
)
load("//flutter/private:app_entrypoint.bzl", "compile_package_config", "synthesize_app_package")

WEB_COMPILER_SETTING = str(Label("@rules_dart//dart:web_compiler"))

# The value of `@rules_dart//dart:web_compiler` each branch is built under.
BRANCH_COMPILER = {
    "dart2wasm": "wasm",
    "dart2js": "js",
    "ddc": "js",
}

def web_branches_target(bundle):
    """The name of the staging target declared beside a bundle.

    Args:
        bundle: The bundle's target name.

    Returns:
        The name of its `flutter_web_branch`.
    """
    return "__%s_branches" % bundle

def web_compile_branches(compiler, js_fallback, debug):
    """The compilers a bundle's Dart goes through, the primary first.

    Each is a branch of the program: what it compiles is read from its own
    branch of `deps`, so a dependency may differ by compiler. The primary is
    `compiler`, the build the bundle describes; dart2js joins a dart2wasm
    bundle as its fallback; and a debug build adds DDC, which compiles the
    app for `flutter_bazel run -d chrome` from the files `_dev_config.json`
    names rather than in this rule.

    Args:
        compiler: The `compiler` attr: "dart2wasm" or "dart2js".
        js_fallback: The `js_fallback` attr.
        debug: Whether this is a debug build.

    Returns:
        A list of "dart2wasm", "dart2js" and "ddc", the primary first.
    """
    branches = [compiler]
    if compiler == "dart2wasm" and js_fallback:
        branches.append("dart2js")
    if debug:
        branches.append("ddc")
    return branches

def branch_settings(branches):
    """The distinct `web_compiler` values of some branches, in order.

    Args:
        branches: Branch names, from `web_compile_branches`.

    Returns:
        A list of "wasm" and "js", each at most once.
    """
    settings = []
    for branch in branches:
        setting = BRANCH_COMPILER[branch]
        if setting not in settings:
            settings.append(setting)
    return settings

def _branches_impl(settings, attr):
    # A profile build is not a debug build under any compilation mode, so
    # `profile` rules the dev loop out as `web_build_mode` does.
    # The mode arrives as a `CompilationMode`, which compares equal to no string.
    debug = str(settings["//command_line_option:compilation_mode"]) == "dbg" and not attr.profile
    return {
        setting: {WEB_COMPILER_SETTING: setting}
        for setting in branch_settings(web_compile_branches(attr.compiler, attr.js_fallback, debug))
    }

# One configuration of a bundle's program per `web_compiler` value its
# compilers need, keyed by that value (`ctx.split_attr.<attr>["wasm"]`). A
# dart2js bundle in release builds its program once.
web_branches = transition(
    implementation = _branches_impl,
    inputs = ["//command_line_option:compilation_mode"],
    outputs = [WEB_COMPILER_SETTING],
)

FlutterWebBranchInfo = provider(
    doc = "What one compiler of a web bundle reads, staged for it.",
    fields = {
        "srcs": "list[File]: the bundle's `srcs` and its dependencies' sources, as declared.",
        "packages": "list[DartPackageInfo]: as declared, the app's own package last.",
        "config_file": "File: the package config, after co-location.",
        "compile_srcs": "list[File]: the sources the package config reaches, after co-location.",
    },
)

def _flutter_web_branch_impl(ctx):
    lib_root = derive_lib_root(ctx.label.workspace_root, ctx.label.package)
    deps = ctx.attr.deps
    srcs = list(ctx.files.srcs) + collect_transitive_srcs(deps).to_list()

    # Register the app's own package (when declared) so `package:<name>/main.dart`
    # is a valid URI for the wrapper to import. Include `main` in the colocate
    # inputs so it ends up inside the same assembled directory as its lib/
    # siblings — that's what lets `main.dart`'s relative imports resolve to
    # the assembled (codegen-co-located) copies of its package siblings.
    packages = synthesize_app_package(ctx.attr.bundle, collect_packages(deps), ctx.attr.package_name, lib_root, ctx.attr.language_version)
    staged = compile_package_config(ctx, packages, srcs + [ctx.file.main])
    return [
        FlutterWebBranchInfo(
            srcs = srcs,
            packages = packages,
            config_file = staged.config_file,
            compile_srcs = staged.srcs,
        ),
        DefaultInfo(files = depset([staged.config_file] + [f for f in staged.srcs if not f.is_source])),
    ]

flutter_web_branch = rule(
    implementation = _flutter_web_branch_impl,
    attrs = {
        "deps": attr.label_list(providers = [DartInfo]),
        "srcs": attr.label_list(allow_files = [".dart"]),
        "main": attr.label(allow_single_file = [".dart"], mandatory = True),
        "package_name": attr.string(mandatory = True),
        "language_version": attr.string(),
        "bundle": attr.string(
            doc = "The bundle this stages, for the messages that name it.",
            mandatory = True,
        ),
    },
    toolchains = COPY_TO_DIRECTORY_TOOLCHAINS,
    doc = """One compiler's view of a `flutter_web_bundle`'s program.

Declared by the bundle macro with the bundle's `deps`, `srcs`, `main`,
`package_name` and `language_version`, and reached from the bundle through the
same split as its `deps`, so each configured target stages the program as one
compiler sees it. Not for use outside that macro.""",
)
