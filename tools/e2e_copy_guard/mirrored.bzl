"""The files that more than one e2e workspace must carry, and so must agree on.

An e2e workspace is its own Bazel project, so it cannot name a file in a
sibling or in the root module the way a package of one project can. Where the
file is a test's input and is read from the workspace itself, it is copied
into each workspace and listed here, and
`//tools/e2e_copy_guard:copies_identical_test` fails when the copies differ.
Test code that several workspaces share lives in `//tools/e2e_testing`
instead, and is not listed.

Every workspace's `.bazelversion` is checked against the root's as well,
without being listed: bazelisk reads it from the workspace being built, and
every workspace runs the root's Bazel.

Each group is a name and the repo-root-relative paths of its copies. Change
the copies of a group together. To make one diverge on purpose, take it out of
the group, and say why where the file is.
"""

MIRRORED = {
    # `main` outside `lib/` and the sibling it imports by relative path:
    # the dev tool's `main_outside_lib_e2e_test` edits them in a copy of the
    # workspace and reloads, so they must be files of the workspace.
    "driver entrypoint app.dart": [
        "e2e/macos_example/test_driver/app.dart",
        "e2e/web_example/test_driver/app.dart",
    ],
    "driver entrypoint banner.dart": [
        "e2e/macos_example/test_driver/banner.dart",
        "e2e/web_example/test_driver/banner.dart",
    ],
    # The iOS and macOS examples ship the same two extensions.
    "widgets extension Info.plist": [
        "e2e/ios_example/extensions/widgets/Info.plist",
        "e2e/macos_example/extensions/widgets/Info.plist",
    ],
    "share extension Info.plist": [
        "e2e/ios_example/extensions/share/Info.plist",
        "e2e/macos_example/extensions/share/Info.plist",
    ],
    "assets/message.txt": [
        "e2e/ios_example/assets/message.txt",
        "e2e/macos_example/assets/message.txt",
    ],
    "indexed.frag": [
        "e2e/hello_world/shaders/indexed.frag",
        "e2e/plugin_example/impeller_shader/pkg/shaders/indexed.frag",
    ],
    # Native sources: the dev loop watches a native library's declared sources
    # by their workspace paths, so they stay files of the workspace.
    "native/add.c": [
        "e2e/android_example/native/add.c",
        "e2e/ffi_example/native/add.c",
        "e2e/macos_example/native/add.c",
    ],
    "native/add.h": [
        "e2e/android_example/native/add.h",
        "e2e/macos_example/native/add.h",
    ],
    "native/counter.c": [
        "e2e/android_example/native/counter.c",
        "e2e/codegen/shared_counter/native/counter.c",
    ],
    "native/counter.h": [
        "e2e/android_example/native/counter.h",
        "e2e/codegen/shared_counter/native/counter.h",
    ],
}
