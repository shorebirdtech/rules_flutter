"""Compile a Flutter plugin's Apple sources into a swift_library.

This is the rules_flutter analog of the Podfile-driven CocoaPods build a
Flutter plugin author would otherwise rely on. It wraps `swift_library`
with the platform's Flutter framework as a dep, and routes any `.m`/
`.mm` ObjC sources through `objc_library`.

Public Tier-2 API: re-exported from `flutter/macos.bzl` and
`flutter/ios.bzl` so users can wire a monorepo plugin's BUILD.bazel
without going through the `ext/` overlay system.

Usage:

    flutter_apple_plugin_library(
        name = "my_plugin_apple_macos",
        srcs = glob(["macos/Classes/**/*.swift"]),
        module_name = "my_plugin",
        platform = "macos",
    )
"""

load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@build_bazel_rules_apple//apple:apple.bzl", "apple_dynamic_framework_import", "apple_dynamic_xcframework_import")
load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@rules_cc//cc:objc_library.bzl", "objc_library")
load(":apple_engine.bzl", "IOS_ENGINE_XCFRAMEWORK", "MACOS_ENGINE_FRAMEWORK", "flutter_engine_module_maps")

_CLANG_SOURCE_EXTENSIONS = ("m", "mm", "c", "cc", "cpp", "cxx", "c++", "s", "S")
_HEADER_EXTENSIONS = ("h", "hh", "hpp", "hxx", "h++", "inc")

# Xcode compiles a plugin, from its Swift package or its podspec, with Clang's
# module autolinking on (`CLANG_MODULES_AUTOLINK`): an SDK framework its sources
# import, as `@import CoreTelephony;` or `#import <CoreTelephony/...>` does, is
# linked into the app without the plugin naming it. apple_support's toolchain
# turns autolinking off for every C-family compile, so it is turned back on here.
_AUTOLINK = ["-fautolink"]

def _extension(path):
    name = path.rsplit("/", 1)[-1]
    return name.rsplit(".", 1)[-1] if "." in name else ""

def _split_srcs(srcs, public_hdrs):
    """Split srcs into (swift_files, clang_files, public_headers, private_headers).

    Returns lists by extension so we can route C, C++ and Objective-C through
    objc_library while keeping Swift on swift_library. With `public_hdrs`,
    those are the module's public headers and the other headers are private.
    Otherwise headers are public, part of the plugin's module, unless the
    sources follow SwiftPM's layout, where only the headers under an
    `include/` directory (`publicHeadersPath`'s default) are: the rest are
    the target's own, compiled with its sources but not importable, and a
    private header that does not stand on its own (one that uses `NS_ENUM`
    without importing Foundation) would fail the module's build.
    """
    swift_files = []
    objc_files = []
    headers = []
    for f in srcs:
        ext = _extension(f)
        if ext == "swift":
            swift_files.append(f)
        elif ext in _CLANG_SOURCE_EXTENSIONS:
            objc_files.append(f)
        elif ext in _HEADER_EXTENSIONS:
            headers.append(f)
    if public_hdrs != None:
        public = {h: True for h in public_hdrs}
        return swift_files, objc_files, list(public_hdrs), [h for h in headers if h not in public]
    public = [h for h in headers if _under_include_dir(h)]
    if not public:
        return swift_files, objc_files, headers, []
    private = [h for h in headers if not _under_include_dir(h)]
    return swift_files, objc_files, public, private

def _under_include_dir(path):
    return path.startswith("include/") or "/include/" in path

def flutter_apple_plugin_library(
        name,
        srcs = [],
        module_name = None,
        platform = "macos",
        deps = [],
        copts = [],
        clang_copts = [],
        cxxopts = [],
        conlyopts = [],
        swift_copts = [],
        linkopts = [],
        public_hdrs = None,
        textual_hdrs = [],
        includes = [],
        sdk_frameworks = [],
        sdk_dylibs = [],
        clang_module = False,
        swift_language_mode = None,
        data = [],
        visibility = None,
        tags = None,
        **kwargs):
    """Build a Flutter plugin's Apple sources into a swift_library.

    Auto-routes C, C++ and Objective-C sources (`.m`, `.mm`, `.c`, `.cpp`
    and the like) through an internal `objc_library` and feeds it into the
    `swift_library` as a dep. Bridging-header support:
    when `<module_name>-Bridging-Header.h` is present in `srcs`, it's
    passed via the swift_library's `swiftc_inputs` and a `-import-
    objc-header` copt.

    Args:
        name: Target name. Pass to runner deps (or via the aspect-based
            aggregator that discovers them automatically).
        srcs: Swift, C, C++, Objective-C and header source files. When some
            headers are under an `include/` directory, as in SwiftPM's
            layout, and `public_hdrs` is not given, only those are the
            module's public headers; the others are private to the ObjC
            compile, as SwiftPM treats them.
        module_name: Swift module name. Defaults to `name`.
        platform: `"macos"` or `"ios"`, which picks the Flutter framework
            the sources compile against; or `"darwin"` for sources that build
            for both (`sharedDarwinSource`), which compile against the
            framework of the platform the build is for. List a `darwin`
            library as the `lib` of both the plugin's `ios` and `macos`
            `flutter_plugin_platform`.
        deps: Additional swift_library / cc_library deps: other plugins,
            other targets of the plugin's package. Both compiles see them.
        copts: Additional compile options, for both the Swift and the ObjC
            compile: a define a plugin's `Package.swift` sets is `-DNAME`,
            which Clang reads as `NAME=1` and Swift as a condition.
        clang_copts: Compile options for the C, C++ and Objective-C sources
            only: a `Package.swift`'s C and C++ defines and its C
            `unsafeFlags`. Split as a shell would, as `objc_library.copts`.
        cxxopts: Compile options for the C++ and Objective-C++ sources only:
            the package's C++ language standard, its C++ `unsafeFlags`.
        conlyopts: Compile options for the C sources only: the package's C
            language standard.
        swift_copts: Compile options for the Swift sources only: a
            `Package.swift`'s Swift defines (`-DNAME`) and its Swift
            `unsafeFlags`.
        linkopts: Options for the link of any binary that links the plugin:
            a `Package.swift`'s linker `unsafeFlags`.
        public_hdrs: The headers of the plugin's module, which the
            `publicHeadersPath` of a `Package.swift` target holds; the other
            headers in `srcs` are private to its compile. Without it, see
            `srcs`.
        textual_hdrs: Headers the C-family sources may include that are
            not the library's own: those of the other targets of a Swift
            package, which SwiftPM lets any target include by path.
        includes: Header search paths forwarded to the inner
            `objc_library`. Mirrors `objc_library.includes` semantics —
            each entry becomes `-I <package>/<entry>` for both the
            ObjC compile and downstream consumers, matching SwiftPM's
            `publicHeadersPath` behavior. Required for plugins that
            follow SwiftPM's canonical layout (header at
            `Sources/<pkg>/include/<pkg>/Foo.h`, `.m` does bare-basename
            `#import "Foo.h"`); without the include path the .m's import
            fails with `'Foo.h' file not found`.
        sdk_frameworks: Apple SDK frameworks to link (e.g. `["AVFoundation"]`),
            as a `Package.swift`'s `linkedFramework` does. A framework the
            C-family sources import is linked without this, as Xcode links
            it: the library compiles them with Clang's module autolinking on.
            A plugin built from its `Package.swift` gets its `linkerSettings`
            without this; an overlay lists them here.
        sdk_dylibs: Apple SDK dynamic libraries to link (e.g. `["c++"]`,
            `["sqlite3"]`), as a `Package.swift`'s `linkedLibrary` does.
        clang_module: Whether a library without Swift sources is a Clang
            module named `module_name` itself, as a C-family target of a
            Swift package is, rather than a Swift module that re-exports one
            (the default, which a plugin's registrant imports).
        data: Resources the app carries for the library, such as the
            `apple_resource_bundle` of a Swift package target's resources.
        swift_language_mode: `"6"` to compile the Swift sources in Swift 6
            mode, as SwiftPM compiles a target of a `swift-tools-version:
            6.0` package; Swift 5 (the default) otherwise.
        visibility: Target visibility.
        tags: Bazel tags. Defaults to `["manual"]` so the spoke target
            is only built when something depends on it.
        **kwargs: Forwarded to the underlying swift_library.
    """
    if platform not in ("macos", "ios", "darwin"):
        fail("flutter_apple_plugin_library: platform must be 'macos', 'ios' or 'darwin', got '%s'" % platform)

    if tags == None:
        tags = ["manual"]

    if module_name == None:
        module_name = name

    # Both per-platform plugin spokes share the same module_name (so the
    # registrant's `import <module>` resolves identically on each platform).
    # Without target_compatible_with, both swift_library targets analyze in
    # the same configuration and produce conflicting `<module>.swiftmodule`
    # outputs. Constrain each to its OS so only one is reachable per build;
    # a `darwin` library, the one of both, to either.
    if platform == "darwin":
        target_compatible_with = select({
            Label("@platforms//os:ios"): [],
            Label("@platforms//os:macos"): [],
            "//conditions:default": [Label("@platforms//:incompatible")],
        })
    else:
        target_compatible_with = ["@platforms//os:%s" % platform]

    swift_files, objc_files, headers, private_headers = _split_srcs(srcs, public_hdrs)

    # The Flutter framework is loaded at runtime (extracted via
    # flutter_macos_engine / flutter_ios_engine elsewhere). For
    # compile-time symbol resolution we depend on a framework import that
    # brings in the framework headers. macOS ships a dynamic framework;
    # iOS ships an xcframework wrapper. The import is the build mode's
    # engine, the one the application bundles: an import of another mode's
    # engine under the same framework name breaks the bundle. A `darwin`
    # library picks the engine of the platform it is built for.
    framework_targets = {}
    for os in (("macos", "ios") if platform == "darwin" else (platform,)):
        framework_target = "_%s__flutter_framework%s" % (name, "_" + os if platform == "darwin" else "")
        framework_targets[os] = ":" + framework_target
        if os == "macos":
            apple_dynamic_framework_import(
                name = framework_target,
                framework_imports = MACOS_ENGINE_FRAMEWORK,
                tags = tags,
                target_compatible_with = ["@platforms//os:macos"],
                visibility = ["//visibility:private"],
            )
        else:
            apple_dynamic_xcframework_import(
                name = framework_target,
                xcframework_imports = IOS_ENGINE_XCFRAMEWORK,
                tags = tags,
                target_compatible_with = ["@platforms//os:ios"],
                visibility = ["//visibility:private"],
            )
    if platform == "darwin":
        framework_deps = select({
            Label("@platforms//os:ios"): [framework_targets["ios"]],
            Label("@platforms//os:macos"): [framework_targets["macos"]],
            "//conditions:default": [],
        })
        framework_files = select({
            Label("@platforms//os:ios"): IOS_ENGINE_XCFRAMEWORK,
            Label("@platforms//os:macos"): MACOS_ENGINE_FRAMEWORK,
            "//conditions:default": [],
        })
    else:
        framework_deps = [framework_targets[platform]]
        framework_files = MACOS_ENGINE_FRAMEWORK if platform == "macos" else IOS_ENGINE_XCFRAMEWORK

    swift_deps = framework_deps + list(deps)

    # The engine's module map, for C-family sources that `@import Flutter`.
    module_maps_target = "_%s__flutter_module_maps" % name
    flutter_engine_module_maps(
        name = module_maps_target,
        framework = framework_files,
        tags = tags,
        target_compatible_with = target_compatible_with,
        visibility = ["//visibility:private"],
    )
    clang_deps = framework_deps + [":" + module_maps_target] + list(deps)

    # The SDK frameworks and libraries are the plugin's to link whatever its
    # sources are in; a Swift-only plugin has no objc_library to carry them.
    sdk_linkopts = ["-Wl,-framework," + f for f in sdk_frameworks] + ["-l" + d for d in sdk_dylibs]

    objc_module_name = ""
    if clang_module and not swift_files:
        objc_library(
            name = name,
            srcs = objc_files + private_headers,
            hdrs = headers,
            textual_hdrs = textual_hdrs,
            includes = includes,
            module_name = module_name,
            enable_modules = True,
            copts = _AUTOLINK + copts + clang_copts,
            cxxopts = cxxopts,
            conlyopts = conlyopts,
            linkopts = sdk_linkopts + linkopts,
            alwayslink = True,
            data = data,
            deps = clang_deps,
            tags = tags,
            target_compatible_with = target_compatible_with,
            visibility = visibility,
        )
        return
    if objc_files:
        # Compile ObjC pieces in their own objc_library and feed into the
        # swift_library so `.m`/`.mm` sources are linked into the plugin
        # module via the produced CcInfo. The objc_library also needs the
        # Flutter framework for `#import <FlutterMacOS/FlutterMacOS.h>` etc.
        # Set module_name so the swift_library can `@_exported import` the
        # ObjC module — this makes ObjC classes (e.g. FPPPackageInfoPlusPlugin)
        # visible to Swift consumers that `import <module_name>`.
        objc_target = "_%s__objc" % name
        objc_module_name = "%s_objc" % module_name
        objc_library(
            name = objc_target,
            srcs = objc_files + private_headers,
            hdrs = headers,
            textual_hdrs = textual_hdrs,
            includes = includes,
            sdk_frameworks = sdk_frameworks,
            sdk_dylibs = sdk_dylibs,
            module_name = objc_module_name,
            enable_modules = True,
            copts = _AUTOLINK + copts + clang_copts,
            cxxopts = cxxopts,
            conlyopts = conlyopts,
            # Every object of the plugin is in the app, as Xcode links a
            # Swift package's objects and CocoaPods its framework: code that
            # only Dart reaches, through `DynamicLibrary.process()`, has no
            # reference from the app's link to pull it in.
            alwayslink = True,
            deps = clang_deps,
            tags = tags,
            target_compatible_with = target_compatible_with,
            visibility = ["//visibility:private"],
        )
        swift_deps = swift_deps + [":" + objc_target]

    bridging_header = None
    extra_copts = []
    for h in headers + private_headers:
        if h.endswith("%s-Bridging-Header.h" % module_name):
            bridging_header = h
            extra_copts.extend([
                "-import-objc-header",
                "$(execpath %s)" % h,
            ])
            break

    # swift_library requires non-empty srcs. ObjC-only plugins (e.g.
    # package_info_plus's `.m`-only macOS impl) get a synthetic placeholder
    # Swift file. The Swift module is essentially empty; the ObjC interface
    # reaches Swift consumers via the objc_library dep's clang module map.
    if not swift_files:
        # ObjC-only plugin: emit a placeholder Swift file that
        # `@_exported import`s the ObjC module so consumers that
        # `import <module_name>` see the ObjC classes.
        placeholder_target = "_%s__swift_placeholder" % name
        placeholder_file = "_%s__placeholder.swift" % name
        placeholder_content = ["// GENERATED — re-exports the ObjC module so Swift `import %s` works." % module_name]
        if objc_module_name:
            placeholder_content.append("@_exported import %s" % objc_module_name)
        write_file(
            name = placeholder_target,
            out = placeholder_file,
            content = placeholder_content,
            tags = tags,
            target_compatible_with = target_compatible_with,
        )
        swift_files = [":" + placeholder_target]

    if swift_language_mode not in (None, "5", "6"):
        fail("flutter_apple_plugin_library: swift_language_mode must be \"5\" or \"6\", got %r" % swift_language_mode)
    features = list(kwargs.pop("features", []))
    swiftc_inputs = list(kwargs.pop("swiftc_inputs", []))
    if swift_language_mode == "6":
        features.append("swift.enable_v6")

    swift_library(
        name = name,
        features = features,
        data = data,
        srcs = swift_files,
        module_name = module_name,
        copts = copts + swift_copts + extra_copts,
        linkopts = sdk_linkopts + linkopts,
        deps = swift_deps,
        swiftc_inputs = swiftc_inputs + ([bridging_header] if bridging_header else []),
        tags = tags,
        target_compatible_with = target_compatible_with,
        visibility = visibility,
        **kwargs
    )
