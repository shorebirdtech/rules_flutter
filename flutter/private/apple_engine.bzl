"""The Flutter engine framework for the build mode, on macOS and iOS.

The application's bundle and every plugin compiled against the engine name
the same framework through these targets. Two imports of one framework name
from different modes reach rules_apple's bundling as one framework, and it
cannot assemble that. Each target follows the build mode itself (debug,
profile or release), so no caller selects. The labels resolve through
rules_flutter's own repo mapping, so a consumer needs none of these repos in
`use_repo`.
"""

# FlutterMacOS.framework of the build mode, as `framework_imports` of an
# apple_dynamic_framework_import.
MACOS_ENGINE_FRAMEWORK = [Label("@flutter_macos_engine//:engine_library")]

# Flutter.xcframework of the build mode, as `xcframework_imports` of an
# apple_dynamic_xcframework_import. Debug (-c dbg) is the JIT engine
# (simulator); profile and release are AOT engines (device).
IOS_ENGINE_XCFRAMEWORK = [Label("@flutter_ios_engine//:Flutter_xcframework")]
