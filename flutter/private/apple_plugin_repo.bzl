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
    "swift_package_target",
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

def _swift_package_library(ctx, name, platform, target):
    """A `flutter_apple_plugin_library` of `target` (`swift_package_target`)."""
    srcs = []
    for source in target.sources:
        srcs.extend(_patterns(ctx, source, SWIFTPM_SOURCE_EXTENSIONS + SWIFTPM_HEADER_EXTENSIONS))

    # A target's headers are its own, wherever its sources are named.
    srcs.extend(_patterns(ctx, target.dir, SWIFTPM_HEADER_EXTENSIONS))
    exclude = []
    for path in target.exclude:
        exclude.extend([path + "/**"] if ctx.path(path).is_dir else [path])
    srcs = _unique(srcs)
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
    name = "{name}_apple_{platform}",
    srcs = glob({srcs}, exclude = {exclude}, allow_empty = True),
    public_hdrs = glob({public_hdrs}, exclude = {exclude}, allow_empty = True),
    includes = {includes},
    clang_copts = {clang_copts},
    cxxopts = {cxxopts},
    conlyopts = {conlyopts},
    swift_copts = {swift_copts},
    linkopts = {linkopts},
    module_name = "{name}",
    platform = "{platform}",
    visibility = ["//visibility:public"],
)
""".format(
        name = name,
        platform = platform,
        srcs = repr(srcs),
        exclude = repr(exclude),
        public_hdrs = repr(public_hdrs),
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

def _apple_plugin_repo_impl(ctx):
    package = ctx.attr.package_name
    info_path = sibling_path(ctx, source_repo(package, ctx.attr.prefix), APPLE_PLUGIN_FILE)
    info = json.decode(ctx.read(info_path))
    plugin_root = info_path.dirname

    # The plugin's Apple directories, as they are in its source repository,
    # so the libraries' paths are the plugin's own.
    for directory in ("ios", "macos", "darwin"):
        if plugin_root.get_child(directory).exists:
            ctx.symlink(plugin_root.get_child(directory), directory)

    dumps = {}
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
        target = swift_package_target(dumps[manifest_dir], package, platform, manifest_dir)
        if target.problems:
            targets.append(_stand_in(package, platform, swift_package_message(
                package,
                ctx.attr.version,
                platform,
                manifest,
                target.problems,
            )))
        else:
            targets.append(_swift_package_library(ctx, package, platform, target))

    ctx.file("BUILD.bazel", """\
load("@rules_flutter//flutter:macos.bzl", "flutter_apple_plugin_library")
load("@rules_flutter//flutter/private:unbuilt_native_code.bzl", "flutter_unbuilt_plugin_library")
{targets}""".format(targets = "".join(targets)))

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
