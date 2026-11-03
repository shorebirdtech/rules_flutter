"""Re-exposes an `android_binary`'s APK under its own name, optionally rebuilt
under another compilation mode.

Two things stand between a test and the APKs it needs. `bazel test //...`
builds the default configuration, so a plain run never produces the debug
APK, whose contents differ from release, most importantly the debug variant
manifest's `INTERNET` permission that `flutter_android_app` merges only for
`-c dbg`. And the APKs of the several ABIs share one file name, so a test that
reads more than one of them from its runfiles needs each under a name of its
own. This rule forces `compilation_mode` on its APK dependency via a Starlark
transition when it is given, and symlinks the signed APK to `<name>.apk`. The
test target itself stays in the default configuration and never compiles under
`-c dbg`.

The ABIs come from the dependency: a `flutter_android_build` names the
platforms its targets are built for.
"""

def _compilation_mode_impl(settings, attr):
    return {
        "//command_line_option:compilation_mode": attr.compilation_mode or settings["//command_line_option:compilation_mode"],
    }

_compilation_mode = transition(
    implementation = _compilation_mode_impl,
    inputs = ["//command_line_option:compilation_mode"],
    outputs = ["//command_line_option:compilation_mode"],
)

def _android_apk_impl(ctx):
    # A transition on the attribute delivers the dependency as a one-element
    # list. android_binary exposes both the signed `<name>.apk` and an
    # unsigned variant; select the signed APK.
    dep = ctx.attr.apk[0]
    matches = [
        f
        for f in dep[DefaultInfo].files.to_list()
        if f.basename.endswith(".apk") and not f.basename.endswith("_unsigned.apk")
    ]
    if len(matches) != 1:
        fail("expected exactly one signed APK from %s, found %s" %
             (dep.label, [f.basename for f in matches]))
    out = ctx.actions.declare_file(ctx.label.name + ".apk")
    ctx.actions.symlink(output = out, target_file = matches[0])
    return [DefaultInfo(files = depset([out]))]

android_apk = rule(
    implementation = _android_apk_impl,
    attrs = {
        "apk": attr.label(
            mandatory = True,
            cfg = _compilation_mode,
            doc = "An android_binary, or a flutter_android_build of one, whose APK to expose.",
        ),
        "compilation_mode": attr.string(
            values = ["", "dbg", "fastbuild", "opt"],
            doc = "The compilation mode to build the APK in. Empty keeps the command line's.",
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    doc = "Re-exposes an android_binary's signed APK as <name>.apk, optionally rebuilt in another compilation mode.",
)
