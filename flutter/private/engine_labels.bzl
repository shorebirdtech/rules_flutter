"""The labels of the engine contract's slices.

An engine source is a repository with its slices at these labels
(docs/design/design_custom_engine.md, section 5.1). The toolchains of every SDK
are written against them, so the stock release and any other source are used
the same way.
"""

ENGINE_MODES = ["debug", "profile", "release"]

# The slice directory of a desktop engine, by the platform string of its target.
_DESKTOP_ENGINE_DIR = {
    "darwin-x64": "macos",
    "darwin-arm64": "macos",
    "linux-x64": "linux-x64",
    "linux-arm64": "linux-arm64",
    "windows-x64": "windows-x64",
}

# The target a host's own gen_snapshot compiles for.
_NATIVE_TARGET = {
    "darwin-arm64": "macos-arm64",
    "darwin-x64": "macos-x64",
    "linux-x64": "linux-x64",
    "linux-arm64": "linux-arm64",
    "windows-x64": "windows-x64",
}

def host_tools_label(engine, host):
    """The label of the host tools slice.

    Args:
        engine: The engine repository, as a label prefix (`@repo`).
        host: A `HOST_PLATFORMS` key.

    Returns:
        The label string.
    """
    return "{}//host/{}:tools".format(engine, host)

def kernel_label(engine, release):
    """The label of a platform kernel slice.

    Args:
        engine: The engine repository, as a label prefix.
        release: Whether the release (product) kernel is wanted, not the debug one.

    Returns:
        The label string.
    """
    return "{}//kernel/{}:platform".format(engine, "release" if release else "debug")

def engine_label(engine, platform, mode):
    """The label of a desktop engine slice.

    Args:
        engine: The engine repository, as a label prefix.
        platform: The target's platform string (`darwin-x64`, `linux-arm64`, ...).
        mode: `debug`, `profile` or `release`.

    Returns:
        The label string.
    """
    return "{}//{}/{}:engine".format(engine, _DESKTOP_ENGINE_DIR[platform], mode)

def desktop_engine_dir(platform):
    """The slice directory of a desktop platform's engine.

    Args:
        platform: The target's platform string.

    Returns:
        `macos`, `linux-<arch>` or `windows-<arch>`.
    """
    return _DESKTOP_ENGINE_DIR[platform]

def native_target(host):
    """The target a host's own gen_snapshot compiles for.

    Args:
        host: A `HOST_PLATFORMS` key.

    Returns:
        `macos-arm64`, `linux-x64`, ...
    """
    return _NATIVE_TARGET[host]

def gen_snapshot_label(engine, target, mode, host):
    """The label of a gen_snapshot slice.

    Args:
        engine: The engine repository, as a label prefix.
        target: `macos-<arch>`, `ios-arm64`, `android-<arch>`, `linux-<arch>` or `windows-x64`.
        mode: `profile` or `release`.
        host: The `HOST_PLATFORMS` key of the host it runs on.

    Returns:
        The label string.
    """
    return "{}//{}/{}:gen_snapshot_{}".format(engine, target, mode, host)

def mode_select(by_mode, debug = None):
    """A `select()` expression choosing a value by build mode.

    Args:
        by_mode: A dict with `profile` and `release` label strings.
        debug: The value under `-c dbg`: a label string, or None for no value.

    Returns:
        The attribute value as BUILD source text.
    """
    return """select({{
        "@rules_flutter//flutter/private:dbg": {debug},
        "@rules_flutter//flutter/private:profile": "{profile}",
        "//conditions:default": "{release}",
    }})""".format(
        debug = '"{}"'.format(debug) if debug else "None",
        profile = by_mode["profile"],
        release = by_mode["release"],
    )
