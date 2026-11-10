"""The layout of `flutter build ios-framework` and `macos-framework`, and its export.

`flutter_apple_xcframeworks_layout` puts the xcframeworks of one build mode,
the configuration's, under `<Mode>/` (`Debug`, `Profile`, `Release`), and the
files upstream writes above the modes beside it. `bazel run` of it writes that
to `build/<platform>/framework/` in the target's package, as the upstream
command does, replacing that mode's directory; a run per mode fills all three.
"""

load("@bazel_skylib//lib:dicts.bzl", "dicts")
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@rules_dart//dart:utils.bzl", "runfiles_path")
load("//flutter/private:apple_add_to_app.bzl", "BUNDLE_ATTRS", "assemble_bundle")
load("//flutter/private:exec_groups.bzl", "PORTABLE_EXEC_GROUPS")

def build_mode_directory(ctx):
    """`Debug`, `Profile` or `Release`: the mode of the configuration, as upstream names it.

    Args:
        ctx: A rule context with a `_profile` attribute (`//flutter:profile`).

    Returns:
        The directory name.
    """
    if ctx.var["COMPILATION_MODE"] == "dbg":
        return "Debug"
    if ctx.attr._profile[BuildSettingInfo].value:
        return "Profile"
    return "Release"

def _layout_impl(ctx):
    mode = build_mode_directory(ctx)
    steps = []
    seen = {}

    def place(name, step):
        if name in seen:
            fail("%s: two inputs are both %s" % (ctx.label, name))
        seen[name] = True
        steps.append(step)

    for target in ctx.attr.xcframeworks:
        for f in target[DefaultInfo].files.to_list():
            if f.basename.endswith(".xcframework"):
                place(f.basename, ("bundle", "%s/%s" % (mode, f.basename), f))
            elif f.extension in ("h", "m", "swift"):
                # The registrant's sources, above the modes as upstream's.
                place(f.basename, ("file", f.basename, f))
    for target, name in ctx.attr.renamed_files.items():
        files = target[DefaultInfo].files.to_list()
        if len(files) != 1:
            fail("%s: `renamed_files` takes targets of one file, and %s has %d" % (ctx.label, target.label, len(files)))
        place(name, ("file", name, files[0]))
    if mode == "Debug":
        for f in ctx.files.debug_files:
            place(f.basename, ("file", f.basename, f))

    tree = ctx.actions.declare_directory(ctx.label.name)
    assemble_bundle(
        ctx,
        tree,
        steps,
        mnemonic = "FlutterXCFrameworksLayout",
        progress_message = "Laying out the %s xcframeworks of %%{label}" % mode,
    )

    workspace = ctx.workspace_name
    config = ctx.actions.declare_file(ctx.label.name + ".xcframeworks_export.json")
    ctx.actions.write(config, json.encode_indent({
        "mode": mode,
        "package": ctx.label.package,
        "platform": ctx.attr.platform,
        "tree": runfiles_path(tree, workspace),
    }))
    tool = ctx.attr._export_tool
    executable = ctx.actions.declare_file(ctx.label.name + ".export")
    ctx.actions.symlink(
        output = executable,
        target_file = tool[DefaultInfo].files_to_run.executable,
        is_executable = True,
    )
    runfiles = ctx.runfiles(files = [config, tree, executable]).merge(tool[DefaultInfo].default_runfiles)
    return [
        DefaultInfo(files = depset([tree]), executable = executable, runfiles = runfiles),
        RunEnvironmentInfo(environment = {
            "RULES_FLUTTER_XCFRAMEWORKS_CONFIG": runfiles_path(config, workspace),
        }),
    ]

flutter_apple_xcframeworks_layout = rule(
    implementation = _layout_impl,
    executable = True,
    attrs = dicts.add(BUNDLE_ATTRS, {
        "platform": attr.string(
            doc = "`ios` or `macos`: where `bazel run` writes, `build/<platform>/framework`.",
            mandatory = True,
            values = ["ios", "macos"],
        ),
        "xcframeworks": attr.label_list(
            doc = "Targets whose `.xcframework` directories go under `<Mode>/`, and whose " +
                  "`.h`, `.m` and `.swift` files go above it.",
            allow_files = True,
        ),
        "renamed_files": attr.label_keyed_string_dict(
            doc = "Single files placed above `<Mode>/` under the name given.",
            allow_files = True,
        ),
        "debug_files": attr.label_list(
            doc = "Files placed above `<Mode>/` when the mode is debug.",
            allow_files = True,
        ),
        "_export_tool": attr.label(
            default = "//flutter/private/tools:apple_xcframeworks_export",
            executable = True,
            cfg = "target",
        ),
        "_profile": attr.label(default = "//flutter:profile"),
    }),
    exec_groups = PORTABLE_EXEC_GROUPS,
    doc = """Lays out the xcframeworks of one build mode as `flutter build ios-framework` and
`macos-framework` do: `<Mode>/` (the configuration's), and the files upstream writes
beside the modes. `bazel run` writes it to `build/<platform>/framework/` in the
package (`-- --output=<dir>` elsewhere), replacing that mode's directory.""",
)
