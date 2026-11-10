"""Public Tier-2 surface for Flutter Native Assets.

Code assets are rules_dart's: a `dart_code_asset` from `@rules_dart//dart:defs.bzl`,
named in a package's `dart_package_metadata(code_assets = ...)` or in a
program's own `code_assets`. This file re-exports what is Flutter's own: the
data-asset marker used by `ext/<pkg>/<major>/BUILD.bazel.tpl` overlays and by
monorepo plugins, and a standalone view of an application's manifest.

    load("@rules_flutter//flutter:native_assets.bzl", "flutter_data_asset")

    flutter_data_asset(
        name = "blob",
        asset_id = "package:pkg/blob.bin",
        file = "data/blob.bin",
    )
"""

load(
    "//flutter/private:flutter_data_asset.bzl",
    _flutter_data_asset = "flutter_data_asset",
)
load(
    "//flutter/private:flutter_native_assets.bzl",
    _flutter_native_assets_manifest = "flutter_native_assets_manifest",
)

flutter_data_asset = _flutter_data_asset
flutter_native_assets_manifest = _flutter_native_assets_manifest
