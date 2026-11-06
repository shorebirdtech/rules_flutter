"""Unit tests for the projection of a pubspec's `flutter:` block (flutter_pubspec.bzl).

The inputs are `fields` dicts, as rules_dart's `read_pubspec` returns them:
the pubspec document as JSON values. Reading a pubspec (YAML, and pub's own
refusals) is `read_pubspec`'s, and is tested where a repository rule runs it:
`tools/dev_tool/test/e2e/pubspec_reading_e2e_test.dart`.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//flutter/private:flutter_pubspec.bzl",
    "flutter_assets_block",
    "flutter_block",
    "flutter_licenses_block",
    "flutter_plugin_block",
)

# Federated umbrella: only default_package per platform, no plugin classes
# (path_provider).
_PATH_PROVIDER = {
    "name": "path_provider",
    "version": "2.1.5",
    "environment": {"sdk": "^3.0.0"},
    "flutter": {
        "plugin": {
            "platforms": {
                "android": {"default_package": "path_provider_android"},
                "ios": {"default_package": "path_provider_foundation"},
                "linux": {"default_package": "path_provider_linux"},
                "macos": {"default_package": "path_provider_foundation"},
                "windows": {"default_package": "path_provider_windows"},
            },
        },
    },
    "dependencies": {"flutter": {"sdk": "flutter"}},
}

# Federated implementation: implements + dartPluginClass on its platform
# (path_provider_foundation).
_PATH_PROVIDER_FOUNDATION = {
    "name": "path_provider_foundation",
    "flutter": {
        "plugin": {
            "implements": "path_provider",
            "platforms": {
                "ios": {"dartPluginClass": "PathProviderFoundation"},
                "macos": {"dartPluginClass": "PathProviderFoundation"},
            },
        },
    },
    "dependencies": {"flutter": {"sdk": "flutter"}},
}

# Monolithic plugin: direct platforms with pluginClass / dartPluginClass /
# package / fileName, no implements/default_package (package_info_plus).
_PACKAGE_INFO_PLUS = {
    "name": "package_info_plus",
    "flutter": {
        "plugin": {
            "platforms": {
                "android": {
                    "package": "dev.fluttercommunity.plus.packageinfo",
                    "pluginClass": "PackageInfoPlugin",
                },
                "ios": {"pluginClass": "FPPPackageInfoPlusPlugin"},
                "linux": {"dartPluginClass": "PackageInfoPlusLinuxPlugin"},
                "macos": {"pluginClass": "FPPPackageInfoPlusPlugin"},
                "web": {
                    "pluginClass": "PackageInfoPlusWebPlugin",
                    "fileName": "src/package_info_plus_web.dart",
                },
                "windows": {"dartPluginClass": "PackageInfoPlusWindowsPlugin"},
            },
        },
    },
}

# Federated impl with both pluginClass and dartPluginClass + fileName
# (url_launcher_macos).
_URL_LAUNCHER_MACOS = {
    "name": "url_launcher_macos",
    "flutter": {
        "plugin": {
            "implements": "url_launcher",
            "platforms": {
                "macos": {
                    "pluginClass": "UrlLauncherPlugin",
                    "fileName": "url_launcher_macos.dart",
                    "dartPluginClass": "UrlLauncherMacOS",
                },
            },
        },
    },
}

# Non-plugin package (path_provider_platform_interface).
_NO_PLUGIN = {
    "name": "path_provider_platform_interface",
    "dependencies": {
        "flutter": {"sdk": "flutter"},
        "plugin_platform_interface": "^2.1.0",
    },
}

# cupertino_icons: flutter.fonts only.
_CUPERTINO_ICONS = {
    "name": "cupertino_icons",
    "version": "1.0.9",
    "flutter": {
        "fonts": [{
            "family": "CupertinoIcons",
            "fonts": [{"asset": "assets/CupertinoIcons.ttf"}],
        }],
    },
}

# Hypothetical font with weight + style attributes.
_FONT_WITH_VARIANTS = {
    "name": "example",
    "flutter": {
        "fonts": [{
            "family": "Roboto",
            "fonts": [
                {"asset": "fonts/Roboto-Regular.ttf"},
                {"asset": "fonts/Roboto-Bold.ttf", "weight": 700},
                {"asset": "fonts/Roboto-Italic.ttf", "weight": 400, "style": "italic"},
            ],
        }],
    },
}

# Asset-shipping package (flutter_localized_locales-style).
_LOCALES = {
    "name": "flutter_localized_locales",
    "flutter": {"assets": ["data/"]},
}

# Modern map-form assets with flavors + platforms.
_MAP_FORM_ASSETS = {
    "name": "example",
    "flutter": {
        "assets": [
            {
                "path": "assets/foo.png",
                "flavors": ["prod"],
                "platforms": ["ios", "android"],
            },
            "assets/bar.png",
        ],
    },
}

# Shaders + material design flag.
_MATERIAL_AND_SHADERS = {
    "name": "example",
    "flutter": {
        "uses-material-design": True,
        "shaders": [
            "shaders/ink_sparkle.frag",
            {"path": "shaders/web_only.frag", "platforms": ["web"]},
            {"path": "shaders/paid.frag", "flavors": ["paid", "premium"]},
        ],
    },
}

# ---------------------------------------------------------------------------
# flutter_plugin_block
# ---------------------------------------------------------------------------

def _umbrella_default_package_test_impl(ctx):
    env = unittest.begin(ctx)
    result = flutter_plugin_block(_PATH_PROVIDER)
    asserts.true(env, result.present)
    asserts.equals(env, "", result.implements)
    asserts.equals(env, False, result.ffi_plugin)
    asserts.equals(env, 5, len(result.platforms))
    asserts.equals(env, "path_provider_android", result.platforms["android"]["default_package"])
    asserts.equals(env, "path_provider_foundation", result.platforms["macos"]["default_package"])
    asserts.equals(env, "path_provider_windows", result.platforms["windows"]["default_package"])

    asserts.true(env, "pluginClass" not in result.platforms["macos"])
    asserts.true(env, "dartPluginClass" not in result.platforms["macos"])
    return unittest.end(env)

def _federated_impl_test_impl(ctx):
    env = unittest.begin(ctx)
    result = flutter_plugin_block(_PATH_PROVIDER_FOUNDATION)
    asserts.true(env, result.present)
    asserts.equals(env, "path_provider", result.implements)
    asserts.equals(env, 2, len(result.platforms))
    asserts.equals(env, "PathProviderFoundation", result.platforms["macos"]["dartPluginClass"])
    asserts.equals(env, "PathProviderFoundation", result.platforms["ios"]["dartPluginClass"])

    asserts.true(env, "default_package" not in result.platforms["macos"])
    return unittest.end(env)

def _monolithic_plugin_test_impl(ctx):
    env = unittest.begin(ctx)
    result = flutter_plugin_block(_PACKAGE_INFO_PLUS)
    asserts.true(env, result.present)
    asserts.equals(env, "", result.implements)
    asserts.equals(env, 6, len(result.platforms))

    asserts.equals(env, "dev.fluttercommunity.plus.packageinfo", result.platforms["android"]["package"])
    asserts.equals(env, "PackageInfoPlugin", result.platforms["android"]["pluginClass"])

    asserts.equals(env, "FPPPackageInfoPlusPlugin", result.platforms["ios"]["pluginClass"])

    asserts.equals(env, "PackageInfoPlusLinuxPlugin", result.platforms["linux"]["dartPluginClass"])
    asserts.equals(env, "PackageInfoPlusWindowsPlugin", result.platforms["windows"]["dartPluginClass"])

    asserts.equals(env, "PackageInfoPlusWebPlugin", result.platforms["web"]["pluginClass"])
    asserts.equals(env, "src/package_info_plus_web.dart", result.platforms["web"]["fileName"])
    return unittest.end(env)

def _impl_with_filename_test_impl(ctx):
    env = unittest.begin(ctx)
    result = flutter_plugin_block(_URL_LAUNCHER_MACOS)
    asserts.true(env, result.present)
    asserts.equals(env, "url_launcher", result.implements)
    macos = result.platforms["macos"]
    asserts.equals(env, "UrlLauncherPlugin", macos["pluginClass"])
    asserts.equals(env, "url_launcher_macos.dart", macos["fileName"])
    asserts.equals(env, "UrlLauncherMacOS", macos["dartPluginClass"])
    return unittest.end(env)

def _no_plugin_block_test_impl(ctx):
    env = unittest.begin(ctx)
    result = flutter_plugin_block(_NO_PLUGIN)
    asserts.equals(env, False, result.present)
    asserts.equals(env, 0, len(result.platforms))
    asserts.equals(env, "", result.implements)
    return unittest.end(env)

def _empty_pubspec_test_impl(ctx):
    env = unittest.begin(ctx)
    result = flutter_plugin_block({})
    asserts.equals(env, False, result.present)
    asserts.equals(env, 0, len(result.platforms))
    return unittest.end(env)

# ---------------------------------------------------------------------------
# flutter_assets_block
# ---------------------------------------------------------------------------

def _cupertino_fonts_test_impl(ctx):
    env = unittest.begin(ctx)
    result = flutter_assets_block(_CUPERTINO_ICONS)
    asserts.equals(env, 1, len(result.fonts))
    asserts.equals(env, "CupertinoIcons", result.fonts[0].family)
    asserts.equals(env, 1, len(result.fonts[0].fonts))
    asserts.equals(env, "assets/CupertinoIcons.ttf", result.fonts[0].fonts[0].asset)
    asserts.equals(env, None, result.fonts[0].fonts[0].weight)
    asserts.equals(env, None, result.fonts[0].fonts[0].style)
    asserts.equals(env, [], result.assets)
    asserts.equals(env, [], result.shaders)
    asserts.equals(env, False, result.uses_material_design)
    return unittest.end(env)

def _font_variants_test_impl(ctx):
    env = unittest.begin(ctx)
    result = flutter_assets_block(_FONT_WITH_VARIANTS)
    asserts.equals(env, 1, len(result.fonts))
    family = result.fonts[0]
    asserts.equals(env, "Roboto", family.family)
    asserts.equals(env, 3, len(family.fonts))

    asserts.equals(env, "fonts/Roboto-Regular.ttf", family.fonts[0].asset)
    asserts.equals(env, None, family.fonts[0].weight)
    asserts.equals(env, None, family.fonts[0].style)

    asserts.equals(env, "fonts/Roboto-Bold.ttf", family.fonts[1].asset)
    asserts.equals(env, 700, family.fonts[1].weight)
    asserts.equals(env, None, family.fonts[1].style)

    asserts.equals(env, "fonts/Roboto-Italic.ttf", family.fonts[2].asset)
    asserts.equals(env, 400, family.fonts[2].weight)
    asserts.equals(env, "italic", family.fonts[2].style)
    return unittest.end(env)

def _string_assets_test_impl(ctx):
    env = unittest.begin(ctx)
    result = flutter_assets_block(_LOCALES)
    asserts.equals(env, 1, len(result.assets))
    asserts.equals(env, "data/", result.assets[0].path)
    asserts.equals(env, [], result.assets[0].flavors)
    asserts.equals(env, [], result.assets[0].platforms)
    return unittest.end(env)

def _map_assets_test_impl(ctx):
    env = unittest.begin(ctx)
    result = flutter_assets_block(_MAP_FORM_ASSETS)
    asserts.equals(env, 2, len(result.assets))

    asserts.equals(env, "assets/foo.png", result.assets[0].path)
    asserts.equals(env, ["prod"], result.assets[0].flavors)
    asserts.equals(env, ["ios", "android"], result.assets[0].platforms)

    asserts.equals(env, "assets/bar.png", result.assets[1].path)
    asserts.equals(env, [], result.assets[1].flavors)
    asserts.equals(env, [], result.assets[1].platforms)
    return unittest.end(env)

def _shaders_and_material_test_impl(ctx):
    env = unittest.begin(ctx)
    result = flutter_assets_block(_MATERIAL_AND_SHADERS)
    asserts.equals(env, True, result.uses_material_design)
    asserts.equals(env, 3, len(result.shaders))
    asserts.equals(env, "shaders/ink_sparkle.frag", result.shaders[0].path)
    asserts.equals(env, [], result.shaders[0].platforms)
    asserts.equals(env, [], result.shaders[0].flavors)

    # The map form carries the restrictions flutter_tools applies to a shader
    # as it does to an asset.
    asserts.equals(env, ["web"], result.shaders[1].platforms)
    asserts.equals(env, ["paid", "premium"], result.shaders[2].flavors)
    return unittest.end(env)

def _empty_flutter_block_test_impl(ctx):
    env = unittest.begin(ctx)
    result = flutter_assets_block({"name": "foo"})
    asserts.equals(env, [], result.fonts)
    asserts.equals(env, [], result.assets)
    asserts.equals(env, [], result.shaders)
    asserts.equals(env, False, result.uses_material_design)
    return unittest.end(env)

# ---------------------------------------------------------------------------
# flutter_block
# ---------------------------------------------------------------------------

def _flutter_block_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, "plugin" in flutter_block(_PATH_PROVIDER))
    asserts.equals(env, {}, flutter_block({}))
    asserts.equals(env, {}, flutter_block(_NO_PLUGIN))

    # A `flutter:` that is not a mapping is no block.
    asserts.equals(env, {}, flutter_block({"flutter": None}))
    asserts.equals(env, {}, flutter_block({"flutter": ["plugin"]}))
    return unittest.end(env)

_t0_test = unittest.make(_umbrella_default_package_test_impl)
_t1_test = unittest.make(_federated_impl_test_impl)
_t2_test = unittest.make(_monolithic_plugin_test_impl)
_t3_test = unittest.make(_impl_with_filename_test_impl)
_t4_test = unittest.make(_no_plugin_block_test_impl)
_t5_test = unittest.make(_empty_pubspec_test_impl)
_t6_test = unittest.make(_cupertino_fonts_test_impl)
_t7_test = unittest.make(_font_variants_test_impl)
_t8_test = unittest.make(_string_assets_test_impl)
_t9_test = unittest.make(_map_assets_test_impl)
_t10_test = unittest.make(_shaders_and_material_test_impl)
_t11_test = unittest.make(_empty_flutter_block_test_impl)
_t12_test = unittest.make(_flutter_block_test_impl)

def _asset_transformers_test_impl(ctx):
    env = unittest.begin(ctx)
    assets = flutter_assets_block({
        "name": "p",
        "flutter": {
            "assets": [
                "assets/plain.txt",
                {"path": "assets/map.txt"},
                {
                    "path": "assets/svg.svg",
                    "transformers": [{
                        "package": "vector_graphics_compiler",
                        "args": ["--tessellate"],
                    }],
                },
            ],
        },
    }).assets
    asserts.equals(env, [False, False, True], [bool(a.transformers) for a in assets])
    return unittest.end(env)

_asset_transformers_test = unittest.make(_asset_transformers_test_impl)

# ---------------------------------------------------------------------------
# flutter_licenses_block
# ---------------------------------------------------------------------------

# A pubspec whose `flutter:` block has the `licenses:` key set to `value`. The
# key is pubspec's, not an attribute of a rule, which the linter takes it for.
def _pubspec_with_licenses(value):
    # buildifier: disable=attr-licenses
    return {"flutter": {"licenses": value}}

def _licenses_listed_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        ["THIRD_PARTY.txt", "licenses/other"],
        flutter_licenses_block(_pubspec_with_licenses(["THIRD_PARTY.txt", "licenses/other"])),
    )

    # An item that is not a string is taken as its text, as flutter_tools does.
    asserts.equals(env, ["7"], flutter_licenses_block(_pubspec_with_licenses([7])))
    return unittest.end(env)

_licenses_listed_test = unittest.make(_licenses_listed_test_impl)

def _licenses_absent_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, [], flutter_licenses_block({"name": "foo"}))
    asserts.equals(env, [], flutter_licenses_block({"flutter": {}}))
    asserts.equals(env, [], flutter_licenses_block(_pubspec_with_licenses("LICENSE")))
    return unittest.end(env)

_licenses_absent_test = unittest.make(_licenses_absent_test_impl)

def flutter_pubspec_test_suite(name):
    unittest.suite(
        name,
        _t0_test,
        _t1_test,
        _t2_test,
        _t3_test,
        _t4_test,
        _t5_test,
        _t6_test,
        _t7_test,
        _t8_test,
        _t9_test,
        _t10_test,
        _t11_test,
        _t12_test,
        _asset_transformers_test,
        _licenses_listed_test,
        _licenses_absent_test,
    )
