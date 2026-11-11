"""Which build mode's engine a file belongs to, for the engine tests."""

# The flags each build mode is selected by.
MODE_FLAGS = {
    "debug": {"//command_line_option:compilation_mode": "dbg"},
    "profile": {
        "//command_line_option:compilation_mode": "opt",
        str(Label("//flutter:profile")): True,
    },
    "release": {"//command_line_option:compilation_mode": "opt"},
}

def engine_mode_of(path):
    """The build mode of the engine that holds the file at `path`.

    Debug engines sit in their own directory of the release repo (macOS,
    and the host SDK repos) or in a repo of their own (iOS, and the desktop
    engines of a cross toolchain); the profile engine is a repo of its own,
    laid out like the release one.

    Args:
        path: A file's exec path.

    Returns:
        "debug", "profile" or "release".
    """
    if "_profile/" in path:
        return "profile"
    if "/engine-debug/" in path or "_debug/" in path:
        return "debug"
    return "release"

def engine_modes(files, marker):
    """The sorted build modes of the files whose path contains `marker`.

    Args:
        files: A list of Files.
        marker: Picks the engine's own files out of `files`.

    Returns:
        A sorted list of modes; one entry when the files agree on a mode.
    """
    return sorted({engine_mode_of(f.path): True for f in files if marker in f.path}.keys())
