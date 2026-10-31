"""The Flutter engine framework for the build mode, on macOS and iOS.

The application's bundle and every plugin compiled against the engine name
the same framework through these selects. Two imports of one framework name
from different modes reach rules_apple's bundling as one framework, and it
cannot assemble that.
"""

def macos_engine_framework():
    """Selects FlutterMacOS.framework for the build mode: debug, profile or release.

    Returns:
        A select over the `framework_imports` of an apple_dynamic_framework_import.
    """
    return select({
        Label("//flutter/private:dbg"): [Label("@flutter_macos_engine//:engine_debug_library")],
        Label("//flutter/private:profile"): [Label("@flutter_macos_engine//:engine_profile_library")],
        "//conditions:default": [Label("@flutter_macos_engine//:engine_library")],
    })

def ios_engine_xcframework():
    """Selects Flutter.xcframework for the build mode.

    Debug (-c dbg): the JIT engine (simulator). Profile (-c opt with
    `//flutter:profile`): the profile AOT engine (device). Release (-c opt /
    default): the AOT engine (device). The labels resolve through
    rules_flutter's own repo mapping, so a consumer needs none of these repos
    in `use_repo`.

    Returns:
        A select over the `xcframework_imports` of an apple_dynamic_xcframework_import.
    """
    return select({
        Label("//flutter/private:dbg"): [Label("@flutter_ios_engine//:Flutter_xcframework_debug")],
        Label("//flutter/private:profile"): [Label("@flutter_ios_engine_profile//:Flutter_xcframework")],
        "//conditions:default": [Label("@flutter_ios_engine//:Flutter_xcframework")],
    })
