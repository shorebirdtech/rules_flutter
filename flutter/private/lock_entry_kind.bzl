"""Who builds a `pubspec.lock` entry, decided by the entry's `source:` alone.

The lock's `source:` says where pub got the package. A hosted package is
fetched from its registry. An `sdk: flutter` package is Flutter's own, and pub
writes one for every `sdk: flutter` package the app's dependencies reach, not
only the ones the app names: `integration_test` brings `flutter_driver`, which
brings `fuchsia_remote_debug_protocol`. A list of package names would be wrong
the day a Flutter release adds one, so the only names this file knows are the
two `sdk` packages that are not built like the rest. A `path` package is the
user's own, built by the target `flutter.pub(resolve = ...)` names for it.
"""

# A package fetched from a pub registry.
HOSTED = "hosted"

# `package:flutter`: its shaders are declared in no pubspec, so it has a rule
# of its own (`flutter_framework_package`) rather than the pub-package writer.
FLUTTER_FRAMEWORK = "flutter_framework"

# The engine provides `sky_engine`'s `dart:ui`; it needs no repository.
ENGINE_PROVIDED = "engine_provided"

# Any other `sdk: flutter` package: built from the pinned Flutter source by the
# pub-package writer, as a hosted package is built from its archive.
FLUTTER_SOURCE = "flutter_source"

# A `path` package: a target in the workspace, named by `flutter.pub(resolve = ...)`.
PATH = "path"

# A git package, or a source rules_flutter has never heard of.
UNSUPPORTED = "unsupported"

def lock_entry_kind(name, source):
    """Says who builds a lock entry.

    Args:
        name: The package name.
        source: The entry's `source:`; `"unknown"` when it has none.

    Returns:
        One of `HOSTED`, `FLUTTER_FRAMEWORK`, `ENGINE_PROVIDED`,
        `FLUTTER_SOURCE`, `PATH`, `UNSUPPORTED`.
    """
    if source == "hosted":
        return HOSTED
    if source == "sdk":
        if name == "flutter":
            return FLUTTER_FRAMEWORK
        if name == "sky_engine":
            return ENGINE_PROVIDED
        return FLUTTER_SOURCE
    if source == "path":
        return PATH
    return UNSUPPORTED
