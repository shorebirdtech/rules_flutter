"""A transition that rebuilds a dependency in a given Flutter build mode.

`bazel test //...` builds the default configuration, which is Flutter's release
mode. A test that checks what another mode builds reaches it through this, and
stays in the default configuration itself.
"""

_PROFILE = str(Label("@rules_flutter//flutter:profile"))

def _compilation_mode_impl(settings, attr):
    # Profile mode is `-c opt` with the profile flag; the flag under any other
    # mode selects nothing, so it is only ever set together with `opt`.
    if attr.profile:
        return {
            "//command_line_option:compilation_mode": "opt",
            _PROFILE: True,
        }
    return {
        "//command_line_option:compilation_mode": attr.compilation_mode or settings["//command_line_option:compilation_mode"],
        _PROFILE: settings[_PROFILE],
    }

compilation_mode_transition = transition(
    implementation = _compilation_mode_impl,
    inputs = [
        "//command_line_option:compilation_mode",
        _PROFILE,
    ],
    outputs = [
        "//command_line_option:compilation_mode",
        _PROFILE,
    ],
)

# The attributes `compilation_mode_transition` reads.
COMPILATION_MODE_ATTRS = {
    "compilation_mode": attr.string(
        values = ["", "dbg", "fastbuild", "opt"],
        doc = "The compilation mode to build the dependency in. Empty keeps the command line's.",
    ),
    "profile": attr.bool(
        doc = "Build the dependency in Flutter profile mode (`-c opt --@rules_flutter//flutter:profile`). Overrides `compilation_mode`.",
    ),
    "_allowlist_function_transition": attr.label(
        default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
    ),
}
