"""Flutter plugin rule.

Declares a Flutter plugin: its Dart code, and a `flutter_plugin_platform` for
each platform it registers on, holding that platform's registration and native
library:

    flutter_plugin_platform(
        name = "linux",
        platform = "linux",
        plugin_class = "UrlLauncherPlugin",
        lib = ":url_launcher_linux",
    )

    flutter_plugin(
        name = "url_launcher",
        srcs = glob(["lib/**/*.dart"]),
        platforms = [":linux"],
    )
"""

load("@build_bazel_rules_swift//swift:swift.bzl", "SwiftInfo")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_dart//dart:providers.bzl", "DartInfo")
load("@rules_dart//dart:utils.bzl", "WEB_COMPILER_INDEPENDENT_ATTR", "dart_info", "library_package", "package_identity_attrs", "web_compiler_reset_when_independent")
load("@rules_java//java/common:java_info.bzl", "JavaInfo")
load("//flutter:providers.bzl", "FlutterDataAssetInfo", "FlutterInfo", "FlutterNativeAssetInfo", "FlutterPluginPlatformInfo")
load("//flutter/private:common.bzl", "collect_binding_contracts", "collect_native_libs")
load("//flutter/private:flutter_desktop_plugin_info.bzl", "FlutterLinuxPluginInfo", "FlutterWindowsPluginInfo")
load("//flutter/private:flutter_font.bzl", "FONTS_ATTR")
load("//flutter/private:flutter_info.bzl", "flutter_info")
load("//flutter/private:flutter_library.bzl", "ADDITIONAL_LICENSES_ATTR", "ASSET_FLAVORS_ATTR", "ASSET_PLATFORMS_ATTR", "SHADER_FLAVORS_ATTR", "SHADER_PLATFORMS_ATTR", "SKY_ENGINE_ATTR", "build_pub_contributions", "flutter_analyzable_info", "own_additional_licenses")
load("//flutter/private:flutter_plugin_platform.bzl", "apple_resource_info", "plugin_platforms_of")
load("//flutter/private:native_sources.bzl", "collect_native_source_pairs", "native_sources_aspect")
load("//flutter/private:swiftpm_app_settings.bzl", "FlutterSwiftPMAppLibraryInfo")
load("//flutter/private:unbuilt_native_code.bzl", "FlutterUnbuiltNativeCodeInfo")

def build_plugin_struct(name, plugin_platforms):
    """Build a plugin metadata struct from per-platform metadata.

    Args:
        name: Plugin package name.
        plugin_platforms: Dict of platform -> FlutterPluginPlatformInfo.

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

    platforms = plugin_platforms_of(ctx.label, ctx.attr.platforms)
    plugins = [build_plugin_struct(
        name = package_name,
        plugin_platforms = platforms,
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

    # Each platform's native library, which `flutter_plugin_platform` gives
    # only to a build for that platform: the iOS and macOS libraries of one
    # plugin share a module name, and analysed in one configuration they
    # would collide on `<module>.swiftmodule`. The runner aggregator merges
    # the Apple ones' CcInfo + SwiftInfo into the runner's compile and link;
    # the Linux and Windows runners fold the desktop ones into theirs.
    extra_apple_plugin_libraries = []
    extra_linux_plugin_libraries = []
    extra_windows_plugin_libraries = []
    for platform_name in sorted(platforms):
        lib = platforms[platform_name].lib
        if lib == None:
            continue
        if platform_name in ("ios", "macos"):
            extra_apple_plugin_libraries.append(struct(
                platform = platform_name,
                label = lib.label,
                cc_info = lib[CcInfo] if CcInfo in lib else None,
                swift_info = lib[SwiftInfo] if SwiftInfo in lib else None,
                # The library's resources (a Swift package target's resource
                # bundle), for the app's bundle.
                resource_info = apple_resource_info(lib),
                unbuilt_native_code = _unbuilt_native_code(lib),
                package = package_name,
                # A library its Package.swift gives defines from the app, which
                # the app's aggregator builds for itself (`swiftpm_app_settings.bzl`).
                app_library = lib[FlutterSwiftPMAppLibraryInfo].library if FlutterSwiftPMAppLibraryInfo in lib else None,
            ))
            continue
        desktop = extra_linux_plugin_libraries if platform_name == "linux" else extra_windows_plugin_libraries
        if FlutterUnbuiltNativeCodeInfo in lib:
            desktop.append(_unbuilt_desktop_entry(lib, package_name))
            continue
        info = lib[FlutterLinuxPluginInfo] if platform_name == "linux" else lib[FlutterWindowsPluginInfo]
        desktop.append(struct(
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
    declared = library_package(ctx, ctx.files.srcs, ctx.files.resources)
    package_name = declared.package_name
    package_root = declared.package_root
    package = declared.record

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
PLUGIN_PACKAGE_ATTRS = package_identity_attrs() | {
    "srcs": attr.label_list(
        doc = "Dart source files for the plugin's public API.",
        allow_files = [".dart"],
    ),
    "resources": attr.label_list(
        doc = "Non-Dart files this package ships inside `lib/` — part of its published surface, but never compiled (a web plugin's bundled JS/wasm, templates, YAML). Anything under `lib/` is addressable as `package:<name>/<path>` whatever its extension, so these are members of the package: they ride `DartInfo.transitive_resources` and are staged wherever the whole package is staged, mirroring `dart_library`. Orthogonal to `assets`/`shaders`/`fonts`, which name flutter_assets bundle contributions. `.dart` files belong in `srcs`.",
        allow_files = True,
    ),
    "assets": attr.label_list(
        doc = "Asset files to include: any file of this target's Dart package, keyed as `flutter_library.assets` is.",
        allow_files = True,
    ),
    "additional_licenses": ADDITIONAL_LICENSES_ATTR,
    "platforms": attr.label_list(
        doc = "The platforms the plugin registers on: a `flutter_plugin_platform` for each, holding that platform's registration and native library, as the entries of a pubspec's `flutter: plugin: platforms:`.",
        providers = [FlutterPluginPlatformInfo],
    ),
    "native_deps": attr.label_list(
        doc = "Native dependencies. Use select() for platform-conditional deps.",
        aspects = [native_sources_aspect],
    ),
    "exports": attr.label_list(
        doc = "The plugin's Android libraries: a `flutter_android_plugin_library` or a `kt_android_library`, anything with `JavaInfo`. Its registration is the `android` entry of `platforms`. An Android app links the libraries of the plugins it depends on, and no others. Set this with `select()` on `@platforms//os:android`, with an empty list as the default, so that only an Android build loads and analyses it: `select({\"@platforms//os:android\": [\"//android:lib\"], \"//conditions:default\": []})`. Named `exports`, as a Java library's re-exported dependencies are, because rules_android dexes an APK's libraries one at a time by an aspect that follows `deps`, `exports` and `runtime_deps` and nothing else, so only an `exports` edge makes the library visible to it.",
        providers = [JavaInfo],
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
    "fonts": FONTS_ATTR,
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
