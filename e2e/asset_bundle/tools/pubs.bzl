"""Repositories for the fixture packages, as `flutter.pub` would make them.

Each package is the three repositories `flutter.pub` makes of a built package:
its source, its library and the hub's index. `MODULE.bazel` names the library
of each, which is what an application depends on.
"""

# The repository rules `flutter.pub` makes a package's repositories with, loaded
# to make our own: there is no public name for them.
# buildifier: disable=bzl-visibility
load("@rules_flutter//flutter/private:flutter_pub_index.bzl", "flutter_pub_index", "index_repo", "library_repo", "source_repo")

# buildifier: disable=bzl-visibility
load("@rules_flutter//flutter/private:flutter_pub_library_repo.bzl", "flutter_pub_library_repo")

# buildifier: disable=bzl-visibility
load("@rules_flutter//flutter/private:flutter_pub_package.bzl", "flutter_pub_package")

_HUB = "fixture"

# The packages under `//registry`, with the version of each.
PACKAGES = {
    "fx_dirs": "1.0.0",
    "fx_extra": "1.0.0",
    "fx_flavors": "1.0.0",
    "fx_font_borrower": "1.0.0",
    "fx_font_owner": "1.0.0",
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
    flutter_pub_index(
        name = index_repo(_HUB),
        built = sorted(PACKAGES.keys()),
        other = [],
    )
    for name, version in PACKAGES.items():
        flutter_pub_package(
            name = source_repo(_HUB, name),
            package_name = name,
            version = version,
            sha256 = checksums[name],
            base_url = "file://" + str(registry),
            hub_name = _HUB,
        )
        flutter_pub_library_repo(
            name = library_repo(_HUB, name),
            package_name = name,
            hub_name = _HUB,
        )
    return mctx.extension_metadata(reproducible = True)

fixture_pubs = module_extension(
    implementation = _pubs_impl,
)
