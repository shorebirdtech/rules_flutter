"""Builds targets with `-c dbg`, whatever the command line asked for."""

_PROFILE = str(Label("//flutter:profile"))

def _dbg_transition_impl(_settings, _attr):
    # Debug mode, not profile: the flag is refused with any `-c` but opt, and a
    # profile build is not debug. What is built here is debug by design: the
    # simulator engine runs nothing else, and upstream refuses a profile
    # simulator build.
    return {
        "//command_line_option:compilation_mode": "dbg",
        _PROFILE: False,
    }

_dbg_transition = transition(
    implementation = _dbg_transition_impl,
    inputs = [],
    outputs = [
        "//command_line_option:compilation_mode",
        _PROFILE,
    ],
)

def _debug_build_impl(ctx):
    return [DefaultInfo(files = depset(transitive = [
        t[DefaultInfo].files
        for t in ctx.attr.targets
    ]))]

debug_build = rule(
    implementation = _debug_build_impl,
    doc = "Forwards the files of `targets`, built with `-c dbg` and without `--@rules_flutter//flutter:profile`.",
    attrs = {
        "targets": attr.label_list(
            cfg = _dbg_transition,
            mandatory = True,
            doc = "The targets to build in debug mode.",
        ),
    },
)
