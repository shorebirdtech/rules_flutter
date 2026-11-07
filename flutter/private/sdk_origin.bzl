"""Where an SDK's engine comes from, for the rules whose platform it does not serve yet.

Every slice of an engine source records where it came from (`provenance`); the
official release's say `origin: release`. A source of the user's choosing
provides the slices of the platforms it supports and says so for the rest, but
a platform whose engine is still imported by its own repository (web, and the
Linux and Windows engines' headers) would be given the release's engine
whatever SDK a build selects. A rule for such a platform checks the SDK it was
given, so a custom engine is never silently combined with the release's.
"""

RELEASE_ORIGIN = "release"

def is_release_engine(host_tools):
    """Whether an SDK's engine is the official release.

    Args:
        host_tools: The `FlutterHostToolsInfo` of the SDK.

    Returns:
        True when the engine source is the stock release.
    """
    return host_tools.provenance.get("origin") == RELEASE_ORIGIN

def require_release_engine(label, sdk, host_tools, platform):
    """Fails when a platform is built against an engine that is not the release.

    Args:
        label: The target being built.
        sdk: The SDK's name.
        host_tools: The `FlutterHostToolsInfo` of the SDK.
        platform: The platform the target builds for, for the message.
    """
    if not is_release_engine(host_tools):
        fail((
            "{label}: the \"{sdk}\" Flutter SDK has no {platform} engine: its engine source " +
            "serves macOS, iOS and Android apps so far. Build {platform} apps with the release SDK " +
            "(--@rules_flutter//flutter:sdk=flutter)."
        ).format(label = label, sdk = sdk, platform = platform))
