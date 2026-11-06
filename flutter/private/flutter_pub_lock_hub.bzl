"""Augmented hub repo rule for Flutter pub lock files.

Mirrors `rules_dart//dart/pub:pub_lock_hub.bzl`'s top-level alias
structure (`@<hub>//:pkg` → the package's library: `@<hub>_lib__<pkg>//:<pkg>`
for a built package, whose dependency cycle is built as one target, and
`@<hub>__<pkg>//:<pkg>` for the lock's other entries) and additionally
emits an `android/BUILD.bazel` with the Maven data an Android app checks the
plugins it links against.

`flutter_android_app` links the Android libraries of the plugins its
application depends on (`flutter_android_plugin_libs`), not those of every
package of the lock, and passes that rule `@<hub>//android:maven_requirements`.

A lock with `flutter_test` also gets a `goldens/BUILD.bazel`: the golden service
the integration tests of the hub share (`flutter/private/goldens/service.dart`,
a `flutter_test` built against the hub's `flutter_test`).

Loaded lazily — Bazel only parses `android/BUILD.bazel` when an Android build
asks for it. Non-Android workspaces (mac-only, web-only) don't pay the
`@rules_android` / `@rules_kotlin` cost.

This rule is the rules_flutter sibling of rules_dart's `pub_lock_hub`;
the two never run for the same hub. `flutter.pub()` always invokes
this one. `pub.pub()` (in non-Flutter modules) keeps using
`pub_lock_hub`.
"""

load("//flutter/private:flutter_pub_index.bzl", "library_repo", "source_repo")

def _flutter_pub_lock_hub_impl(ctx):
    spoke_prefix = ctx.attr.spoke_prefix if ctx.attr.spoke_prefix else ctx.attr.hub_name

    # Top-level aliases — same shape as rules_dart's pub_lock_hub.
    built = {pkg: True for pkg in ctx.attr.built_packages}
    aliases = []
    for pkg in ctx.attr.packages:
        aliases.append("""\
alias(
    name = "{pkg}",
    actual = "@{repo}//:{pkg}",
    visibility = ["//visibility:public"],
)""".format(
            pkg = pkg,
            repo = library_repo(spoke_prefix, pkg) if pkg in built else source_repo(spoke_prefix, pkg),
        ))
    ctx.file("BUILD.bazel", "\n\n".join(aliases) + "\n")

    if "flutter_test" in ctx.attr.packages:
        ctx.file(
            "goldens/BUILD.bazel",
            """\
load("{flutter_test_bzl}", "flutter_test")

# Compares the goldens of an integration test for its host runner, which has no
# `dart:ui`: started by the runner, told which test it compares for. It needs
# only `package:flutter_test`, so the integration tests of this hub share it.
flutter_test(
    name = "service",
    main = "{service}",
    srcs = ["{comparator}"],
    package_name = "rules_flutter_golden_service",
    deps = ["//:flutter_test"],
    tags = ["manual"],
    testonly = True,
    visibility = ["//visibility:public"],
)
""".format(
                flutter_test_bzl = str(Label("//flutter/private:flutter_test.bzl")),
                service = str(Label("//flutter/private/goldens:service.dart")),
                comparator = str(Label("//flutter/private/goldens:comparator.dart")),
            ),
        )

    ctx.file(
        "android/BUILD.bazel",
        """\
# What an Android app's `flutter_android_plugin_libs` checks the plugins it
# links against: every plugin's Maven requirements and what
# @rules_android_maven resolved.
alias(
    name = "maven_requirements",
    actual = "@{hub}-android_maven//:requirements",
    visibility = ["//visibility:public"],
)

# Prints every Maven artifact the lock's Android plugins declare, ready to
# paste into the root module's maven.install(name = "rules_android_maven").
alias(
    name = "maven_artifacts",
    actual = "@{hub}-android_maven//:maven_artifacts",
    visibility = ["//visibility:public"],
)
""".format(hub = ctx.attr.hub_name),
    )

flutter_pub_lock_hub = repository_rule(
    implementation = _flutter_pub_lock_hub_impl,
    attrs = {
        "hub_name": attr.string(
            doc = "The apparent name of this hub repo (for constructing spoke labels).",
            mandatory = True,
        ),
        "spoke_prefix": attr.string(
            doc = "Prefix for spoke repo names. If empty, defaults to hub_name.",
            default = "",
        ),
        "packages": attr.string_list(
            doc = "All package names of the lock to create aliases for.",
            mandatory = True,
        ),
        "built_packages": attr.string_list(
            doc = "The built ones among `packages` (hosted, and Flutter SDK packages built from the Flutter source): their alias is their library repository's, the others' their one repository's.",
            default = [],
        ),
    },
    doc = "Creates a Flutter pub hub repo with both the standard top-level package aliases " +
          "and an `android/` package: the Maven requirements the `flutter_android_app` Tier-1 " +
          "macro's `flutter_android_plugin_libs` checks the plugins an app links against, " +
          "and the `maven_artifacts` report; with `flutter_test`, a `goldens/` package: the " +
          "golden service the integration test macros share.",
)
