"""Extensions for bzlmod.

Installs a Flutter toolchain and optionally resolves pub dependencies
(including Flutter SDK packages like package:flutter).

Every module can define a toolchain version under the default name, "flutter".
The latest of those versions will be selected (the rest discarded),
and will always be registered by rules_flutter.

Additionally, the root module can define arbitrarily many more toolchain versions under different
names (the latest version will be picked for each name) and can register them as it sees fit,
effectively overriding the default named toolchain due to toolchain resolution precedence.
"""

load("@rules_dart//dart/ext:registry.bzl", "curated_code_assets")
load("@rules_dart//dart/pub:pub_lock_package.bzl", "check_pub_archive_sha256")
load("@rules_dart//dart/pub:yaml_parser.bzl", "parse_pubspec_lock")
load("//flutter/private:android_plugin_maven.bzl", "MAVEN_DEPS_FILE", "flutter_android_maven")
load("//flutter/private:flutter_chrome_for_testing.bzl", "flutter_chrome_for_testing")
load("//flutter/private:flutter_framework_package.bzl", "flutter_framework_package")
load("//flutter/private:flutter_gen_l10n_repo.bzl", "flutter_gen_l10n_repo")
load("//flutter/private:flutter_linux_runtime_repo.bzl", "flutter_linux_runtime_repo")
load("//flutter/private:flutter_pub_index.bzl", "flutter_pub_index", "index_repo", "library_repo", "source_repo")
load("//flutter/private:flutter_pub_library_repo.bzl", "flutter_pub_library_repo")
load("//flutter/private:flutter_pub_lock_hub.bzl", "flutter_pub_lock_hub")
load("//flutter/private:flutter_pub_package.bzl", "flutter_pub_package")
load("//flutter/private:flutter_resolved_package.bzl", "flutter_resolved_package")
load("//flutter/private:flutter_unsupported_package.bzl", "flutter_unsupported_package", "unsupported_package_message")
load("//flutter/private:linux_runtime_pins.bzl", "LINUX_RUNTIME")
load("//flutter/private:lock_entry_kind.bzl", "ENGINE_PROVIDED", "FLUTTER_FRAMEWORK", "FLUTTER_SOURCE", "HOSTED", "lock_entry_kind")
load("//flutter/private:pub_lock_sdks.bzl", "parse_lock_sdk_constraints", "version_below_lower_bound")
load("//flutter/private:pub_resolve.bzl", "resolve_errors")
load("//flutter/private:versions.bzl", "CHROME_FOR_TESTING", "flutter_source_sha256")
load(":repositories.bzl", "flutter_register_toolchains")

_DEFAULT_NAME = "flutter"

def _parse_version(v):
    """Splits a version string into a list of ints for comparison."""
    parts = v.split(".")
    result = []
    for x in parts:
        if not x.isdigit():
            # Parenthesised before `.format`: without them it binds to the last
            # fragment of the concatenation alone, so this printed a literal
            # `{}` for the version and then substituted the version into the
            # slot meant for the offending component — which was never shown.
            fail(
                (
                    "Invalid Flutter version '{}': expected numeric " +
                    "components separated by dots (e.g. '3.41.2'), but got " +
                    "non-numeric component '{}'."
                ).format(v, x),
            )
        result.append(int(x))
    return result

flutter_toolchain = tag_class(attrs = {
    "name": attr.string(doc = """\
Base name for generated repositories, allowing more than one Flutter toolchain to be registered.
Overriding the default is only permitted in the root module.
""", default = _DEFAULT_NAME),
    "flutter_version": attr.string(doc = "Version of the Flutter SDK.", mandatory = True),
})

_flutter_pub = tag_class(attrs = {
    "name": attr.string(
        doc = "Repository name for the resolved packages hub.",
        mandatory = True,
    ),
    "lock": attr.label(
        doc = "The pubspec.lock file to parse.",
        mandatory = True,
        allow_single_file = True,
    ),
    "resolve": attr.string_keyed_label_dict(
        doc = """\
Lock packages, each mapped to the target that builds it: a `flutter_library`,
`flutter_plugin` or `dart_library` whose `package_name` is the pub package's
name (a target that declares another name fails analysis, naming both). The
hub's `@<name>//:<package>` is that target, and a hosted package that depends
on the package gets it too.

Every `path` package of the lock must be mapped, to a target in the Bazel
package at the path the lock gives, relative to the lock, in this repository.
A hosted, git or sdk package may be mapped, to replace it for the whole graph
with a fork or a patched copy, from any repository; the locked package is then
not fetched, and its version is not checked. Naming a package the lock does
not list is an error.

```starlark
flutter.pub(
    name = "deps",
    lock = "//apps/greeter:pubspec.lock",
    resolve = {
        "greeting": "//packages/greeting",
        "tagline": "//packages/tagline:tagline_lib",
        "intl": "//third_party/intl",  # replaces the locked hosted package
    },
)
```
""",
        default = {},
    ),
    "ignore_hooks": attr.string_list(
        doc = "Pub package names whose `hook/build.dart` is knowingly " +
              "irrelevant to this build (its native code is never reached). " +
              "Suppresses the unreplaced-hook error for them. This is a " +
              "declaration you make deliberately; it is never a default.",
        default = [],
    ),
})

_flutter_plugin_overlays = tag_class(attrs = {
    "roots": attr.label_list(
        doc = "BUILD.bazel anchors for user-supplied overlay trees. Each " +
              "label points at an `ext/BUILD.bazel` (or equivalent) that " +
              "anchors a directory tree of `<package>/<version>/BUILD.bazel.tpl` " +
              "overrides. flutter_pub_package walks user roots first, then the " +
              "bundled `@rules_flutter//ext:BUILD.bazel`. A template declares " +
              "its language version and its dependencies by placeholder " +
              "(`{LANGUAGE_VERSION}`, `{DEPS}`), never by hand; see " +
              "docs/TESTING.md \"Native Assets overlay authoring\".",
        allow_files = True,
        default = [],
    ),
})

def _toolchain_extension(module_ctx):
    registrations = {}
    selected_versions = {}
    for mod in module_ctx.modules:
        for toolchain in mod.tags.toolchain:
            if toolchain.name != _DEFAULT_NAME and not mod.is_root:
                fail("""\
                Only the root module may override the default name for the Flutter toolchain.
                This prevents conflicting registrations in the global namespace of external repos.
                """)
            if toolchain.name not in registrations.keys():
                registrations[toolchain.name] = []
            registrations[toolchain.name].append(toolchain.flutter_version)
    for name, versions in registrations.items():
        unique_versions = {v: True for v in versions}.keys()
        if len(unique_versions) > 1:
            selected = versions[0]
            for v in versions[1:]:
                if _parse_version(v) > _parse_version(selected):
                    selected = v

            # buildifier: disable=print
            print("NOTE: Flutter toolchain {} has multiple versions {}, selected {}".format(name, list(unique_versions), selected))
        else:
            selected = versions[0]

        flutter_register_toolchains(
            name = name,
            flutter_version = selected,
        )

        # The gen-l10n generator, carved out of the same release's
        # flutter_tools. Declared unconditionally because bzlmod repositories
        # are lazy: a workspace that never references `@{name}_gen_l10n` never
        # fetches the tarball, the same way gen_snapshot repos work.
        flutter_gen_l10n_repo(
            name = name + "_gen_l10n",
            flutter_version = selected,
            sha256 = flutter_source_sha256(selected),
            hub_name = "gen_l10n_deps",
        )
        selected_versions[name] = selected

    # The browser web integration tests run in, one repository per host it is
    # built for. Declared unconditionally: a repository is fetched only when
    # something references it, and only the `chrome` runner of
    # `//flutter/integration_test` does, selecting the host's own.
    for platform, sha256 in CHROME_FOR_TESTING.sha256.items():
        flutter_chrome_for_testing(
            name = "flutter_chrome_for_testing_" + platform.replace("-", "_"),
            platform = platform,
            version = CHROME_FOR_TESTING.version,
            sha256 = sha256,
        )

    # The X server, GTK, Mesa and libraries a Linux integration test runs with,
    # one repository per architecture, fetched only when a Linux runner of
    # `//flutter/integration_test` selects the host's.
    for arch, packages in LINUX_RUNTIME.packages.items():
        flutter_linux_runtime_repo(
            name = "flutter_linux_runtime_" + arch,
            arch = arch,
            snapshot = LINUX_RUNTIME.snapshot,
            debs = {path: sha256 for _, _, path, sha256 in packages},
            floor = LINUX_RUNTIME.floor,
        )

    # Collect user-supplied overlay roots from `flutter.plugin_overlays(...)`
    # tags. They're applied to every flutter_pub_package invocation in
    # the order seen, then the bundled `@rules_flutter//ext` root. This
    # makes any pub plugin user-fixable locally — drop a
    # `<workspace>/plugin_overlays/<pkg>/<major>/BUILD.bazel.tpl` and
    # register the root in MODULE.bazel; the next build picks it up.
    user_overlay_roots = []
    for mod in module_ctx.modules:
        for tag in mod.tags.plugin_overlays:
            user_overlay_roots.extend(tag.roots)

    # Handle flutter.pub() tags — resolve pubspec.lock with Flutter SDK support.
    for mod in module_ctx.modules:
        for pub_tag in mod.tags.pub:
            hub_name = pub_tag.name
            lock_content = module_ctx.read(pub_tag.lock)
            lock_pkgs = parse_pubspec_lock(lock_content)

            # Before anything else is checked, so a wrong map is not masked.
            resolve_problems = resolve_errors(pub_tag.lock, hub_name, lock_pkgs, pub_tag.resolve)
            if resolve_problems:
                fail("\n\n".join(resolve_problems))
            ignore_hooks = {pkg_name: True for pkg_name in pub_tag.ignore_hooks}

            # Determine the Flutter version to use for SDK packages.
            # Use the default toolchain version; fail if no toolchain is registered.
            flutter_version = selected_versions.get(_DEFAULT_NAME)
            if not flutter_version:
                fail("flutter.pub() requires a flutter.toolchain() to be registered.")

            # This is the one moment where the SDK that resolved the lock and
            # the SDK that will consume it are both in view. Pub does not
            # record the resolver's version, but it does record the floor its
            # solution needs; a toolchain below that floor cannot compile what
            # the lock pins.
            flutter_constraint = parse_lock_sdk_constraints(lock_content).get("flutter", "")
            if flutter_constraint and version_below_lower_bound(flutter_version, flutter_constraint):
                fail((
                    "{lock} was resolved against a newer Flutter than this " +
                    "build pins: the lock requires flutter {constraint}, and " +
                    "flutter.toolchain() pins {version}.\n" +
                    "Either raise flutter.toolchain(flutter_version = ...) or " +
                    "re-resolve with the pinned toolchain:\n" +
                    "    bazel run @rules_flutter//flutter:pub -- upgrade"
                ).format(
                    lock = str(pub_tag.lock),
                    constraint = flutter_constraint,
                    version = flutter_version,
                ))

            # Classify packages by who builds them (`lock_entry_kind`).
            built = {}  # hosted and Flutter-source packages: a source and a library repository
            hosted = {}
            flutter_source = {}
            framework = {}
            resolved = {}  # mapped to a workspace target: one repository, whatever the lock says
            unsupported = {}
            all_package_names = []
            for name, info in lock_pkgs.items():
                source = info.get("source", "unknown")
                kind = lock_entry_kind(name, source)
                if name in pub_tag.resolve:
                    all_package_names.append(name)
                    resolved[name] = info
                    continue
                if kind == ENGINE_PROVIDED:
                    continue
                all_package_names.append(name)
                if kind == HOSTED:
                    hosted[name] = info
                    built[name] = info
                elif kind == FLUTTER_SOURCE:
                    flutter_source[name] = info
                    built[name] = info
                elif kind == FLUTTER_FRAMEWORK:
                    framework[name] = info
                else:
                    # A git package, or a source rules_flutter has never heard
                    # of (a `path` package is always mapped, above). The hub
                    # still loads, so an app that only lists it builds. Its
                    # target fails when something depends on it.
                    unsupported[name] = unsupported_package_message(
                        lock = str(pub_tag.lock),
                        package = name,
                        source = source,
                    )

            # What every repository of the hub plans against, stated once
            # rather than on each of them: the lock records each repository's
            # attributes, so the package list on every repository would grow
            # it by the square of the package count.
            flutter_pub_index(
                name = index_repo(hub_name),
                built = sorted(built.keys()),
                other = sorted([n for n in all_package_names if n not in built]),
            )

            for name, message in unsupported.items():
                flutter_unsupported_package(
                    name = source_repo(hub_name, name),
                    package_name = name,
                    message = message,
                )

            # A mapped package is one repository, the workspace target the user
            # mapped it to, so it sits among the index's `other` packages
            # whatever the lock lists it from: a hosted package that depends on
            # it reaches the target, the hub's label for it is the same
            # repository, and the locked package is not fetched.
            for name in resolved:
                flutter_resolved_package(
                    name = source_repo(hub_name, name),
                    package_name = name,
                    actual = str(pub_tag.resolve[name]),
                    lock = str(pub_tag.lock),
                )

            # Create a source repo and a library repo for each built package
            # (a hosted one, below, or a Flutter SDK one, after it).
            # flutter.pub() routes every hosted package through
            # flutter_pub_package — the `flutter pub get` analog — so plugins
            # surface their `flutter.plugin.platforms` metadata via
            # FlutterInfo. Pure-Dart packages are still rules_dart's own
            # member kind; the rule branches internally on whether the
            # pubspec declares anything of Flutter's. The library repo is the
            # package's dependency cycle (usually just itself) as one target:
            # pub allows packages to depend on each other, Bazel does not.
            # Non-Flutter modules using `pub.pub()` keep using rules_dart's
            # `pub_lock_package` directly.
            for name, info in hosted.items():
                desc = info.get("description", {})
                version = info.get("version", "")
                sha256 = desc.get("sha256", "") if type(desc) == "dict" else ""

                # An empty digest means "do not check" to Bazel's downloader,
                # so a lock entry without one is refused here, where the lock
                # can be named, rather than fetched on trust.
                check_pub_archive_sha256(name, version, sha256, str(pub_tag.lock))
                flutter_pub_library_repo(
                    name = library_repo(hub_name, name),
                    package_name = name,
                    hub_name = hub_name,
                )
                flutter_pub_package(
                    name = source_repo(hub_name, name),
                    package_name = name,
                    version = version,
                    sha256 = sha256,
                    base_url = desc.get("url", "https://pub.dev") if type(desc) == "dict" else "https://pub.dev",
                    hub_name = hub_name,
                    overlay_roots = user_overlay_roots + ["@rules_flutter//ext:BUILD.bazel"],
                    # rules_dart's curated registry is the single source of
                    # truth for which pub package a Bazel-built native library
                    # stands in for, and at which versions. Consulting it here
                    # is what makes a Flutter app depending on, say, `drift`
                    # get `sqlite3`'s library without naming it: the asset
                    # lands on the package that owns it, so it propagates
                    # through the Dart graph exactly as pub's own would.
                    code_assets = curated_code_assets(name, version),
                    ignore_hook = name in ignore_hooks,
                )

            # Create the repos of the Flutter SDK packages. Each pins the same
            # framework source tarball, so the checksum is read once here for
            # all of them. `package:flutter` has a rule of its own (its shaders
            # are declared in no pubspec); every other `sdk: flutter` package
            # is built from `packages/<name>` of that source exactly as a
            # hosted package is built from its archive, `ext/` overlays
            # (keyed `<package>/0.0.0`) and library repository included.
            sdk_source_sha256 = flutter_source_sha256(flutter_version)
            for name in framework.keys():
                flutter_framework_package(
                    name = source_repo(hub_name, name),
                    flutter_version = flutter_version,
                    sha256 = sdk_source_sha256,
                    hub_name = hub_name,
                )
            for name, info in flutter_source.items():
                flutter_pub_library_repo(
                    name = library_repo(hub_name, name),
                    package_name = name,
                    hub_name = hub_name,
                )
                flutter_pub_package(
                    name = source_repo(hub_name, name),
                    package_name = name,
                    version = info.get("version", ""),
                    sha256 = sdk_source_sha256,
                    flutter_source_version = flutter_version,
                    hub_name = hub_name,
                    overlay_roots = user_overlay_roots + ["@rules_flutter//ext:BUILD.bazel"],
                )

            # The hub's Android Maven data: what every built spoke's Gradle
            # build declares, against what `@rules_android_maven` resolved. An
            # Android app's `flutter_android_plugin_libs` checks the part its
            # plugins need, and a spoke's `android/` package reads what
            # resolved, so only Android builds fetch it. The dash keeps its
            # name from any `<hub>__<pkg>` spoke.
            flutter_android_maven(
                name = hub_name + "-android_maven",
                hub_name = hub_name,
                spokes = [
                    "@{}//:{}".format(source_repo(hub_name, name), MAVEN_DEPS_FILE)
                    for name in sorted(built.keys())
                ],
            )

            # Create the hub repo with aliases for all packages and its
            # `android/` package, which hands an Android app the Maven data its
            # check reads. flutter.pub() always uses `flutter_pub_lock_hub`
            # (not rules_dart's plain `pub_lock_hub`) for that package.
            # Non-Flutter pub.pub() consumers keep using rules_dart's plain hub.
            flutter_pub_lock_hub(
                name = hub_name,
                hub_name = hub_name,
                packages = sorted(all_package_names),
                built_packages = sorted(built.keys()),
            )

    # Don't declare root_module_direct_deps: flutter_register_toolchains creates
    # many repos (iOS, Android, web, desktop, cross-compile per platform) and
    # each user workspace only needs a subset — a macOS-only app doesn't want
    # Android engine repos forced into its use_repo. Declaring a strict subset
    # makes `bazel mod tidy` strip out repos the user actually needs; declaring
    # the full set makes tidy force repos they don't. Letting users maintain
    # their own use_repo lists (rules_python does the same) is the right
    # tradeoff for an extension with this many optional outputs.
    return module_ctx.extension_metadata(reproducible = True)

flutter = module_extension(
    implementation = _toolchain_extension,
    tag_classes = {
        "toolchain": flutter_toolchain,
        "pub": _flutter_pub,
        "plugin_overlays": _flutter_plugin_overlays,
    },
    os_dependent = False,
    arch_dependent = False,
    doc = "Installs a Flutter SDK toolchain and optionally resolves pub dependencies including Flutter SDK packages.",
)
