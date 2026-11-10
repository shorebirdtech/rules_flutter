"""Public Tier-2 surface for Flutter Native Assets.

Assets are rules_dart's: a `dart_code_asset` or a `dart_data_asset` from
`@rules_dart//dart:defs.bzl` (also re-exported from
`@rules_flutter//flutter:defs.bzl`), named in a package's
`dart_package_metadata(code_assets = ..., data_assets = ...)`, or a code asset
in a program's own `code_assets`. This file exports what is Flutter's own: a
standalone view of an application's native-assets manifest.
"""

load(
    "//flutter/private:flutter_native_assets.bzl",
    _flutter_native_assets_manifest = "flutter_native_assets_manifest",
)

flutter_native_assets_manifest = _flutter_native_assets_manifest
