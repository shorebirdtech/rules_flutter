"""Flutter plugin rule.

Declares a Flutter plugin with Dart code and platform metadata.

Platform-specific native dependencies use select() in BUILD files:

    flutter_plugin(
        name = "url_launcher",
        srcs = glob(["lib/**/*.dart"]),
        platforms = ["android", "ios", "macos", "linux", "windows", "web"],
        dart_plugin_class = "UrlLauncherPlugin",
        native_deps = select({
            "@platforms//os:linux": [":url_launcher_linux_cc"],
            "@platforms//os:windows": [":url_launcher_windows_cc"],
            "//conditions:default": [],
        }),
    )
"""

load("@build_bazel_rules_apple//apple:providers.bzl", "AppleResourceInfo")

# rules_apple has no public aspect that collects a library's resources (5.4.0),
# so this is its internal one: a rules_apple upgrade can move or change it, and
# the Apple build of any plugin then fails to load. Check it on every upgrade.
# buildifier: disable=bzl-visibility
load("@build_bazel_rules_apple//apple/internal/aspects:resource_aspect.bzl", "apple_resource_aspect")
load("@build_bazel_rules_swift//swift:swift.bzl", "SwiftInfo")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_dart//dart:providers.bzl", "DartInfo")
load("@rules_dart//dart:utils.bzl", "WEB_COMPILER_INDEPENDENT_ATTR", "dart_info", "web_compiler_reset_when_independent")
load("@rules_java//java/common:java_info.bzl", "JavaInfo")
load("//flutter:providers.bzl", "FlutterDataAssetInfo", "FlutterInfo", "FlutterNativeAssetInfo")
load("//flutter/private:common.bzl", "collect_binding_contracts", "collect_native_libs")
load("//flutter/private:flutter_desktop_plugin_info.bzl", "FlutterLinuxPluginInfo", "FlutterWindowsPluginInfo")
load("//flutter/private:flutter_info.bzl", "flutter_info")
load("//flutter/private:flutter_library.bzl", "ADDITIONAL_LICENSES_ATTR", "ASSET_FLAVORS_ATTR", "ASSET_PLATFORMS_ATTR", "LIBRARY_PACKAGE_DOC", "SHADER_FLAVORS_ATTR", "SHADER_PLATFORMS_ATTR", "SKY_ENGINE_ATTR", "build_pub_contributions", "flutter_analyzable_info", "own_additional_licenses", "package_attr", "package_identity", "package_record")
load("//flutter/private:native_sources.bzl", "collect_native_source_pairs", "native_sources_aspect")
load("//flutter/private:swiftpm_app_settings.bzl", "FlutterSwiftPMAppLibraryInfo")
load("//flutter/private:unbuilt_native_code.bzl", "FlutterUnbuiltNativeCodeInfo")

def build_plugin_struct(name, plugin_platforms):
    """Build a plugin metadata struct from per-platform metadata.

    Args:
        name: Plugin package name.
        plugin_platforms: Dict of platform -> {pluginClass, dartPluginClass, ...}.

    Returns:
        A struct with name and platforms dict.
    """
    return struct(name = name, platforms = plugin_platforms)

def _unbuilt_native_code(lib):
    """The message of a library standing in for unbuilt native code, or ""."""
    return lib[FlutterUnbuiltNativeCodeInfo].message if FlutterUnbuiltNativeCodeInfo in lib else ""

def _unbuilt_desktop_entry(lib, package_name):
    """A Linux or Windows plugin library entry with nothing to compile, whose runner fails on its message."""
    return struct(
        label = lib.label,
        srcs = depset(),
        hdrs = depset(),
        include_dirs = depset(),
        linkopts = (),
        link_errors = (),
        unbuilt_native_code = _unbuilt_native_code(lib),
        package = package_name,
    )

def plugin_contributions(ctx, package_name, package_root, declares_plugin):
    """What a plugin-shaped target adds to `FlutterInfo`, beyond its dependencies'.

    Shared by `flutter_plugin` and by the member of a generated pub package
    (`flutter_pub_member`), so a package contributes the same whether its target
    stands alone or is built with the others of its dependency cycle.

    Args:
      ctx: The rule context: the attributes of `flutter_plugin` other than `deps`.
      package_name: The Dart package name.
      package_root: Its package root, from `derive_package_root`.
      declares_plugin: Whether the target is a plugin to register. A pub
        package without a `flutter.plugin` block is not one, though it
        contributes assets and fonts.

    Returns:
      A dict of the keyword arguments of `flutter_info()` for what the target
      itself contributes.
    """

    # Build plugin metadata.
    # If plugin_platforms_json is set, decode it directly.
    # Otherwise construct from scalar attrs (for manual BUILD files).
    if ctx.attr.plugin_platforms_json:
        plugin_platforms = json.decode(ctx.attr.plugin_platforms_json)
    else:
        plugin_platforms = {}
        for p in ctx.attr.platforms:
            info = {}
            if ctx.attr.plugin_class:
                info["pluginClass"] = ctx.attr.plugin_class
            if ctx.attr.dart_plugin_class:
                info["dartPluginClass"] = ctx.attr.dart_plugin_class
            if p == "android" and ctx.attr.android_package:
                info["package"] = ctx.attr.android_package
            plugin_platforms[p] = info

    plugins = [build_plugin_struct(
        name = package_name,
        plugin_platforms = plugin_platforms,
    )] if declares_plugin else []

    # Collect native libs from native_deps.
    native_libs = collect_native_libs(ctx.attr.native_deps)

    # And what their bindings were generated from, for the ones whose build said
    # so. Carried to the app rather than used here: a plugin bundles nothing, and
    # the app is where the dev config that a reload reads is written.
    binding_contracts = collect_binding_contracts(ctx.attr.native_deps)

    # `native_deps` and the Native Assets alike: an asset's own rule pairs the
    # library it declares with its sources, on its `FlutterInfo`.
    native_lib_sources = collect_native_source_pairs(ctx.attr.native_deps) + [
        pair
        for dep in ctx.attr.native_assets
        if FlutterInfo in dep
        for pair in dep[FlutterInfo].native_lib_sources.to_list()
    ]

    # Pull CcInfo + SwiftInfo from the per-platform Apple plugin libraries
    # so the runner aggregator can merge them into the runner's
    # swift_library compilation/link inputs. The `apple_libs` attribute
    # is a label_list typically populated via a `select()` on the target
    # platform — only the relevant platform's swift_library is in scope
    # for any one build, which avoids the swiftmodule output collision
    # that would happen if both platforms' libraries with the same module
    # name analyzed in the same configuration.
    extra_apple_plugin_libraries = []
    for lib in ctx.attr.apple_libs:
        platform_name = "macos" if "macos" in lib.label.name else ("ios" if "ios" in lib.label.name else "")
        if not platform_name:
            fail("flutter_plugin: apple_libs entry %s must have 'macos' or 'ios' in its label name" % lib.label)
        extra_apple_plugin_libraries.append(struct(
            platform = platform_name,
            label = lib.label,
            cc_info = lib[CcInfo] if CcInfo in lib else None,
            swift_info = lib[SwiftInfo] if SwiftInfo in lib else None,
            # The library's resources (a Swift package target's resource
            # bundle), for the app's bundle.
            resource_info = lib[AppleResourceInfo] if AppleResourceInfo in lib else None,
            unbuilt_native_code = _unbuilt_native_code(lib),
            package = package_name,
            # A library its Package.swift gives defines from the app, which
            # the app's aggregator builds for itself (`swiftpm_app_settings.bzl`).
            app_library = lib[FlutterSwiftPMAppLibraryInfo].library if FlutterSwiftPMAppLibraryInfo in lib else None,
        ))

    # Pull source bundles from linux + windows plugin libraries so the
    # corresponding runner can fold them into its compile.
    extra_linux_plugin_libraries = []
    for lib in ctx.attr.linux_libs:
        if FlutterUnbuiltNativeCodeInfo in lib:
            extra_linux_plugin_libraries.append(_unbuilt_desktop_entry(lib, package_name))
            continue
        if FlutterLinuxPluginInfo not in lib:
            fail("flutter_plugin: linux_libs entry %s must provide FlutterLinuxPluginInfo (use flutter_linux_plugin_library)." % lib.label)
        info = lib[FlutterLinuxPluginInfo]
        extra_linux_plugin_libraries.append(struct(
            label = lib.label,
            srcs = info.srcs,
            hdrs = info.hdrs,
            include_dirs = info.include_dirs,
            linkopts = info.linkopts,
            link_errors = info.link_errors,
            unbuilt_native_code = "",
            package = package_name,
        ))

    extra_windows_plugin_libraries = []
    for lib in ctx.attr.windows_libs:
        if FlutterUnbuiltNativeCodeInfo in lib:
            extra_windows_plugin_libraries.append(_unbuilt_desktop_entry(lib, package_name))
            continue
        if FlutterWindowsPluginInfo not in lib:
            fail("flutter_plugin: windows_libs entry %s must provide FlutterWindowsPluginInfo (use flutter_windows_plugin_library)." % lib.label)
        info = lib[FlutterWindowsPluginInfo]
        extra_windows_plugin_libraries.append(struct(
            label = lib.label,
            srcs = info.srcs,
            hdrs = info.hdrs,
            include_dirs = info.include_dirs,
            linkopts = info.linkopts,
            link_errors = info.link_errors,
            unbuilt_native_code = "",
            package = package_name,
        ))

    # Native Assets contributed by this plugin (or its parent ext/ overlay).
    extra_native_assets = []
    for dep in ctx.attr.native_assets:
        if FlutterNativeAssetInfo not in dep:
            fail(
                "flutter_plugin: native_assets entry %s must provide " % dep.label +
                "FlutterNativeAssetInfo (use flutter_native_asset).",
            )
        extra_native_assets.append(dep[FlutterNativeAssetInfo])

    extra_data_assets = []
    for dep in ctx.attr.data_assets:
        if FlutterDataAssetInfo not in dep:
            fail(
                "flutter_plugin: data_assets entry %s must provide " % dep.label +
                "FlutterDataAssetInfo (use flutter_data_asset).",
            )
        extra_data_assets.append(dep[FlutterDataAssetInfo])

    extra_apple_privacy_manifests = list(ctx.files.apple_privacy_files)

    # The plugin's Android library, when this build selected one. Only an
    # Android build does, so nothing else loads the library's package.
    extra_android_libs = [
        struct(package = package_name, lib = lib)
        for lib in ctx.attr.exports
    ]

    # Pub-package asset contributions (fonts/assets/shaders from the parsed
    # flutter:-block, applicable to plugins that also ship icon fonts or
    # bundled assets — same shape as flutter_library), of the Dart package.
    extra_pub_fonts, extra_pub_assets, extra_pub_shaders = build_pub_contributions(ctx, package_name, package_root)

    # `resources` names the non-Dart remainder of `lib/`; a Dart source there
    # is a mis-filed `srcs` entry, and identical paths with identical
    # extensions would otherwise collide silently. Mirrors `dart_library`.
    for f in ctx.files.resources:
        if f.extension == "dart":
            fail(
                ("%s: `%s` is a Dart source in `resources`. `resources` names " +
                 "the non-Dart remainder of `lib/`; Dart sources belong in " +
                 "`srcs`.") % (ctx.label, f.short_path),
            )

    return dict(
        plugins = plugins,
        native_libs = native_libs,
        binding_contracts = binding_contracts,
        native_lib_sources = native_lib_sources,
        apple_plugin_libraries = extra_apple_plugin_libraries,
        linux_plugin_libraries = extra_linux_plugin_libraries,
        windows_plugin_libraries = extra_windows_plugin_libraries,
        apple_privacy_manifests = extra_apple_privacy_manifests,
        native_assets = extra_native_assets,
        data_assets = extra_data_assets,
        pub_fonts = extra_pub_fonts,
        pub_assets = extra_pub_assets,
        pub_shaders = extra_pub_shaders,
        additional_licenses = own_additional_licenses(ctx, package_name),
        android_libs = extra_android_libs,
    )

def _flutter_plugin_impl(ctx):
    identity = package_identity(ctx)
    package_name = identity.package_name
    package_root = identity.package_root
    package = package_record(ctx.label, identity)

    # A plugin contributes on more channels than a library does, but the shape
    # is the same: name what this target adds, and let each constructor merge
    # the dependencies. `shader_srcs`, the framework's own shaders, is absent
    # here — only `package:flutter` has them — which is a thing the caller
    # simply does not say, rather than something the merge has to probe for.
    return [
        DefaultInfo(files = depset(ctx.files.srcs + ctx.files.resources)),
        dart_info(
            label = ctx.label,
            packages = [package],
            deps = ctx.attr.deps,
            srcs = ctx.files.srcs,
            resources = ctx.files.resources,
        ),
        flutter_analyzable_info(ctx, package),
        flutter_info(
            deps = ctx.attr.deps,
            **plugin_contributions(ctx, package_name, package_root, True)
        ),
    ]

# The attributes of a plugin that describe the package itself, which the member
# of a generated pub package (`flutter_pub_member`) takes too. The rest of
# `flutter_plugin`'s are `deps` and `_sky_engine`: what a dependency cycle's
# library states once for all of its members.
PLUGIN_PACKAGE_ATTRS = {
    "srcs": attr.label_list(
        doc = "Dart source files for the plugin's public API.",
        allow_files = [".dart"],
    ),
    "resources": attr.label_list(
        doc = "Non-Dart files this package ships inside `lib/` — part of its published surface, but never compiled (a web plugin's bundled JS/wasm, templates, YAML). Anything under `lib/` is addressable as `package:<name>/<path>` whatever its extension, so these are members of the package: they ride `DartInfo.transitive_resources` and are staged wherever the whole package is staged, mirroring `dart_library`. Orthogonal to `assets`/`shaders`/`font_files`, which name flutter_assets bundle contributions. `.dart` files belong in `srcs`.",
        allow_files = True,
    ),
    "assets": attr.label_list(
        doc = "Asset files to include: any file of this target's Dart package, keyed as `flutter_library.assets` is.",
        allow_files = True,
    ),
    "package": package_attr(LIBRARY_PACKAGE_DOC),
    "additional_licenses": ADDITIONAL_LICENSES_ATTR,
    "platforms": attr.string_list(
        doc = "Platforms this plugin supports (android, ios, macos, linux, windows, web).",
    ),
    "plugin_class": attr.string(
        doc = "Native plugin class name (for platform channel registration).",
    ),
    "android_package": attr.string(
        doc = "Java package of the Android `plugin_class`, as " +
              "`flutter.plugin.platforms.android.package` in a pubspec. " +
              "Required when `platforms` lists android with a " +
              "`plugin_class`. Its Kotlin/Java is a " +
              "`flutter_android_plugin_library` listed in `exports`.",
    ),
    "dart_plugin_class": attr.string(
        doc = "Dart-only plugin class name (for Dart-side registration).",
    ),
    "plugin_platforms_json": attr.string(
        doc = "JSON-encoded per-platform metadata dict. Overrides platforms/plugin_class/dart_plugin_class if set.",
    ),
    "native_deps": attr.label_list(
        doc = "Native dependencies. Use select() for platform-conditional deps.",
        aspects = [native_sources_aspect],
    ),
    "exports": attr.label_list(
        doc = "The plugin's Android libraries: a `flutter_android_plugin_library` or a `kt_android_library`, anything with `JavaInfo`. An Android app links the libraries of the plugins it depends on, and no others. Set this with `select()` on `@platforms//os:android`, with an empty list as the default, so that only an Android build loads and analyses it: `select({\"@platforms//os:android\": [\"//android:lib\"], \"//conditions:default\": []})`. Named `exports`, as a Java library's re-exported dependencies are, because rules_android dexes an APK's libraries one at a time by an aspect that follows `deps`, `exports` and `runtime_deps` and nothing else, so only an `exports` edge makes the library visible to it.",
        providers = [JavaInfo],
    ),
    "apple_libs": attr.label_list(
        doc = "Per-platform Apple swift_library targets (typically `flutter_apple_plugin_library`s) carrying the plugin's macOS / iOS native code. Each label's name must contain `macos` or `ios` so the runner aggregator can route it. Set this via `select()` on the target platform so only one platform's swift_library analyzes per build — both with the same module name in the same configuration would conflict on the produced `<module>.swiftmodule` output. A generated pub package may name a `flutter_unbuilt_plugin_library` instead, which fails the build of that platform (see `unbuilt_native_code.bzl`), or a `flutter_swiftpm_app_library`, which stands for a library each app builds for itself (see `swiftpm_app_settings.bzl`).",
        providers = [[CcInfo], [FlutterUnbuiltNativeCodeInfo], [FlutterSwiftPMAppLibraryInfo]],
        # The libraries' resources, as an app's bundling collects them from
        # its own dependencies: the runner links the libraries through the
        # aggregator, which carries them on (`flutter_apple_plugins_aggregator`).
        aspects = [apple_resource_aspect],
    ),
    "linux_libs": attr.label_list(
        doc = "Linux plugin source bundles (`flutter_linux_plugin_library`). Propagated through `FlutterInfo.linux_plugin_libraries` so the Linux runner folds them into its `cc_common.compile()` pass. A generated pub package may name a `flutter_unbuilt_plugin_library` instead, which fails the Linux runner.",
        providers = [[FlutterLinuxPluginInfo], [FlutterUnbuiltNativeCodeInfo]],
    ),
    "windows_libs": attr.label_list(
        doc = "Windows plugin source bundles (`flutter_windows_plugin_library`). Propagated through `FlutterInfo.windows_plugin_libraries` so the Windows runner folds them into its `cc_common.compile()` pass. A generated pub package may name a `flutter_unbuilt_plugin_library` instead, which fails the Windows runner.",
        providers = [[FlutterWindowsPluginInfo], [FlutterUnbuiltNativeCodeInfo]],
    ),
    "native_assets": attr.label_list(
        doc = "Native Assets `CodeAsset` declarations (each a `flutter_native_asset` target). Propagated through `FlutterInfo.native_assets` and aggregated by `flutter_application` into the `--native-assets` manifest. Declare per-platform asset sets with `select()`: this is what routes each asset to the applications built for its platform, and listing two targets with the same `asset_id` in one configuration fails analysis.",
        providers = [FlutterNativeAssetInfo],
    ),
    "data_assets": attr.label_list(
        doc = "Native Assets `DataAsset` declarations (each a `flutter_data_asset` target). Propagated through `FlutterInfo.data_assets` and bundled at `flutter_assets/packages/<pkg>/<name>` by `flutter_application`.",
        providers = [FlutterDataAssetInfo],
    ),
    "apple_privacy_files": attr.label_list(
        doc = "`PrivacyInfo.xcprivacy` files this plugin contributes to the iOS / macOS app bundle. Apple requires every framework to ship a privacy manifest since iOS 17.4 / macOS 14.4; the App Store submission validator walks the bundle and aggregates them. Propagated through `FlutterInfo.apple_privacy_manifests` and threaded into the platform application bundle's `Resources/<pkg>/PrivacyInfo.xcprivacy` slot. Auto-detected by `flutter_pub_package` from both layouts pub plugins use (`Sources/<pkg>/PrivacyInfo.xcprivacy` and `Sources/<pkg>/Resources/PrivacyInfo.xcprivacy`).",
        allow_files = [".xcprivacy"],
    ),
    "fonts_json": attr.string(
        doc = "JSON-encoded list of font-family declarations (mirrors `flutter.fonts` in pubspec.yaml). Same shape as `flutter_library.fonts_json`.",
        default = "",
    ),
    "font_files": attr.label_keyed_string_dict(
        doc = "Map of font File label -> package-relative asset path. Same shape as `flutter_library.font_files`.",
        allow_files = True,
    ),
    "asset_platforms": ASSET_PLATFORMS_ATTR,
    "shader_platforms": SHADER_PLATFORMS_ATTR,
    "asset_flavors": ASSET_FLAVORS_ATTR,
    "shader_flavors": SHADER_FLAVORS_ATTR,
    "shader_includes": attr.label_list(
        doc = "Files this package's `shaders` may `#include` (e.g. " +
              "`glob([\"shaders/**/*.glsl\"])`). A shader compiles in a " +
              "sandbox holding only its declared inputs, so an include " +
              "not listed here is not found.",
        allow_files = True,
    ),
    "shaders": attr.label_list(
        doc = "The package's fragment shaders, mirroring `flutter: shaders:`: any file of this target's Dart package, keyed as `flutter_library.shaders` is.",
        allow_files = True,
    ),
}

flutter_plugin = rule(
    implementation = _flutter_plugin_impl,
    # As `flutter_library`: configured once per web compiler that reaches it,
    # unless `web_compiler_independent`.
    cfg = web_compiler_reset_when_independent,
    attrs = PLUGIN_PACKAGE_ATTRS | {
        "_sky_engine": SKY_ENGINE_ATTR,
        "deps": attr.label_list(
            doc = "Dart/Flutter library dependencies.",
            providers = [DartInfo],
        ),
    } | WEB_COMPILER_INDEPENDENT_ATTR,
    doc = "Declares a Flutter plugin with platform metadata and optional native dependencies.",
)
