"""The `pub` extension: pub dependencies from `pubspec.lock` files.

```starlark
flutter_pub = use_extension("@rules_flutter//flutter/pub:extensions.bzl", "pub")
flutter_pub.from_lock(name = "deps", lock = "//:pubspec.lock")
use_repo(flutter_pub, "deps")
```

Every `pubspec.lock` entry becomes a repository, including the Flutter SDK
packages like package:flutter. This is its own extension, apart from `flutter`
(the toolchains), so that a lock it refuses breaks only the builds that use its
repositories, never the toolchains, and `bazel run @rules_flutter//flutter/pub`,
which fixes the lock, still runs.
"""

load("//flutter/private:pub_extension.bzl", "pub_cycle_tag", "pub_extension", "pub_from_lock_tag", "pub_plugin_overlays_tag", "pub_settings_tag")

pub = module_extension(
    implementation = pub_extension,
    tag_classes = {
        "cycle": pub_cycle_tag,
        "from_lock": pub_from_lock_tag,
        "plugin_overlays": pub_plugin_overlays_tag,
        "settings": pub_settings_tag,
    },
    os_dependent = False,
    arch_dependent = False,
    doc = "Resolves pub dependencies, including Flutter SDK packages, from " +
          "`pubspec.lock` files. Separate from `flutter`, so that a lock it " +
          "refuses leaves the toolchains working, and with them `bazel run " +
          "@rules_flutter//flutter/pub`, which fixes the lock.",
)
