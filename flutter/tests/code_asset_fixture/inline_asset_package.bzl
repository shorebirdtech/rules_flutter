"""A Dart package rule that makes its code asset itself, as no target of its own.

The package's `DartInfo` carries the `DartCodeAssetInfo` of a target the rule
takes as a tool, so the application bundles the library, and no target
anywhere below the package provides the asset for a walk of the build graph to
find. This is the
shape a build cannot describe: nothing says what the library is built from.
"""

load("@rules_dart//dart:providers.bzl", "DartCodeAssetInfo", "DartInfo", "DartPackageInfo")

def _inline_asset_package_impl(ctx):
    pkg = DartPackageInfo(
        label = ctx.label,
        package_name = ctx.attr.package_name,
        package_root = ctx.label.package,
        language_version = "",
        code_assets = [ctx.attr.code_asset],
    )
    return [DartInfo(
        packages = (pkg,),
        transitive_srcs = depset(),
        transitive_resources = depset(),
        transitive_packages = depset([pkg]),
    )]

inline_asset_package = rule(
    implementation = _inline_asset_package_impl,
    attrs = {
        # A tool dependency, so the aspect that walks an application's graph
        # for code assets does not follow it: the record holds the asset, and
        # no target anywhere below the package provides it.
        "code_asset": attr.label(
            mandatory = True,
            cfg = "exec",
            providers = [DartCodeAssetInfo],
        ),
        "package_name": attr.string(mandatory = True),
    },
)
