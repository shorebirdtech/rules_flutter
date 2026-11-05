"""Spoke repository rule for the Flutter framework package (package:flutter).

Downloads the Flutter SDK source from GitHub and generates a flutter_library
target for the framework. Follows the same hub/spoke pattern as rules_dart's
pub_lock_package, so it integrates seamlessly into the same hub repo.

`package:flutter` is the one Flutter SDK package with a rule of its own. The
others (`flutter_test`, `integration_test`, ...) are built from the same source
tarball by `flutter_pub_package`, as a hosted package is built from its archive.
The framework cannot be: its shaders (`lib/src/material/shaders/*.frag`) are
declared in no pubspec (flutter_tools hardcodes them), so they reach the bundle
through `flutter_library.shaders`, not the pub-asset channel.

Like a pub spoke, this spoke declares the language version the package's own
`environment.sdk` implies, which is what pub writes for it too. Omitting it is
not neutral: `package_config.json` reads a missing `languageVersion` as the
current SDK's.
"""

load("@rules_dart//dart/pub:pub_lock_package.bzl", "derive_language_version")
load("@rules_dart//dart/pub:yaml_parser.bzl", "parse_pubspec_deps", "parse_pubspec_sdk_constraint")
load("//flutter/private:artifact_urls.bzl", "flutter_source_tarball_url")
load("//flutter/private:flutter_pub_index.bzl", "library_label", "read_index")
load("//flutter/private:pinned.bzl", "pinned")

_PACKAGE = "flutter"

def make_flutter_framework_build_content(deps, language_version):
    """Generate BUILD content for the framework spoke.

    The package uses flutter_library (not dart_library) so that its shader
    source files are propagated transitively via FlutterInfo.

    `lib/` is partitioned into `srcs` + `resources`, the same shape
    rules_dart's pub spokes use: everything under lib/ is addressable as
    `package:flutter/<path>` whatever its extension (package:flutter ships
    lib/analysis_options.yaml and lib/fix_data/*.yaml), so the non-Dart
    remainder rides `DartInfo.transitive_resources` rather than being
    dropped. The ink_sparkle .frag appears on both channels by design:
    `shaders` routes it through the impellerc compile into flutter_assets,
    `resources` keeps it a member of the staged package tree.

    Args:
        deps: Fully-qualified Bazel label strings for sibling spokes.
        language_version: Dart language version string (e.g. `"3.11"`), or
            `""` when no pubspec was read. An empty string reaches the
            generated target as `language_version = ""`, which is what makes
            the `languageVersion` key absent from `package_config.json`
            entries downstream.

    Returns:
        BUILD.bazel content as a string.
    """
    deps_block = ""
    if deps:
        dep_lines = ['        "{}",'.format(dep) for dep in deps]
        deps_block = "    deps = [\n{}\n    ],\n".format("\n".join(dep_lines))

    return """\
load("@rules_flutter//flutter:defs.bzl", "flutter_library")

flutter_library(
    name = "{name}",
    srcs = glob(["lib/**/*.dart"]),
    resources = glob(
        ["lib/**"],
        exclude = ["lib/**/*.dart"],
        allow_empty = True,
    ),
    shaders = glob(["lib/src/material/shaders/*.frag"]),
{deps}    package_name = "{name}",
    language_version = "{language_version}",
    web_compiler_independent = True,
    visibility = ["//visibility:public"],
)
""".format(
        name = _PACKAGE,
        deps = deps_block,
        language_version = language_version,
    )

def _flutter_framework_package_impl(repository_ctx):
    flutter_version = repository_ctx.attr.flutter_version

    # Download Flutter SDK source, extracting only the framework package.
    #
    # This same tarball is requested once per SDK package in the lock (by
    # flutter_pub_package), and again by flutter_gen_l10n_repo and
    # flutter_dev_root_repo. Because every one of those fetches is pinned to
    # the same checksum, Bazel's content-addressed repository cache serves
    # them all from a single download; an unpinned fetch could not be
    # deduplicated that way.
    repository_ctx.download_and_extract(
        url = flutter_source_tarball_url(flutter_version),
        sha256 = pinned(flutter_version + ".tar.gz", repository_ctx.attr.sha256),
        stripPrefix = "flutter-{version}/packages/{pkg}".format(
            version = flutter_version,
            pkg = _PACKAGE,
        ),
    )

    # Discover deps and the language version from the downloaded pubspec.yaml,
    # filtering deps to packages available in the lock file (same pattern as
    # pub_lock_package). No pubspec means no constraint was read, so the
    # language version stays empty rather than taking `derive_language_version`'s
    # missing-constraint default — that default is pub's answer for a pubspec
    # that *has* no `environment.sdk`, not for a package we never inspected.
    index = read_index(repository_ctx, repository_ctx.attr.hub_name)
    bazel_deps = []
    language_version = ""
    pubspec_path = repository_ctx.path("pubspec.yaml")
    if pubspec_path.exists:
        content = repository_ctx.read(pubspec_path)
        all_deps = parse_pubspec_deps(content)
        bazel_deps = sorted([d for d in all_deps if d in index.built or d in index.other])
        language_version = derive_language_version(
            parse_pubspec_sdk_constraint(content),
        )

    # Build dep labels pointing to the libraries of the packages' repos.
    dep_labels = [library_label(repository_ctx.attr.hub_name, index, dep) for dep in bazel_deps]

    repository_ctx.file("BUILD.bazel", make_flutter_framework_build_content(
        deps = dep_labels,
        language_version = language_version,
    ))

    # Emit an empty `android/BUILD.bazel` so the hub's aggregator
    # (`@<hub>//android:all_android_plugin_libs`) can depend on every
    # spoke uniformly, including `package:flutter`. Loaded lazily — only
    # parsed when something queries `@<spoke>//android:lib`, so non-Android
    # workspaces never pay the `@rules_kotlin` cost.
    repository_ctx.file("android/BUILD.bazel", """\
load("@rules_kotlin//kotlin:android.bzl", "kt_android_library")

kt_android_library(
    name = "lib",
    srcs = [],
    visibility = ["//visibility:public"],
)
""")

flutter_framework_package = repository_rule(
    implementation = _flutter_framework_package_impl,
    doc = "Downloads package:flutter from the pinned Flutter source and generates its flutter_library target.",
    attrs = {
        "flutter_version": attr.string(
            doc = "Flutter SDK version tag on GitHub.",
            mandatory = True,
        ),
        "sha256": attr.string(
            doc = "Expected SHA-256 of the Flutter SDK source tarball. " +
                  "Guaranteed non-empty by the caller: extensions.bzl reads " +
                  "it through `flutter_source_sha256()`, which refuses a " +
                  "version with no recorded checksum.",
            mandatory = True,
        ),
        "hub_name": attr.string(
            doc = "Name of the hub repo: the prefix of the hub's repositories, whose index lists the lock's packages.",
            mandatory = True,
        ),
    },
)
