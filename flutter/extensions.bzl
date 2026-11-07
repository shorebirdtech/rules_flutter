"""Extensions for bzlmod.

`flutter` installs the Flutter SDKs and their toolchains. The pub dependency
extension is `pub` in `@rules_flutter//flutter/pub:extensions.bzl`; it is its
own extension so that a lock it refuses breaks only the builds that use its
repositories, never the toolchains, and `bazel run @rules_flutter//flutter/pub`,
which fixes the lock, still runs.

Every module can define a toolchain version under the default name, "flutter".
The latest of those versions will be selected (the rest discarded),
and will always be registered by rules_flutter.

Additionally, the root module can define arbitrarily many more toolchain versions under different
names (the latest version will be picked for each name) and can register them as it sees fit,
effectively overriding the default named toolchain due to toolchain resolution precedence.
"""

load("//flutter/private:constants.bzl", "ANDROID_ABI_FOR_ARCH")
load("//flutter/private:engine_labels.bzl", "android_arches")
load("//flutter/private:flutter_chrome_for_testing.bzl", "flutter_chrome_for_testing")
load("//flutter/private:flutter_dev_root_repo.bzl", "flutter_dev_root_repo")
load("//flutter/private:flutter_face_repo.bzl", "IOS_ENGINE_EXTRA", "IOS_ENGINE_TARGETS", "MACOS_ENGINE_EXTRA", "MACOS_ENGINE_TARGETS", "WEB_SDK_TARGETS", "android_engine_face_extra", "flutter_face_repo")
load("//flutter/private:flutter_linux_runtime_repo.bzl", "flutter_linux_runtime_repo")
load("//flutter/private:flutter_material_fonts_repo.bzl", "flutter_material_fonts_repo")
load("//flutter/private:flutter_sdk_toolchains_repo.bzl", "flutter_sdk_toolchains_repo")
load("//flutter/private:flutter_sdks_repo.bzl", "encode_sdks", "flutter_sdks_repo")
load("//flutter/private:linux_runtime_pins.bzl", "LINUX_RUNTIME")
load("//flutter/private:pub_extension.bzl", "DEFAULT_SDK_NAME", "framework_json", "pub_from_lock_tag", "pub_plugin_overlays_tag")
load("//flutter/private:toolchain_version.bzl", "select_flutter_version")
load("//flutter/private:toolchains_repo.bzl", "flutter_toolchains_repo", "sdk_repo_name")
load("//flutter/private:versions.bzl", "CHROME_FOR_TESTING", "FLUTTER_VERSIONS", "flutter_source_sha256", "require_supported_flutter_version")
load(":repositories.bzl", "flutter_register_toolchains")

flutter_toolchain = tag_class(attrs = {
    "name": attr.string(doc = """\
The name of the SDK this declares. `flutter` is the stock release (or the SDK a
team always builds against, given sources); any other name is another SDK, which
a build chooses with `--@rules_flutter//flutter:sdk=<name>`. A name other than
the default is only permitted in the root module.
""", default = DEFAULT_SDK_NAME),
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

def _declared_sdks(module_ctx):
    """The SDKs the modules declare: a struct for each, by name."""

    # The root module chooses each toolchain's Flutter version, as it chooses
    # every toolchain: its own tag wins. A name the root does not declare takes
    # the highest version the other modules ask for.
    tags = {}
    root_versions = {}
    for mod in module_ctx.modules:
        for toolchain in mod.tags.toolchain:
            if toolchain.name != DEFAULT_SDK_NAME and not mod.is_root:
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
        if selected:
            require_supported_flutter_version(selected)
        fonts_sha256 = [t.material_fonts_sha256 for t in name_tags if t.material_fonts_sha256]
        sdks[name] = struct(
            name = name,
            version = selected,
            framework = framework,
            engine = engine,
            material_fonts_sha256 = fonts_sha256[0] if fonts_sha256 else "",
        )
    if DEFAULT_SDK_NAME not in sdks:
        fail("A flutter.toolchain() is required: the default SDK, named \"{}\".".format(DEFAULT_SDK_NAME))
    return sdks

def _label_prefix(label):
    """A label's repository, as a prefix any repository can name it by."""
    return "@@" + label.repo_name

def _register_sdk(sdk):
    """Declares the repositories of one SDK; returns the label prefix of its engine source."""
    name = sdk.name
    if sdk.engine == None:
        # The release engine, with the artifact repositories it is made of.
        flutter_register_toolchains(
            name = name,
            flutter_version = sdk.version,
            framework_json = str(framework_json(sdk.framework)) if sdk.framework else "",
            framework_json_file = framework_json(sdk.framework) if sdk.framework else None,
        )
        return "@{}_stock_engine".format(name)

    # An engine of the root module's choosing: the toolchains are written
    # against its slices. The Material fonts come with the framework.
    version_meta = FLUTTER_VERSIONS[sdk.version] if sdk.version else None
    fonts = name + "_material_fonts"
    flutter_material_fonts_repo(
        name = fonts,
        flutter_version = sdk.version or "",
        framework_json = framework_json(sdk.framework) if sdk.framework else None,
        sha256 = sdk.material_fonts_sha256,
    )
    flutter_sdk_toolchains_repo(
        name = sdk_repo_name(name),
        engine = _label_prefix(sdk.engine),
        sdk = name,
        version = sdk.version or "",
        engine_revision = version_meta.engine_revision if version_meta else "",
        material_fonts = "@{}//:material-fonts/MaterialIcons-Regular.otf".format(fonts),
        sysroot_prefix = DEFAULT_SDK_NAME,
        framework_json = str(framework_json(sdk.framework)) if sdk.framework else "",
        framework_json_file = framework_json(sdk.framework) if sdk.framework else None,
        engine_json_file = Label("@@{}//:flutter_engine.json".format(sdk.engine.repo_name)),
    )
    return _label_prefix(sdk.engine)

# The MODULE.bazel lines that replace the old pub extension, for the messages
# that tell a module to migrate.
_MIGRATION = (
    "    flutter_pub = use_extension(\"@rules_flutter//flutter/pub:extensions.bzl\", \"pub\")\n" +
    "    flutter_pub.from_lock(...)        # same attributes as before\n" +
    "    flutter_pub.plugin_overlays(...)  # same attributes as before\n" +
    "    use_repo(flutter_pub, \"deps\")     # the hubs are repositories of this extension"
)

def moved_to_pub_message(modules):
    """The error for modules that declare pub tags on an extension that no longer resolves them."""
    return ("`flutter.pub(...)`, `flutter.plugin_overlays(...)` and the `flutter_pub` extension of " +
            "`@rules_flutter//flutter:extensions.bzl` moved to `pub` in " +
            "`@rules_flutter//flutter/pub:extensions.bzl`. In the MODULE.bazel of {modules}:\n" +
            "{migration}").format(
        modules = ", ".join(sorted(modules)),
        migration = _MIGRATION,
    )

def _moved_to_pub(module_ctx):
    """Fails naming each module that still declares pub tags on `flutter`."""
    stale = [
        mod.name
        for mod in module_ctx.modules
        if mod.tags.pub or mod.tags.plugin_overlays
    ]
    if stale:
        fail(moved_to_pub_message(stale))

def _flutter_pub_moved(module_ctx):
    fail(moved_to_pub_message([mod.name for mod in module_ctx.modules]))

def _toolchain_extension(module_ctx):
    _moved_to_pub(module_ctx)
    sdks = _declared_sdks(module_ctx)
    engine_prefixes = {}
    for name in sorted(sdks.keys()):
        sdk = sdks[name]
        engine_prefixes[name] = _register_sdk(sdk)

        # The SDK's dev root, for `@rules_flutter//flutter/pub`. Declared
        # unconditionally because bzlmod repositories are lazy: a workspace
        # that never references it never fetches the tarball.
        released = sdk.version and not sdk.framework
        flutter_dev_root_repo(
            name = name + "_dev_root_src",
            flutter_version = sdk.version or "",
            framework_json = framework_json(sdk.framework) if sdk.framework else None,
            engine_revision = FLUTTER_VERSIONS[sdk.version].engine_revision if released else "",
            sha256 = flutter_source_sha256(sdk.version) if released else "",
        )

    # The repositories rules_flutter and its users name by fixed names, each
    # an alias into the selected SDK's own.
    flutter_face_repo(
        name = "flutter_macos_engine",
        sdks = engine_prefixes,
        targets = MACOS_ENGINE_TARGETS,
        extra = MACOS_ENGINE_EXTRA,
    )
    flutter_face_repo(
        name = "flutter_ios_engine",
        sdks = engine_prefixes,
        targets = IOS_ENGINE_TARGETS,
        extra = IOS_ENGINE_EXTRA,
    )
    flutter_face_repo(
        name = "flutter_web_sdk",
        sdks = engine_prefixes,
        targets = WEB_SDK_TARGETS,
    )
    for arch in android_arches():
        flutter_face_repo(
            name = "flutter_android_engine_" + arch,
            sdks = engine_prefixes,
            targets = {},
            extra = android_engine_face_extra(engine_prefixes, arch, ANDROID_ABI_FOR_ARCH[arch]),
        )
    flutter_face_repo(
        name = "flutter_dev_root",
        sdks = {name: "@{}_dev_root_src".format(name) for name in sdks},
        targets = {"dev_root": "{prefix}//:dev_root", "version_manifest": "{prefix}//:version_manifest"},
    )

    # What the `pub` extension needs of the SDKs: it cannot see the toolchain tags.
    flutter_sdks_repo(
        name = "flutter_sdks",
        sdks = encode_sdks(sdks),
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
        # Moved to `pub` in `@rules_flutter//flutter/pub:extensions.bzl`.
        # Declared here only so a module still using them gets the migration,
        # not Bazel's bare "does not generate repository" error.
        "pub": pub_from_lock_tag,
        "plugin_overlays": pub_plugin_overlays_tag,
    },
    os_dependent = False,
    arch_dependent = False,
    doc = "Installs the Flutter SDKs and their toolchains.",
)

flutter_pub = module_extension(
    implementation = _flutter_pub_moved,
    tag_classes = {
        "from_lock": pub_from_lock_tag,
        "plugin_overlays": pub_plugin_overlays_tag,
    },
    os_dependent = False,
    arch_dependent = False,
    doc = "Moved to `pub` in `@rules_flutter//flutter/pub:extensions.bzl`; " +
          "using this fails with the lines to change.",
)
