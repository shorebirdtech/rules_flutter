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
load("@rules_dart//dart/pub:pub_lock_package.bzl", "check_pub_archive_sha256", "check_pub_git_resolved_ref", "is_relative_git_url")
load("@rules_dart//dart/pub:yaml_parser.bzl", "parse_pubspec_lock")
load("//flutter/private:android_plugin_maven.bzl", "MAVEN_DEPS_FILE", "flutter_android_maven")
load("//flutter/private:flutter_chrome_for_testing.bzl", "flutter_chrome_for_testing")
load("//flutter/private:flutter_dev_root_repo.bzl", "flutter_dev_root_repo")
load("//flutter/private:flutter_face_repo.bzl", "MACOS_ENGINE_EXTRA", "MACOS_ENGINE_TARGETS", "flutter_face_repo")
load("//flutter/private:flutter_framework_package.bzl", "flutter_framework_package")
load("//flutter/private:flutter_gen_l10n_repo.bzl", "flutter_gen_l10n_repo")
load("//flutter/private:flutter_linux_runtime_repo.bzl", "flutter_linux_runtime_repo")
load("//flutter/private:flutter_material_fonts_repo.bzl", "flutter_material_fonts_repo")
load("//flutter/private:flutter_pub_goldens.bzl", "flutter_pub_goldens")
load("//flutter/private:flutter_pub_index.bzl", "ANDROID_MAVEN_REPO", "GOLDENS_REPO", "INDEX_REPO", "SPOKE_PREFIX", "flutter_pub_index", "index_repo", "library_repo", "sdk_prefix", "source_repo")
load("//flutter/private:flutter_pub_library_repo.bzl", "flutter_pub_library_repo")
load("//flutter/private:flutter_pub_lock_hub.bzl", "flutter_pub_lock_hub")
load("//flutter/private:flutter_pub_package.bzl", "flutter_pub_package")
load("//flutter/private:flutter_resolved_package.bzl", "flutter_resolved_package")
load("//flutter/private:flutter_sdk_toolchains_repo.bzl", "flutter_sdk_toolchains_repo")
load("//flutter/private:flutter_unsupported_package.bzl", "flutter_unsupported_package", "unsupported_package_message")
load("//flutter/private:linux_runtime_pins.bzl", "LINUX_RUNTIME")
load("//flutter/private:lock_entry_kind.bzl", "ENGINE_PROVIDED", "FLUTTER_FRAMEWORK", "FLUTTER_SOURCE", "GIT", "HOSTED", "UNSUPPORTED", "lock_entry_kind")
load("//flutter/private:pub_lock_sdks.bzl", "parse_lock_sdk_constraints")
load("//flutter/private:pub_reconcile.bzl", "reconcile_package", "sdk_pin_errors", "unsupported_locks")
load("//flutter/private:pub_resolve.bzl", "resolve_errors", "resolved_targets")
load("//flutter/private:toolchain_version.bzl", "select_flutter_version")
load("//flutter/private:toolchains_repo.bzl", "flutter_toolchains_repo", "sdk_repo_name")
load("//flutter/private:versions.bzl", "CHROME_FOR_TESTING", "FLUTTER_VERSIONS", "flutter_sdk_exact_pins", "flutter_source_sha256")
load(":repositories.bzl", "flutter_register_toolchains")

_DEFAULT_NAME = "flutter"

flutter_toolchain = tag_class(attrs = {
    "name": attr.string(doc = """\
The name of the SDK this declares. `flutter` is the stock release (or the SDK a
team always builds against, given sources); any other name is another SDK, which
a build chooses with `--@rules_flutter//flutter:sdk=<name>`. A name other than
the default is only permitted in the root module.
""", default = _DEFAULT_NAME),
    "flutter_version": attr.string(doc = """\
Version of the Flutter release that supplies whichever half of the SDK is not
given as `framework` or `engine`. An error when both are given, and required
when either is not.
"""),
    "framework": attr.label(doc = """\
A repository whose root is a flutter/flutter tree and which holds
`flutter_framework.json` (the framework contract): the SDK's packages come from
it instead of the release. Root module only.
"""),
    "engine": attr.label(doc = """\
A repository whose slices are the engine contract's labels (see
`@rules_flutter//flutter:engine.bzl`): the SDK's engine comes from it instead of
the release. Root module only.
"""),
    "material_fonts_sha256": attr.string(doc = """\
The checksum of the Material fonts archive a non-release framework expects, when
its `bin/internal/material_fonts.version` names a revision no pinned release does.
"""),
})

_flutter_pub = tag_class(attrs = {
    "name": attr.string(
        doc = """\
Repository name for the resolved packages hub: `@<name>//:<package>` for each
package of the lock. Several tags may share a name, in this or other modules;
the hub then holds the packages of all their locks, each aliased once.

Every package is one repository for the whole build, however many hubs list it,
so a name starting with `flutter_pub` is reserved. The locks that list a package
must agree on it: the same source and, for a hosted package, the same version and
digest (for a git package, the same commit).
""",
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
name (a target that declares another name fails analysis, naming both). Every
hub's `@<hub>//:<package>` for it is that target, and a hosted package that
depends on the package gets it too, for the whole build: another lock's entry
for the package is not fetched, and a package mapped to different targets by two
tags fails.

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
    "on_version_conflict": attr.string(
        doc = """\
What to do when another `flutter.pub` lock brings a higher version of a package
this lock lists. A build has one version of each package, the highest any lock
records, and nothing is built below the version its lock records.

`"error"` (the default) fails when the module is read, naming both locks and the
fix (`bazel run @rules_flutter//flutter:pub -- upgrade <package>` in this lock's
directory). `"upgrade"` accepts the higher version: this lock's packages are
built at it. Use it for a lock whose constraints do not allow the version the
other brings, or for a tool's own lock, which must not stop a consumer.

A lock that lists the package from another source, registry or digest, or at
another git commit, always fails.
""",
        default = "error",
        values = ["error", "upgrade"],
    ),
    "ignore_hooks": attr.string_list(
        doc = "Pub package names whose `hook/build.dart` is knowingly " +
              "irrelevant to this build (its native code is never reached). " +
              "Suppresses the unreplaced-hook error for them, for the whole " +
              "build: the names of every tag are one set. This is a " +
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

def _declared_sdks(module_ctx):
    """The SDKs the modules declare: a struct for each, by name."""
    # The root module chooses each toolchain's Flutter version, as it chooses
    # every toolchain: its own tag wins. A name the root does not declare takes
    # the highest version the other modules ask for.
    tags = {}
    root_versions = {}
    for mod in module_ctx.modules:
        for toolchain in mod.tags.toolchain:
            if toolchain.name != _DEFAULT_NAME and not mod.is_root:
                fail("""\
                Only the root module may override the default name for the Flutter toolchain.
                This prevents conflicting registrations in the global namespace of external repos.
                """)
            if mod.is_root and toolchain.flutter_version:
                if toolchain.name in root_versions and root_versions[toolchain.name] != toolchain.flutter_version:
                    fail("The root module declares the Flutter toolchain {} twice, with versions {} and {}.".format(
                        toolchain.name,
                        root_versions[toolchain.name],
                        toolchain.flutter_version,
                    ))
                root_versions[toolchain.name] = toolchain.flutter_version
            if (toolchain.framework or toolchain.engine) and not mod.is_root:
                fail((
                    "flutter.toolchain(name = \"{}\") in module {} gives a framework or an engine. " +
                    "Only the root module may: a library module must not impose a fork on its dependents."
                ).format(toolchain.name, mod.name))
            tags.setdefault(toolchain.name, []).append(toolchain)

    sdks = {}
    for name, name_tags in tags.items():
        versions = [t.flutter_version for t in name_tags if t.flutter_version]
        frameworks = {str(t.framework): t.framework for t in name_tags if t.framework}
        engines = {str(t.engine): t.engine for t in name_tags if t.engine}
        if len(frameworks) > 1 or len(engines) > 1:
            fail("flutter.toolchain(name = \"{}\") is declared with more than one framework or engine.".format(name))
        framework = frameworks.values()[0] if frameworks else None
        engine = engines.values()[0] if engines else None
        if framework and engine and versions:
            fail((
                "flutter.toolchain(name = \"{}\") gives a framework and an engine, so its " +
                "flutter_version = \"{}\" would be unused. Drop it."
            ).format(name, versions[0]))
        if not (framework and engine) and not versions:
            fail((
                "flutter.toolchain(name = \"{}\") needs flutter_version: the release that " +
                "supplies the half of the SDK that is not given."
            ).format(name))
        selected = select_flutter_version(root_versions.get(name), versions) if versions else None
        fonts_sha256 = [t.material_fonts_sha256 for t in name_tags if t.material_fonts_sha256]
        sdks[name] = struct(
            name = name,
            version = selected,
            framework = framework,
            engine = engine,
            material_fonts_sha256 = fonts_sha256[0] if fonts_sha256 else "",
        )
    if _DEFAULT_NAME not in sdks:
        fail("A flutter.toolchain() is required: the default SDK, named \"{}\".".format(_DEFAULT_NAME))
    return sdks

def _label_prefix(label):
    """A label's repository, as a prefix any repository can name it by."""
    return "@@" + label.repo_name

def _framework_json(framework):
    """The label of `flutter_framework.json` in a framework source."""
    return Label("@@{}//:flutter_framework.json".format(framework.repo_name))

def _register_sdk(sdk):
    """Declares the repositories of one SDK; returns the label prefix of its engine source."""
    name = sdk.name
    if sdk.engine == None:
        # The release engine, with the artifact repositories it is made of.
        flutter_register_toolchains(
            name = name,
            flutter_version = sdk.version,
            framework_json = str(_framework_json(sdk.framework)) if sdk.framework else "",
        )
        return "@{}_stock_engine".format(name)

    # An engine of the root module's choosing: the toolchains are written
    # against its slices. The Material fonts come with the framework.
    version_meta = FLUTTER_VERSIONS[sdk.version] if sdk.version else None
    fonts = name + "_material_fonts"
    flutter_material_fonts_repo(
        name = fonts,
        flutter_version = sdk.version or "",
        framework_json = _framework_json(sdk.framework) if sdk.framework else None,
        sha256 = sdk.material_fonts_sha256,
    )
    flutter_sdk_toolchains_repo(
        name = sdk_repo_name(name),
        engine = _label_prefix(sdk.engine),
        sdk = name,
        version = sdk.version or "",
        engine_revision = version_meta.engine_revision if version_meta else "",
        material_fonts = "@{}//:material-fonts/MaterialIcons-Regular.otf".format(fonts),
        sysroot_prefix = _DEFAULT_NAME,
        framework_json = str(_framework_json(sdk.framework)) if sdk.framework else "",
    )
    return _label_prefix(sdk.engine)

def _framework_variants(sdks):
    """The prefix of the repositories that hold each SDK's framework packages, by SDK name.

    There is one repository per package for the whole build, so the default
    SDK's framework packages are the build's own (`SPOKE_PREFIX`). Another SDK
    shares them when it has the same framework (the same release, or the same
    framework source); otherwise its framework's packages are repositories of
    their own, one per package, named by `sdk_prefix` of the first SDK to have
    that framework and shared by every SDK that has it.
    """
    key_prefix = {_framework_key(sdks[_DEFAULT_NAME]): SPOKE_PREFIX}
    prefixes = {_DEFAULT_NAME: SPOKE_PREFIX}
    for name in sorted(sdks.keys()):
        key = _framework_key(sdks[name])
        if key not in key_prefix:
            key_prefix[key] = sdk_prefix(name)
        prefixes[name] = key_prefix[key]
    return prefixes

def _framework_representatives(sdks, prefixes):
    """For each prefix that holds framework packages, the first SDK whose they are."""
    reps = {}
    for name in sorted(sdks.keys(), key = lambda n: (n != _DEFAULT_NAME, n)):
        reps.setdefault(prefixes[name], sdks[name])
    return reps

def _framework_key(sdk):
    """What two SDKs must share for them to share their framework's packages."""
    if sdk.framework:
        return "source " + str(sdk.framework)
    return "release " + sdk.version

def _toolchain_extension(module_ctx):
    sdks = _declared_sdks(module_ctx)
    selected_versions = {}
    engine_prefixes = {}
    for name in sorted(sdks.keys()):
        sdk = sdks[name]
        engine_prefixes[name] = _register_sdk(sdk)

        # The SDK's dev root, for `@rules_flutter//flutter:pub`, and the
        # gen-l10n generator, carved out of its flutter_tools. Declared
        # unconditionally because bzlmod repositories are lazy: a workspace
        # that never references them never fetches the tarball.
        released = sdk.version and not sdk.framework
        flutter_dev_root_repo(
            name = name + "_dev_root_src",
            flutter_version = sdk.version or "",
            framework_json = _framework_json(sdk.framework) if sdk.framework else None,
            engine_revision = FLUTTER_VERSIONS[sdk.version].engine_revision if released else "",
            sha256 = flutter_source_sha256(sdk.version) if released else "",
        )
        flutter_gen_l10n_repo(
            name = name + "_gen_l10n_src",
            flutter_version = sdk.version or "",
            framework_json = _framework_json(sdk.framework) if sdk.framework else None,
            sha256 = flutter_source_sha256(sdk.version) if released else "",
        )
        selected_versions[name] = sdk.version

    # The repositories rules_flutter and its users name by fixed names, each
    # an alias into the selected SDK's own.
    flutter_face_repo(
        name = "flutter_macos_engine",
        sdks = engine_prefixes,
        targets = MACOS_ENGINE_TARGETS,
        extra = MACOS_ENGINE_EXTRA,
    )
    flutter_face_repo(
        name = "flutter_dev_root",
        sdks = {name: "@{}_dev_root_src".format(name) for name in sdks},
        targets = {"dev_root": "{prefix}//:dev_root", "version_manifest": "{prefix}//:version_manifest"},
    )
    flutter_face_repo(
        name = "flutter_gen_l10n",
        sdks = {name: "@{}_gen_l10n_src".format(name) for name in sdks},
        targets = {"gen_l10n": "{prefix}//:gen_l10n"},
    )

    # Every SDK's toolchains, chosen among by `--@rules_flutter//flutter:sdk`.
    flutter_toolchains_repo(
        name = "flutter_toolchains",
        sdks = sorted(sdks.keys()),
    )

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
    # Every tag of every module is read first, because a package is one
    # repository for the whole build: the locks that list it must agree on it
    # (`reconcile_package`), and a package any tag maps with `resolve` is that
    # target for every hub.
    tags = []
    for mod in module_ctx.modules:
        for pub_tag in mod.tags.pub:
            hub_name = pub_tag.name
            if hub_name == SPOKE_PREFIX or hub_name.startswith(SPOKE_PREFIX + "_") or hub_name.startswith(SPOKE_PREFIX + "-"):
                fail((
                    "flutter.pub(name = \"{}\") is reserved: hubs may not be named " +
                    "`{}` or start with `{}_` or `{}-`, which name the repositories " +
                    "shared by every hub."
                ).format(hub_name, SPOKE_PREFIX, SPOKE_PREFIX, SPOKE_PREFIX))
            lock_content = module_ctx.read(pub_tag.lock)
            lock_pkgs = parse_pubspec_lock(lock_content, str(pub_tag.lock))

            # Before anything else is checked, so a wrong map is not masked.
            resolve_problems = resolve_errors(pub_tag.lock, hub_name, lock_pkgs, pub_tag.resolve)
            if resolve_problems:
                fail("\n\n".join(resolve_problems))

            # The default SDK must exist; the lock is checked against each SDK's
            # framework by that SDK's own `package:flutter` spoke, which only
            # the SDK a build selects fetches.
            if not selected_versions.keys():
                fail("flutter.pub() requires a flutter.toolchain() to be registered.")
            flutter_constraint = parse_lock_sdk_constraints(lock_content).get("flutter", "")
            tags.append(struct(tag = pub_tag, packages = lock_pkgs, flutter_constraint = flutter_constraint))

    if tags:
        _declare_pub_packages(tags, sdks, user_overlay_roots)

    # Don't declare root_module_direct_deps: flutter_register_toolchains creates
    # many repos (iOS, Android, web, desktop, cross-compile per platform) and
    # each user workspace only needs a subset — a macOS-only app doesn't want
    # Android engine repos forced into its use_repo. Declaring a strict subset
    # makes `bazel mod tidy` strip out repos the user actually needs; declaring
    # the full set makes tidy force repos they don't. Letting users maintain
    # their own use_repo lists (rules_python does the same) is the right
    # tradeoff for an extension with this many optional outputs.
    return module_ctx.extension_metadata(reproducible = True)

def _hosted_entry(tag, name, info):
    desc = info.get("description", {})
    version = info.get("version", "")
    sha256 = desc.get("sha256", "") if type(desc) == "dict" else ""

    # An empty digest means "do not check" to Bazel's downloader, so a lock
    # entry without one is refused here, where the lock can be named, rather
    # than fetched on trust.
    check_pub_archive_sha256(name, version, sha256, str(tag.lock))
    return dict(
        kind = HOSTED,
        version = version,
        sha256 = sha256,
        url = desc.get("url", "https://pub.dev") if type(desc) == "dict" else "https://pub.dev",
    )

def _git_entry(tag, name, info):
    # A repository package is fetched at the commit the lock records, laid out
    # as pub lays it out (`fetch_pub_git`), and built as a hosted package is.
    # The lock is checked here, where it can be named: an entry that pins no
    # commit would be whatever the server holds on the day of the fetch.
    desc = info.get("description", {})
    version = info.get("version", "")
    url = desc.get("url", "") if type(desc) == "dict" else ""
    if not url:
        fail("The git package \"%s\" %s (in %s) has no `description.url`. Run `dart pub get` to rewrite the lock." % (name, version, tag.lock))
    resolved_ref = desc.get("resolved-ref", "")
    check_pub_git_resolved_ref(name, version, resolved_ref, str(tag.lock))
    return dict(
        kind = GIT,
        version = version,
        git_url = url,
        resolved_ref = resolved_ref,
        git_path = desc.get("path", "."),
        # A relative url is resolved against the lock's directory; any other
        # leaves the lock out, so editing the lock does not refetch the package.
        git_lock = str(tag.lock) if is_relative_git_url(url) else "",
        lock = tag.lock if is_relative_git_url(url) else None,
    )

def _hub_listing(hub_packages, package):
    """A hub that lists a package: its alias follows the selected SDK."""
    return [h for h in sorted(hub_packages.keys()) if package in hub_packages[h]][0]

def _declare_pub_packages(tags, sdks, user_overlay_roots):
    """Declares the repositories of every `flutter.pub()` tag: one per package.

    Args:
        tags: One `struct(tag, packages)` per tag, `packages` being its parsed lock.
        sdks: The declared SDKs, by name. The default SDK's framework builds the
            build's Flutter SDK packages; another SDK with another framework
            has packages of its own.
        user_overlay_roots: The overlay roots every package is built with.
    """
    ignore_hooks = {}
    for t in tags:
        for pkg_name in t.tag.ignore_hooks:
            ignore_hooks[pkg_name] = True

    mapped = resolved_targets([struct(lock = t.tag.lock, hub = t.tag.name, resolve = t.tag.resolve) for t in tags])
    if mapped.errors:
        fail("\n\n".join(mapped.errors))

    # Every lock's entry for each package, classified by who builds it
    # (`lock_entry_kind`). A mapped package is a workspace target whatever the
    # locks say, so it is not compared, fetched or version-checked.
    entries = {}
    hub_packages = {}
    for t in tags:
        tag = t.tag
        hub = hub_packages.setdefault(tag.name, {})
        for name, info in t.packages.items():
            source = info.get("source", "unknown")
            kind = lock_entry_kind(name, source)
            if name in mapped.targets:
                hub[name] = True
                continue
            if kind == ENGINE_PROVIDED:
                continue
            hub[name] = True
            if kind == HOSTED:
                fields = _hosted_entry(tag, name, info)
            elif kind == GIT:
                fields = _git_entry(tag, name, info)
            elif kind == FLUTTER_SOURCE:
                fields = dict(kind = kind, version = info.get("version", ""))
            elif kind == FLUTTER_FRAMEWORK:
                fields = dict(kind = kind)
            else:
                # A source rules_flutter has never heard of (a `path` package
                # is always mapped, above). The hub still loads, so an app that
                # only lists it builds. Its target fails when something
                # depends on it.
                fields = dict(kind = UNSUPPORTED, source = source)
            entries.setdefault(name, []).append(struct(
                hub = tag.name,
                lock_label = str(tag.lock),
                on_version_conflict = tag.on_version_conflict,
                **fields
            ))

    chosen = {}
    problems = []
    for name in sorted(entries.keys()):
        result = reconcile_package(name, entries[name])
        problems.extend(result.errors)
        chosen[name] = result.entry
    if problems:
        fail("\n\n".join(problems))

    # A release's packages are held to the pins it records; another framework
    # has its constraints checked against the locks when its spokes are fetched.
    default_sdk = sdks[_DEFAULT_NAME]
    if not default_sdk.framework:
        pin_problems = sdk_pin_errors(default_sdk.version, flutter_sdk_exact_pins(default_sdk.version), chosen, entries)
        if pin_problems:
            fail("\n\n".join(pin_problems))

    built = {name: e for name, e in chosen.items() if e.kind in [HOSTED, GIT, FLUTTER_SOURCE]}
    other = sorted(
        [name for name in chosen if name not in built] +
        [name for name in mapped.targets if name not in chosen],
    )

    # What every repository plans against, stated once rather than on each of
    # them: the lock records each repository's attributes, so the package list
    # on every repository would grow it by the square of the package count.
    #
    # The SDKs whose frameworks differ have Flutter SDK packages of their own
    # (a framework's packages are one repository each, shared by every SDK with
    # that framework): an index per prefix, over the same locks. Which package a
    # build uses is chosen by the hubs' aliases, on `--@rules_flutter//flutter:sdk`.
    sdk_packages = sorted([n for n, e in chosen.items() if e.kind in [FLUTTER_FRAMEWORK, FLUTTER_SOURCE]])
    prefixes = _framework_variants(sdks)
    multi = len({p: True for p in prefixes.values()}) > 1
    index_attrs = dict(
        built = sorted(built.keys()),
        other = other,
        sdk_packages = sdk_packages,
        versions = {n: e.version for n, e in chosen.items() if e.kind in [HOSTED, GIT] and e.version},
        locks = sorted({str(t.tag.lock): True for t in tags}.keys()),
        flutter_constraints = {str(t.tag.lock): t.flutter_constraint for t in tags if t.flutter_constraint},
    )
    flutter_pub_index(
        name = INDEX_REPO,
        via_hub = multi,
        sdk_hubs = {n: _hub_listing(hub_packages, n) for n in sdk_packages},
        **index_attrs
    )
    for prefix in sorted({p: True for p in prefixes.values() if p != SPOKE_PREFIX}.keys()):
        flutter_pub_index(
            name = index_repo(prefix),
            main_prefix = SPOKE_PREFIX,
            sdk_prefix = prefix,
            via_hub = False,
            **index_attrs
        )

    for name, target in mapped.targets.items():
        # A mapped package is one repository, the workspace target the user
        # mapped it to, so it sits among the index's `other` packages whatever
        # the locks list it from: a hosted package that depends on it reaches
        # the target, every hub's label for it is the same repository, and the
        # locked package is not fetched.
        flutter_resolved_package(
            name = source_repo(name),
            package_name = name,
            actual = target.target,
            lock = target.lock,
        )

    overlay_roots = user_overlay_roots + ["@rules_flutter//ext:BUILD.bazel"]

    # Create a source repo and a library repo for each built package. They are
    # all routed through flutter_pub_package — the `flutter pub get` analog —
    # so plugins surface their `flutter.plugin.platforms` metadata via
    # FlutterInfo. Pure-Dart packages are still rules_dart's own member kind;
    # the rule branches internally on whether the pubspec declares anything of
    # Flutter's. The library repo is the package's dependency cycle (usually
    # just itself) as one target: pub allows packages to depend on each other,
    # Bazel does not. Non-Flutter modules using `pub.pub()` keep using
    # rules_dart's `pub_lock_package` directly.
    #
    # Each Flutter SDK package other than `package:flutter` is built from
    # `packages/<name>` of the one pinned Flutter source exactly as a hosted
    # package is built from its archive, `ext/` overlays (keyed
    # `<package>/0.0.0`) and library repository included. `package:flutter` has
    # a rule of its own (its shaders are declared in no pubspec).
    reps = _framework_representatives(sdks, prefixes)
    for name, e in sorted(chosen.items()):
        if e.kind == UNSUPPORTED:
            flutter_unsupported_package(
                name = source_repo(name),
                package_name = name,
                message = unsupported_package_message(
                    lock = unsupported_locks(entries[name]),
                    package = name,
                    source = e.source,
                ),
            )
        elif e.kind == FLUTTER_FRAMEWORK:
            for prefix, sdk in reps.items():
                flutter_framework_package(
                    name = source_repo(name, prefix),
                    flutter_version = sdk.version or "",
                    framework_json = _framework_json(sdk.framework) if sdk.framework else None,
                    sha256 = flutter_source_sha256(sdk.version) if sdk.version and not sdk.framework else "",
                    sdk = sdk.name,
                    prefix = prefix,
                )
        elif e.kind == HOSTED:
            flutter_pub_library_repo(name = library_repo(name), package_name = name)
            flutter_pub_package(
                name = source_repo(name),
                package_name = name,
                version = e.version,
                sha256 = e.sha256,
                base_url = e.url,
                overlay_roots = overlay_roots,
                # rules_dart's curated registry is the single source of truth
                # for which pub package a Bazel-built native library stands in
                # for, and at which versions. Consulting it here is what makes a
                # Flutter app depending on, say, `drift` get `sqlite3`'s
                # library without naming it: the asset lands on the package
                # that owns it, so it propagates through the Dart graph exactly
                # as pub's own would.
                code_assets = curated_code_assets(name, e.version),
                ignore_hook = name in ignore_hooks,
            )
        elif e.kind == GIT:
            flutter_pub_library_repo(name = library_repo(name), package_name = name)
            flutter_pub_package(
                name = source_repo(name),
                package_name = name,
                version = e.version,
                git_url = e.git_url,
                resolved_ref = e.resolved_ref,
                git_path = e.git_path,
                lock = e.lock,
                overlay_roots = overlay_roots,
                code_assets = curated_code_assets(name, e.version),
                ignore_hook = name in ignore_hooks,
            )
        elif e.kind == FLUTTER_SOURCE:
            for prefix, sdk in reps.items():
                flutter_pub_library_repo(name = library_repo(name, prefix), package_name = name, prefix = prefix)
                flutter_pub_package(
                    name = source_repo(name, prefix),
                    package_name = name,
                    version = e.version,
                    sha256 = flutter_source_sha256(sdk.version) if sdk.version and not sdk.framework else "",
                    flutter_source_version = sdk.version if not sdk.framework else "",
                    framework_json = _framework_json(sdk.framework) if sdk.framework else None,
                    sdk = sdk.name,
                    prefix = prefix,
                    overlay_roots = overlay_roots,
                )

    # The build's Android Maven data: what every built spoke's Gradle build
    # declares, against what `@rules_android_maven` resolved. An Android app's
    # `flutter_android_plugin_libs` checks the part its plugins need, and a
    # spoke's `android/` package reads what resolved, so only Android builds
    # fetch it.
    flutter_android_maven(
        name = ANDROID_MAVEN_REPO,
        spokes = [
            "@{}//:{}".format(source_repo(name), MAVEN_DEPS_FILE)
            for name in sorted(built.keys())
        ],
    )

    if "flutter_test" in built:
        flutter_pub_goldens(name = GOLDENS_REPO)

    # One hub repo per name, with aliases for the packages of its lock(s). Two
    # tags of one name are one hub holding both locks' packages. flutter.pub()
    # always uses `flutter_pub_lock_hub` (not rules_dart's plain `pub_lock_hub`)
    # for its `android/` and `goldens/` packages. Non-Flutter pub.pub()
    # consumers keep using rules_dart's plain hub.
    for hub_name, packages in sorted(hub_packages.items()):
        flutter_pub_lock_hub(
            name = hub_name,
            hub_name = hub_name,
            packages = sorted(packages.keys()),
            built_packages = sorted([n for n in packages if n in built]),
            sdk_packages = [n for n in sdk_packages if n in packages],
            sdk_prefixes = prefixes,
        )

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
