"""Builds targets in a chosen Flutter build mode, whatever the command line says."""

_COMPILATION_MODE = "//command_line_option:compilation_mode"
_PROFILE = "@rules_flutter//flutter:profile"

# Flutter mode -> (Bazel compilation mode, profile flag).
_MODES = {
    "debug": ("dbg", False),
    "fastbuild": ("fastbuild", False),
    "release": ("opt", False),
    "profile": ("opt", True),
}

def _transition_impl(_settings, attr):
    compilation_mode, profile = _MODES[attr.mode]
    return {_COMPILATION_MODE: compilation_mode, _PROFILE: profile}

_transition = transition(
    implementation = _transition_impl,
    inputs = [],
    outputs = [_COMPILATION_MODE, _PROFILE],
)

def _impl(ctx):
    return [DefaultInfo(files = depset(transitive = [
        t[DefaultInfo].files
        for t in ctx.attr.targets
    ]))]

build_in_mode = rule(
    implementation = _impl,
    doc = """Builds `targets` in the Flutter build mode `mode` and forwards their files.

A test of a built artifact lists this in its `data` to look at the artifact of
each mode in one plain `bazel test`. The test itself stays in the default
configuration: a `dart_test` does not build under `-c dbg`.""",
    attrs = {
        "mode": attr.string(
            mandatory = True,
            values = sorted(_MODES.keys()),
            doc = "The mode to build in. `fastbuild` is Bazel's own default, " +
                  "which builds a release app in Flutter terms too.",
        ),
        "targets": attr.label_list(
            cfg = _transition,
            mandatory = True,
            doc = "The targets to build in `mode`.",
        ),
    },
)
