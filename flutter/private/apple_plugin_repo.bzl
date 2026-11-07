"""The Apple libraries of a pub plugin, as its `Package.swift` says to build them.

A plugin's source repository (`flutter_pub_package`) says which of iOS and
macOS it has a library for, and where its sources are: the directory of its
`Package.swift` (`ios/<plugin>`, or `darwin/<plugin>` with
`sharedDarwinSource`), or, for a plugin without one, the directories of its
CocoaPods layout. This repository builds each of those libraries. It reads a
`Package.swift` with Xcode's `swift package dump-package`, which evaluates the
manifest as SwiftPM does, and turns the plugin's target into a
`flutter_apple_plugin_library` (`swiftpm_manifest.bzl`); a manifest it cannot
honour gets a stand-in that fails the platform's build, naming why.

Only an iOS or macOS build reaches the libraries, so only such a build fetches
this repository, and needs Xcode for it: other builds, and other hosts, never
evaluate a manifest.
"""

load(":flutter_pub_index.bzl", "SPOKE_PREFIX", "sibling_path", "source_repo")
load(":swift_packages.bzl", "SWIFT_PACKAGES_FILE", "SWIFT_PACKAGES_REPO", "swift_product_label")
load(
    ":swiftpm_manifest.bzl",
    "CONFIGURATIONS",
    "SWIFTPM_HEADER_EXTENSIONS",
    "SWIFTPM_SOURCE_EXTENSIONS",
    "build_settings_message",
    "find_manifest_computations",
    "find_swiftpm_build_settings",
    "shell_quote_copt",
    "swift_package_message",
    "swift_package_targets",
)

# What a plugin's source repository writes for this one.
APPLE_PLUGIN_FILE = "flutter_apple_plugin.json"

# The extensions of a CocoaPods-layout plugin's sources.
_LEGACY_EXTENSIONS = ("swift", "m", "mm", "h")

def apple_repo(package, prefix = SPOKE_PREFIX):
    """The name of the repository holding a plugin's Apple libraries."""
    return "{}_apple__{}".format(prefix, package)

def apple_library_label(package, platform, prefix = SPOKE_PREFIX):
    """The label, in a sibling repository's BUILD file, of a plugin's `platform` library."""
    return "@{}//:{}_apple_{}".format(apple_repo(package, prefix), package, platform)

def _dump_package(ctx, manifest_dir):
    """`swift package dump-package` of the package in `manifest_dir`, decoded."""
    xcrun = ctx.which("xcrun")
    if not xcrun:
        fail((
            "package:{pkg}: building its iOS or macOS library reads its Package.swift " +
            "with Xcode's `swift package dump-package`, and `xcrun` is not on PATH. " +
            "Install Xcode, or select it with `xcode-select`."
        ).format(pkg = ctx.attr.package_name))

    # SwiftPM writes its build state under the scratch path, by default in
    # the package: keep the plugin's files as they are.
    scratch = ctx.path("_swiftpm_scratch")
    result = ctx.execute(
        [
            xcrun,
            "swift",
            "package",
            "--package-path",
            str(manifest_dir),
            "--scratch-path",
            str(scratch),
            "--manifest-cache",
            "none",
            "dump-package",
        ],
        quiet = True,
    )
    ctx.delete(scratch)
    if result.return_code != 0:
        fail("package:{pkg}: `swift package dump-package` of {dir} failed:\n{err}".format(
            pkg = ctx.attr.package_name,
            dir = manifest_dir,
            err = result.stderr,
        ))
    return json.decode(result.stdout)

def _configured(values, quote):
    """A BUILD expression of the list `values` (a dict by configuration) selects."""
    always = [quote(v) for v in values[""]]
    debug = [quote(v) for v in values["debug"]]
    release = [quote(v) for v in values["release"]]
    if not debug and not release:
        return repr(always)
    return '{} + select({{\n        "@rules_flutter//flutter/private:swiftpm_release": {},\n        "//conditions:default": {},\n    }})'.format(
        repr(always),
        repr(release),
        repr(debug),
    )

def _unique(values):
    """`values` without repeats, in first-seen order."""
    return {v: None for v in values}.keys()

def _make_variables_escaped(flag):
    return flag.replace("$", "$$")

def _patterns(ctx, path, extensions):
    """Glob patterns for the files with `extensions` at `path`, a file or a directory."""
    if not ctx.path(path).exists:
        fail("package:{}: its Package.swift names {}, which it does not have".format(ctx.attr.package_name, path))
    if ctx.path(path).is_dir:
        return ["{}/**/*.{}".format(path, ext) for ext in extensions]
    return [path]

def _target_label(package, platform, target, main):
    """The name of a package target's library: the plugin's own for its module."""
    name = "{}_apple_{}".format(package, platform)
    return name if target == main else "{}__{}".format(name, target)

def _swift_package_library(ctx, package, platform, target, main, manifest_dir, products):
    """A `flutter_apple_plugin_library` of `target` (`swift_package_targets`).

    The plugin's module is named after the plugin, as its registrant imports
    it; each other target is a module named after itself, a Clang module
    when it has no Swift sources, as SwiftPM builds it.
    """
    srcs = []
    for source in target.sources:
        srcs.extend(_patterns(ctx, source, SWIFTPM_SOURCE_EXTENSIONS + SWIFTPM_HEADER_EXTENSIONS))

    # A target's headers are its own, wherever its sources are named.
    srcs.extend(_patterns(ctx, target.dir, SWIFTPM_HEADER_EXTENSIONS))
    exclude = []
    for path in target.exclude:
        exclude.extend([path + "/**"] if ctx.path(path).is_dir else [path])
    srcs = _unique(srcs)

    # SwiftPM lets a target include any header of its package by path.
    textual_hdrs = _patterns(ctx, manifest_dir, SWIFTPM_HEADER_EXTENSIONS)
    public_hdrs = []
    if ctx.path(target.public_headers).is_dir:
        public_hdrs = _patterns(ctx, target.public_headers, SWIFTPM_HEADER_EXTENSIONS)

    # Linked SDK frameworks and libraries go to the link of whatever binary
    # links the plugin, configuration by configuration.
    linkopts = {
        c: (
            ["-Wl,-framework," + f for f in target.sdk_frameworks[c]] +
            ["-l" + d for d in target.sdk_dylibs[c]] +
            target.linkopts[c]
        )
        for c in CONFIGURATIONS
    }
    return """
flutter_apple_plugin_library(
    name = "{name}",
    srcs = glob({srcs}, exclude = {exclude}, allow_empty = True),
    public_hdrs = glob({public_hdrs}, exclude = {exclude}, allow_empty = True),
    textual_hdrs = glob({textual_hdrs}, exclude = {own}, allow_empty = True),
    includes = {includes},
    clang_copts = {clang_copts},
    cxxopts = {cxxopts},
    conlyopts = {conlyopts},
    swift_copts = {swift_copts},
    linkopts = {linkopts},
    deps = {deps},
    module_name = "{module}",
    clang_module = {clang_module},
    platform = "{platform}",
    visibility = ["//visibility:public"],
)
""".format(
        name = _target_label(package, platform, target.name, main),
        module = package if target.name == main else target.name,
        clang_module = target.name != main,
        deps = repr([":" + _target_label(package, platform, d, main) for d in target.deps] + products),
        platform = platform,
        srcs = repr(srcs),
        exclude = repr(exclude),
        public_hdrs = repr(public_hdrs),
        textual_hdrs = repr(textual_hdrs),
        own = repr([target.dir + "/**"]),
        includes = repr(_unique(target.includes)),
        clang_copts = _configured(target.clang_copts, shell_quote_copt),
        cxxopts = _configured(target.cxxopts, shell_quote_copt),
        conlyopts = _configured(target.conlyopts, shell_quote_copt),
        swift_copts = _configured(target.swift_copts, _make_variables_escaped),
        linkopts = _configured(linkopts, _make_variables_escaped),
    )

def _legacy_library(name, platform, layout):
    """A `flutter_apple_plugin_library` of a plugin without a `Package.swift`."""
    return """
flutter_apple_plugin_library(
    name = "{name}_apple_{platform}",
    srcs = glob({srcs}, allow_empty = True),
    includes = {includes},
    module_name = "{name}",
    platform = "{platform}",
    visibility = ["//visibility:public"],
)
""".format(
        name = name,
        platform = platform,
        srcs = repr([
            "{}/**/*.{}".format(d, ext)
            for d in layout["srcs_dirs"]
            for ext in _LEGACY_EXTENSIONS
        ]),
        includes = repr(layout["include_dirs"]),
    )

def _stand_in(name, platform, message):
    return """
flutter_unbuilt_plugin_library(
    name = "{name}_apple_{platform}",
    message = {message},
    visibility = ["//visibility:public"],
)
""".format(name = name, platform = platform, message = repr(message))

def _swift_packages(ctx):
    """The pinned Swift packages: `struct(packages, resolved)` (`swift_packages.bzl`)."""
    data = json.decode(ctx.read(sibling_path(ctx, SWIFT_PACKAGES_REPO, SWIFT_PACKAGES_FILE)))
    return struct(packages = data["packages"], resolved = data["resolved"])

def _unpinned_message(package, version, platform, manifest, unpinned, resolved):
    return (
        "package:{pkg} {version} depends for {platform} on Swift packages that no " +
        "`Package.resolved` pins ({manifest}):\n    {unpinned}\n" +
        "rules_flutter builds the Swift packages an Apple plugin depends on at the versions " +
        "a `Package.resolved` records, as Xcode does for `flutter build`. Run " +
        "`bazel run @<hub>//swift:resolve`, <hub> being the `name` of your " +
        "`flutter_pub.from_lock`, and name the file it writes in that tag's " +
        "`swift_package_resolved`.{read}"
    ).format(
        pkg = package,
        version = version,
        platform = {"ios": "iOS", "macos": "macOS"}[platform],
        manifest = manifest,
        unpinned = "\n    ".join(unpinned),
        read = " The build reads " + ", ".join(resolved) + "." if resolved else "",
    )

def _apple_plugin_repo_impl(ctx):
    package = ctx.attr.package_name
    info_path = sibling_path(ctx, source_repo(package, ctx.attr.prefix), APPLE_PLUGIN_FILE)
    if not info_path.exists:
        # A package with no Apple library: nothing to build or resolve.
        ctx.file(SWIFT_MANIFESTS_FILE, json.encode({"package": package, "platforms": {}}))
        ctx.file("BUILD.bazel", _SWIFT_MANIFESTS_TARGET.format(manifests = "[]"))
        return ctx.repo_metadata(reproducible = True)
    info = json.decode(ctx.read(info_path))
    plugin_root = info_path.dirname

    # The plugin's Apple directories, as they are in its source repository,
    # so the libraries' paths are the plugin's own.
    for directory in ("ios", "macos", "darwin"):
        if plugin_root.get_child(directory).exists:
            ctx.symlink(plugin_root.get_child(directory), directory)

    # What `swift:resolve` resolves: each platform's manifest.
    manifest_dirs = {
        platform: layout["manifest_dir"]
        for platform, layout in info["platforms"].items()
        if layout["manifest_dir"]
    }
    ctx.file(SWIFT_MANIFESTS_FILE, json.encode({"package": package, "platforms": manifest_dirs}))

    dumps = {}
    swift_packages = None
    targets = []
    for platform in sorted(info["platforms"].keys()):
        layout = info["platforms"][platform]
        manifest_dir = layout["manifest_dir"]
        if not manifest_dir:
            targets.append(_legacy_library(package, platform, layout))
            continue
        manifest = manifest_dir + "/Package.swift"
        content = ctx.read(plugin_root.get_child(manifest))
        computations = find_manifest_computations(content)
        settings = find_swiftpm_build_settings(content)
        if computations and settings:
            targets.append(_stand_in(package, platform, build_settings_message(
                package,
                ctx.attr.version,
                platform,
                manifest,
                settings,
                computations,
            )))
            continue
        if manifest_dir not in dumps:
            dumps[manifest_dir] = _dump_package(ctx, plugin_root.get_child(manifest_dir))
        built = swift_package_targets(dumps[manifest_dir], package, platform, manifest_dir)
        if built.problems:
            targets.append(_stand_in(package, platform, swift_package_message(
                package,
                ctx.attr.version,
                platform,
                manifest,
                built.problems,
            )))
            continue

        # The remote packages' products, from the repositories of their pins.
        remote = [p for t in built.targets for p in t.remote_products]
        if remote and swift_packages == None:
            swift_packages = _swift_packages(ctx)
        unpinned = []
        for identity, _ in remote:
            if identity not in swift_packages.packages:
                location = [d for d in _remote_locations(dumps[manifest_dir]) if d[0] == identity]
                entry = "{} ({})".format(identity, location[0][1]) if location else identity
                if entry not in unpinned:
                    unpinned.append(entry)
        if unpinned:
            targets.append(_stand_in(package, platform, _unpinned_message(
                package,
                ctx.attr.version,
                platform,
                manifest,
                unpinned,
                swift_packages.resolved,
            )))
            continue
        for target in built.targets:
            products = [swift_product_label(identity, product) for identity, product in target.remote_products]
            targets.append(_swift_package_library(ctx, package, platform, target, built.main, manifest_dir, products))

    ctx.file("BUILD.bazel", """\
load("@rules_flutter//flutter:macos.bzl", "flutter_apple_plugin_library")
load("@rules_flutter//flutter/private:unbuilt_native_code.bzl", "flutter_unbuilt_plugin_library")
{targets}{manifests}""".format(
        targets = "".join(targets),
        manifests = _SWIFT_MANIFESTS_TARGET.format(manifests = repr(sorted([d + "/Package.swift" for d in {d: None for d in manifest_dirs.values()}]))),
    ))

    # What `dump-package` evaluates depends on the host's Xcode.
    return ctx.repo_metadata(reproducible = False)

# The manifests `swift:resolve` reads, and which platform each is.
SWIFT_MANIFESTS_FILE = "swift_manifests.json"

_SWIFT_MANIFESTS_TARGET = """
filegroup(
    name = "swift_manifests",
    srcs = ["swift_manifests.json"] + {manifests},
    visibility = ["//visibility:public"],
)
"""

def _remote_locations(dump):
    """`(identity, url)` of each remote package a manifest depends on."""
    found = []
    for dep in dump.get("dependencies", []):
        for entry in dep.get("sourceControl", []):
            remote = (entry.get("location") or {}).get("remote") or [{}]
            found.append((entry.get("identity", ""), remote[0].get("urlString", "")))
    return found

flutter_apple_plugin_repo = repository_rule(
    implementation = _apple_plugin_repo_impl,
    attrs = {
        "package_name": attr.string(mandatory = True),
        "prefix": attr.string(
            default = SPOKE_PREFIX,
            doc = "What the build's repositories are named by (`source_repo`).",
        ),
        "version": attr.string(doc = "The package's version, for messages."),
    },
    doc = "The iOS and macOS libraries of a pub plugin, built as its `Package.swift` says. See the module docstring.",
)
