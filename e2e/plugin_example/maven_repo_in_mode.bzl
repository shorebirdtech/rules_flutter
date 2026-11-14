"""Re-exposes a `flutter_android_aar` repository under its own name, optionally
built in another Flutter build mode, so that one test reads the repositories of
several modes from its runfiles."""

load(":compilation_mode.bzl", "COMPILATION_MODE_ATTRS", "compilation_mode_transition")

def _maven_repo_in_mode_impl(ctx):
    # A transition on the attribute delivers the dependency as a list of one.
    repos = ctx.attr.repo[0][DefaultInfo].files.to_list()
    if len(repos) != 1 or not repos[0].is_directory:
        fail("expected one repository directory from %s, found %s" % (ctx.attr.repo[0].label, repos))
    out = ctx.actions.declare_directory(ctx.label.name)
    ctx.actions.symlink(output = out, target_file = repos[0])
    return [DefaultInfo(files = depset([out]))]

maven_repo_in_mode = rule(
    implementation = _maven_repo_in_mode_impl,
    attrs = {
        "repo": attr.label(
            mandatory = True,
            cfg = compilation_mode_transition,
            doc = "A `flutter_android_aar` (or `flutter_android_maven_repo`).",
        ),
    } | COMPILATION_MODE_ATTRS,
    doc = "Re-exposes a Maven repository directory as <name>, optionally built in another mode.",
)
