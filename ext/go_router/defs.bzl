"""`go_router_codegen`: go_router_builder's routes for `@TypedGoRoute` classes.

    load("@rules_flutter//ext/go_router:defs.bzl", "go_router_codegen")

    go_router_codegen(
        name = "routes",
        srcs = ["lib/routes.dart"],
        package = ":pubspec",
        deps = ["@pub_deps//:flutter"],
    )

    flutter_application(
        name = "app",
        srcs = ["lib/routes.dart", ":routes"],
        package = ":pubspec",
        deps = ["@pub_deps//:flutter", "@pub_deps//:go_router"],
        ...
    )

`lib/routes.dart` declares `part 'routes.g.dart';`, which `:routes` writes, as
`dart run build_runner build` would.
"""

load("@rules_dart//dart/ext:defs.bzl", "shared_part_codegen")

def go_router_codegen(
        name,
        srcs,
        deps = [],
        asset_deps = [],
        annotation_dep = "@pub_deps//:go_router",
        config = "",
        **kwargs):
    """go_router_builder's `<src>.g.dart` for each of `srcs`, for their library's `srcs`.

    Args:
      name: The filegroup of the generated parts.
      srcs: `.dart` sources carrying `@TypedGoRoute`.
      deps: The libraries of other packages the sources import.
      asset_deps: The files of the sources' own package they import.
      annotation_dep: The library of `package:go_router`, added to `deps`.
      config: Builder options as a JSON string, as in `build.yaml`.
      **kwargs: `package`, and the filegroup's `visibility`, `tags`
        and `testonly`.
    """
    shared_part_codegen(
        name = name,
        srcs = srcs,
        shim = Label("//ext/go_router:shim"),
        part_suffix = ".go_router.g.part",
        annotation_dep = annotation_dep,
        deps = deps,
        asset_deps = asset_deps,
        config = config,
        **kwargs
    )
