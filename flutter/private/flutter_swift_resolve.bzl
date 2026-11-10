"""`bazel run @<hub>//swift:resolve`: writes the hub's `Package.resolved`.

Each pub hub has this target. It resolves the Swift package dependencies of the
hub's Apple plugins (`flutter/private/tools/swift_resolve.dart`) and writes the
file `flutter_pub.from_lock(swift_package_resolved = ...)` names, or
`Package.resolved` beside the lock. See `swift_packages.bzl`.
"""

load("@rules_dart//dart:utils.bzl", "runfiles_path")

# buildifier: disable=bzl-visibility
load("@rules_dart//dart/private:dart_compile.bzl", "dart_compile_action")
load("//flutter/private:host_transition.bzl", "host_transition")

def _flutter_swift_resolve_impl(ctx):
    dart_sdk_info = ctx.toolchains["@rules_dart//dart:toolchain_type"].dart_sdk_info
    workspace_name = ctx.workspace_name
    listings = [f for f in ctx.files.manifests if f.basename == "swift_manifests.json"]
    config = ctx.actions.declare_file(ctx.label.name + ".config.json")
    ctx.actions.write(config, json.encode({
        "hub": ctx.attr.hub,
        "manifests": [runfiles_path(f, workspace_name) for f in listings],
        "output": ctx.attr.output,
    }))
    executable = ctx.actions.declare_file(ctx.label.name)
    dart_compile_action(
        ctx = ctx,
        sdk = dart_sdk_info,
        kernel = ctx.file._main,
        sources = depset(ctx.files._srcs + [ctx.file._main]),
        output = executable,
        extra_flags = [
            "-Drules_flutter.swift_resolve.config=" + runfiles_path(config, workspace_name),
        ],
    )
    return [DefaultInfo(
        executable = executable,
        runfiles = ctx.runfiles(files = [config] + ctx.files.manifests),
    )]

flutter_swift_resolve = rule(
    implementation = _flutter_swift_resolve_impl,
    executable = True,
    cfg = host_transition,
    toolchains = ["@rules_dart//dart:toolchain_type"],
    attrs = {
        "hub": attr.string(doc = "The hub's name, for messages.", mandatory = True),
        "manifests": attr.label_list(
            doc = "The `swift_manifests` of the hub's packages' Apple repositories.",
            allow_files = True,
        ),
        "output": attr.string(
            doc = "Where to write, relative to the workspace; empty when the file is not the workspace's.",
        ),
        "_main": attr.label(
            default = "//flutter/private/tools:swift_resolve.dart",
            allow_single_file = [".dart"],
        ),
        "_srcs": attr.label_list(
            default = ["//flutter/private/tools:pub_runfiles.dart"],
            allow_files = [".dart"],
        ),
    },
    doc = "Resolves a pub hub's Apple plugins' Swift package dependencies. See the module docstring.",
)
