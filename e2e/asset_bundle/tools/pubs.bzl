"""Spoke repositories for the fixture packages, as `flutter.pub` would make them."""

# The repository rule `flutter.pub` makes a spoke with, loaded to make one of
# our own: there is no public name for it.
# buildifier: disable=bzl-visibility
load("@rules_flutter//flutter/private:flutter_pub_package.bzl", "flutter_pub_package")

# The packages under `//registry`, with the version of each.
PACKAGES = {
    "fx_dirs": "1.0.0",
    "fx_flavors": "1.0.0",
    "fx_names": "1.0.0",
    "fx_platforms": "1.0.0",
    "fx_shader_flavors": "1.0.0",
    "fx_shaders": "1.0.0",
    "fx_variants": "1.0.0",
}

def _pubs_impl(mctx):
    # Resolving a label into the registry fetches it, which is what makes its
    # directory exist to be named in a URL.
    registry = mctx.path(Label("@pub_registry//:registry")).dirname
    checksums = json.decode(mctx.read(Label("@pub_registry//:checksums.json")))
    for name, version in PACKAGES.items():
        flutter_pub_package(
            name = name,
            package_name = name,
            version = version,
            sha256 = checksums[name],
            base_url = "file://" + str(registry),
            hub_name = "fixture",
        )
    return mctx.extension_metadata(reproducible = True)

fixture_pubs = module_extension(
    implementation = _pubs_impl,
)
